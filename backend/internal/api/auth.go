package api

import (
	"crypto/subtle"
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

		if !s.tokenOK(extractToken(r)) {
			writeErr(w, http.StatusUnauthorized, "invalid or missing token")
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

func (s *Server) tokenOK(candidate string) bool {
	if candidate == "" || s.cfg.Token == "" {
		return false
	}
	// Constant-time comparison so the token cannot be recovered by timing.
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(s.cfg.Token)) == 1
}
