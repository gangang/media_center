package api

import (
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// Directory browsing, so the client can offer a directory picker.
//
// The client and the server are two different machines: a phone cannot open a
// file dialog on the Mac. So "pick a folder to scan" is served by this
// endpoint, which lists the server's directories plus a per-platform set of
// shortcuts (home, Pictures, mounted drives) that the UI renders as one-tap
// chips.
//
// What this endpoint deliberately is not:
//
//   - Not an authorization surface. Browsing only navigates. A directory gains
//     file-management rights when the user registers it via POST /api/folders,
//     and that registration is the authorization — see the file-management
//     design (授权路径模型).
//   - Not a file browser. Only directories are listed and no file contents are
//     reachable through it. Anything more would turn the media center into a
//     network drive, which is a different product with a different maintenance
//     cost.
//
// The two exclusions below are deliberate and easy to "fix" by accident:
//
//   - Symlinked directories are hidden. The scanner uses filepath.WalkDir,
//     which does not descend into symlinks, so offering one here would let the
//     user register a directory that silently indexes nothing.
//   - Hidden directories (dot-prefixed) are listed but flagged, and sorted
//     last. Hiding them outright would make the picker disagree with reality:
//     scanning the *parent* of a dot-directory skips it, but registering the
//     dot-directory itself does scan it.

// browseEntryLimit caps how much a single response carries. A directory with
// ten thousand subdirectories would make the picker unusable and the response
// slow; the client tells the user to type the path by hand instead.
const browseEntryLimit = 500

type browseEntry struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Hidden bool   `json:"hidden"`
}

type browseShortcut struct {
	Label string `json:"label"`
	Path  string `json:"path"`
}

type browseResponse struct {
	Path      string           `json:"path"`
	Parent    string           `json:"parent,omitempty"`
	Home      string           `json:"home"`
	Entries   []browseEntry    `json:"entries"`
	Shortcuts []browseShortcut `json:"shortcuts"`
	Truncated bool             `json:"truncated"`
}

func (s *Server) handleBrowse(w http.ResponseWriter, r *http.Request) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		writeErr(w, http.StatusInternalServerError, "the server cannot determine its home directory")
		return
	}

	path := strings.TrimSpace(r.URL.Query().Get("path"))
	if path == "" || path == "~" {
		path = home
	} else if strings.HasPrefix(path, "~") {
		path = filepath.Join(home, strings.TrimPrefix(path, "~"))
	}

	abs, err := filepath.Abs(path)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "cannot resolve path")
		return
	}
	if info, err := os.Stat(abs); err != nil || !info.IsDir() {
		writeErr(w, http.StatusBadRequest, "path does not exist or is not a directory")
		return
	}

	dirents, err := os.ReadDir(abs)
	if err != nil {
		// Typical cause: a permissions cleanup on macOS, or a drive mounted
		// with restrictive options. Saying so helps more than a bare 500.
		writeErr(w, http.StatusForbidden, "the server cannot read this directory: "+err.Error())
		return
	}

	entries := make([]browseEntry, 0, len(dirents))
	for _, d := range dirents {
		// d.IsDir() is false for symlinks, which is what excludes them.
		if !d.IsDir() {
			continue
		}
		name := d.Name()
		entries = append(entries, browseEntry{
			Name:   name,
			Path:   filepath.Join(abs, name),
			Hidden: strings.HasPrefix(name, "."),
		})
	}

	// Ordinary directories first, hidden ones after: the common case is a
	// Pictures folder full of trip names, not .git.
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].Hidden != entries[j].Hidden {
			return !entries[i].Hidden
		}
		return entries[i].Name < entries[j].Name
	})

	truncated := false
	if len(entries) > browseEntryLimit {
		entries = entries[:browseEntryLimit]
		truncated = true
	}

	parent := filepath.Dir(abs)
	if parent == abs {
		parent = "" // already at the root; nothing to go up to
	}

	writeJSON(w, http.StatusOK, browseResponse{
		Path:      abs,
		Parent:    parent,
		Home:      home,
		Entries:   entries,
		Shortcuts: browseShortcuts(home),
		Truncated: truncated,
	})
}

// browseShortcuts computes the one-tap destinations for the picker.
//
// This runs on the server, not the client, because only the server knows its
// own platform and mount points — otherwise every platform difference leaks
// into the Flutter UI. Every entry is a directory that actually exists, so a
// chip can never lead to an error.
func browseShortcuts(home string) []browseShortcut {
	out := []browseShortcut{{Label: "主目录", Path: home}}

	// The two places photos actually live, when they exist. Checking keeps the
	// row honest on machines that have neither.
	for _, sub := range []struct{ label, name string }{
		{"图片", "Pictures"},
		{"照片图库", "DCIM"},
	} {
		if p := filepath.Join(home, sub.name); isDir(p) {
			out = append(out, browseShortcut{Label: sub.label, Path: p})
		}
	}

	switch runtime.GOOS {
	case "darwin":
		// Every mounted volume shows up here, including the boot volume and
		// any external drive. Labels are the volume names, which is what the
		// user recognises.
		if ents, err := os.ReadDir("/Volumes"); err == nil {
			for _, e := range ents {
				if !e.IsDir() {
					continue
				}
				p := filepath.Join("/Volumes", e.Name())
				out = append(out, browseShortcut{Label: e.Name(), Path: p})
			}
		}
	case "linux":
		for _, p := range []string{"/media", "/mnt"} {
			if isDir(p) {
				out = append(out, browseShortcut{Label: p, Path: p})
			}
		}
	case "windows":
		for _, drive := range "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
			p := string(drive) + `:\`
			if isDir(p) {
				out = append(out, browseShortcut{Label: p, Path: p})
			}
		}
	}

	return out
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
