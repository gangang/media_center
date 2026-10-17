package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"mediacenter/internal/config"
	"mediacenter/internal/store"
)

// Tests for the device-token surface.
//
// These run the real middleware chain against a real SQLite file: the thing
// worth checking is not "does the handler write JSON" but "can a revoked phone
// still read the library". A mock would let the second question pass by
// construction.

const ownerToken = "owner-token-for-tests"

func newTestServer(t *testing.T) *Server {
	t.Helper()

	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	cfg := &config.Config{
		DataDir:    dir,
		ServerName: "test",
		Token:      ownerToken,
	}
	// The scanner is nil: none of the routes exercised here touch it.
	return NewServer(cfg, st, nil)
}

// do sends a request through the full middleware chain.
func do(t *testing.T, s *Server, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()

	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

// createToken mints a device token and returns its plaintext.
func createToken(t *testing.T, s *Server, name string) string {
	t.Helper()

	rec := do(t, s, http.MethodPost, "/api/tokens", ownerToken, map[string]string{"name": name})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create token: status %d, body %s", rec.Code, rec.Body)
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if out.Token == "" {
		t.Fatal("create returned an empty token")
	}
	return out.Token
}

func TestDeviceTokenGrantsAccess(t *testing.T) {
	s := newTestServer(t)
	token := createToken(t, s, "我的手机")

	rec := do(t, s, http.MethodGet, "/api/folders", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("device token should be accepted, got %d: %s", rec.Code, rec.Body)
	}
}

func TestOwnerTokenStillWorks(t *testing.T) {
	s := newTestServer(t)

	rec := do(t, s, http.MethodGet, "/api/folders", ownerToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("owner token should be accepted, got %d: %s", rec.Code, rec.Body)
	}
}

func TestMissingOrWrongTokenRejected(t *testing.T) {
	s := newTestServer(t)

	for _, tok := range []string{"", "not-a-real-token"} {
		rec := do(t, s, http.MethodGet, "/api/folders", tok, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("token %q should be rejected, got %d", tok, rec.Code)
		}
	}
}

func TestRevokedTokenStopsWorkingImmediately(t *testing.T) {
	s := newTestServer(t)
	token := createToken(t, s, "旧手机")

	// Sanity: it works before revocation.
	if rec := do(t, s, http.MethodGet, "/api/folders", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("token should work before revoke, got %d", rec.Code)
	}

	rec := do(t, s, http.MethodDelete, "/api/tokens/1", ownerToken, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("revoke: status %d, body %s", rec.Code, rec.Body)
	}

	if rec := do(t, s, http.MethodGet, "/api/folders", token, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token must be rejected, got %d", rec.Code)
	}
}

func TestRevokeIsIdempotent(t *testing.T) {
	s := newTestServer(t)
	createToken(t, s, "旧手机")

	for i := 0; i < 2; i++ {
		if rec := do(t, s, http.MethodDelete, "/api/tokens/1", ownerToken, nil); rec.Code != http.StatusNoContent {
			t.Fatalf("revoke #%d: status %d, body %s", i+1, rec.Code, rec.Body)
		}
	}
}

func TestRevokeUnknownTokenIs404(t *testing.T) {
	s := newTestServer(t)

	rec := do(t, s, http.MethodDelete, "/api/tokens/999", ownerToken, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("revoking a missing token should be 404, got %d", rec.Code)
	}
}

func TestDeviceTokenCannotManageTokens(t *testing.T) {
	s := newTestServer(t)
	device := createToken(t, s, "我的手机")

	cases := []struct {
		method string
		path   string
		body   any
	}{
		{http.MethodGet, "/api/tokens", nil},
		{http.MethodPost, "/api/tokens", map[string]string{"name": "另一个"}},
		{http.MethodDelete, "/api/tokens/1", nil},
	}
	for _, c := range cases {
		rec := do(t, s, c.method, c.path, device, c.body)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("%s %s with a device token: want 403, got %d", c.method, c.path, rec.Code)
		}
	}
}

func TestListNeverLeaksTheSecret(t *testing.T) {
	s := newTestServer(t)
	token := createToken(t, s, "我的手机")

	rec := do(t, s, http.MethodGet, "/api/tokens", ownerToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list: status %d", rec.Code)
	}
	if bytes.Contains(rec.Body.Bytes(), []byte(token)) {
		t.Fatal("list response contains the plaintext token")
	}
	// And the digest must not be in there either — it is not a credential, but
	// there is no reason to publish it.
	if bytes.Contains(rec.Body.Bytes(), []byte("token_hash")) {
		t.Fatal("list response exposes the stored hash")
	}
}

func TestTwoDevicesGetDifferentTokens(t *testing.T) {
	s := newTestServer(t)
	a := createToken(t, s, "手机")
	b := createToken(t, s, "平板")

	if a == b {
		t.Fatal("two devices received the same token")
	}
	// Revoking one must leave the other working — that is the whole point of
	// per-device tokens.
	if rec := do(t, s, http.MethodDelete, "/api/tokens/1", ownerToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("revoke: status %d", rec.Code)
	}
	if rec := do(t, s, http.MethodGet, "/api/folders", a, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token still works: %d", rec.Code)
	}
	if rec := do(t, s, http.MethodGet, "/api/folders", b, nil); rec.Code != http.StatusOK {
		t.Fatalf("untouched token broke: %d", rec.Code)
	}
}

func TestPingAdvertisesDeviceTokens(t *testing.T) {
	s := newTestServer(t)

	rec := do(t, s, http.MethodGet, "/api/ping", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("ping: status %d", rec.Code)
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode ping: %v", err)
	}
	if out["device_tokens"] != true {
		t.Fatalf("ping should advertise device_tokens, got %v", out["device_tokens"])
	}
}
