package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"strings"
)

// publicPaths are the only routes reachable without a token. /api/ping exists
// so a client can confirm it found the right server and learn whether a token
// is required before it starts sending one.
var publicPaths = map[string]bool{
	"/":         true,
	"/api/ping": true,
}

// principal is who a request speaks for.
//
// The distinction matters: the token in config.json is the owner — it can mint
// and revoke device tokens. A device token is just a key to the library and
// must not be able to create more keys, otherwise revoking one lost phone
// would be pointless.
type principal struct {
	// owner is true when the request authenticated with the config token.
	owner bool
	// tokenID is the api_tokens row for a device token, 0 for the owner.
	tokenID int64
}

type principalKey struct{}

func principalFrom(r *http.Request) principal {
	p, _ := r.Context().Value(principalKey{}).(principal)
	return p
}

// withAuth enforces the shared token.
//
// A home LAN is not a trusted network: guest Wi-Fi, shared flats and office
// networks all put other people on the same subnet. Without this check anyone
// who can reach the port can download every original photo, which would defeat
// the entire point of a private media server.
func (s *Server) withAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if publicPaths[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}

		p, ok := s.resolvePrincipal(extractToken(r))
		if !ok {
			writeErr(w, http.StatusUnauthorized, "invalid or missing token")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, p)))
	})
}

// ownerOnly rejects device tokens. Used for the routes that manage credentials.
func (s *Server) ownerOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !principalFrom(r).owner {
			writeErr(w, http.StatusForbidden, "only the owner token may manage device tokens")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// extractToken accepts the token from the standard Authorization header, from
// a custom header, or from a query parameter.
//
// The query parameter is not elegant, but plain <img src> and <video src>
// tags cannot attach headers, and the built-in status page relies on them.
func extractToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); h != "" {
		if len(h) > 7 && strings.EqualFold(h[:7], "Bearer ") {
			return strings.TrimSpace(h[7:])
		}
		return strings.TrimSpace(h)
	}
	if t := r.Header.Get("X-Token"); t != "" {
		return strings.TrimSpace(t)
	}
	return strings.TrimSpace(r.URL.Query().Get("token"))
}

// resolvePrincipal maps a presented token to who it belongs to.
func (s *Server) resolvePrincipal(candidate string) (principal, bool) {
	if candidate == "" {
		return principal{}, false
	}

	// The owner token is compared in constant time so it cannot be recovered
	// by measuring how long the comparison takes.
	if s.cfg.Token != "" &&
		subtle.ConstantTimeCompare([]byte(candidate), []byte(s.cfg.Token)) == 1 {
		return principal{owner: true}, true
	}

	// Device tokens are looked up by digest. A database read on every request
	// is deliberate: caching a revoked token for even a few seconds would mean
	// "I cut that phone off" is not immediately true.
	sum := sha256.Sum256([]byte(candidate))
	tok, found, err := s.st.TokenByHash(hex.EncodeToString(sum[:]))
	if err != nil || !found || tok.Revoked() {
		return principal{}, false
	}
	_ = s.st.TouchToken(tok.ID)
	return principal{tokenID: tok.ID}, true
}
