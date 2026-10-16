package api

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"mediacenter/internal/scanner"
	"mediacenter/internal/store"
)

// Limits for the chunked upload API.
const (
	// defaultChunkSize is what the server suggests when a client does not care.
	// 4 MiB is a compromise: large enough that per-request overhead vanishes,
	// small enough that a dropped connection only costs a few seconds of work.
	defaultChunkSize = 4 << 20
	minChunkSize     = 256 << 10
	maxChunkSize     = 64 << 20

	// maxUploadSize caps a single file. It is far above any phone video and
	// exists only to stop a runaway client from filling the disk.
	maxUploadSize = 64 << 30

	// minUploadSize matches the floor the folder scanner applies. Accepting a
	// smaller file would create an index row that the very next scan prunes,
	// because the walk never reports anything under this size.
	minUploadSize = 1024

	maxUploadNameLen = 200
	maxNameAttempts  = 1000

	// UploadSessionTTL is how long an unfinished session is kept before the
	// sweeper removes it and unlinks its partial file. It is exported so the
	// server's startup sweep uses exactly the same window the API advertises.
	UploadSessionTTL = 24 * time.Hour
)

// uploadDTO is the wire format for an upload session.
//
// Received is the list of chunk indexes already on disk rather than just a
// count: a client that reconnects after a crash needs to know exactly which
// pieces to send, and a count alone cannot tell it that.
type uploadDTO struct {
	UploadID       string `json:"upload_id"`
	FileName       string `json:"file_name"`
	Status         string `json:"status"`
	MediaType      string `json:"media_type"`
	TotalSize      int64  `json:"total_size"`
	ChunkSize      int64  `json:"chunk_size"`
	ChunkCount     int    `json:"chunk_count"`
	ReceivedChunks int    `json:"received_chunks"`
	Received       []int  `json:"received"`
	MediaID        int64  `json:"media_id,omitempty"`
	ExpiresAt      string `json:"expires_at"`
	CreatedAt      string `json:"created_at"`
}

// ---------------------------------------------------------------- handlers --

// handleCreateUpload opens a session, or short-circuits entirely when the
// server already holds these exact bytes.
func (s *Server) handleCreateUpload(w http.ResponseWriter, r *http.Request) {
	var body struct {
		FileName    string `json:"file_name"`
		FileSize    int64  `json:"file_size"`
		ContentHash string `json:"content_hash"`
		ChunkSize   int64  `json:"chunk_size"`
	}
	if !decodeBody(w, r, &body) {
		return
	}

	name, ok := s.validateUploadName(w, body.FileName)
	if !ok {
		return
	}

	// The extension decides everything downstream, so reject anything the
	// indexer could not read before a single byte travels.
	if _, mediaType, known := scanner.MediaTypeForName(name); !known {
		writeErr(w, http.StatusUnsupportedMediaType,
			"不支持的文件类型: "+filepath.Ext(name))
		return
	} else {
		body.FileName = name
		_ = mediaType
	}

	if body.FileSize < minUploadSize {
		writeErr(w, http.StatusBadRequest,
			fmt.Sprintf("file_size 不能小于 %d 字节", minUploadSize))
		return
	}
	if body.FileSize > maxUploadSize {
		writeErr(w, http.StatusRequestEntityTooLarge,
			fmt.Sprintf("file_size 不能超过 %d 字节", int64(maxUploadSize)))
		return
	}

	hash := normalizeHash(body.ContentHash)

	// Instant upload: if the client can name the content, the server may
	// already have it. A phone re-running a backup then costs one small request
	// per photo instead of a full transfer.
	if hash != "" {
		existing, err := s.st.FindMediaByHash(hash)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if existing != nil {
			writeJSON(w, http.StatusOK, map[string]any{
				"dedup": true,
				"media": toDTO(*existing),
			})
			return
		}
	}

	chunkSize := clampInt64(body.ChunkSize, minChunkSize, maxChunkSize)
	if body.ChunkSize <= 0 {
		chunkSize = defaultChunkSize
	}
	chunkCount := int((body.FileSize + chunkSize - 1) / chunkSize)

	id, err := newUploadID()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Create the temp file up front. An obviously impossible size then fails
	// here, before the phone has spent ten minutes on a doomed transfer.
	tempPath := filepath.Join(s.cfg.UploadTempDir(), id+".part")
	f, err := os.OpenFile(tempPath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "无法创建上传临时文件: "+err.Error())
		return
	}
	if err := f.Truncate(body.FileSize); err != nil {
		f.Close()
		os.Remove(tempPath)
		writeErr(w, http.StatusInternalServerError, "无法预分配上传空间: "+err.Error())
		return
	}
	if err := f.Close(); err != nil {
		os.Remove(tempPath)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	u := &store.Upload{
		ID:          id,
		FileName:    name,
		ContentHash: hash,
		TotalSize:   body.FileSize,
		ChunkSize:   chunkSize,
		ChunkCount:  chunkCount,
		MediaType:   mediaTypeOf(name),
		TempPath:    tempPath,
		Status:      store.UploadPending,
	}
	if err := s.st.CreateUpload(u); err != nil {
		os.Remove(tempPath)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, toUploadDTO(u, []int{}))
}

// handleUploadChunk receives one slice of a file and writes it straight to its
// final offset.
//
// Nothing is buffered in memory and no temporary chunk files are kept, so a
// 4 GB video costs the server the same as a 4 KB photo.
func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request) {
	u, ok := s.lookupUpload(w, r)
	if !ok {
		return
	}
	if u.Status != store.UploadPending {
		writeErr(w, http.StatusConflict, "上传会话已结束，状态为 "+u.Status)
		return
	}

	index, err := strconv.Atoi(r.PathValue("index"))
	if err != nil || index < 0 || index >= u.ChunkCount {
		writeErr(w, http.StatusBadRequest,
			fmt.Sprintf("分片序号越界，应为 0 至 %d", u.ChunkCount-1))
		return
	}

	want := u.ChunkSize
	if index == u.ChunkCount-1 {
		want = u.TotalSize - int64(index)*u.ChunkSize
	}
	if r.ContentLength >= 0 && r.ContentLength != want {
		writeErr(w, http.StatusBadRequest,
			fmt.Sprintf("该分片应为 %d 字节，实际 %d 字节", want, r.ContentLength))
		return
	}

	f, err := os.OpenFile(u.TempPath, os.O_WRONLY, 0o644)
	if err != nil {
		writeErr(w, http.StatusNotFound, "上传临时文件已丢失，请重新发起上传")
		return
	}
	defer f.Close()

	// LimitReader(1 extra byte) makes a body that is too long an error instead
	// of a silent partial write that happens to look complete.
	offset := int64(index) * u.ChunkSize
	n, err := io.Copy(io.NewOffsetWriter(f, offset), io.LimitReader(r.Body, want+1))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "写入分片失败: "+err.Error())
		return
	}
	if n != want {
		writeErr(w, http.StatusBadRequest,
			fmt.Sprintf("该分片应为 %d 字节，实际 %d 字节", want, n))
		return
	}

	received, err := s.st.AddUploadChunk(u.ID, index, n)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"upload_id":       u.ID,
		"chunk_index":     index,
		"chunk_size":      n,
		"received_chunks": received,
		"chunk_count":     u.ChunkCount,
		"done":            received >= u.ChunkCount,
	})
}

// handleCompleteUpload verifies the assembled file and turns it into media.
//
// The order matters: verify the bytes, then claim a destination name, then move
// and index. A file that fails verification never reaches the library and never
// becomes a row, so a truncated transfer can never show up in the gallery as a
// plausible-looking photo.
func (s *Server) handleCompleteUpload(w http.ResponseWriter, r *http.Request) {
	u, ok := s.lookupUpload(w, r)
	if !ok {
		return
	}

	// Completion is idempotent: a client that lost the response can ask again
	// and still get its media id back.
	if u.Status == store.UploadDone && u.MediaID > 0 {
		if m, err := s.st.GetMedia(u.MediaID); err == nil && m != nil {
			writeJSON(w, http.StatusOK, map[string]any{"media": toDTO(*m), "dedup": false})
			return
		}
	}
	if u.Status != store.UploadPending {
		writeErr(w, http.StatusConflict, "上传会话状态为 "+u.Status+"，无法完成")
		return
	}

	received, err := s.st.ReceivedChunkIndexes(u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(received) != u.ChunkCount {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    "分片不完整，无法完成上传",
			"received": received,
			"missing":  missingChunks(received, u.ChunkCount),
		})
		return
	}

	info, err := os.Stat(u.TempPath)
	if err != nil {
		writeErr(w, http.StatusNotFound, "上传临时文件已丢失，请重新发起上传")
		return
	}
	if info.Size() != u.TotalSize {
		_ = s.st.FailUpload(u.ID)
		writeErr(w, http.StatusConflict,
			fmt.Sprintf("文件大小不符：声明 %d 字节，实际 %d 字节", u.TotalSize, info.Size()))
		return
	}

	// Recompute the identity from the bytes on disk. A client-declared hash is
	// a claim, not evidence.
	hash, err := scanner.ContentHash(u.TempPath, info.Size())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "校验文件失败: "+err.Error())
		return
	}
	if u.ContentHash != "" && !strings.EqualFold(u.ContentHash, hash) {
		_ = s.st.FailUpload(u.ID)
		writeErr(w, http.StatusUnprocessableEntity,
			"内容校验失败：收到文件的哈希与声明不一致，请重新上传")
		return
	}

	// The client may not have known the hash up front. Now that we do, a
	// duplicate can still be recognised — and the copy we just received is
	// simply discarded instead of being stored twice.
	if u.ContentHash == "" {
		if existing, err := s.st.FindMediaByHash(hash); err == nil && existing != nil {
			s.discardUpload(u)
			writeJSON(w, http.StatusOK, map[string]any{
				"dedup": true,
				"media": toDTO(*existing),
			})
			return
		}
	}

	target, err := s.claimTargetPath(u.FileName)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := os.Rename(u.TempPath, target); err != nil {
		// Release the name we just claimed so a retry is not blocked by an
		// empty placeholder.
		_ = os.Remove(target)
		writeErr(w, http.StatusInternalServerError, "移动文件到媒体库失败: "+err.Error())
		return
	}

	folderID, err := s.st.FolderIDByPath(s.cfg.LibraryDir())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	mf, err := s.sc.IndexFile(target, folderID, store.OriginUpload)
	if err != nil {
		// The file is safely in the library, so the next scan will pick it up
		// even though this request failed.
		writeErr(w, http.StatusInternalServerError, "索引新文件失败: "+err.Error())
		return
	}

	if err := s.st.FinishUpload(u.ID, mf.ID, target); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"media": toDTO(*mf),
		"dedup": false,
	})
}

// handleGetUpload reports progress so an interrupted transfer can resume.
func (s *Server) handleGetUpload(w http.ResponseWriter, r *http.Request) {
	u, ok := s.lookupUpload(w, r)
	if !ok {
		return
	}
	received, err := s.st.ReceivedChunkIndexes(u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, toUploadDTO(u, received))
}

// handleCancelUpload abandons a transfer and cleans up after it.
func (s *Server) handleCancelUpload(w http.ResponseWriter, r *http.Request) {
	u, ok := s.lookupUpload(w, r)
	if !ok {
		return
	}
	s.discardUpload(u)
	writeJSON(w, http.StatusOK, map[string]any{"canceled": u.ID})
}

// ----------------------------------------------------------------- helpers --

// lookupUpload resolves the {id} path value, writing the appropriate error when
// the session is unknown. It reports whether the caller may proceed.
func (s *Server) lookupUpload(w http.ResponseWriter, r *http.Request) (*store.Upload, bool) {
	id := strings.TrimSpace(r.PathValue("id"))
	if id == "" || len(id) > 64 {
		writeErr(w, http.StatusBadRequest, "invalid upload id")
		return nil, false
	}
	u, err := s.st.GetUpload(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return nil, false
	}
	if u == nil {
		writeErr(w, http.StatusNotFound, "上传会话不存在或已过期")
		return nil, false
	}
	return u, true
}

// discardUpload removes a session's temp file and its database rows. It is used
// both by cancel and by the dedup path, where the bytes are good but unwanted.
func (s *Server) discardUpload(u *store.Upload) {
	if u.TempPath != "" {
		_ = os.Remove(u.TempPath)
	}
	_ = s.st.DeleteUpload(u.ID)
}

// claimTargetPath picks a destination inside the library and claims the name
// atomically.
//
// Camera filenames collide constantly — two phones backing up IMG_0001.JPG is
// the normal case, not a rare one. O_EXCL makes the existence check and the
// claim a single operation, so nothing can slip between them and silently
// overwrite a photo that arrived a moment earlier.
func (s *Server) claimTargetPath(name string) (string, error) {
	// Shard by month so the library stays browsable instead of becoming one
	// directory with fifty thousand entries.
	dir := filepath.Join(s.cfg.LibraryDir(), time.Now().UTC().Format("2006/01"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)

	for i := 0; i <= maxNameAttempts; i++ {
		candidate := filepath.Join(dir, name)
		if i > 0 {
			candidate = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		}
		f, err := os.OpenFile(candidate, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err == nil {
			f.Close()
			return candidate, nil
		}
		if !os.IsExist(err) {
			return "", err
		}
	}
	return "", fmt.Errorf("无法为 %q 生成唯一文件名", name)
}

// validateUploadName rejects anything that is not a plain file name.
//
// The upload API is the one place where a client chooses a path component, so
// it is also the one place where a traversal attempt would matter.
func (s *Server) validateUploadName(w http.ResponseWriter, raw string) (string, bool) {
	name := strings.TrimSpace(raw)
	switch {
	case name == "":
		writeErr(w, http.StatusBadRequest, "file_name 不能为空")
		return "", false
	case name == "." || name == "..":
		writeErr(w, http.StatusBadRequest, "file_name 非法")
		return "", false
	case strings.HasPrefix(name, "."):
		writeErr(w, http.StatusBadRequest, "file_name 不能以点开头")
		return "", false
	case len([]rune(name)) > maxUploadNameLen:
		writeErr(w, http.StatusBadRequest, "file_name 过长")
		return "", false
	case strings.ContainsAny(name, "/\\\x00"):
		writeErr(w, http.StatusBadRequest, "file_name 不能包含路径分隔符")
		return "", false
	case filepath.Base(name) != name:
		writeErr(w, http.StatusBadRequest, "file_name 必须是文件名，不能是路径")
		return "", false
	}
	return name, true
}

// toUploadDTO renders a session for the wire. received may be nil, which is how
// a freshly created session is reported.
func toUploadDTO(u *store.Upload, received []int) uploadDTO {
	if received == nil {
		received = []int{}
	}
	return uploadDTO{
		UploadID:       u.ID,
		FileName:       u.FileName,
		Status:         u.Status,
		MediaType:      u.MediaType,
		TotalSize:      u.TotalSize,
		ChunkSize:      u.ChunkSize,
		ChunkCount:     u.ChunkCount,
		ReceivedChunks: u.ReceivedChunks,
		Received:       received,
		MediaID:        u.MediaID,
		ExpiresAt:      expiresAt(u.UpdatedAt),
		CreatedAt:      u.CreatedAt,
	}
}

// expiresAt tells the client how long it has before the sweeper reclaims an
// unfinished session.
func expiresAt(updatedAt string) string {
	t, err := time.Parse(time.RFC3339, updatedAt)
	if err != nil {
		return ""
	}
	return t.Add(UploadSessionTTL).UTC().Format(time.RFC3339)
}

// missingChunks lists the indexes still outstanding, given what has arrived.
func missingChunks(received []int, total int) []int {
	have := make(map[int]bool, len(received))
	for _, i := range received {
		have[i] = true
	}
	missing := []int{}
	for i := 0; i < total; i++ {
		if !have[i] {
			missing = append(missing, i)
		}
	}
	return missing
}

// normalizeHash accepts a hex digest in either case and ignores anything that
// is not a plausible sha256, so a client cannot make the server compare against
// a value that could never match.
func normalizeHash(raw string) string {
	h := strings.ToLower(strings.TrimSpace(raw))
	if len(h) != 64 {
		return ""
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return ""
		}
	}
	return h
}

// mediaTypeOf classifies a validated file name. The name has already passed
// MediaTypeForName, so the fallback is unreachable in practice.
func mediaTypeOf(name string) string {
	if _, mediaType, ok := scanner.MediaTypeForName(name); ok {
		return mediaType
	}
	return "photo"
}

// newUploadID returns a random session id. It is random rather than sequential
// so one client cannot guess or disturb another's transfer.
func newUploadID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func clampInt64(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
