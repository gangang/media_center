package store

import (
	"database/sql"
	"fmt"
)

// Upload session states.
const (
	// UploadPending means the session is open and chunks may still arrive.
	UploadPending = "pending"
	// UploadDone means the file was assembled, indexed and handed back.
	UploadDone = "done"
	// UploadFailed means assembly was attempted and rejected, e.g. a hash
	// mismatch. The session is kept so the client can read the reason.
	UploadFailed = "failed"
	// UploadCanceled means the client gave up. The temp file is removed.
	UploadCanceled = "canceled"
)

// Upload mirrors one row of uploads: a resumable, chunked file transfer.
//
// The session exists independently of media_files. A file only becomes media
// once every chunk has arrived and the assembled bytes match the declared
// content hash, so a half-finished transfer can never appear in the gallery.
type Upload struct {
	ID             string `json:"id"`
	FileName       string `json:"file_name"`
	ContentHash    string `json:"content_hash"`
	TotalSize      int64  `json:"total_size"`
	ChunkSize      int64  `json:"chunk_size"`
	ChunkCount     int    `json:"chunk_count"`
	ReceivedChunks int    `json:"received_chunks"`
	MediaType      string `json:"media_type"`
	TargetPath     string `json:"target_path"`
	TempPath       string `json:"temp_path"`
	Status         string `json:"status"`
	MediaID        int64  `json:"media_id"`
	Dedup          bool   `json:"dedup"`
	CreatedAt      string `json:"created_at"`
	UpdatedAt      string `json:"updated_at"`
}

const uploadColumns = `id, file_name, COALESCE(content_hash,''), total_size, chunk_size,
	chunk_count, received_chunks, COALESCE(media_type,''), target_path, temp_path,
	status, COALESCE(media_id,0), dedup, created_at, updated_at`

func scanUpload(row interface{ Scan(...any) error }) (Upload, error) {
	var u Upload
	err := row.Scan(
		&u.ID, &u.FileName, &u.ContentHash, &u.TotalSize, &u.ChunkSize,
		&u.ChunkCount, &u.ReceivedChunks, &u.MediaType, &u.TargetPath, &u.TempPath,
		&u.Status, &u.MediaID, &u.Dedup, &u.CreatedAt, &u.UpdatedAt,
	)
	return u, err
}

// CreateUpload opens a session. The caller has already chosen the id and the
// temp path, so this is a plain insert.
//
// target_path is deliberately left empty: the destination name is only claimed
// once every chunk has arrived.
func (s *Store) CreateUpload(u *Upload) error {
	ts := nowISO()
	u.CreatedAt = ts
	u.UpdatedAt = ts
	if u.Status == "" {
		u.Status = UploadPending
	}
	_, err := s.db.Exec(
		`INSERT INTO uploads (id, file_name, content_hash, total_size, chunk_size,
		     chunk_count, received_chunks, media_type, target_path, temp_path,
		     status, dedup, created_at, updated_at)
		 VALUES (?,?,?,?,?,?,0,?,'',?,?,?,?,?)`,
		u.ID, u.FileName, u.ContentHash, u.TotalSize, u.ChunkSize,
		u.ChunkCount, u.MediaType, u.TempPath,
		u.Status, u.Dedup, ts, ts,
	)
	if err != nil {
		return fmt.Errorf("create upload: %w", err)
	}
	return nil
}

// GetUpload returns one session, or nil when the id is unknown.
func (s *Store) GetUpload(id string) (*Upload, error) {
	row := s.db.QueryRow(`SELECT `+uploadColumns+` FROM uploads WHERE id = ?`, id)
	u, err := scanUpload(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// AddUploadChunk records that one chunk arrived and returns the new total.
//
// The chunk row is written first and the counter is then recomputed from the
// chunk table rather than incremented. A retried chunk therefore cannot inflate
// the count, and the counter can never disagree with the rows it summarises.
func (s *Store) AddUploadChunk(uploadID string, index int, size int64) (int, error) {
	received := 0
	err := s.withTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(
			`INSERT INTO upload_chunks (upload_id, chunk_index, size, received_at)
			 VALUES (?,?,?,?)
			 ON CONFLICT(upload_id, chunk_index) DO UPDATE SET
			     size        = excluded.size,
			     received_at = excluded.received_at`,
			uploadID, index, size, nowISO(),
		); err != nil {
			return err
		}
		if err := tx.QueryRow(
			`SELECT COUNT(*) FROM upload_chunks WHERE upload_id = ?`, uploadID,
		).Scan(&received); err != nil {
			return err
		}
		_, err := tx.Exec(
			`UPDATE uploads SET received_chunks = ?, updated_at = ? WHERE id = ?`,
			received, nowISO(), uploadID)
		return err
	})
	if err != nil {
		return 0, fmt.Errorf("record chunk: %w", err)
	}
	return received, nil
}

// ReceivedChunkIndexes lists the chunks already on disk, ascending. This is
// what lets an interrupted transfer resume instead of starting over.
func (s *Store) ReceivedChunkIndexes(uploadID string) ([]int, error) {
	rows, err := s.db.Query(
		`SELECT chunk_index FROM upload_chunks WHERE upload_id = ? ORDER BY chunk_index`,
		uploadID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []int{}
	for rows.Next() {
		var i int
		if err := rows.Scan(&i); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

// FinishUpload marks a session complete, records where the assembled file ended
// up, and links it to the media row it produced.
//
// The target path is decided at completion time rather than at init, because
// the destination name is claimed with an exclusive create once the bytes are
// known to be good.
func (s *Store) FinishUpload(uploadID string, mediaID int64, targetPath string) error {
	_, err := s.db.Exec(
		`UPDATE uploads SET status = ?, media_id = ?, target_path = ?, updated_at = ? WHERE id = ?`,
		UploadDone, mediaID, targetPath, nowISO(), uploadID)
	return err
}

// FailUpload records a rejected assembly. The reason is logged, not stored: the
// client is told synchronously by the response it is already waiting on.
func (s *Store) FailUpload(uploadID string) error {
	_, err := s.db.Exec(
		`UPDATE uploads SET status = ?, updated_at = ? WHERE id = ?`,
		UploadFailed, nowISO(), uploadID)
	return err
}

// DeleteUpload drops a session and, by cascade, its chunk rows. Removing an
// unknown id is not an error: cancel is meant to be safe to retry.
func (s *Store) DeleteUpload(uploadID string) error {
	_, err := s.db.Exec(`DELETE FROM uploads WHERE id = ?`, uploadID)
	return err
}

// FindMediaByHash returns the first media row with the given content hash, or
// nil. The upload API uses it to recognise a file the server already has, which
// turns a re-upload of an existing photo into an instant, zero byte response.
func (s *Store) FindMediaByHash(hash string) (*MediaFile, error) {
	if hash == "" {
		return nil, nil
	}
	row := s.db.QueryRow(
		`SELECT `+mediaColumns+` FROM media_files WHERE content_hash = ? ORDER BY id LIMIT 1`,
		hash)
	m, err := scanMedia(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// DeleteStaleUploads drops unfinished sessions last touched before the cutoff
// and returns the temp files the caller should unlink from disk.
//
// Without this, a client that crashed mid-transfer would leave a partially
// written file behind forever, invisible in the UI but still consuming space.
func (s *Store) DeleteStaleUploads(beforeISO string) ([]string, error) {
	var tempPaths []string
	err := s.withTx(func(tx *sql.Tx) error {
		rows, err := tx.Query(
			`SELECT temp_path FROM uploads
			  WHERE status IN (?,?) AND updated_at < ?`,
			UploadPending, UploadFailed, beforeISO)
		if err != nil {
			return err
		}
		for rows.Next() {
			var p string
			if err := rows.Scan(&p); err != nil {
				rows.Close()
				return err
			}
			tempPaths = append(tempPaths, p)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		rows.Close()

		_, err = tx.Exec(
			`DELETE FROM uploads WHERE status IN (?,?) AND updated_at < ?`,
			UploadPending, UploadFailed, beforeISO)
		return err
	})
	if err != nil {
		return nil, fmt.Errorf("prune uploads: %w", err)
	}
	return tempPaths, nil
}
