package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"mediacenter/internal/store"
)

// Limits that keep a single request from doing unbounded work. They are
// generous enough for real use and small enough to reject abuse.
const (
	maxAlbumNameLen = 200
	maxAlbumDescLen = 2000
	maxAlbumItems   = 500
)

// albumDTO is the wire format for an album.
//
// CoverURL is derived rather than stored so the client never has to build it,
// and so an album whose cover file was pruned degrades to an empty string
// instead of a broken link.
type albumDTO struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	ItemCount   int64  `json:"item_count"`
	CoverURL    string `json:"cover_url"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

func toAlbumDTO(a store.Album) albumDTO {
	d := albumDTO{
		ID:          a.ID,
		Name:        a.Name,
		Description: a.Description,
		ItemCount:   a.ItemCount,
		CreatedAt:   a.CreatedAt,
		UpdatedAt:   a.UpdatedAt,
	}
	if a.CoverMediaID > 0 {
		d.CoverURL = fmt.Sprintf("/api/media/%d/thumbnail", a.CoverMediaID)
	}
	return d
}

// ---------------------------------------------------------------- handlers --

func (s *Server) handleListAlbums(w http.ResponseWriter, r *http.Request) {
	albums, err := s.st.ListAlbums()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	items := make([]albumDTO, 0, len(albums))
	for _, a := range albums {
		items = append(items, toAlbumDTO(a))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) handleCreateAlbum(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}
	if !decodeBody(w, r, &body) {
		return
	}

	name, ok := s.validateAlbumName(w, body.Name)
	if !ok {
		return
	}
	if len(body.Description) > maxAlbumDescLen {
		writeErr(w, http.StatusBadRequest, "description is too long")
		return
	}

	album, err := s.st.CreateAlbum(name, body.Description)
	if errors.Is(err, store.ErrAlbumNameTaken) {
		writeErr(w, http.StatusConflict, "已存在同名相册")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, toAlbumDTO(*album))
}

func (s *Server) handleGetAlbum(w http.ResponseWriter, r *http.Request) {
	album, ok := s.lookupAlbum(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, toAlbumDTO(*album))
}

// handleUpdateAlbum renames and/or re-describes an album. Absent JSON keys mean
// "leave unchanged", which is why the request uses pointers.
func (s *Server) handleUpdateAlbum(w http.ResponseWriter, r *http.Request) {
	album, ok := s.lookupAlbum(w, r)
	if !ok {
		return
	}

	var body struct {
		Name        *string `json:"name"`
		Description *string `json:"description"`
	}
	if !decodeBody(w, r, &body) {
		return
	}

	if body.Name != nil {
		name, ok := s.validateAlbumName(w, *body.Name)
		if !ok {
			return
		}
		body.Name = &name
	}
	if body.Description != nil && len(*body.Description) > maxAlbumDescLen {
		writeErr(w, http.StatusBadRequest, "description is too long")
		return
	}

	updated, err := s.st.UpdateAlbum(album.ID, body.Name, body.Description)
	if errors.Is(err, store.ErrAlbumNameTaken) {
		writeErr(w, http.StatusConflict, "已存在同名相册")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if updated == nil {
		writeErr(w, http.StatusNotFound, "album not found")
		return
	}
	writeJSON(w, http.StatusOK, toAlbumDTO(*updated))
}

// handleDeleteAlbum removes the album only. The media it grouped stays on disk
// and stays in the index — albums are a view, not a container.
func (s *Server) handleDeleteAlbum(w http.ResponseWriter, r *http.Request) {
	album, ok := s.lookupAlbum(w, r)
	if !ok {
		return
	}
	if err := s.st.DeleteAlbum(album.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": album.ID})
}

func (s *Server) handleListAlbumMedia(w http.ResponseWriter, r *http.Request) {
	album, ok := s.lookupAlbum(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	res, err := s.st.ListAlbumMedia(
		album.ID,
		q.Get("sort"),
		atoiDefault(q.Get("page"), 1),
		atoiDefault(q.Get("page_size"), 60),
	)
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

func (s *Server) handleAddAlbumMedia(w http.ResponseWriter, r *http.Request) {
	album, ok := s.lookupAlbum(w, r)
	if !ok {
		return
	}
	ids, ok := s.readMediaIDs(w, r)
	if !ok {
		return
	}

	added, missing, err := s.st.AddAlbumItems(album.ID, ids)
	if errors.Is(err, store.ErrNoSuchMedia) {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error":   "部分媒体不存在",
			"missing": missing,
		})
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"added":     added,
		"requested": len(ids),
	})
}

func (s *Server) handleRemoveAlbumMedia(w http.ResponseWriter, r *http.Request) {
	album, ok := s.lookupAlbum(w, r)
	if !ok {
		return
	}
	ids, ok := s.readMediaIDs(w, r)
	if !ok {
		return
	}

	removed, err := s.st.RemoveAlbumItems(album.ID, ids)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"removed":   removed,
		"requested": len(ids),
	})
}

// handleMediaAlbums answers "which albums is this item in?" for the viewer.
func (s *Server) handleMediaAlbums(w http.ResponseWriter, r *http.Request) {
	m, ok := s.lookup(w, r)
	if !ok {
		return
	}
	membership, err := s.st.AlbumsForMedia([]int64{m.ID})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	ids := membership[m.ID]
	items := []albumDTO{}
	for _, id := range ids {
		a, err := s.st.GetAlbum(id)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if a != nil {
			items = append(items, toAlbumDTO(*a))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// ----------------------------------------------------------------- helpers --

// lookupAlbum resolves the {id} path value into an album, writing the right
// error response when it is missing. It reports whether the caller may proceed.
func (s *Server) lookupAlbum(w http.ResponseWriter, r *http.Request) (*store.Album, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, "invalid album id")
		return nil, false
	}
	a, err := s.st.GetAlbum(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return nil, false
	}
	if a == nil {
		writeErr(w, http.StatusNotFound, "album not found")
		return nil, false
	}
	return a, true
}

// validateAlbumName trims, bounds-checks and rejects an empty name.
func (s *Server) validateAlbumName(w http.ResponseWriter, raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	if name == "" {
		writeErr(w, http.StatusBadRequest, "相册名称不能为空")
		return "", false
	}
	if len([]rune(name)) > maxAlbumNameLen {
		writeErr(w, http.StatusBadRequest, "相册名称过长")
		return "", false
	}
	return name, true
}

// readMediaIDs accepts the ids from a JSON body, falling back to a
// comma-separated query parameter.
//
// The query form exists because DELETE with a body is awkward for some HTTP
// clients; supporting both costs almost nothing.
func (s *Server) readMediaIDs(w http.ResponseWriter, r *http.Request) ([]int64, bool) {
	var body struct {
		MediaIDs []int64 `json:"media_ids"`
	}

	if r.Body != nil {
		// An empty body is not an error here: the query parameter may carry
		// the ids instead.
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body)
	}

	ids := body.MediaIDs
	if len(ids) == 0 {
		if raw := r.URL.Query().Get("media_ids"); raw != "" {
			for _, part := range strings.Split(raw, ",") {
				part = strings.TrimSpace(part)
				if part == "" {
					continue
				}
				id, err := strconv.ParseInt(part, 10, 64)
				if err != nil || id <= 0 {
					writeErr(w, http.StatusBadRequest, "invalid media id: "+part)
					return nil, false
				}
				ids = append(ids, id)
			}
		}
	}

	if len(ids) == 0 {
		writeErr(w, http.StatusBadRequest, "media_ids 不能为空")
		return nil, false
	}
	if len(ids) > maxAlbumItems {
		writeErr(w, http.StatusBadRequest, "一次最多操作 500 个媒体")
		return nil, false
	}
	for _, id := range ids {
		if id <= 0 {
			writeErr(w, http.StatusBadRequest, "invalid media id")
			return nil, false
		}
	}
	return ids, true
}

// decodeBody reads a bounded JSON body and writes 400 on malformed input.
func decodeBody(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	return true
}
