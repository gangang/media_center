// Package store owns the SQLite index: schema, migrations and every query.
//
// The database deliberately only holds metadata. Original media files stay
// where the user put them and thumbnails live on the filesystem, which keeps
// the index small and makes it safe to delete and rebuild at any time.
package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure Go driver, keeps CGO out of the build
)

const schema = `
CREATE TABLE IF NOT EXISTS scan_folders (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    path       TEXT    NOT NULL UNIQUE,
    enabled    INTEGER NOT NULL DEFAULT 1,
    last_scan  TEXT,
    created_at TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS media_files (
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

CREATE INDEX IF NOT EXISTS idx_media_taken_at ON media_files(taken_at DESC);
CREATE INDEX IF NOT EXISTS idx_media_type     ON media_files(media_type);
CREATE INDEX IF NOT EXISTS idx_media_hash     ON media_files(content_hash);
CREATE INDEX IF NOT EXISTS idx_media_folder   ON media_files(scan_folder_id);

-- Albums are pure metadata: they only group media, never own it. Deleting an
-- album must not touch a single file on disk.
--
-- NOCASE on the name stops "Vacation" and "vacation" from coexisting, which
-- users read as a bug. (SQLite's NOCASE only folds ASCII, which is fine: the
-- languages that matter here have no letter case.)
CREATE TABLE IF NOT EXISTS albums (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL COLLATE NOCASE UNIQUE,
    description TEXT    NOT NULL DEFAULT '',
    created_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL
);

-- Both foreign keys cascade. That is deliberate: when a file is pruned from
-- the index, its album memberships must go with it, otherwise the album would
-- keep pointing at a row that no longer exists.
CREATE TABLE IF NOT EXISTS album_items (
    album_id INTEGER NOT NULL REFERENCES albums(id)      ON DELETE CASCADE,
    media_id INTEGER NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    added_at TEXT    NOT NULL,
    PRIMARY KEY (album_id, media_id)
);

CREATE INDEX IF NOT EXISTS idx_album_items_media ON album_items(media_id);
CREATE INDEX IF NOT EXISTS idx_album_items_album ON album_items(album_id, added_at);
`

// MediaFile mirrors one row of media_files.
type MediaFile struct {
	ID            int64  `json:"id"`
	FilePath      string `json:"file_path"`
	ContentHash   string `json:"content_hash"`
	FileName      string `json:"file_name"`
	FileSize      int64  `json:"file_size"`
	FileMtime     int64  `json:"file_mtime"`
	MimeType      string `json:"mime_type"`
	MediaType     string `json:"media_type"`
	TakenAt       string `json:"taken_at"`
	IndexedAt     string `json:"indexed_at"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	DurationMs    int64  `json:"duration_ms"`
	VideoCodec    string `json:"video_codec"`
	AudioCodec    string `json:"audio_codec"`
	ThumbnailPath string `json:"thumbnail_path"`
	ScanFolderID  int64  `json:"scan_folder_id"`
}

// ScanFolder mirrors one row of scan_folders.
type ScanFolder struct {
	ID        int64  `json:"id"`
	Path      string `json:"path"`
	Enabled   bool   `json:"enabled"`
	LastScan  string `json:"last_scan"`
	CreatedAt string `json:"created_at"`
}

// ListParams describes a media query.
type ListParams struct {
	Type     string // "photo", "video" or "" for both
	Page     int
	PageSize int
	Sort     string
	Query    string
	From     string
	To       string
}

// ListResult is a page of media plus the total row count.
type ListResult struct {
	Items    []MediaFile `json:"items"`
	Total    int         `json:"total"`
	Page     int         `json:"page"`
	PageSize int         `json:"page_size"`
}

// Stats is the summary shown on the status page and used by clients.
type Stats struct {
	Photos     int64 `json:"photos"`
	Videos     int64 `json:"videos"`
	TotalBytes int64 `json:"total_bytes"`
	Folders    int64 `json:"folders"`
}

// Store wraps the database handle.
type Store struct {
	db *sql.DB
}

// Open connects to the SQLite file at path, applies the pragmas that make
// concurrent reads safe, and runs the schema migration.
func Open(path string) (*Store, error) {
	dsn := "file:" + path +
		"?_pragma=busy_timeout(5000)" +
		"&_pragma=journal_mode(WAL)" +
		"&_pragma=foreign_keys(1)" +
		"&_pragma=synchronous(NORMAL)"

	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// WAL lets readers and one writer proceed together; a handful of
	// connections is plenty for a single household.
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(8)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close releases the database handle.
func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	for _, stmt := range strings.Split(schema, ";") {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("migrate: %w\nstatement: %s", err, stmt)
		}
	}
	return nil
}

func nowISO() string { return time.Now().UTC().Format(time.RFC3339) }

// nullStr maps an empty string to NULL so optional columns stay clean.
func nullStr(v string) any {
	if v == "" {
		return nil
	}
	return v
}

func nullInt(v int) any {
	if v == 0 {
		return nil
	}
	return v
}

func nullInt64(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}

// ---------------------------------------------------------------- folders --

// AddFolder registers a directory to scan. Adding an existing path re-enables it.
func (s *Store) AddFolder(path string) (int64, error) {
	var id int64
	err := s.db.QueryRow(
		`INSERT INTO scan_folders (path, enabled, created_at) VALUES (?, 1, ?)
		 ON CONFLICT(path) DO UPDATE SET enabled = 1
		 RETURNING id`,
		path, nowISO(),
	).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("add folder: %w", err)
	}
	return id, nil
}

// ListFolders returns every configured folder, newest first.
func (s *Store) ListFolders() ([]ScanFolder, error) {
	return s.queryFolders(`SELECT id, path, enabled, COALESCE(last_scan,''), created_at
	                      FROM scan_folders ORDER BY id`)
}

// EnabledFolders returns only the folders the user has left switched on.
func (s *Store) EnabledFolders() ([]ScanFolder, error) {
	return s.queryFolders(`SELECT id, path, enabled, COALESCE(last_scan,''), created_at
	                      FROM scan_folders WHERE enabled = 1 ORDER BY id`)
}

func (s *Store) queryFolders(q string, args ...any) ([]ScanFolder, error) {
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []ScanFolder{}
	for rows.Next() {
		var f ScanFolder
		if err := rows.Scan(&f.ID, &f.Path, &f.Enabled, &f.LastScan, &f.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// DeleteFolder removes a folder and, via the cascade, every media row indexed
// from it.
func (s *Store) DeleteFolder(id int64) error {
	_, err := s.db.Exec(`DELETE FROM scan_folders WHERE id = ?`, id)
	return err
}

// MarkFolderScanned records when a folder was last walked.
func (s *Store) MarkFolderScanned(id int64, ts string) error {
	_, err := s.db.Exec(`UPDATE scan_folders SET last_scan = ? WHERE id = ?`, ts, id)
	return err
}

// ------------------------------------------------------------------ media --

const mediaColumns = `id, file_path, COALESCE(content_hash,''), file_name, file_size,
	COALESCE(file_mtime,0), COALESCE(mime_type,''), media_type, COALESCE(taken_at,''),
	indexed_at, COALESCE(width,0), COALESCE(height,0), COALESCE(duration_ms,0),
	COALESCE(video_codec,''), COALESCE(audio_codec,''), COALESCE(thumbnail_path,''),
	COALESCE(scan_folder_id,0)`

func scanMedia(row interface{ Scan(...any) error }) (MediaFile, error) {
	var m MediaFile
	err := row.Scan(
		&m.ID, &m.FilePath, &m.ContentHash, &m.FileName, &m.FileSize,
		&m.FileMtime, &m.MimeType, &m.MediaType, &m.TakenAt,
		&m.IndexedAt, &m.Width, &m.Height, &m.DurationMs,
		&m.VideoCodec, &m.AudioCodec, &m.ThumbnailPath,
		&m.ScanFolderID,
	)
	return m, err
}

// UpsertMedia inserts a freshly indexed file, or refreshes the row if the same
// path was already known. file_path is the conflict target, which keeps
// re-scans idempotent.
func (s *Store) UpsertMedia(m *MediaFile) (int64, error) {
	var id int64
	err := s.db.QueryRow(
		`INSERT INTO media_files (
		     file_path, content_hash, file_name, file_size, file_mtime, mime_type,
		     media_type, taken_at, indexed_at, width, height, duration_ms,
		     video_codec, audio_codec, thumbnail_path, scan_folder_id)
		 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		 ON CONFLICT(file_path) DO UPDATE SET
		     content_hash   = excluded.content_hash,
		     file_name      = excluded.file_name,
		     file_size      = excluded.file_size,
		     file_mtime     = excluded.file_mtime,
		     mime_type      = excluded.mime_type,
		     media_type     = excluded.media_type,
		     taken_at       = excluded.taken_at,
		     indexed_at     = excluded.indexed_at,
		     width          = excluded.width,
		     height         = excluded.height,
		     duration_ms    = excluded.duration_ms,
		     video_codec    = excluded.video_codec,
		     audio_codec    = excluded.audio_codec,
		     thumbnail_path = excluded.thumbnail_path,
		     scan_folder_id = excluded.scan_folder_id
		 RETURNING id`,
		m.FilePath, m.ContentHash, m.FileName, m.FileSize, m.FileMtime, m.MimeType,
		m.MediaType, nullStr(m.TakenAt), m.IndexedAt, nullInt(m.Width), nullInt(m.Height),
		nullInt64(m.DurationMs), nullStr(m.VideoCodec), nullStr(m.AudioCodec),
		nullStr(m.ThumbnailPath), nullInt64(m.ScanFolderID),
	).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("upsert media: %w", err)
	}
	return id, nil
}

// GetMediaByPath looks up a single row by absolute path. Used by the scanner
// to decide whether a file can be skipped.
func (s *Store) GetMediaByPath(path string) (*MediaFile, error) {
	row := s.db.QueryRow(`SELECT `+mediaColumns+` FROM media_files WHERE file_path = ?`, path)
	m, err := scanMedia(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// GetMedia looks up a single row by id.
func (s *Store) GetMedia(id int64) (*MediaFile, error) {
	row := s.db.QueryRow(`SELECT `+mediaColumns+` FROM media_files WHERE id = ?`, id)
	m, err := scanMedia(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// orderByClause maps a client supplied sort key to a whitelisted SQL fragment.
// Never interpolate raw user input into SQL.
func orderByClause(sort string) string {
	switch sort {
	case "taken_at_asc":
		return "COALESCE(NULLIF(taken_at,''), indexed_at) ASC, id ASC"
	case "name_asc":
		return "file_name COLLATE NOCASE ASC, id ASC"
	case "size_desc":
		return "file_size DESC, id DESC"
	case "size_asc":
		return "file_size ASC, id ASC"
	case "indexed_desc":
		return "indexed_at DESC, id DESC"
	default: // taken_at_desc
		return "COALESCE(NULLIF(taken_at,''), indexed_at) DESC, id DESC"
	}
}

// ListMedia returns one page of media plus the total number of matches.
func (s *Store) ListMedia(p ListParams) (*ListResult, error) {
	if p.Page < 1 {
		p.Page = 1
	}
	if p.PageSize < 1 || p.PageSize > 500 {
		p.PageSize = 60
	}

	var where []string
	var args []any

	switch p.Type {
	case "photo", "video":
		where = append(where, "media_type = ?")
		args = append(args, p.Type)
	}
	if p.Query != "" {
		where = append(where, "file_name LIKE ?")
		args = append(args, "%"+p.Query+"%")
	}
	if p.From != "" {
		where = append(where, "COALESCE(NULLIF(taken_at,''), indexed_at) >= ?")
		args = append(args, p.From)
	}
	if p.To != "" {
		where = append(where, "COALESCE(NULLIF(taken_at,''), indexed_at) <= ?")
		args = append(args, p.To)
	}

	clause := ""
	if len(where) > 0 {
		clause = " WHERE " + strings.Join(where, " AND ")
	}

	res := &ListResult{Page: p.Page, PageSize: p.PageSize, Items: []MediaFile{}}

	if err := s.db.QueryRow(`SELECT COUNT(*) FROM media_files`+clause, args...).Scan(&res.Total); err != nil {
		return nil, fmt.Errorf("count media: %w", err)
	}

	q := `SELECT ` + mediaColumns + ` FROM media_files` + clause +
		` ORDER BY ` + orderByClause(p.Sort) + ` LIMIT ? OFFSET ?`
	pageArgs := append(append([]any{}, args...), p.PageSize, (p.Page-1)*p.PageSize)

	rows, err := s.db.Query(q, pageArgs...)
	if err != nil {
		return nil, fmt.Errorf("list media: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		m, err := scanMedia(rows)
		if err != nil {
			return nil, err
		}
		res.Items = append(res.Items, m)
	}
	return res, rows.Err()
}

// PathRef is a lightweight (id, path, hash) triple used when pruning rows for
// files that disappeared from disk.
type PathRef struct {
	ID   int64
	Path string
	Hash string
}

// ListRefsByFolder returns every indexed file belonging to a folder.
func (s *Store) ListRefsByFolder(folderID int64) ([]PathRef, error) {
	rows, err := s.db.Query(
		`SELECT id, file_path, COALESCE(content_hash,'') FROM media_files WHERE scan_folder_id = ?`,
		folderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []PathRef
	for rows.Next() {
		var r PathRef
		if err := rows.Scan(&r.ID, &r.Path, &r.Hash); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// DeleteMediaByIDs removes rows in small batches to stay well clear of
// SQLite's variable limit.
func (s *Store) DeleteMediaByIDs(ids []int64) error {
	const batch = 400
	for start := 0; start < len(ids); start += batch {
		end := start + batch
		if end > len(ids) {
			end = len(ids)
		}
		chunk := ids[start:end]
		placeholders := strings.TrimSuffix(strings.Repeat("?,", len(chunk)), ",")
		args := make([]any, len(chunk))
		for i, id := range chunk {
			args[i] = id
		}
		if _, err := s.db.Exec(`DELETE FROM media_files WHERE id IN (`+placeholders+`)`, args...); err != nil {
			return err
		}
	}
	return nil
}

// CountByHash tells the pruner whether a thumbnail is still referenced by
// another row (the same file indexed from a second folder).
func (s *Store) CountByHash(hash string) (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COUNT(*) FROM media_files WHERE content_hash = ?`, hash).Scan(&n)
	return n, err
}

// Stats summarises the index for the status page.
func (s *Store) Stats() (*Stats, error) {
	out := &Stats{}
	row := s.db.QueryRow(`SELECT
		COALESCE(SUM(CASE WHEN media_type = 'photo' THEN 1 ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN media_type = 'video' THEN 1 ELSE 0 END), 0),
		COALESCE(SUM(file_size), 0)
		FROM media_files`)
	if err := row.Scan(&out.Photos, &out.Videos, &out.TotalBytes); err != nil {
		return nil, err
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM scan_folders`).Scan(&out.Folders); err != nil {
		return nil, err
	}
	return out, nil
}
