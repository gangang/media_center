package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrAlbumNameTaken is returned when a name collides with an existing album.
// The API layer turns it into 409 rather than 500.
var ErrAlbumNameTaken = errors.New("album name already exists")

// ErrNoSuchMedia is returned when an album operation references media ids that
// are not in the index.
var ErrNoSuchMedia = errors.New("one or more media ids do not exist")

// Album is an album plus the two derived fields the list view needs.
//
// ItemCount and CoverMediaID are computed on read rather than stored, so they
// can never drift out of sync with album_items.
type Album struct {
	ID           int64  `json:"id"`
	Name         string `json:"name"`
	Description  string `json:"description"`
	ItemCount    int64  `json:"item_count"`
	CoverMediaID int64  `json:"cover_media_id"`
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`
}

// albumSelect is shared by every album read so the derived columns stay
// consistent between the list and the single-album endpoints.
const albumSelect = `
SELECT a.id, a.name, a.description,
       (SELECT COUNT(*) FROM album_items ai WHERE ai.album_id = a.id),
       COALESCE((SELECT ai.media_id FROM album_items ai
                  WHERE ai.album_id = a.id
                  ORDER BY ai.added_at ASC, ai.media_id ASC LIMIT 1), 0),
       a.created_at, a.updated_at
FROM albums a`

func scanAlbum(row interface{ Scan(...any) error }) (Album, error) {
	var a Album
	err := row.Scan(&a.ID, &a.Name, &a.Description, &a.ItemCount,
		&a.CoverMediaID, &a.CreatedAt, &a.UpdatedAt)
	return a, err
}

// isUniqueViolation reports whether err is SQLite rejecting a UNIQUE index.
// The pure-Go driver does not expose a typed error for this, so the message is
// the only signal available.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToUpper(err.Error())
	return strings.Contains(msg, "UNIQUE CONSTRAINT FAILED") ||
		strings.Contains(msg, "CONSTRAINT FAILED: UNIQUE")
}

// CreateAlbum inserts a new album. The name is unique case-insensitively.
func (s *Store) CreateAlbum(name, description string) (*Album, error) {
	ts := nowISO()
	res, err := s.db.Exec(
		`INSERT INTO albums (name, description, created_at, updated_at) VALUES (?,?,?,?)`,
		name, description, ts, ts)
	if isUniqueViolation(err) {
		return nil, ErrAlbumNameTaken
	}
	if err != nil {
		return nil, fmt.Errorf("create album: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return s.GetAlbum(id)
}

// ListAlbums returns every album, most recently touched first.
func (s *Store) ListAlbums() ([]Album, error) {
	rows, err := s.db.Query(albumSelect + ` ORDER BY a.updated_at DESC, a.id DESC`)
	if err != nil {
		return nil, fmt.Errorf("list albums: %w", err)
	}
	defer rows.Close()

	out := []Album{}
	for rows.Next() {
		a, err := scanAlbum(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// GetAlbum returns one album, or nil when the id is unknown.
func (s *Store) GetAlbum(id int64) (*Album, error) {
	row := s.db.QueryRow(albumSelect+` WHERE a.id = ?`, id)
	a, err := scanAlbum(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// UpdateAlbum renames an album and/or replaces its description. A nil field
// means "leave unchanged"; that distinction is why the parameters are pointers.
func (s *Store) UpdateAlbum(id int64, name, description *string) (*Album, error) {
	var sets []string
	var args []any
	if name != nil {
		sets = append(sets, "name = ?")
		args = append(args, *name)
	}
	if description != nil {
		sets = append(sets, "description = ?")
		args = append(args, *description)
	}
	if len(sets) == 0 {
		return s.GetAlbum(id)
	}
	sets = append(sets, "updated_at = ?")
	args = append(args, nowISO(), id)

	res, err := s.db.Exec(`UPDATE albums SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...)
	if isUniqueViolation(err) {
		return nil, ErrAlbumNameTaken
	}
	if err != nil {
		return nil, fmt.Errorf("update album: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// Either the album is gone, or the update was a no-op. Distinguish by
		// reading it back.
		return s.GetAlbum(id)
	}
	return s.GetAlbum(id)
}

// DeleteAlbum removes the album and, by cascade, its membership rows. Media
// files themselves are untouched — this is the whole point of the design.
func (s *Store) DeleteAlbum(id int64) error {
	_, err := s.db.Exec(`DELETE FROM albums WHERE id = ?`, id)
	return err
}

// AddAlbumItems adds media to an album. Ids that are already members are
// ignored rather than treated as an error, which makes the client's "select
// several and add" flow idempotent.
//
// Returns the number of newly added rows and the ids that were skipped because
// no such media exists.
func (s *Store) AddAlbumItems(albumID int64, mediaIDs []int64) (int64, []int64, error) {
	if len(mediaIDs) == 0 {
		return 0, nil, nil
	}
	existing, err := s.existingMediaIDs(mediaIDs)
	if err != nil {
		return 0, nil, err
	}
	var missing []int64
	for _, id := range mediaIDs {
		if !existing[id] {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		return 0, missing, ErrNoSuchMedia
	}

	ts := nowISO()
	var added int64
	err = s.withTx(func(tx *sql.Tx) error {
		stmt, err := tx.Prepare(
			`INSERT OR IGNORE INTO album_items (album_id, media_id, added_at) VALUES (?,?,?)`)
		if err != nil {
			return err
		}
		defer stmt.Close()

		for _, id := range mediaIDs {
			res, err := stmt.Exec(albumID, id, ts)
			if err != nil {
				return err
			}
			n, _ := res.RowsAffected()
			added += n
		}
		return touchAlbum(tx, albumID, ts)
	})
	if err != nil {
		return 0, nil, err
	}
	return added, nil, nil
}

// RemoveAlbumItems drops media from an album. Removing something that is not a
// member is a no-op.
func (s *Store) RemoveAlbumItems(albumID int64, mediaIDs []int64) (int64, error) {
	if len(mediaIDs) == 0 {
		return 0, nil
	}
	var removed int64
	err := s.withTx(func(tx *sql.Tx) error {
		for _, id := range mediaIDs {
			res, err := tx.Exec(
				`DELETE FROM album_items WHERE album_id = ? AND media_id = ?`, albumID, id)
			if err != nil {
				return err
			}
			n, _ := res.RowsAffected()
			removed += n
		}
		return touchAlbum(tx, albumID, nowISO())
	})
	if err != nil {
		return 0, err
	}
	return removed, nil
}

// ListAlbumMedia returns a page of the media inside an album, newest taken
// first — the same ordering the gallery uses, so an album feels like a filtered
// view of the library rather than a separate world.
//
// mediaColumns and orderByClause are safe to use unqualified here: album_items
// holds only (album_id, media_id, added_at), so none of their column names are
// ambiguous against the join.
func (s *Store) ListAlbumMedia(albumID int64, sort string, page, pageSize int) (*ListResult, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 500 {
		pageSize = 60
	}

	const from = ` FROM media_files
	               JOIN album_items ON album_items.media_id = media_files.id
	               WHERE album_items.album_id = ?`

	res := &ListResult{Page: page, PageSize: pageSize, Items: []MediaFile{}}
	if err := s.db.QueryRow(`SELECT COUNT(*)`+from, albumID).Scan(&res.Total); err != nil {
		return nil, fmt.Errorf("count album media: %w", err)
	}

	q := `SELECT ` + mediaColumns + from +
		` ORDER BY ` + orderByClause(sort) + ` LIMIT ? OFFSET ?`

	rows, err := s.db.Query(q, albumID, pageSize, (page-1)*pageSize)
	if err != nil {
		return nil, fmt.Errorf("list album media: %w", err)
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

// AlbumMediaIDs returns every media id in an album. The client uses it to mark
// which items are already in an album when the user is picking more.
func (s *Store) AlbumMediaIDs(albumID int64) ([]int64, error) {
	rows, err := s.db.Query(
		`SELECT media_id FROM album_items WHERE album_id = ? ORDER BY added_at, media_id`, albumID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// AlbumsForMedia reports which albums each media id belongs to. Used to render
// "already in these albums" without one request per item.
func (s *Store) AlbumsForMedia(mediaIDs []int64) (map[int64][]int64, error) {
	out := map[int64][]int64{}
	if len(mediaIDs) == 0 {
		return out, nil
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(mediaIDs)), ",")
	args := make([]any, len(mediaIDs))
	for i, id := range mediaIDs {
		args[i] = id
	}
	rows, err := s.db.Query(
		`SELECT media_id, album_id FROM album_items WHERE media_id IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var mid, aid int64
		if err := rows.Scan(&mid, &aid); err != nil {
			return nil, err
		}
		out[mid] = append(out[mid], aid)
	}
	return out, rows.Err()
}

// ---------------------------------------------------------------- helpers --

// withTx runs fn inside a transaction, rolling back on error. Several album
// operations touch two tables and must not half-apply.
func (s *Store) withTx(fn func(*sql.Tx) error) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// touchAlbum bumps updated_at so the album sorts to the top after a change.
func touchAlbum(tx *sql.Tx, albumID int64, ts string) error {
	_, err := tx.Exec(`UPDATE albums SET updated_at = ? WHERE id = ?`, ts, albumID)
	return err
}

// existingMediaIDs returns the subset of ids that are present in media_files.
func (s *Store) existingMediaIDs(ids []int64) (map[int64]bool, error) {
	out := make(map[int64]bool, len(ids))
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
		rows, err := s.db.Query(`SELECT id FROM media_files WHERE id IN (`+placeholders+`)`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			out[id] = true
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		rows.Close()
	}
	return out, nil
}
