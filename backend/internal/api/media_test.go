package api

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"

	"mediacenter/internal/config"
	"mediacenter/internal/store"
)

// The list response used to stop short of the file's location on the server,
// which made two things impossible: answering "where does this photo live?",
// and confirming to the user exactly which file a destructive operation is
// about to touch. Both are prerequisites for the file-management work, so the
// field is asserted here rather than trusted.

func newServerWithStore(t *testing.T) (*Server, *store.Store) {
	t.Helper()

	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	cfg := &config.Config{DataDir: dir, ServerName: "test", Token: ownerToken}
	return NewServer(cfg, st, nil), st
}

func TestListMediaIncludesFilePath(t *testing.T) {
	s, st := newServerWithStore(t)

	folderID, err := st.AddFolder("/library")
	if err != nil {
		t.Fatalf("add folder: %v", err)
	}
	if _, err := st.UpsertMedia(&store.MediaFile{
		FilePath:     "/library/2026/10/trip.jpg",
		FileName:     "trip.jpg",
		FileSize:     4096,
		MimeType:     "image/jpeg",
		MediaType:    "photo",
		IndexedAt:    "2026-10-01T00:00:00Z",
		ScanFolderID: folderID,
		Origin:       store.OriginUpload,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	rec := do(t, s, http.MethodGet, "/api/media?page_size=10", ownerToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}

	var out struct {
		Items []struct {
			ID       int64  `json:"id"`
			FilePath string `json:"file_path"`
			Origin   string `json:"origin"`
		} `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode %s: %v", rec.Body.String(), err)
	}
	if len(out.Items) != 1 {
		t.Fatalf("items = %d, want 1", len(out.Items))
	}
	if got := out.Items[0].FilePath; got != "/library/2026/10/trip.jpg" {
		t.Errorf("file_path = %q, want the absolute path on the server", got)
	}
	if got := out.Items[0].Origin; got != store.OriginUpload {
		t.Errorf("origin = %q, want %q", got, store.OriginUpload)
	}
}

// The origin filter is what lets a phone show "only what I backed up" — and it
// is the field the file-management authorisation model leans on, so it gets a
// test of its own rather than relying on the manual regression script.
func TestListMediaOriginFilter(t *testing.T) {
	s, st := newServerWithStore(t)

	folderID, err := st.AddFolder("/library")
	if err != nil {
		t.Fatalf("add folder: %v", err)
	}
	for _, c := range []struct{ path, origin string }{
		{"/library/uploaded.jpg", store.OriginUpload},
		{"/library/scanned.jpg", store.OriginScan},
	} {
		if _, err := st.UpsertMedia(&store.MediaFile{
			FilePath:     c.path,
			FileName:     filepath.Base(c.path),
			FileSize:     2048,
			MimeType:     "image/jpeg",
			MediaType:    "photo",
			IndexedAt:    "2026-10-01T00:00:00Z",
			ScanFolderID: folderID,
			Origin:       c.origin,
		}); err != nil {
			t.Fatalf("seed %s: %v", c.path, err)
		}
	}

	for _, c := range []struct {
		query string
		want  int
	}{
		{"?origin=upload&page_size=10", 1},
		{"?origin=scan&page_size=10", 1},
		{"?page_size=10", 2},
	} {
		rec := do(t, s, http.MethodGet, "/api/media"+c.query, ownerToken, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d, body %s", c.query, rec.Code, rec.Body)
		}
		var out struct {
			Total int `json:"total"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s: decode: %v", c.query, err)
		}
		if out.Total != c.want {
			t.Errorf("%s: total = %d, want %d", c.query, out.Total, c.want)
		}
	}
}
