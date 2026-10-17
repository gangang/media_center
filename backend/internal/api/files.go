package api

// File management: rename and move.
//
// Two invariants shape everything in this file.
//
// 1. **Operations only apply to registered directories.** A media file can be
//    renamed or moved only when both its current path and its destination are
//    inside a scan folder the user registered (授权路径模型). Registering a
//    directory is the act of authorisation; it is visible in the folder list
//    and can be withdrawn by removing the folder. Origin (upload/scan) is
//    deliberately not the boundary — it answers "where did this come from",
//    not "did the user hand this to the media centre".
//
// 2. **The row is updated in place, never replaced.** The scanner identifies
//    files by path, so "delete the old row, insert a new one" would mint a new
//    media id, and album_items cascades on delete (D15): the photo would drop
//    out of every album, permanently. An UPDATE keeps the id, keeps the albums,
//    and keeps the thumbnail valid (it is addressed by content hash).
//
// Disk first, database second. If the rename fails on disk, the index still
// points at a file that exists; the other order would leave a row pointing at
// a file that does not.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"mediacenter/internal/store"
)

// maxFileBatch bounds one batch of file operations. Renaming, moving and
// deleting are cheap per item but unbounded input is not: a client bug that
// sends 100k ids would otherwise hold the request (and the disk) for minutes.
const maxFileBatch = 200

// renameBody is PATCH /api/media/{id}. Both fields are optional, but at least
// one must be present — a request that changes nothing is a client bug, and
// answering 200 would hide it.
type renameBody struct {
	Name     string `json:"name"`
	FolderID int64  `json:"folder_id"`
}

// moveBody is POST /api/media/move.
type moveBody struct {
	IDs      []int64 `json:"ids"`
	FolderID int64   `json:"folder_id"`
}

func (s *Server) handleRenameMedia(w http.ResponseWriter, r *http.Request) {
	id, err := idFromPath(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid media id")
		return
	}

	var body renameBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	m, err := s.st.GetMedia(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if m == nil {
		writeErr(w, http.StatusNotFound, "media not found")
		return
	}

	roots, err := s.st.EnabledFolders()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !underRoots(m.FilePath, roots) {
		writeErr(w, http.StatusForbidden,
			"该文件所在的目录未注册为扫描目录，不能管理。请先在服务器管理中添加该目录")
		return
	}

	// Destination directory: where the file lives now, unless a folder was
	// named. A folder id that is not registered (or not enabled) is refused
	// rather than silently creating an unindexed corner of the disk.
	targetDir := filepath.Dir(m.FilePath)
	targetFolderID := m.ScanFolderID
	if body.FolderID > 0 && body.FolderID != m.ScanFolderID {
		folder := folderByID(roots, body.FolderID)
		if folder == nil {
			writeErr(w, http.StatusBadRequest, "目标目录不存在或未启用")
			return
		}
		targetDir = folder.Path
		targetFolderID = folder.ID
	}

	newName := m.FileName
	if name := strings.TrimSpace(body.Name); name != "" {
		if err := checkMediaName(name); err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		// The extension decides which branch of the pipeline a file takes
		// (MediaTypeForName). Renaming a photo to .txt would leave the index
		// claiming one thing about a file that is another.
		if !strings.EqualFold(filepath.Ext(name), filepath.Ext(m.FileName)) {
			writeErr(w, http.StatusBadRequest, "不能修改扩展名：类型判定依据扩展名")
			return
		}
		newName = name
	}

	if newName == m.FileName && targetFolderID == m.ScanFolderID {
		writeErr(w, http.StatusBadRequest, "名称或目标目录没有变化")
		return
	}
	if !underRoots(targetDir, roots) {
		writeErr(w, http.StatusBadRequest, "目标目录未注册为扫描目录")
		return
	}

	target, err := uniqueTarget(targetDir, newName)
	if err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}

	info, err := moveOnDisk(m.FilePath, target)
	if err != nil {
		// The index still points at a file that exists, so this is a clean
		// failure: nothing was half-done.
		writeErr(w, http.StatusBadRequest, "文件移动失败："+err.Error())
		return
	}

	if err := s.st.UpdateMediaLocation(
		m.ID, target, filepath.Base(target), info.Size(), info.ModTime().Unix(),
		targetFolderID, nowISO(),
	); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	updated, err := s.st.GetMedia(m.ID)
	if err != nil || updated == nil {
		writeErr(w, http.StatusInternalServerError, "moved, but failed to read the row back")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"item": toDTO(*updated),
		// The applied name can differ from the requested one when the
		// directory already had a file by that name.
		"applied_name": filepath.Base(target),
	})
}

func (s *Server) handleMoveMedia(w http.ResponseWriter, r *http.Request) {
	var body moveBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if len(body.IDs) == 0 {
		writeErr(w, http.StatusBadRequest, "ids 不能为空")
		return
	}
	if len(body.IDs) > maxFileBatch {
		writeErr(w, http.StatusBadRequest,
			fmt.Sprintf("一次最多移动 %d 个文件", maxFileBatch))
		return
	}

	roots, err := s.st.EnabledFolders()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	folder := folderByID(roots, body.FolderID)
	if folder == nil {
		writeErr(w, http.StatusBadRequest, "目标目录不存在或未启用")
		return
	}

	type result struct {
		ID    int64  `json:"id"`
		OK    bool   `json:"ok"`
		Path  string `json:"path,omitempty"`
		Error string `json:"error,omitempty"`
	}

	results := make([]result, 0, len(body.IDs))
	moved := 0
	for _, id := range body.IDs {
		m, err := s.st.GetMedia(id)
		if err != nil {
			results = append(results, result{ID: id, Error: err.Error()})
			continue
		}
		if m == nil {
			results = append(results, result{ID: id, Error: "找不到该媒体"})
			continue
		}
		if !underRoots(m.FilePath, roots) {
			results = append(results, result{
				ID:    id,
				Error: "所在目录未注册，不能管理",
			})
			continue
		}
		if m.ScanFolderID == folder.ID {
			results = append(results, result{
				ID:    id,
				OK:    true,
				Path:  m.FilePath,
				Error: "",
			})
			moved++
			continue
		}

		target, err := uniqueTarget(folder.Path, m.FileName)
		if err != nil {
			results = append(results, result{ID: id, Error: err.Error()})
			continue
		}
		info, err := moveOnDisk(m.FilePath, target)
		if err != nil {
			results = append(results, result{ID: id, Error: "文件移动失败：" + err.Error()})
			continue
		}
		if err := s.st.UpdateMediaLocation(
			m.ID, target, filepath.Base(target), info.Size(), info.ModTime().Unix(),
			folder.ID, nowISO(),
		); err != nil {
			results = append(results, result{ID: id, Error: err.Error()})
			continue
		}
		results = append(results, result{ID: id, OK: true, Path: target})
		moved++
	}

	// Partial success is the expected shape: three files, one on a drive that
	// just got unplugged. Rolling the batch back would make the user think
	// nothing happened, and they would retry the same doomed operation.
	writeJSON(w, http.StatusOK, map[string]any{
		"moved":   moved,
		"failed":  len(body.IDs) - moved,
		"results": results,
	})
}

// ---------------------------------------------------------------- delete --

// deleteBody is POST /api/media/delete.
type deleteBody struct {
	IDs []int64 `json:"ids"`
}

// handleDeleteMedia removes one file: index row, the file on disk, and its
// thumbnail.
//
// All three, in that order of importance but not of execution: dropping only
// the row would let the next scan re-index the file (the user sees "it came
// back"), and leaving the thumbnail behind would keep a picture of a deleted
// file on disk forever.
//
// There is no trash. The design considered one and the decision was to ship
// the simpler thing first: a recycle bin doubles the disk footprint for a
// failure mode (a mis-tap) that a confirmation dialog showing the full path
// addresses more directly. It can be added later as a directory plus a
// "clear trash" action, without changing this API.
//
// A file that is already gone from disk is not an error: the row is stale,
// and removing it is exactly what the user asked for.
func (s *Server) handleDeleteMedia(w http.ResponseWriter, r *http.Request) {
	id, err := idFromPath(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid media id")
		return
	}

	m, err := s.st.GetMedia(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if m == nil {
		writeErr(w, http.StatusNotFound, "media not found")
		return
	}

	roots, err := s.st.EnabledFolders()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !underRoots(m.FilePath, roots) {
		writeErr(w, http.StatusForbidden,
			"该文件所在的目录未注册为扫描目录，不能管理。请先在服务器管理中添加该目录")
		return
	}

	fileRemoved := false
	fileExisted := true
	if err := os.Remove(m.FilePath); err == nil {
		fileRemoved = true
	} else if os.IsNotExist(err) {
		// Stale row: the file is already gone, so removing the row is the
		// whole job and there is nothing to report as a problem.
		fileExisted = false
	} else {
		// A file that cannot be removed (permissions, an immutable flag, a
		// read-only mount) must not have its row silently dropped: the index
		// would be describing a file that is still there.
		writeErr(w, http.StatusBadRequest, "删除文件失败："+err.Error())
		return
	}

	if err := s.st.DeleteMediaByIDs([]int64{m.ID}); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.dropOrphanThumbnails([]string{m.ContentHash})

	writeJSON(w, http.StatusOK, map[string]any{
		"deleted":      true,
		"file_removed": fileRemoved,
		"file_existed": fileExisted,
	})
}

func (s *Server) handleDeleteMediaBatch(w http.ResponseWriter, r *http.Request) {
	var body deleteBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if len(body.IDs) == 0 {
		writeErr(w, http.StatusBadRequest, "ids 不能为空")
		return
	}
	if len(body.IDs) > maxFileBatch {
		writeErr(w, http.StatusBadRequest,
			fmt.Sprintf("一次最多删除 %d 个文件", maxFileBatch))
		return
	}

	roots, err := s.st.EnabledFolders()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	type result struct {
		ID    int64  `json:"id"`
		OK    bool   `json:"ok"`
		Error string `json:"error,omitempty"`
	}

	results := make([]result, 0, len(body.IDs))
	var hashes []string
	deleted := 0

	for _, id := range body.IDs {
		m, err := s.st.GetMedia(id)
		if err != nil {
			results = append(results, result{ID: id, Error: err.Error()})
			continue
		}
		if m == nil {
			results = append(results, result{ID: id, Error: "找不到该媒体"})
			continue
		}
		if !underRoots(m.FilePath, roots) {
			results = append(results, result{ID: id, Error: "所在目录未注册，不能管理"})
			continue
		}
		if err := os.Remove(m.FilePath); err != nil && !os.IsNotExist(err) {
			results = append(results, result{ID: id, Error: "删除文件失败：" + err.Error()})
			continue
		}
		if err := s.st.DeleteMediaByIDs([]int64{m.ID}); err != nil {
			results = append(results, result{ID: id, Error: err.Error()})
			continue
		}
		hashes = append(hashes, m.ContentHash)
		results = append(results, result{ID: id, OK: true})
		deleted++
	}

	s.dropOrphanThumbnails(hashes)

	// Same partial-failure contract as batch move: report what happened per
	// item, never roll back what already succeeded.
	writeJSON(w, http.StatusOK, map[string]any{
		"deleted": deleted,
		"failed":  len(body.IDs) - deleted,
		"results": results,
	})
}

// dropOrphanThumbnails removes cache files that no row references any more.
//
// The reference count is the content hash: two identical files in different
// folders share one thumbnail, so a hash still referenced by any row must be
// kept. This is the same rule the scanner applies when pruning.
func (s *Server) dropOrphanThumbnails(hashes []string) {
	for _, h := range hashes {
		if h == "" {
			continue
		}
		n, err := s.st.CountByHash(h)
		if err != nil || n > 0 {
			continue
		}
		_ = os.Remove(s.cfg.ThumbPath(h))
	}
}

// -------------------------------------------------------------- helpers --

func idFromPath(r *http.Request, key string) (int64, error) {
	var id int64
	if _, err := fmt.Sscanf(r.PathValue(key), "%d", &id); err != nil {
		return 0, err
	}
	return id, nil
}

func folderByID(folders []store.ScanFolder, id int64) *store.ScanFolder {
	for i := range folders {
		if folders[i].ID == id {
			return &folders[i]
		}
	}
	return nil
}

// underRoots reports whether path is one of the registered scan folders or
// anything inside one.
//
// filepath.Rel, not a prefix compare: "/data" is not under "/database" even
// though it has "/data" as a string prefix, and a bare HasPrefix would hand
// out file management over a directory the user never registered.
func underRoots(path string, roots []store.ScanFolder) bool {
	clean := filepath.Clean(path)
	for _, f := range roots {
		rel, err := filepath.Rel(f.Path, clean)
		if err != nil {
			continue
		}
		if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			continue
		}
		return true
	}
	return false
}

// checkMediaName validates a plain file name.
func checkMediaName(name string) error {
	switch {
	case name == "":
		return errors.New("文件名不能为空")
	case name == "." || name == "..":
		return errors.New("文件名非法")
	case strings.ContainsAny(name, `/\`):
		return errors.New("文件名不能包含路径分隔符")
	case strings.HasPrefix(name, "."):
		// A dot-prefixed file inside a scanned folder is skipped by the walk,
		// so renaming to one would make the photo vanish from the library.
		return errors.New("文件名不能以点开头，那样的文件不会被扫描到")
	}
	return nil
}

// uniqueTarget picks a path in dir that does not exist yet, appending
// " (1)", " (2)"… when the name is taken — the same scheme the upload API
// uses, so a renamed file looks exactly like one that arrived from a phone.
func uniqueTarget(dir, name string) (string, error) {
	candidate := filepath.Join(dir, name)
	if _, err := os.Lstat(candidate); os.IsNotExist(err) {
		return candidate, nil
	}

	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 1; i <= maxNameAttempts; i++ {
		candidate = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		if _, err := os.Lstat(candidate); os.IsNotExist(err) {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("目录下同名文件太多，无法为 %q 生成新名字", name)
}

// moveOnDisk moves src to dst, falling back to copy-then-delete.
//
// The fallback exists because "move to another registered folder" can easily
// be a cross-volume move (internal disk ↔ external drive), where rename always
// fails. Surfacing that raw error would make the feature unusable on a Mac
// with a photo library on an external disk.
//
// The copy path is deliberately careful: copy to a sibling .part name, verify
// the size, restore the modification time (the timeline must not shift because
// a file was moved), rename into place, and only then remove the source. Any
// failure cleans up and reports the *original* rename error — guessing whether
// an error was "cross-device" is unreliable across platforms, and guessing
// wrong would turn a permission error into a full-file copy.
func moveOnDisk(src, dst string) (os.FileInfo, error) {
	renameErr := os.Rename(src, dst)
	if renameErr == nil {
		return os.Stat(dst)
	}

	tmp := dst + ".mc-move-part"
	if err := copyFile(src, tmp); err != nil {
		_ = os.Remove(tmp)
		return nil, renameErr
	}

	srcInfo, err1 := os.Stat(src)
	tmpInfo, err2 := os.Stat(tmp)
	if err1 != nil || err2 != nil || srcInfo.Size() != tmpInfo.Size() {
		_ = os.Remove(tmp)
		return nil, renameErr
	}
	// Keep the timeline stable: taken_at comes from EXIF, but the fallback
	// sorting for files without EXIF reads the mtime.
	_ = os.Chtimes(tmp, srcInfo.ModTime(), srcInfo.ModTime())

	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return nil, renameErr
	}
	if err := os.Remove(src); err != nil {
		// The destination is complete, so report the source cleanup problem
		// honestly rather than pretending the whole thing worked. The caller
		// leaves the index pointing at src, which still exists.
		return nil, fmt.Errorf("已复制到目标位置，但删除源文件失败：%v", err)
	}
	return os.Stat(dst)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}

	buf := make([]byte, 1<<20)
	if _, err := io.CopyBuffer(out, in, buf); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// nowISO is the timestamp written into indexed_at. It has to sort
// lexicographically against every other value in that column, which RFC3339
// in UTC does (see scanner.prune for the consumer).
func nowISO() string { return time.Now().UTC().Format(time.RFC3339) }
