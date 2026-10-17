package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
)

// The picker endpoint is what makes "add a media directory" usable from a
// phone, which previously had to type an absolute server path by hand. These
// tests pin the three behaviours the UI depends on (navigation, ordering,
// exclusions) plus the one that matters for safety (a device token cannot
// browse the server's filesystem at all).

// browseTree builds a directory with one of everything the picker has to
// handle: ordinary dirs, a hidden dir, a symlink to a dir, and a plain file.
func browseTree(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	for _, name := range []string{"北京游记", "z-last", "aaa"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(root, ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "notes.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A symlink to a directory: the scanner never descends into one, so the
	// picker must not offer it as if it worked.
	if err := os.Symlink(filepath.Join(root, "aaa"), filepath.Join(root, "link")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	return root
}

func browse(t *testing.T, s *Server, token, path string) *httptest.ResponseRecorder {
	t.Helper()

	q := url.Values{}
	if path != "" {
		q.Set("path", path)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/fs/browse?"+q.Encode(), nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func decodeBrowse(t *testing.T, rec *httptest.ResponseRecorder) browseResponse {
	t.Helper()

	var out browseResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode %s: %v", rec.Body.String(), err)
	}
	return out
}

func TestBrowseListsDirectoriesInUsableOrder(t *testing.T) {
	s := newTestServer(t)
	root := browseTree(t)

	rec := browse(t, s, ownerToken, root)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}
	out := decodeBrowse(t, rec)

	var names []string
	for _, e := range out.Entries {
		names = append(names, e.Name)
	}
	want := []string{"aaa", "z-last", "北京游记", ".hidden"}
	if len(names) != len(want) {
		t.Fatalf("entries = %v, want %v", names, want)
	}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("entries = %v, want %v (files and symlinks excluded, hidden last, then by name)", names, want)
		}
	}
	for _, e := range out.Entries {
		if e.Name == ".hidden" && !e.Hidden {
			t.Error("dot-directory is not flagged hidden, so the UI cannot dim it")
		}
		if e.Path != filepath.Join(root, e.Name) {
			t.Errorf("entry %s path = %q, want it joined under the browsed directory", e.Name, e.Path)
		}
	}
	if out.Path != root {
		t.Errorf("path = %q, want %q", out.Path, root)
	}
	if out.Parent != filepath.Dir(root) {
		t.Errorf("parent = %q, want %q", out.Parent, filepath.Dir(root))
	}
	if out.Home == "" {
		t.Error("home is empty; the picker needs it for its 主目录 chip")
	}
	if out.Truncated {
		t.Error("truncated on a four-entry directory")
	}
}

func TestBrowseRootHasNoParent(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("path semantics differ; covered by the unix build")
	}
	s := newTestServer(t)

	rec := browse(t, s, ownerToken, "/")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}
	if out := decodeBrowse(t, rec); out.Parent != "" {
		t.Errorf("parent = %q, want empty at the filesystem root", out.Parent)
	}
}

func TestBrowseDefaultsToHome(t *testing.T) {
	s := newTestServer(t)

	rec := browse(t, s, ownerToken, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if out := decodeBrowse(t, rec); out.Path != home {
		t.Errorf("path = %q, want the server home %q", out.Path, home)
	}
}

func TestBrowseTruncatesHugeDirectories(t *testing.T) {
	s := newTestServer(t)
	root := t.TempDir()

	// One over the limit: the cap must engage rather than ship everything.
	for i := 0; i <= browseEntryLimit; i++ {
		if err := os.Mkdir(filepath.Join(root, "dir"+strconv.Itoa(i)), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	rec := browse(t, s, ownerToken, root)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body)
	}
	out := decodeBrowse(t, rec)
	if !out.Truncated {
		t.Error("a directory over the limit did not report truncation")
	}
	if len(out.Entries) != browseEntryLimit {
		t.Errorf("entries = %d, want the cap %d", len(out.Entries), browseEntryLimit)
	}
}

func TestBrowseRejectsDeviceTokens(t *testing.T) {
	s := newTestServer(t)
	root := browseTree(t)

	device := createToken(t, s, "phone")

	rec := browse(t, s, device, root)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("device token browse: status %d, want 403; body %s", rec.Code, rec.Body)
	}
	var errOut struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &errOut); err != nil {
		t.Fatal(err)
	}
	if errOut.Error == "" {
		t.Error("403 carries no reason; the user cannot tell what to do")
	}
}

func TestBrowseRejectsUnreadableAndMissingPaths(t *testing.T) {
	s := newTestServer(t)

	missing := filepath.Join(t.TempDir(), "nope")
	if rec := browse(t, s, ownerToken, missing); rec.Code != http.StatusBadRequest {
		t.Errorf("missing path: status %d, want 400", rec.Code)
	}

	file := filepath.Join(t.TempDir(), "plain.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rec := browse(t, s, ownerToken, file); rec.Code != http.StatusBadRequest {
		t.Errorf("file path: status %d, want 400", rec.Code)
	}
}

// Shortcuts are computed on the server, so a chip can never lead somewhere
// that does not exist. The platform-specific parts can only be asserted where
// they apply, which is why this test branches.
func TestBrowseShortcutsPointAtRealDirectories(t *testing.T) {
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, "Pictures"), 0o755); err != nil {
		t.Fatal(err)
	}
	// DCIM deliberately absent: it must not produce a chip.

	shorts := browseShortcuts(home)

	var sawHome, sawPictures bool
	for _, sc := range shorts {
		info, err := os.Stat(sc.Path)
		if err != nil || !info.IsDir() {
			t.Errorf("shortcut %q points at %q, which is not a directory", sc.Label, sc.Path)
		}
		switch sc.Path {
		case home:
			sawHome = true
		case filepath.Join(home, "Pictures"):
			sawPictures = true
		}
		if sc.Path == filepath.Join(home, "DCIM") {
			t.Error("a shortcut was produced for a directory that does not exist")
		}
	}
	if !sawHome {
		t.Error("主目录 chip missing")
	}
	if !sawPictures {
		t.Error("图片 chip missing")
	}

	switch runtime.GOOS {
	case "darwin":
		if len(shorts) < 2 {
			t.Skip("no mounted volumes on this machine")
		}
		var sawVolume bool
		for _, sc := range shorts {
			if filepath.Dir(sc.Path) == "/Volumes" {
				sawVolume = true
			}
		}
		if !sawVolume {
			t.Error("macOS exposes mounted volumes under /Volumes; none offered")
		}
	case "linux", "windows":
		if len(shorts) < 1 {
			t.Error("home alone should always be offered")
		}
	}
}
