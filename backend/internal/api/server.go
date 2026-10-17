// Package api exposes the HTTP surface consumed by the Flutter clients and by
// the built-in status page.
package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"mediacenter/internal/config"
	"mediacenter/internal/scanner"
	"mediacenter/internal/store"
)

// Server wires the store, the scanner and the configuration into an HTTP mux.
type Server struct {
	cfg *config.Config
	st  *store.Store
	sc  *scanner.Scanner
	mux *http.ServeMux
}

// NewServer builds the router.
func NewServer(cfg *config.Config, st *store.Store, sc *scanner.Scanner) *Server {
	s := &Server{cfg: cfg, st: st, sc: sc, mux: http.NewServeMux()}
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /{$}", s.handleIndex)
	s.mux.HandleFunc("GET /api/ping", s.handlePing)
	s.mux.HandleFunc("GET /api/stats", s.handleStats)

	s.mux.HandleFunc("GET /api/folders", s.handleListFolders)
	s.mux.HandleFunc("POST /api/folders", s.handleAddFolder)
	s.mux.HandleFunc("DELETE /api/folders/{id}", s.handleDeleteFolder)

	s.mux.HandleFunc("POST /api/scan/start", s.handleScanStart)
	s.mux.HandleFunc("GET /api/scan/status", s.handleScanStatus)

	s.mux.HandleFunc("GET /api/media", s.handleListMedia)
	s.mux.HandleFunc("GET /api/media/{id}", s.handleGetMedia)
	s.mux.HandleFunc("GET /api/media/{id}/thumbnail", s.handleThumbnail)
	s.mux.HandleFunc("GET /api/media/{id}/original", s.handleOriginal)
	s.mux.HandleFunc("GET /api/media/{id}/albums", s.handleMediaAlbums)

	// File management. Owner-only: these mutate the user's files, so a device
	// token (a phone) must not be able to rename or move anything. Path-level
	// authorisation (registered folders only) is enforced inside the handlers.
	s.mux.Handle("PATCH /api/media/{id}", s.ownerOnly("rename or move files", http.HandlerFunc(s.handleRenameMedia)))
	s.mux.Handle("POST /api/media/move", s.ownerOnly("rename or move files", http.HandlerFunc(s.handleMoveMedia)))

	s.mux.HandleFunc("GET /api/albums", s.handleListAlbums)
	s.mux.HandleFunc("POST /api/albums", s.handleCreateAlbum)
	s.mux.HandleFunc("GET /api/albums/{id}", s.handleGetAlbum)
	s.mux.HandleFunc("PATCH /api/albums/{id}", s.handleUpdateAlbum)
	s.mux.HandleFunc("DELETE /api/albums/{id}", s.handleDeleteAlbum)
	s.mux.HandleFunc("GET /api/albums/{id}/media", s.handleListAlbumMedia)
	s.mux.HandleFunc("POST /api/albums/{id}/media", s.handleAddAlbumMedia)
	s.mux.HandleFunc("DELETE /api/albums/{id}/media", s.handleRemoveAlbumMedia)

	// Phone backup. The transfer is split into chunks so an interrupted upload
	// resumes instead of restarting.
	s.mux.HandleFunc("POST /api/uploads", s.handleCreateUpload)
	s.mux.HandleFunc("GET /api/uploads/{id}", s.handleGetUpload)
	s.mux.HandleFunc("PUT /api/uploads/{id}/chunks/{index}", s.handleUploadChunk)
	s.mux.HandleFunc("POST /api/uploads/{id}/complete", s.handleCompleteUpload)
	s.mux.HandleFunc("DELETE /api/uploads/{id}", s.handleCancelUpload)

	// Device tokens. Wrapped in ownerOnly because a device token that could
	// mint tokens would survive its own revocation.
	s.mux.Handle("GET /api/tokens", s.ownerOnly("manage device tokens", http.HandlerFunc(s.handleListTokens)))
	s.mux.Handle("POST /api/tokens", s.ownerOnly("manage device tokens", http.HandlerFunc(s.handleCreateToken)))
	s.mux.Handle("DELETE /api/tokens/{id}", s.ownerOnly("manage device tokens", http.HandlerFunc(s.handleRevokeToken)))

	// Directory browsing for the folder picker. Owner-only: the tree says a lot
	// about the machine (usernames, mounted drives), which is more than a
	// device token needs. See browse.go for what this endpoint is not.
	s.mux.Handle("GET /api/fs/browse", s.ownerOnly("browse the server's directories", http.HandlerFunc(s.handleBrowse)))
}

// Handler returns the full middleware chain. Authentication wraps the mux so
// every route is protected unless it opts out explicitly.
func (s *Server) Handler() http.Handler {
	return s.withLogging(s.withCORS(s.withAuth(s.mux)))
}

// writeJSON renders v as JSON with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write json: %v", err)
	}
}

// writeErr renders a uniform error envelope.
func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// statusRecorder captures the response code so the log line can report it.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
	})
}

// withCORS keeps browser-based clients (and Flutter web during development)
// usable. The server is meant for a trusted LAN, so the origin is not
// restricted, but the token still gates every call.
func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Access-Control-Allow-Origin", "*")
		h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Token")
		h.Set("Access-Control-Max-Age", "600")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
