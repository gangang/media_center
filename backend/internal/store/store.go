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
    scan_folder_id INTEGER REFERENCES scan_folders(id) ON DELETE CASCADE,
    origin         TEXT    NOT NULL DEFAULT 'scan'
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

-- Upload sessions. A phone backup is split into fixed size chunks so a dropped
-- Wi-Fi connection resumes from where it stopped instead of restarting a 4 GB
-- video. A row exists only for the duration of the transfer; once the file is
-- assembled and indexed the session is kept around just long enough for the
-- client to read back the resulting media id.
CREATE TABLE IF NOT EXISTS uploads (
    id              TEXT    PRIMARY KEY,
    file_name       TEXT    NOT NULL,
    content_hash    TEXT    NOT NULL DEFAULT '',
    total_size      INTEGER NOT NULL,
    chunk_size      INTEGER NOT NULL,
    chunk_count     INTEGER NOT NULL,
    received_chunks INTEGER NOT NULL DEFAULT 0,
    media_type      TEXT    NOT NULL DEFAULT '',
    -- Resolved when the upload completes. The name is claimed only at that
    -- point, with an exclusive create, so two phones backing up the same camera
    -- filename can never overwrite each other.
    target_path     TEXT    NOT NULL DEFAULT '',
    temp_path       TEXT    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'pending',
    media_id        INTEGER REFERENCES media_files(id) ON DELETE SET NULL,
    dedup           INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT    NOT NULL,
    updated_at      TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_uploads_status ON uploads(status, updated_at);
CREATE INDEX IF NOT EXISTS idx_uploads_hash   ON uploads(content_hash);

-- One row per chunk that actually arrived. Tracking them individually is what
-- lets a resumed upload learn exactly which pieces are still missing, rather
-- than trusting a counter that could drift after a retry.
CREATE TABLE IF NOT EXISTS upload_chunks (
    upload_id   TEXT    NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    size        INTEGER NOT NULL,
    received_at TEXT    NOT NULL,
    PRIMARY KEY (upload_id, chunk_index)
);

-- Device tokens. One row per phone or laptop that is allowed in, so a lost
-- device can be cut off without invalidating every other client.
--
-- Only the SHA-256 digest is stored. index.db gets copied around (backups, a
-- NAS share, someone poking at it) and a file full of live credentials would
-- turn every one of those copies into a key to the whole library.
--
-- The token in config.json stays valid and is not represented here: it is the
-- owner credential, the one that can create and revoke the rows in this table.
CREATE TABLE IF NOT EXISTS api_tokens (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL,
    token_hash   TEXT    NOT NULL UNIQUE,
    created_at   TEXT    NOT NULL,
    last_used_at TEXT,
    revoked_at   TEXT
);

CREATE INDEX IF NOT EXISTS idx_api_tokens_hash ON api_tokens(token_hash);
`

// postSchema runs after the column migrations, so it may safely reference
// columns that only exist on databases upgraded from an earlier release.
const postSchema = `
CREATE INDEX IF NOT EXISTS idx_media_origin ON media_files(origin);
`

// Origin values recorded in media_files.origin.
const (
	// OriginScan marks a file the scanner found in a user configured folder.
	OriginScan = "scan"
	// OriginUpload marks a file the server itself wrote, i.e. a phone backup.
	OriginUpload = "upload"
)

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
	// Origin is OriginScan or OriginUpload. It is set once, when the row is
	// first created, and never rewritten.
	Origin string `json:"origin"`
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
	Origin   string // OriginScan, OriginUpload or "" for both
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
	// Uploaded counts media that arrived through the backup API rather than
	// from a scan folder.
	Uploaded int64 `json:"uploaded"`
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
	if err := execStatements(s.db, schema); err != nil {
		return err
	}
	// CREATE TABLE IF NOT EXISTS never touches a table that already exists, so
	// a column introduced after the first release needs an explicit ALTER.
	// Every step below is a no-op once it has been applied.
	if err := s.ensureColumn("media_files", "origin", "TEXT NOT NULL DEFAULT 'scan'"); err != nil {
		return err
	}
	return execStatements(s.db, postSchema)
}

// execStatements runs a semicolon separated script, one statement at a time.
func execStatements(db *sql.DB, script string) error {
	for _, stmt := range splitStatements(script) {
		if _, err := db.Exec(stmt); err != nil {
			return fmt.Errorf("migrate: %w\nstatement: %s", err, stmt)
		}
	}
	return nil
}

// splitStatements breaks a script into individual statements.
//
// Line comments are removed before splitting. A naive split on ";" tears a
// statement in half the moment a comment happens to contain a semicolon — a
// bug that stays invisible until someone writes an ordinary English sentence in
// the wrong place, and then breaks startup for every existing install.
func splitStatements(script string) []string {
	var kept []string
	for _, line := range strings.Split(script, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "--") {
			continue
		}
		kept = append(kept, line)
	}

	var stmts []string
	for _, chunk := range strings.Split(strings.Join(kept, "\n"), ";") {
		if s := strings.TrimSpace(chunk); s != "" {
			stmts = append(stmts, s)
		}
	}
	return stmts
}

// ensureColumn adds a column when the table exists without it. It is how the
// schema evolves in place, without a migration framework and without ever
// dropping user data.
//
// table, column and decl are internal constants, never user input.
func (s *Store) ensureColumn(table, column, decl string) error {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", table, err)
	}

	found := false
	for rows.Next() {
		var (
			cid     int
			name    string
			ctype   string
			notNull int
			dflt    any
			pk      int
		)
		if err := rows.Scan(&cid, &name, &ctype, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return err
		}
		if strings.EqualFold(name, column) {
			found = true
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	// Close before writing: the open cursor would otherwise hold a connection.
	rows.Close()

	if found {
		return nil
	}
	if _, err := s.db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + decl); err != nil {
		return fmt.Errorf("add column %s.%s: %w", table, column, err)
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

// UpdateMediaLocation rewrites a media row in place after the file was renamed
// or moved on disk.
//
// In place is the entire point: the id must survive, because album_items is a
// foreign key with ON DELETE CASCADE (D15). Deleting the old row and inserting
// a new one would silently drop the photo out of every album it belongs to,
// and that loss does not undo itself.
//
// indexed_at is refreshed deliberately. The scanner's cleanup only removes
// rows older than the start of the current run, so a rename that lands while
// a scan is walking must look fresh or it gets pruned as "file disappeared"
// — and the next scan would then re-index it under a brand new id, losing the
// album membership anyway.
func (s *Store) UpdateMediaLocation(id int64, path, name string, size, mtime int64, folderID int64, indexedAt string) error {
	res, err := s.db.Exec(
		`UPDATE media_files
		    SET file_path = ?, file_name = ?, file_size = ?, file_mtime = ?,
		        scan_folder_id = ?, indexed_at = ?
		  WHERE id = ?`,
		path, name, size, mtime, folderID, indexedAt, id,
	)
	if err != nil {
		return fmt.Errorf("update media location: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("media %d not found", id)
	}
	return nil
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

// SetFolderEnabled toggles a folder without deleting it.
//
// A disabled folder stops being an authorisation root for file management
// while staying in the list, so the user can switch a directory back on
// without re-adding it (and without losing its row id).
func (s *Store) SetFolderEnabled(id int64, enabled bool) error {
	flag := 0
	if enabled {
		flag = 1
	}
	res, err := s.db.Exec(`UPDATE scan_folders SET enabled = ? WHERE id = ?`, flag, id)
	if err != nil {
		return fmt.Errorf("set folder enabled: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("folder %d not found", id)
	}
	return nil
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

// FolderIDByPath returns the id of a registered folder, or 0 when the path is
// not configured. The upload API uses it to attach an incoming file to the
// managed library folder.
func (s *Store) FolderIDByPath(path string) (int64, error) {
	var id int64
	err := s.db.QueryRow(`SELECT id FROM scan_folders WHERE path = ?`, path).Scan(&id)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return id, nil
}

// ------------------------------------------------------------------ media --

const mediaColumns = `id, file_path, COALESCE(content_hash,''), file_name, file_size,
	COALESCE(file_mtime,0), COALESCE(mime_type,''), media_type, COALESCE(taken_at,''),
	indexed_at, COALESCE(width,0), COALESCE(height,0), COALESCE(duration_ms,0),
	COALESCE(video_codec,''), COALESCE(audio_codec,''), COALESCE(thumbnail_path,''),
	COALESCE(scan_folder_id,0), COALESCE(origin,'scan')`

func scanMedia(row interface{ Scan(...any) error }) (MediaFile, error) {
	var m MediaFile
	err := row.Scan(
		&m.ID, &m.FilePath, &m.ContentHash, &m.FileName, &m.FileSize,
		&m.FileMtime, &m.MimeType, &m.MediaType, &m.TakenAt,
		&m.IndexedAt, &m.Width, &m.Height, &m.DurationMs,
		&m.VideoCodec, &m.AudioCodec, &m.ThumbnailPath,
		&m.ScanFolderID, &m.Origin,
	)
	return m, err
}

// UpsertMedia inserts a freshly indexed file, or refreshes the row if the same
// path was already known. file_path is the conflict target, which keeps
// re-scans idempotent.
//
// origin is written on insert only. A file that arrived through the upload API
// lives inside the managed library folder, which the scanner also walks; if the
// update refreshed origin too, the next scan would relabel it as "scan" and the
// upload/scan distinction would quietly disappear.
func (s *Store) UpsertMedia(m *MediaFile) (int64, error) {
	var id int64
	err := s.db.QueryRow(
		`INSERT INTO media_files (
		     file_path, content_hash, file_name, file_size, file_mtime, mime_type,
		     media_type, taken_at, indexed_at, width, height, duration_ms,
		     video_codec, audio_codec, thumbnail_path, scan_folder_id, origin)
		 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
		nullStr(m.ThumbnailPath), nullInt64(m.ScanFolderID), originOrDefault(m.Origin),
	).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("upsert media: %w", err)
	}
	return id, nil
}

// originOrDefault maps the zero value to OriginScan so callers that do not care
// about provenance still write a valid, indexed value.
func originOrDefault(origin string) string {
	if origin == "" {
		return OriginScan
	}
	return origin
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
	switch p.Origin {
	case OriginScan, OriginUpload:
		where = append(where, "COALESCE(origin,'scan') = ?")
		args = append(args, p.Origin)
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

// PathRef is a lightweight (id, path, hash, indexed_at) record used when
// pruning rows for files that disappeared from disk.
//
// IndexedAt is part of the contract: pruning must not touch rows written after
// the current scan started, because those belong to files that landed on disk
// while the walk was already running (see scanner.prune).
type PathRef struct {
	ID        int64
	Path      string
	Hash      string
	IndexedAt string
}

// ListRefsByFolder returns every indexed file belonging to a folder.
func (s *Store) ListRefsByFolder(folderID int64) ([]PathRef, error) {
	rows, err := s.db.Query(
		`SELECT id, file_path, COALESCE(content_hash,''), COALESCE(indexed_at,'')
		   FROM media_files WHERE scan_folder_id = ?`,
		folderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []PathRef
	for rows.Next() {
		var r PathRef
		if err := rows.Scan(&r.ID, &r.Path, &r.Hash, &r.IndexedAt); err != nil {
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
		COALESCE(SUM(file_size), 0),
		COALESCE(SUM(CASE WHEN COALESCE(origin,'scan') = 'upload' THEN 1 ELSE 0 END), 0)
		FROM media_files`)
	if err := row.Scan(&out.Photos, &out.Videos, &out.TotalBytes, &out.Uploaded); err != nil {
		return nil, err
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM scan_folders`).Scan(&out.Folders); err != nil {
		return nil, err
	}
	return out, nil
}
