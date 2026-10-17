package api

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

// Device tokens.
//
// One token per device, so losing a phone costs one revoke instead of rotating
// the credential every client shares. The config token remains the owner and is
// the only one that can manage this list.

// handleListTokens returns every device token, without the secrets.
func (s *Server) handleListTokens(w http.ResponseWriter, r *http.Request) {
	tokens, err := s.st.ListTokens()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": tokens})
}

// handleCreateToken mints a token and returns the plaintext exactly once.
//
// Only the digest is stored, so this response is the only moment the value
// exists in readable form. Losing it means creating another token, which is
// the correct trade: a server that can re-show tokens is a server whose
// database is enough to impersonate every client.
func (s *Server) handleCreateToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		name = "未命名设备"
	}
	if len([]rune(name)) > 60 {
		name = string([]rune(name)[:60])
	}

	plain, hash, err := newDeviceToken()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "generate token failed")
		return
	}

	tok, err := s.st.CreateToken(name, hash)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":         tok.ID,
		"name":       tok.Name,
		"created_at": tok.CreatedAt,
		"token":      plain,
	})
}

// handleRevokeToken cuts a device off. Idempotent: revoking twice is fine.
func (s *Server) handleRevokeToken(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, "invalid token id")
		return
	}

	if err := s.st.RevokeToken(id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeErr(w, http.StatusNotFound, "token not found")
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// newDeviceToken returns a fresh plaintext token and its stored digest.
//
// 32 random bytes, base64url encoded: 43 characters, no padding, no characters
// that need escaping in a URL or a shell. The entropy is the point — a token
// that can be guessed is worse than no token, because it looks like security.
func newDeviceToken() (plain, hash string, err error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", "", err
	}
	plain = base64.RawURLEncoding.EncodeToString(b)
	sum := sha256.Sum256([]byte(plain))
	return plain, hex.EncodeToString(sum[:]), nil
}
