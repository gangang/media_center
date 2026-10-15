package api

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"mediacenter/internal/store"
)

// mediaDTO is the wire format for a media item.
//
// The URLs are relative so a client that reached the server through any
// address (mDNS hostname, IP, reverse proxy) can resolve them correctly.
type mediaDTO struct {
	ID           int64  `json:"id"`
	FileName     string `json:"file_name"`
	MediaType    string `json:"media_type"`
	MimeType     string `json:"mime_type"`
	FileSize     int64  `json:"file_size"`
	TakenAt      string `json:"taken_at"`
	Width        int    `json:"width"`
	Height       int    `json:"height"`
	DurationMs   int64  `json:"duration_ms"`
	VideoCodec   string `json:"video_codec,omitempty"`
	AudioCodec   string `json:"audio_codec,omitempty"`
	ThumbnailURL string `json:"thumbnail_url"`
	OriginalURL  string `json:"original_url"`
}

func toDTO(m store.MediaFile) mediaDTO {
	return mediaDTO{
		ID:           m.ID,
		FileName:     m.FileName,
		MediaType:    m.MediaType,
		MimeType:     m.MimeType,
		FileSize:     m.FileSize,
		TakenAt:      m.TakenAt,
		Width:        m.Width,
		Height:       m.Height,
		DurationMs:   m.DurationMs,
		VideoCodec:   m.VideoCodec,
		AudioCodec:   m.AudioCodec,
		ThumbnailURL: fmt.Sprintf("/api/media/%d/thumbnail", m.ID),
		OriginalURL:  fmt.Sprintf("/api/media/%d/original", m.ID),
	}
}

func (s *Server) handleListMedia(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	p := store.ListParams{
		Type:     q.Get("type"),
		Page:     atoiDefault(q.Get("page"), 1),
		PageSize: atoiDefault(q.Get("page_size"), 60),
		Sort:     q.Get("sort"),
		Query:    q.Get("q"),
		From:     q.Get("from"),
		To:       q.Get("to"),
	}

	res, err := s.st.ListMedia(p)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	items := make([]mediaDTO, 0, len(res.Items))
	for _, m := range res.Items {
		items = append(items, toDTO(m))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"items":     items,
		"total":     res.Total,
		"page":      res.Page,
		"page_size": res.PageSize,
	})
}

func (s *Server) handleGetMedia(w http.ResponseWriter, r *http.Request) {
	m, ok := s.lookup(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, toDTO(*m))
}

func (s *Server) handleThumbnail(w http.ResponseWriter, r *http.Request) {
	m, ok := s.lookup(w, r)
	if !ok {
		return
	}

	path, err := s.sc.EnsureThumbnail(m)
	if err != nil {
		writeErr(w, http.StatusNotFound, "thumbnail unavailable: "+err.Error())
		return
	}

	// Thumbnails are addressed by content hash, so they never change: cache
	// them aggressively on the client.
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.Header().Set("Content-Type", "image/jpeg")
	http.ServeFile(w, r, path)
}

// handleOriginal streams the untouched media file.
//
// http.ServeContent gives us HTTP Range, If-Range and Last-Modified handling
// for free, which is exactly what lets a video player seek without the server
// transcoding anything.
func (s *Server) handleOriginal(w http.ResponseWriter, r *http.Request) {
	m, ok := s.lookup(w, r)
	if !ok {
		return
	}

	f, err := os.Open(m.FilePath)
	if err != nil {
		writeErr(w, http.StatusNotFound, "file is no longer available on disk")
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if info.IsDir() {
		writeErr(w, http.StatusBadRequest, "path is a directory")
		return
	}

	w.Header().Set("Accept-Ranges", "bytes")
	if m.MimeType != "" {
		w.Header().Set("Content-Type", m.MimeType)
	}
	// Originals are immutable too, but they can be replaced in place, so a
	// shorter window keeps things correct without hammering the disk.
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Header().Set("Content-Disposition", contentDisposition(m.FileName))

	http.ServeContent(w, r, m.FileName, info.ModTime(), f)
}

// lookup resolves the {id} path value and writes the appropriate error
// response when the row does not exist. It reports whether the caller should
// continue.
func (s *Server) lookup(w http.ResponseWriter, r *http.Request) (*store.MediaFile, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, "invalid media id")
		return nil, false
	}
	m, err := s.st.GetMedia(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return nil, false
	}
	if m == nil {
		writeErr(w, http.StatusNotFound, "media not found")
		return nil, false
	}
	return m, true
}

// contentDisposition builds a header that survives non-ASCII file names.
func contentDisposition(name string) string {
	ascii := strings.Map(func(r rune) rune {
		if r < 32 || r > 126 || r == '"' || r == '\\' {
			return '_'
		}
		return r
	}, name)
	return fmt.Sprintf("inline; filename=%q; filename*=UTF-8''%s", ascii, urlEncode(name))
}

func urlEncode(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
			continue
		}
		fmt.Fprintf(&b, "%%%02X", c)
	}
	return b.String()
}

func atoiDefault(s string, def int) int {
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}
