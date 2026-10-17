package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"mediacenter/internal/store"
)

// Tests for rename/move.
//
// The property that matters most is invisible in a happy-path test: the media
// id must survive a rename, because album_items cascades on delete. So the
// main test here is not "did the file move" but "is the photo still in its
// album afterwards" — that is the bug this design exists to prevent.

// seedMedia writes a real file under root and indexes it, the way the upload
// path would.
func seedMedia(t *testing.T, st *store.Store, root, name, origin string) *store.MediaFile {
	t.Helper()

	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte("pretend-jpeg-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}

	folderID, err := st.AddFolder(root)
	if err != nil {
		t.Fatal(err)
	}
	mf := &store.MediaFile{
		FilePath:     path,
		FileName:     name,
		FileSize:     int64(len("pretend-jpeg-bytes")),
		FileMtime:    1700000000,
		MimeType:     "image/jpeg",
		MediaType:    "photo",
		IndexedAt:    "2026-10-01T00:00:00Z",
		ScanFolderID: folderID,
		Origin:       origin,
	}
	if _, err := st.UpsertMedia(mf); err != nil {
		t.Fatal(err)
	}
	got, err := st.GetMediaByPath(path)
	if err != nil || got == nil {
		t.Fatalf("seed row not readable: %v", err)
	}
	return got
}

func TestRenameKeepsIDAndAlbumMembership(t *testing.T) {
	s, st := newServerWithStore(t)
	root := t.TempDir()
	m := seedMedia(t, st, root, "IMG_0001.JPG", store.OriginUpload)

	album, err := st.CreateAlbum("旅行", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.AddAlbumItems(album.ID, []int64{m.ID}); err != nil {
		t.Fatal(err)
	}

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"name": "海边日落.jpg"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}

	// On disk: the new name exists, the old one does not.
	newPath := filepath.Join(root, "海边日落.jpg")
	if _, err := os.Stat(newPath); err != nil {
		t.Errorf("renamed file missing on disk: %v", err)
	}
	if _, err := os.Stat(m.FilePath); !os.IsNotExist(err) {
		t.Error("old file still on disk")
	}

	// In the index: same id, new path. A new id here is the bug that silently
	// drops the photo out of every album.
	updated, err := st.GetMedia(m.ID)
	if err != nil || updated == nil {
		t.Fatalf("row gone after rename: %v", err)
	}
	if updated.FilePath != newPath {
		t.Errorf("file_path = %q, want %q", updated.FilePath, newPath)
	}
	if updated.FileName != "海边日落.jpg" {
		t.Errorf("file_name = %q", updated.FileName)
	}
	// GetMediaByPath returns (nil, nil) when nothing matches, so the row
	// pointer is the assertion, not the error.
	if got, _ := st.GetMediaByPath(m.FilePath); got != nil {
		t.Errorf("a row still exists under the old path: %+v", got)
	}

	ids, err := st.AlbumMediaIDs(album.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 1 || ids[0] != m.ID {
		t.Errorf("album membership = %v, want [%d] — rename must not touch album_items", ids, m.ID)
	}
}

func TestRenameRefusesToChangeExtension(t *testing.T) {
	s, st := newServerWithStore(t)
	m := seedMedia(t, st, t.TempDir(), "photo.jpg", store.OriginScan)

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"name": "photo.txt"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400; body %s", rec.Code, rec.Body)
	}
	// The row must be untouched when the request is refused.
	if got, _ := st.GetMedia(m.ID); got.FileName != "photo.jpg" {
		t.Errorf("file_name = %q, want it unchanged", got.FileName)
	}
}

func TestRenameRejectsPathLikeNames(t *testing.T) {
	s, st := newServerWithStore(t)
	m := seedMedia(t, st, t.TempDir(), "photo.jpg", store.OriginScan)

	for _, name := range []string{"../escape.jpg", "sub/photo.jpg", ".hidden.jpg", ".."} {
		rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
			map[string]any{"name": name})
		if rec.Code != http.StatusBadRequest {
			t.Errorf("name %q: status %d, want 400", name, rec.Code)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(m.FilePath), "..", "escape.jpg")); err == nil {
		t.Error("a traversal name was written outside the folder")
	}
}

func TestRenameConflictGetsSerialNumber(t *testing.T) {
	s, st := newServerWithStore(t)
	root := t.TempDir()
	m := seedMedia(t, st, root, "a.jpg", store.OriginScan)
	// A second file already owns the name we are about to ask for.
	if err := os.WriteFile(filepath.Join(root, "b.jpg"), []byte("other"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"name": "b.jpg"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}

	var out struct {
		AppliedName string `json:"applied_name"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.AppliedName != "b (1).jpg" {
		t.Errorf("applied_name = %q, want the serial-number scheme the uploads use", out.AppliedName)
	}
	if _, err := os.Stat(filepath.Join(root, "b.jpg")); err != nil {
		t.Error("the pre-existing file was overwritten")
	}
}

func TestMoveToAnotherRegisteredFolder(t *testing.T) {
	s, st := newServerWithStore(t)
	src := t.TempDir()
	dst := t.TempDir()

	m := seedMedia(t, st, src, "clip.jpg", store.OriginScan)
	dstID, err := st.AddFolder(dst)
	if err != nil {
		t.Fatal(err)
	}

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"folder_id": dstID})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}

	want := filepath.Join(dst, "clip.jpg")
	if _, err := os.Stat(want); err != nil {
		t.Errorf("file not at destination: %v", err)
	}
	updated, _ := st.GetMedia(m.ID)
	if updated.FilePath != want {
		t.Errorf("file_path = %q, want %q", updated.FilePath, want)
	}
	if updated.ScanFolderID != dstID {
		t.Errorf("scan_folder_id = %d, want %d", updated.ScanFolderID, dstID)
	}
}

func TestMoveToUnregisteredFolderRefused(t *testing.T) {
	s, st := newServerWithStore(t)
	src := t.TempDir()
	m := seedMedia(t, st, src, "clip.jpg", store.OriginScan)

	// Folder row exists but is disabled: not an authorised root.
	dstID, err := st.AddFolder(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetFolderEnabled(dstID, false); err != nil {
		t.Fatal(err)
	}

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"folder_id": dstID})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400; body %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(m.FilePath); err != nil {
		t.Error("file was moved despite the refusal")
	}
}

// A row pointing outside every registered folder is exactly what the
// authorisation model exists to stop — unplug the drive, or edit the database
// by hand, and the file must stop being manageable.
func TestManageRejectsFilesOutsideRegisteredFolders(t *testing.T) {
	s, st := newServerWithStore(t)
	outside := t.TempDir()

	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(outside, "loose.jpg")
	if err := os.WriteFile(path, []byte("bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Indexed directly, without AddFolder: no registered root covers it.
	if _, err := st.UpsertMedia(&store.MediaFile{
		FilePath: path, FileName: "loose.jpg", FileSize: 5,
		MimeType: "image/jpeg", MediaType: "photo",
		IndexedAt: "2026-10-01T00:00:00Z", Origin: store.OriginScan,
	}); err != nil {
		t.Fatal(err)
	}
	m, _ := st.GetMediaByPath(path)

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"name": "renamed.jpg"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status %d, want 403; body %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(path); err != nil {
		t.Error("file outside the roots was renamed anyway")
	}
}

func TestRenameMissingFileReportsCleanly(t *testing.T) {
	s, st := newServerWithStore(t)
	root := t.TempDir()
	m := seedMedia(t, st, root, "gone.jpg", store.OriginScan)
	// Someone deleted the file behind the index's back.
	if err := os.Remove(m.FilePath); err != nil {
		t.Fatal(err)
	}

	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), ownerToken,
		map[string]any{"name": "back.jpg"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400; body %s", rec.Code, rec.Body)
	}
	// The row survived: the index still describes reality, and the next scan
	// will prune it.
	got, err := st.GetMedia(m.ID)
	if err != nil || got == nil || got.FilePath != m.FilePath {
		t.Errorf("row was rewritten despite the failed move: %+v (%v)", got, err)
	}
}

func TestBatchMoveReportsPartialFailure(t *testing.T) {
	s, st := newServerWithStore(t)
	src := t.TempDir()
	dst := t.TempDir()

	ok := seedMedia(t, st, src, "good.jpg", store.OriginScan)
	missing := seedMedia(t, st, src, "also-good.jpg", store.OriginScan)
	if err := os.Remove(missing.FilePath); err != nil {
		t.Fatal(err)
	}
	dstID, err := st.AddFolder(dst)
	if err != nil {
		t.Fatal(err)
	}

	rec := do(t, s, http.MethodPost, "/api/media/move", ownerToken, map[string]any{
		"ids":       []int64{ok.ID, missing.ID, 999999},
		"folder_id": dstID,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}

	var out struct {
		Moved   int `json:"moved"`
		Failed  int `json:"failed"`
		Results []struct {
			ID    int64  `json:"id"`
			OK    bool   `json:"ok"`
			Error string `json:"error"`
		} `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out.Moved != 1 || out.Failed != 2 {
		t.Errorf("moved = %d, failed = %d, want 1 and 2", out.Moved, out.Failed)
	}
	if len(out.Results) != 3 {
		t.Fatalf("results = %d, want one per requested id", len(out.Results))
	}
	// The good one must have landed even though the batch had failures.
	if _, err := os.Stat(filepath.Join(dst, "good.jpg")); err != nil {
		t.Errorf("successful item was not moved: %v", err)
	}
	for _, r := range out.Results {
		if !r.OK && r.Error == "" {
			t.Errorf("failed item %d carries no reason", r.ID)
		}
	}
}

func TestBatchMoveRejectsUnknownFolderAndEmptyIDs(t *testing.T) {
	s, st := newServerWithStore(t)
	root := t.TempDir()
	m := seedMedia(t, st, root, "a.jpg", store.OriginScan)

	if rec := do(t, s, http.MethodPost, "/api/media/move", ownerToken,
		map[string]any{"ids": []int64{m.ID}}); rec.Code != http.StatusBadRequest {
		t.Errorf("missing folder: status %d, want 400", rec.Code)
	}

	dstID, _ := st.AddFolder(t.TempDir())
	if rec := do(t, s, http.MethodPost, "/api/media/move", ownerToken,
		map[string]any{"ids": []int64{}, "folder_id": dstID}); rec.Code != http.StatusBadRequest {
		t.Errorf("empty ids: status %d, want 400", rec.Code)
	}
	if rec := do(t, s, http.MethodPost, "/api/media/move", ownerToken,
		map[string]any{"ids": []int64{m.ID}, "folder_id": 4242}); rec.Code != http.StatusBadRequest {
		t.Errorf("unknown folder: status %d, want 400", rec.Code)
	}
}

// Renaming and moving mutate the user's files, so they are owner-only. A
// paired phone (device token) must not be able to reorganise the library.
func TestRenameRequiresOwnerToken(t *testing.T) {
	s, st := newServerWithStore(t)
	m := seedMedia(t, st, t.TempDir(), "a.jpg", store.OriginScan)

	device := createToken(t, s, "phone")
	rec := do(t, s, http.MethodPatch, "/api/media/"+itoa(m.ID), device,
		map[string]any{"name": "b.jpg"})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("device token rename: status %d, want 403; body %s", rec.Code, rec.Body)
	}
	rec = do(t, s, http.MethodPost, "/api/media/move", device,
		map[string]any{"ids": []int64{m.ID}, "folder_id": 1})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("device token move: status %d, want 403", rec.Code)
	}
}

// -------------------------------------------------------------- helpers --

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
