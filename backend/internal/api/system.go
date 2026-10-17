package api

import (
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"mediacenter/internal/meta"
)

// Version is the API/backend version reported to clients during discovery and
// in the startup banner.
//
// It is a var rather than a const so a release build can stamp it in:
//
//	go build -ldflags "-X mediacenter/internal/api.Version=0.2.0"
//
// Without that, every binary ever built claims to be the same version, and the
// first question anyone asks about a misbehaving release ("which build are you
// running?") becomes unanswerable. See scripts/build-release.sh.
var Version = "0.1.0"

// APIVersion lets a client refuse to talk to an incompatible server.
//
// Deliberately NOT injectable: this is a compatibility contract, not a label.
// It must only change when the wire format actually changes.
const APIVersion = 1

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"name":          s.cfg.ServerName,
		"version":       Version,
		"api_version":   APIVersion,
		"auth_required": true,
		// Additive capability flag: a client that wants per-device tokens can
		// check this instead of probing and handling a 404.
		"device_tokens": true,
	})
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	st, err := s.st.Stats()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"photos":            st.Photos,
		"videos":            st.Videos,
		"total_bytes":       st.TotalBytes,
		"folders":           st.Folders,
		"uploaded":          st.Uploaded,
		"scan":              s.sc.Status(),
		"ffmpeg_available":  meta.HasTool(s.cfg.FFmpeg),
		"ffprobe_available": meta.HasTool(s.cfg.FFprobe),
		// HEIC (iPhone photos) can only be thumbnailed when ffmpeg has an HEVC
		// decoder. Surfacing it here is the difference between "the gallery is
		// broken" and "install an ffmpeg with HEVC support".
		"heic_thumbnails": meta.CanDecodeHEVC(s.cfg.FFmpeg),
	})
}

// ---------------------------------------------------------------- folders --

func (s *Server) handleListFolders(w http.ResponseWriter, r *http.Request) {
	folders, err := s.st.ListFolders()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": folders})
}

func (s *Server) handleAddFolder(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	path := strings.TrimSpace(body.Path)
	if path == "" {
		writeErr(w, http.StatusBadRequest, "path is required")
		return
	}
	if strings.HasPrefix(path, "~") {
		if home, err := os.UserHomeDir(); err == nil {
			path = filepath.Join(home, strings.TrimPrefix(path, "~"))
		}
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "cannot resolve path")
		return
	}

	info, err := os.Stat(abs)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "path does not exist or is not readable")
		return
	}
	if !info.IsDir() {
		writeErr(w, http.StatusBadRequest, "path must be a directory")
		return
	}

	id, err := s.st.AddFolder(abs)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Index the new folder right away so the user sees results without having
	// to trigger a scan manually.
	scanStarted := s.sc.Start(0) == nil

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":           id,
		"path":         abs,
		"scan_started": scanStarted,
	})
}

func (s *Server) handleDeleteFolder(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, "invalid folder id")
		return
	}

	// The library folder is where the backup API writes. Removing it would not
	// delete a single photo, but it would quietly stop every future upload from
	// reaching the index — a failure that looks like data loss and is not.
	if libID, err := s.st.FolderIDByPath(s.cfg.LibraryDir()); err == nil && libID == id {
		writeErr(w, http.StatusConflict, "媒体库目录由手机备份功能使用，不能移除")
		return
	}

	if err := s.st.DeleteFolder(id); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": id})
}

// ------------------------------------------------------------------- scan --

func (s *Server) handleScanStart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		FolderID int64 `json:"folder_id"`
	}
	// An empty body is valid and means "scan everything".
	if r.Body != nil {
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body)
	}

	if err := s.sc.Start(body.FolderID); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"status": "started"})
}

func (s *Server) handleScanStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.sc.Status())
}

// ------------------------------------------------------------ status page --

// handleIndex serves a tiny built-in page. It gives a user who just started
// the binary somewhere to land in a browser and confirm the server is alive,
// without needing the Flutter client installed yet.
func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	st, err := s.st.Stats()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	tok := r.URL.Query().Get("token")
	// The page is public, so a token in the URL is the visitor's way of making
	// the links on it usable. An invalid one is dropped rather than echoed
	// back into the HTML.
	if _, ok := s.resolvePrincipal(tok); !ok {
		tok = ""
	}

	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">`)
	b.WriteString(`<meta name="viewport" content="width=device-width,initial-scale=1">`)
	fmt.Fprintf(&b, `<title>%s</title>`, html.EscapeString(s.cfg.ServerName))
	b.WriteString(`<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif;
max-width:660px;margin:48px auto;padding:0 20px;color:#1a1a1a;line-height:1.6}
h1{font-size:20px;font-weight:500;margin:0 0 4px}
.sub{color:#666;font-size:13px;margin:0 0 28px}
table{border-collapse:collapse;width:100%;font-size:13px}
td{padding:7px 0;border-bottom:1px solid #eee}
td:first-child{color:#666;width:150px}
code{background:#f4f4f4;padding:2px 6px;border-radius:4px;font-size:12px}
.note{background:#fff8e6;border:1px solid #f0d9a0;border-radius:8px;padding:12px 14px;
font-size:13px;margin-top:24px}
</style></head><body>`)
	fmt.Fprintf(&b, `<h1>%s</h1>`, html.EscapeString(s.cfg.ServerName))
	fmt.Fprintf(&b, `<p class="sub">本地媒体中心 · v%s · API v%d</p>`, Version, APIVersion)

	b.WriteString(`<table>`)
	fmt.Fprintf(&b, `<tr><td>照片</td><td>%d</td></tr>`, st.Photos)
	fmt.Fprintf(&b, `<tr><td>视频</td><td>%d</td></tr>`, st.Videos)
	fmt.Fprintf(&b, `<tr><td>占用</td><td>%s</td></tr>`, humanBytes(st.TotalBytes))
	fmt.Fprintf(&b, `<tr><td>扫描目录</td><td>%d 个</td></tr>`, st.Folders)
	fmt.Fprintf(&b, `<tr><td>FFmpeg</td><td>%s</td></tr>`, yesNo(meta.HasTool(s.cfg.FFmpeg)))
	fmt.Fprintf(&b, `<tr><td>数据目录</td><td><code>%s</code></td></tr>`, html.EscapeString(s.cfg.DataDir))
	b.WriteString(`</table>`)

	if tok == "" {
		b.WriteString(`<div class="note">需要在地址后附加 <code>?token=你的令牌</code> 才能调用接口。` +
			`令牌保存在数据目录的 <code>config.json</code> 中。</div>`)
	} else {
		fmt.Fprintf(&b, `<p style="font-size:13px">试试 <a href="/api/media?token=%s">/api/media</a></p>`,
			html.EscapeString(tok))
	}
	b.WriteString(`</body></html>`)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(b.String()))
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit && exp < 4; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTP"[exp])
}

func yesNo(v bool) string {
	if v {
		return "可用"
	}
	return "未检测到"
}
