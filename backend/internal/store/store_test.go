package store

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// legacySchema is media_files as the first release created it: no origin
// column. Upgrading a database in this shape must work in place.
const legacySchema = `
CREATE TABLE scan_folders (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    path       TEXT    NOT NULL UNIQUE,
    enabled    INTEGER NOT NULL DEFAULT 1,
    last_scan  TEXT,
    created_at TEXT    NOT NULL
);

CREATE TABLE media_files (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path      TEXT    NOT NULL UNIQUE,
    content_hash   TEXT    NOT NULL DEFAULT '',
    file_name      TEXT    NOT NULL,
    file_size      INTEGER NOT NULL,
    file_mtime     INTEGER NOT NULL DEFAULT 0,
    mime_type      TEXT    NOT NULL DEFAULT '',
    media_type     TEXT    NOT NULL CHECK (media_type IN ('photo','video')),
    taken_at       TEXT,
    indexed_at     TEXT    NOT NULL,
    width          INTEGER,
    height         INTEGER,
    duration_ms    INTEGER,
    video_codec    TEXT,
    audio_codec    TEXT,
    thumbnail_path TEXT,
    scan_folder_id INTEGER REFERENCES scan_folders(id) ON DELETE CASCADE
);
`

// TestMigrateAddsOriginToExistingDatabase is the test that matters most for
// this change: a user who already indexed a library must not have to rebuild it,
// and their existing rows must keep working after the upgrade.
func TestMigrateAddsOriginToExistingDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.db")

	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(legacySchema); err != nil {
		t.Fatalf("build legacy schema: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO media_files
		(file_path, file_name, file_size, media_type, indexed_at)
		VALUES ('/old/holiday.jpg','holiday.jpg',4096,'photo','2020-01-01T00:00:00Z')`); err != nil {
		t.Fatalf("seed legacy row: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("open after upgrade: %v", err)
	}
	defer s.Close()

	m, err := s.GetMedia(1)
	if err != nil {
		t.Fatalf("read legacy row: %v", err)
	}
	if m == nil {
		t.Fatal("legacy row vanished during migration")
	}
	if m.Origin != OriginScan {
		t.Fatalf("legacy row origin = %q, want %q", m.Origin, OriginScan)
	}
	if m.FileName != "holiday.jpg" || m.FileSize != 4096 {
		t.Fatalf("legacy row was altered: %+v", m)
	}

	// A row written before origin existed must be visible to the origin filter.
	res, err := s.ListMedia(ListParams{Origin: OriginScan, PageSize: 10})
	if err != nil {
		t.Fatal(err)
	}
	if res.Total != 1 {
		t.Fatalf("origin=scan matched %d rows, want 1", res.Total)
	}

	// The tables introduced by this change must be usable.
	if _, err := s.db.Exec(`INSERT INTO uploads
		(id, file_name, total_size, chunk_size, chunk_count, target_path, temp_path, created_at, updated_at)
		VALUES ('u1','a.jpg',10,4,3,'/lib/a.jpg','/tmp/u1.part','t','t')`); err != nil {
		t.Fatalf("uploads table unusable after upgrade: %v", err)
	}
	if _, err := s.db.Exec(
		`INSERT INTO upload_chunks (upload_id, chunk_index, size, received_at) VALUES ('u1',0,4,'t')`); err != nil {
		t.Fatalf("upload_chunks table unusable after upgrade: %v", err)
	}
}

// TestMigrateIsIdempotent guards against a migration that only works the first
// time — the server runs it on every start.
func TestMigrateIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.db")
	for i := 1; i <= 3; i++ {
		s, err := Open(path)
		if err != nil {
			t.Fatalf("open #%d: %v", i, err)
		}
		if err := s.Close(); err != nil {
			t.Fatalf("close #%d: %v", i, err)
		}
	}
}

// TestUpsertPreservesOrigin pins the rule that a re-scan must not relabel an
// uploaded file as scanned. The library folder is a scan folder, so this
// collision is the normal case, not an edge case.
func TestUpsertPreservesOrigin(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	first := &MediaFile{
		FilePath: "/lib/2026/10/backup.jpg", ContentHash: "h1", FileName: "backup.jpg",
		FileSize: 100, FileMtime: 1, MimeType: "image/jpeg", MediaType: "photo",
		IndexedAt: "2026-10-15T00:00:00Z", Origin: OriginUpload,
	}
	if _, err := s.UpsertMedia(first); err != nil {
		t.Fatal(err)
	}

	// The scanner walks the same path and upserts it as a scanned file.
	rescan := *first
	rescan.Origin = OriginScan
	rescan.FileMtime = 2
	if _, err := s.UpsertMedia(&rescan); err != nil {
		t.Fatal(err)
	}

	m, err := s.GetMediaByPath(first.FilePath)
	if err != nil {
		t.Fatal(err)
	}
	if m.Origin != OriginUpload {
		t.Fatalf("origin after re-scan = %q, want %q", m.Origin, OriginUpload)
	}
	if m.FileMtime != 2 {
		t.Fatalf("re-scan did not refresh file_mtime: %d", m.FileMtime)
	}
}

// TestUploadChunkCountsAreIdempotent covers the retry path: a client that
// re-sends a chunk it already sent must not inflate the received count.
func TestUploadChunkCountsAreIdempotent(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	u := &Upload{
		ID: "sess1", FileName: "v.mp4", TotalSize: 10, ChunkSize: 4,
		ChunkCount: 3, TargetPath: "/lib/v.mp4", TempPath: "/tmp/sess1.part",
	}
	if err := s.CreateUpload(u); err != nil {
		t.Fatal(err)
	}

	for _, i := range []int{0, 1, 2} {
		if _, err := s.AddUploadChunk("sess1", i, 4); err != nil {
			t.Fatal(err)
		}
	}
	// Re-send chunk 1 and then chunk 0.
	if _, err := s.AddUploadChunk("sess1", 1, 4); err != nil {
		t.Fatal(err)
	}
	n, err := s.AddUploadChunk("sess1", 0, 4)
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Fatalf("received_chunks = %d after retries, want 3", n)
	}

	got, err := s.GetUpload("sess1")
	if err != nil {
		t.Fatal(err)
	}
	if got.ReceivedChunks != 3 {
		t.Fatalf("stored received_chunks = %d, want 3", got.ReceivedChunks)
	}

	idxs, err := s.ReceivedChunkIndexes("sess1")
	if err != nil {
		t.Fatal(err)
	}
	if len(idxs) != 3 || idxs[0] != 0 || idxs[2] != 2 {
		t.Fatalf("received indexes = %v, want [0 1 2]", idxs)
	}
}

// TestDeleteUploadCascadesChunks keeps the chunk table from accumulating
// orphans when a client cancels.
func TestDeleteUploadCascadesChunks(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	u := &Upload{
		ID: "sess2", FileName: "v.mp4", TotalSize: 10, ChunkSize: 4,
		ChunkCount: 3, TargetPath: "/lib/v.mp4", TempPath: "/tmp/sess2.part",
	}
	if err := s.CreateUpload(u); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddUploadChunk("sess2", 0, 4); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteUpload("sess2"); err != nil {
		t.Fatal(err)
	}

	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM upload_chunks WHERE upload_id = 'sess2'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("%d orphan chunk rows survived the cascade", n)
	}
	// Cancelling an unknown session must stay a no-op so retries are safe.
	if err := s.DeleteUpload("sess2"); err != nil {
		t.Fatalf("second cancel: %v", err)
	}
}

// TestDeleteStaleUploadsReturnsTempFiles verifies the sweeper both drops the
// session and reports the file the caller has to unlink.
func TestDeleteStaleUploadsReturnsTempFiles(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	old := &Upload{
		ID: "old", FileName: "a.jpg", TotalSize: 10, ChunkSize: 4,
		ChunkCount: 3, TargetPath: "/lib/a.jpg", TempPath: "/tmp/old.part",
	}
	fresh := &Upload{
		ID: "fresh", FileName: "b.jpg", TotalSize: 10, ChunkSize: 4,
		ChunkCount: 3, TargetPath: "/lib/b.jpg", TempPath: "/tmp/fresh.part",
	}
	if err := s.CreateUpload(old); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateUpload(fresh); err != nil {
		t.Fatal(err)
	}

	// Backdate the old session past the cutoff.
	if _, err := s.db.Exec(
		`UPDATE uploads SET updated_at = '2020-01-01T00:00:00Z' WHERE id = 'old'`); err != nil {
		t.Fatal(err)
	}

	paths, err := s.DeleteStaleUploads("2021-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 1 || paths[0] != "/tmp/old.part" {
		t.Fatalf("stale temp files = %v, want [/tmp/old.part]", paths)
	}

	if u, err := s.GetUpload("old"); err != nil || u != nil {
		t.Fatalf("stale session survived: %+v (err=%v)", u, err)
	}
	if u, err := s.GetUpload("fresh"); err != nil || u == nil {
		t.Fatalf("fresh session was swept: %+v (err=%v)", u, err)
	}
}
