package scanner

import (
	"path/filepath"
	"testing"
	"time"

	"mediacenter/internal/config"
	"mediacenter/internal/store"
)

// TestPruneSparesRowsIndexedAfterScanStarted is the regression test for a race
// that deleted freshly uploaded photos.
//
// The race: the folder walk takes minutes on a large library. A phone upload
// that completes while the walk is running writes its index row at that moment.
// Pruning then reads the rows *after* the walk finished, so the new file is not
// in `seen`, and the old code treated "not seen" as "gone from disk" — the photo
// vanished from the gallery with only a silent `removed=1` in the log.
//
// The test drives prune directly rather than orchestrating the real race: the
// property being protected is the invariant "a row newer than the scan start
// survives even when the walk never saw the file". If that holds, the race
// cannot bite, whatever the timing.
func TestPruneSparesRowsIndexedAfterScanStarted(t *testing.T) {
	dir := t.TempDir()

	st, err := store.Open(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()

	folderID, err := st.AddFolder(filepath.Join(dir, "library"))
	if err != nil {
		t.Fatalf("add folder: %v", err)
	}

	// The moment the scan run starts, as run() would compute it.
	cutoff := time.Now().UTC().Format(time.RFC3339)

	rows := []struct {
		path      string
		indexedAt string
		descr     string
	}{
		{
			path:      filepath.Join(dir, "library", "old.jpg"),
			indexedAt: time.Now().Add(-2 * time.Second).UTC().Format(time.RFC3339),
			descr:     "indexed long before the scan, file gone from disk",
		},
		{
			path:      filepath.Join(dir, "library", "just-uploaded.jpg"),
			indexedAt: time.Now().Add(2 * time.Second).UTC().Format(time.RFC3339),
			descr:     "indexed after the scan started, walk never saw the file",
		},
	}

	ids := make(map[string]int64, len(rows))
	for _, r := range rows {
		mf := &store.MediaFile{
			FilePath:     r.path,
			FileName:     filepath.Base(r.path),
			FileSize:     4096,
			MimeType:     "image/jpeg",
			MediaType:    "photo",
			IndexedAt:    r.indexedAt,
			ScanFolderID: folderID,
			Origin:       store.OriginUpload,
		}
		id, err := st.UpsertMedia(mf)
		if err != nil {
			t.Fatalf("seed %s: %v", r.descr, err)
		}
		ids[r.path] = id
	}

	s := &Scanner{cfg: &config.Config{DataDir: dir}, st: st}

	// seen is empty: neither file was encountered by the walk.
	n, err := s.prune(folderID, map[string]bool{}, cutoff)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if n != 1 {
		t.Errorf("prune removed %d rows, want exactly 1 (the stale one)", n)
	}

	if m, err := st.GetMedia(ids[rows[0].path]); err != nil {
		t.Fatalf("read stale row: %v", err)
	} else if m != nil {
		t.Error("stale row survived pruning")
	}

	m, err := st.GetMedia(ids[rows[1].path])
	if err != nil {
		t.Fatalf("read fresh row: %v", err)
	}
	if m == nil {
		t.Fatal("row indexed after the scan started was pruned — the upload race is back")
	}
	if m.Origin != store.OriginUpload {
		t.Errorf("surviving row origin = %q, want %q", m.Origin, store.OriginUpload)
	}
}

// TestPruneStillRemovesStaleRows is the other half of the contract: the cutoff
// must not turn pruning off. A row that predates the scan and whose file is
// really gone still has to disappear, or the index grows without bound and
// deleted files linger in the gallery forever.
func TestPruneStillRemovesStaleRows(t *testing.T) {
	dir := t.TempDir()

	st, err := store.Open(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()

	folderID, err := st.AddFolder(filepath.Join(dir, "pictures"))
	if err != nil {
		t.Fatalf("add folder: %v", err)
	}

	gone := filepath.Join(dir, "pictures", "deleted-last-week.jpg")
	if _, err := st.UpsertMedia(&store.MediaFile{
		FilePath:     gone,
		FileName:     "deleted-last-week.jpg",
		FileSize:     2048,
		MimeType:     "image/jpeg",
		MediaType:    "photo",
		IndexedAt:    time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339),
		ScanFolderID: folderID,
		Origin:       store.OriginScan,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	s := &Scanner{cfg: &config.Config{DataDir: dir}, st: st}
	cutoff := time.Now().UTC().Format(time.RFC3339)

	n, err := s.prune(folderID, map[string]bool{}, cutoff)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if n != 1 {
		t.Errorf("prune removed %d rows, want 1", n)
	}

	refs, err := st.ListRefsByFolder(folderID)
	if err != nil {
		t.Fatalf("list refs: %v", err)
	}
	if len(refs) != 0 {
		t.Errorf("folder still holds %d rows, want 0", len(refs))
	}
}
