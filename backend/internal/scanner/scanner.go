// Package scanner walks the configured folders and keeps the index in sync.
//
// Heavy per-file work (hashing, metadata extraction, thumbnail rendering) runs
// on a small worker pool so a large library indexes quickly, while all database
// writes funnel through a single goroutine so SQLite never sees concurrent
// writers.
package scanner

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"mediacenter/internal/config"
	"mediacenter/internal/imageutil"
	"mediacenter/internal/meta"
	"mediacenter/internal/store"
)

// photoExt and videoExt map a lower-cased extension to a MIME type. The
// extension decides which branch of the pipeline a file takes.
var photoExt = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
	".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
	".tif": "image/tiff", ".tiff": "image/tiff", ".heic": "image/heic",
	".heif": "image/heif", ".avif": "image/avif",
}

var videoExt = map[string]string{
	".mp4": "video/mp4", ".m4v": "video/x-m4v", ".mov": "video/quicktime",
	".mkv": "video/x-matroska", ".webm": "video/webm", ".avi": "video/x-msvideo",
	".wmv": "video/x-ms-wmv", ".flv": "video/x-flv", ".mpg": "video/mpeg",
	".mpeg": "video/mpeg", ".ts": "video/mp2t", ".3gp": "video/3gpp",
}

// skipDirs are directory names that never contain user media but can be huge
// or noisy.
var skipDirs = map[string]bool{
	"@eaDir": true, "#recycle": true, "$RECYCLE.BIN": true,
	"System Volume Information": true, "node_modules": true,
	"lost+found": true, ".Trashes": true,
}

// State is a snapshot of scan progress, safe to serialise straight to JSON.
type State struct {
	Running    bool     `json:"running"`
	StartedAt  string   `json:"started_at"`
	FinishedAt string   `json:"finished_at"`
	FilesSeen  int64    `json:"files_seen"`
	Indexed    int64    `json:"indexed"`
	Skipped    int64    `json:"skipped"`
	Failed     int64    `json:"failed"`
	Removed    int64    `json:"removed"`
	Current    string   `json:"current"`
	Errors     []string `json:"errors"`
	DurationMs int64    `json:"duration_ms"`
}

// Scanner coordinates index runs. Only one run happens at a time.
type Scanner struct {
	cfg *config.Config
	st  *store.Store

	mu    sync.Mutex
	state State
}

// New builds a scanner bound to a config and an index.
func New(cfg *config.Config, st *store.Store) *Scanner {
	return &Scanner{cfg: cfg, st: st}
}

// Status returns the current progress snapshot.
func (s *Scanner) Status() State {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.state
	out.Errors = append([]string(nil), s.state.Errors...)
	return out
}

// Start kicks off an index run. Pass folderID > 0 to scan a single folder.
func (s *Scanner) Start(folderID int64) error {
	s.mu.Lock()
	if s.state.Running {
		s.mu.Unlock()
		return fmt.Errorf("a scan is already running")
	}
	s.state = State{Running: true, StartedAt: nowISO(), Errors: []string{}}
	s.mu.Unlock()

	go s.run(folderID)
	return nil
}

func (s *Scanner) run(folderID int64) {
	started := time.Now()
	defer func() {
		s.mu.Lock()
		s.state.Running = false
		s.state.FinishedAt = nowISO()
		s.state.Current = ""
		s.state.DurationMs = time.Since(started).Milliseconds()
		s.mu.Unlock()
	}()

	folders, err := s.st.EnabledFolders()
	if err != nil {
		s.fail("list folders: " + err.Error())
		return
	}
	if folderID > 0 {
		filtered := folders[:0]
		for _, f := range folders {
			if f.ID == folderID {
				filtered = append(filtered, f)
			}
		}
		folders = filtered
	}
	if len(folders) == 0 {
		s.fail("no enabled scan folders configured")
		return
	}

	for _, f := range folders {
		s.scanFolder(f)
	}
}

// outcome is what a worker reports back about a single file.
type outcome struct {
	mf      *store.MediaFile
	skipped bool
	err     string
}

func (s *Scanner) scanFolder(f store.ScanFolder) {
	if _, err := os.Stat(f.Path); err != nil {
		s.fail(fmt.Sprintf("folder %s is not readable: %v", f.Path, err))
		return
	}

	type job struct {
		path string
		size int64
		mod  time.Time
	}

	jobs := make(chan job, 128)
	results := make(chan outcome, 128)
	seen := make(map[string]bool)

	workers := runtime.NumCPU()
	if workers < 2 {
		workers = 2
	}
	if workers > 8 {
		workers = 8
	}

	var workersWG sync.WaitGroup
	for i := 0; i < workers; i++ {
		workersWG.Add(1)
		go func() {
			defer workersWG.Done()
			for j := range jobs {
				results <- s.processFile(j.path, j.size, j.mod, f.ID)
			}
		}()
	}

	// A single writer goroutine keeps SQLite writes serialised.
	var writerWG sync.WaitGroup
	writerWG.Add(1)
	go func() {
		defer writerWG.Done()
		for res := range results {
			switch {
			case res.err != "":
				s.fail(res.err)
			case res.skipped:
				s.bump(func(st *State) { st.Skipped++ })
			case res.mf != nil:
				if _, err := s.st.UpsertMedia(res.mf); err != nil {
					s.fail("index: " + err.Error())
					continue
				}
				s.bump(func(st *State) { st.Indexed++ })
			}
		}
	}()

	walkErr := filepath.WalkDir(f.Path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			// Unreadable subtrees are common (permissions, dead symlinks);
			// skip them rather than aborting the whole run.
			return nil
		}
		if d.IsDir() {
			name := d.Name()
			if p != f.Path && (strings.HasPrefix(name, ".") || skipDirs[name]) {
				return fs.SkipDir
			}
			return nil
		}

		ext := strings.ToLower(filepath.Ext(d.Name()))
		if _, ok := photoExt[ext]; !ok {
			if _, ok := videoExt[ext]; !ok {
				return nil
			}
		}

		info, ierr := d.Info()
		if ierr != nil || info.Size() < 1024 {
			return nil
		}

		seen[p] = true
		s.bump(func(st *State) {
			st.FilesSeen++
			st.Current = p
		})
		jobs <- job{path: p, size: info.Size(), mod: info.ModTime()}
		return nil
	})

	close(jobs)
	workersWG.Wait()
	close(results)
	writerWG.Wait()

	if walkErr != nil {
		s.fail("walk " + f.Path + ": " + walkErr.Error())
	}

	if n, err := s.prune(f.ID, seen); err != nil {
		s.fail("prune: " + err.Error())
	} else if n > 0 {
		s.bump(func(st *State) { st.Removed += int64(n) })
	}

	if err := s.st.MarkFolderScanned(f.ID, nowISO()); err != nil {
		s.fail("mark folder: " + err.Error())
	}
}

// processFile does all the expensive work for one file and returns the row to
// be written, or a signal that the file was unchanged and can be skipped.
func (s *Scanner) processFile(path string, size int64, mod time.Time, folderID int64) outcome {
	mtime := mod.Unix()

	if prev, err := s.st.GetMediaByPath(path); err == nil && prev != nil {
		if prev.FileSize == size && prev.FileMtime == mtime {
			return outcome{skipped: true}
		}
	}

	ext := strings.ToLower(filepath.Ext(path))
	mimeType, isPhoto := photoExt[ext]
	mediaType := "photo"
	if !isPhoto {
		mimeType = videoExt[ext]
		mediaType = "video"
	}

	hash, err := quickHash(path, size)
	if err != nil {
		return outcome{err: fmt.Sprintf("hash %s: %v", path, err)}
	}

	mf := &store.MediaFile{
		FilePath:     path,
		ContentHash:  hash,
		FileName:     filepath.Base(path),
		FileSize:     size,
		FileMtime:    mtime,
		MimeType:     mimeType,
		MediaType:    mediaType,
		IndexedAt:    nowISO(),
		ScanFolderID: folderID,
	}

	if isPhoto {
		s.readPhotoMeta(mf, path)
	} else {
		s.readVideoMeta(mf, path)
	}
	// A timeline must never have holes, so fall back to the filesystem
	// timestamp when nothing better is available.
	if mf.TakenAt == "" {
		mf.TakenAt = mod.UTC().Format(time.RFC3339)
	}

	thumbPath := s.cfg.ThumbPath(hash)
	if _, statErr := os.Stat(thumbPath); statErr != nil {
		if err := s.makeThumbnail(mf, path, thumbPath); err != nil {
			// A missing thumbnail is not fatal: the file stays indexed and the
			// API will try again on demand.
			log.Printf("thumbnail %s: %v", path, err)
		}
	}
	if _, statErr := os.Stat(thumbPath); statErr == nil {
		mf.ThumbnailPath = thumbPath
	}

	return outcome{mf: mf}
}

func (s *Scanner) readPhotoMeta(mf *store.MediaFile, path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	// Standard library handles jpeg/png/gif. Everything else (HEIC, WebP,
	// AVIF) falls through to ffprobe below.
	head := make([]byte, 256*1024)
	n, _ := io.ReadFull(f, head)
	head = head[:n]

	if w, h, err := imageutil.Dimensions(head); err == nil {
		mf.Width, mf.Height = w, h
	}

	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".jpg" || ext == ".jpeg" {
		if t, ok := meta.JPEGTakenAt(head); ok {
			mf.TakenAt = t.Format(time.RFC3339)
		}
	}

	if mf.Width == 0 || mf.Height == 0 || mf.TakenAt == "" {
		if pr, err := meta.Probe(s.cfg.FFprobe, path); err == nil {
			if mf.Width == 0 || mf.Height == 0 {
				mf.Width, mf.Height = pr.Width, pr.Height
			}
			if mf.TakenAt == "" && pr.HasTakenAt {
				mf.TakenAt = pr.TakenAt.Format(time.RFC3339)
			}
		}
	}
}

func (s *Scanner) readVideoMeta(mf *store.MediaFile, path string) {
	pr, err := meta.Probe(s.cfg.FFprobe, path)
	if err != nil {
		return
	}
	mf.Width, mf.Height = pr.Width, pr.Height
	mf.DurationMs = pr.DurationMs
	mf.VideoCodec = pr.VideoCodec
	mf.AudioCodec = pr.AudioCodec
	if pr.HasTakenAt {
		mf.TakenAt = pr.TakenAt.Format(time.RFC3339)
	}
}

// makeThumbnail prefers the in-process path and only shells out to ffmpeg when
// the format is one the standard library cannot read.
func (s *Scanner) makeThumbnail(mf *store.MediaFile, src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if mf.MediaType == "photo" {
		if b, err := os.ReadFile(src); err == nil {
			if out, err := imageutil.ThumbnailJPEG(b, s.cfg.ThumbMaxPx, s.cfg.ThumbQuality); err == nil {
				return os.WriteFile(dst, out, 0o644)
			}
		}
	}
	return s.ffmpegThumb(src, dst, mf.MediaType == "video")
}

func (s *Scanner) ffmpegThumb(src, dst string, seek bool) error {
	vf := fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=decrease",
		s.cfg.ThumbMaxPx, s.cfg.ThumbMaxPx)

	attempt := func(withSeek bool) error {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		args := []string{"-y", "-v", "error"}
		if withSeek {
			// Seek a little way in so the frame is not a black fade-in.
			args = append(args, "-ss", "1")
		}
		args = append(args, "-i", src, "-frames:v", "1", "-vf", vf, "-q:v", "4", dst)

		out, err := exec.CommandContext(ctx, s.cfg.FFmpeg, args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("ffmpeg: %v: %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}

	err := attempt(seek)
	if err != nil && seek {
		// Clip shorter than one second: retry from the very first frame.
		err = attempt(false)
	}
	return err
}

// EnsureThumbnail returns the thumbnail path for a media row, rendering it on
// demand when the cache is missing or was cleared.
func (s *Scanner) EnsureThumbnail(mf *store.MediaFile) (string, error) {
	if mf.ThumbnailPath != "" {
		if _, err := os.Stat(mf.ThumbnailPath); err == nil {
			return mf.ThumbnailPath, nil
		}
	}
	if mf.ContentHash == "" {
		return "", fmt.Errorf("media %d has no content hash", mf.ID)
	}
	dst := s.cfg.ThumbPath(mf.ContentHash)
	if err := s.makeThumbnail(mf, mf.FilePath, dst); err != nil {
		return "", err
	}
	return dst, nil
}

// prune drops index rows for files that no longer exist on disk, and removes
// thumbnails that nothing references any more.
func (s *Scanner) prune(folderID int64, seen map[string]bool) (int, error) {
	refs, err := s.st.ListRefsByFolder(folderID)
	if err != nil {
		return 0, err
	}

	var goneIDs []int64
	var goneHashes []string
	for _, r := range refs {
		if !seen[r.Path] {
			goneIDs = append(goneIDs, r.ID)
			goneHashes = append(goneHashes, r.Hash)
		}
	}
	if len(goneIDs) == 0 {
		return 0, nil
	}

	if err := s.st.DeleteMediaByIDs(goneIDs); err != nil {
		return 0, err
	}

	for _, h := range goneHashes {
		if h == "" {
			continue
		}
		n, err := s.st.CountByHash(h)
		if err != nil || n > 0 {
			continue // still referenced by a duplicate in another folder
		}
		_ = os.Remove(s.cfg.ThumbPath(h))
	}
	return len(goneIDs), nil
}

func (s *Scanner) bump(fn func(*State)) {
	s.mu.Lock()
	fn(&s.state)
	s.mu.Unlock()
}

func (s *Scanner) fail(msg string) {
	s.mu.Lock()
	s.state.Failed++
	if len(s.state.Errors) < 50 {
		s.state.Errors = append(s.state.Errors, msg)
	}
	s.mu.Unlock()
	log.Printf("scan: %s", msg)
}

// quickHash derives a stable identity from the file size plus its first and
// last 256 KiB. Hashing a whole 4 GB video would dominate scan time, while a
// head+tail fingerprint is enough to survive moves and renames, which is what
// the identity is for.
func quickHash(path string, size int64) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	h := sha256.New()
	var sz [8]byte
	binary.LittleEndian.PutUint64(sz[:], uint64(size))
	h.Write(sz[:])

	const chunk = 256 * 1024
	buf := make([]byte, chunk)

	n, _ := io.ReadFull(f, buf)
	h.Write(buf[:n])

	if size > chunk {
		if _, err := f.Seek(-chunk, io.SeekEnd); err == nil {
			n2, _ := io.ReadFull(f, buf)
			h.Write(buf[:n2])
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func nowISO() string { return time.Now().UTC().Format(time.RFC3339) }
