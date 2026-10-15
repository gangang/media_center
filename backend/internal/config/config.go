package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// Config holds every runtime setting of the media center backend.
//
// It is persisted as config.json inside the data directory so a user can edit
// it by hand, and individual fields can be overridden by command line flags.
type Config struct {
	DataDir      string `json:"data_dir"`
	Host         string `json:"host"`
	Port         int    `json:"port"`
	ServerName   string `json:"server_name"`
	Token        string `json:"token"`
	ThumbMaxPx   int    `json:"thumb_max_px"`
	ThumbQuality int    `json:"thumb_quality"`
	FFmpeg       string `json:"ffmpeg_path"`
	FFprobe      string `json:"ffprobe_path"`
}

// DefaultDataDir returns ~/.mediacenter, falling back to a relative path when
// the home directory cannot be determined.
func DefaultDataDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".mediacenter"
	}
	return filepath.Join(home, ".mediacenter")
}

// Load reads (or creates) the configuration, applies defaults, applies flag
// overrides, and makes sure the on-disk layout exists.
func Load(dataDir, host string, port int) (*Config, error) {
	if dataDir == "" {
		dataDir = DefaultDataDir()
	}
	abs, err := filepath.Abs(dataDir)
	if err != nil {
		return nil, fmt.Errorf("resolve data dir: %w", err)
	}
	dataDir = abs

	cfg := &Config{}
	if b, err := os.ReadFile(filepath.Join(dataDir, "config.json")); err == nil {
		_ = json.Unmarshal(b, cfg)
	}

	cfg.DataDir = dataDir
	if cfg.Host == "" {
		cfg.Host = "0.0.0.0"
	}
	if cfg.Port == 0 {
		cfg.Port = 8080
	}
	if cfg.ServerName == "" {
		cfg.ServerName = defaultServerName()
	}
	if cfg.ThumbMaxPx <= 0 {
		cfg.ThumbMaxPx = 320
	}
	if cfg.ThumbQuality <= 0 || cfg.ThumbQuality > 100 {
		cfg.ThumbQuality = 82
	}
	if cfg.FFmpeg == "" {
		cfg.FFmpeg = "ffmpeg"
	}
	if cfg.FFprobe == "" {
		cfg.FFprobe = "ffprobe"
	}
	if cfg.Token == "" {
		cfg.Token = newToken()
	}

	if host != "" {
		cfg.Host = host
	}
	if port != 0 {
		cfg.Port = port
	}

	if err := os.MkdirAll(cfg.ThumbDir(), 0o755); err != nil {
		return nil, fmt.Errorf("create thumbnail dir: %w", err)
	}
	if err := cfg.Save(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// Save writes the configuration back to disk with owner-only permissions,
// because it contains the access token.
func (c *Config) Save() error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(c.DataDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(c.DataDir, "config.json"), b, 0o600)
}

// DBPath is the SQLite index file.
func (c *Config) DBPath() string { return filepath.Join(c.DataDir, "index.db") }

// ThumbDir is the root of the thumbnail cache.
func (c *Config) ThumbDir() string { return filepath.Join(c.DataDir, "thumbs") }

// Addr is the listen address in host:port form.
func (c *Config) Addr() string { return net.JoinHostPort(c.Host, fmt.Sprintf("%d", c.Port)) }

// ThumbPath returns the on-disk location of a thumbnail. Thumbnails are
// sharded by the first two characters of the content hash so the cache does
// not become one enormous flat directory.
func (c *Config) ThumbPath(hash string) string {
	if len(hash) < 2 {
		return filepath.Join(c.ThumbDir(), "misc", hash+".jpg")
	}
	return filepath.Join(c.ThumbDir(), hash[:2], hash+".jpg")
}

func defaultServerName() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "MediaCenter"
	}
	return "MediaCenter-" + h
}

func newToken() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "insecure-token-please-change"
	}
	return hex.EncodeToString(b)
}
