package meta

import (
	"context"
	"encoding/json"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// ProbeResult is the subset of ffprobe output the index actually needs.
type ProbeResult struct {
	Width      int
	Height     int
	DurationMs int64
	VideoCodec string
	AudioCodec string
	TakenAt    time.Time
	HasTakenAt bool
}

type ffprobeDoc struct {
	Streams []struct {
		CodecType string `json:"codec_type"`
		CodecName string `json:"codec_name"`
		Width     int    `json:"width"`
		Height    int    `json:"height"`
	} `json:"streams"`
	Format struct {
		Duration string            `json:"duration"`
		Tags     map[string]string `json:"tags"`
	} `json:"format"`
}

// Probe shells out to ffprobe.
//
// Calling the ffprobe binary instead of linking against libav* keeps the build
// free of C dependencies, makes the produced executable portable, and means
// upgrading media support is just a matter of dropping in a newer ffmpeg.
func Probe(ffprobe, file string) (*ProbeResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, ffprobe,
		"-v", "error",
		"-print_format", "json",
		"-show_format",
		"-show_streams",
		file,
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var doc ffprobeDoc
	if err := json.Unmarshal(out, &doc); err != nil {
		return nil, err
	}

	res := &ProbeResult{}
	for _, s := range doc.Streams {
		switch s.CodecType {
		case "video":
			// The first video stream wins; later ones are usually embedded
			// cover art or thumbnails.
			if res.VideoCodec == "" {
				res.VideoCodec = s.CodecName
				res.Width, res.Height = s.Width, s.Height
			}
		case "audio":
			if res.AudioCodec == "" {
				res.AudioCodec = s.CodecName
			}
		}
	}

	if d, err := strconv.ParseFloat(doc.Format.Duration, 64); err == nil && d > 0 {
		res.DurationMs = int64(d * 1000)
	}

	for k, v := range doc.Format.Tags {
		if !strings.EqualFold(k, "creation_time") {
			continue
		}
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			res.TakenAt = t.Local()
			res.HasTakenAt = true
		}
		break
	}
	return res, nil
}

// HasTool reports whether an external binary is present on PATH.
func HasTool(name string) bool {
	if name == "" {
		return false
	}
	_, err := exec.LookPath(name)
	return err == nil
}
