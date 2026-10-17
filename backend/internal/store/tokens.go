package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// APIToken is one credential that can reach the API.
//
// The plaintext token is never stored and never returned by a read: only its
// SHA-256 digest lives in the database. A copy of index.db is therefore not
// enough to talk to the server, which matters because the file sits on a NAS
// share people copy around without thinking.
type APIToken struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	CreatedAt string `json:"created_at"`
	// LastUsedAt is refreshed at most once a minute per token; see TouchToken.
	LastUsedAt string `json:"last_used_at"`
	RevokedAt  string `json:"revoked_at"`
}

// Revoked reports whether the token has been withdrawn.
func (t APIToken) Revoked() bool { return t.RevokedAt != "" }

// CreateToken stores a new token under the given name.
//
// hash must already be the SHA-256 digest, hex encoded. This layer does not
// hash anything: keeping the transformation in one place (the API layer) makes
// it impossible for a caller to accidentally store a plaintext token.
func (s *Store) CreateToken(name, hash string) (APIToken, error) {
	now := nowISO()
	res, err := s.db.Exec(
		`INSERT INTO api_tokens (name, token_hash, created_at) VALUES (?, ?, ?)`,
		name, hash, now,
	)
	if err != nil {
		return APIToken{}, fmt.Errorf("create token: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return APIToken{}, fmt.Errorf("create token: %w", err)
	}
	return APIToken{ID: id, Name: name, CreatedAt: now}, nil
}

// ListTokens returns every token, newest first, including revoked ones.
//
// Revoked tokens stay visible on purpose: "this phone was cut off last March"
// is information the user needs when deciding whether to trust a device.
func (s *Store) ListTokens() ([]APIToken, error) {
	rows, err := s.db.Query(
		`SELECT id, name, created_at, COALESCE(last_used_at, ''), COALESCE(revoked_at, '')
		   FROM api_tokens ORDER BY id DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("list tokens: %w", err)
	}
	defer rows.Close()

	out := make([]APIToken, 0, 8)
	for rows.Next() {
		var t APIToken
		if err := rows.Scan(&t.ID, &t.Name, &t.CreatedAt, &t.LastUsedAt, &t.RevokedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// RevokeToken withdraws a token. Revoking twice is not an error: the caller's
// intent ("this must not work any more") is already satisfied.
func (s *Store) RevokeToken(id int64) error {
	res, err := s.db.Exec(
		`UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`,
		nowISO(), id,
	)
	if err != nil {
		return fmt.Errorf("revoke token: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// Either the id does not exist or it was already revoked. Distinguish
		// so a typo'd id does not look like a successful revoke.
		var exists int
		err := s.db.QueryRow(`SELECT COUNT(1) FROM api_tokens WHERE id = ?`, id).Scan(&exists)
		if err != nil {
			return fmt.Errorf("revoke token: %w", err)
		}
		if exists == 0 {
			return sql.ErrNoRows
		}
	}
	return nil
}

// TokenByHash resolves a digest to a token row.
//
// Returns the row even when revoked, with Revoked() telling the caller what to
// do. The auth layer needs that distinction: "unknown token" and "token we
// deliberately cut off" deserve different log lines.
func (s *Store) TokenByHash(hash string) (APIToken, bool, error) {
	var t APIToken
	err := s.db.QueryRow(
		`SELECT id, name, created_at, COALESCE(last_used_at, ''), COALESCE(revoked_at, '')
		   FROM api_tokens WHERE token_hash = ?`, hash,
	).Scan(&t.ID, &t.Name, &t.CreatedAt, &t.LastUsedAt, &t.RevokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return APIToken{}, false, nil
	}
	if err != nil {
		return APIToken{}, false, fmt.Errorf("lookup token: %w", err)
	}
	return t, true, nil
}

// TouchToken records that a token was just used.
//
// Only writes when the previous stamp is older than a minute. Without that
// guard every single request would rewrite a row, and since SQLite allows one
// writer at a time, browsing a gallery would serialise behind its own audit
// trail.
func (s *Store) TouchToken(id int64) error {
	now := time.Now().UTC()
	// Both stamps are RFC3339 in UTC, so the string comparison in SQL is also
	// a chronological one — no date parsing needed inside the database.
	_, err := s.db.Exec(
		`UPDATE api_tokens SET last_used_at = ?
		  WHERE id = ? AND (last_used_at IS NULL OR last_used_at < ?)`,
		now.Format(time.RFC3339),
		id,
		now.Add(-time.Minute).Format(time.RFC3339),
	)
	if err != nil {
		return fmt.Errorf("touch token: %w", err)
	}
	return nil
}
