// Package imageutil does the small amount of pixel work the backend needs.
//
// Resizing is implemented here rather than pulled in as a dependency: the
// operation is a box filter, which is the right choice for downscaling and is
// only a few dozen lines.
package imageutil

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	_ "image/gif" // register decoder
	"image/jpeg"
	_ "image/png" // register decoder
)

// ErrUnsupported is returned when the standard library cannot decode the image,
// which tells the caller to fall back to ffmpeg.
var ErrUnsupported = errors.New("imageutil: format not supported by the standard library")

// ThumbnailJPEG decodes src, downscales it so the longest edge is at most
// maxEdge pixels, and re-encodes it as JPEG.
func ThumbnailJPEG(src []byte, maxEdge, quality int) ([]byte, error) {
	img, _, err := image.Decode(bytes.NewReader(src))
	if err != nil {
		return nil, ErrUnsupported
	}
	if quality <= 0 || quality > 100 {
		quality = 82
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, Fit(img, maxEdge), &jpeg.Options{Quality: quality}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Dimensions reports the pixel size of an image without decoding every pixel.
func Dimensions(src []byte) (int, int, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(src))
	if err != nil {
		return 0, 0, ErrUnsupported
	}
	return cfg.Width, cfg.Height, nil
}

// Fit scales img down so neither edge exceeds maxEdge. Images already small
// enough are returned untouched.
func Fit(img image.Image, maxEdge int) image.Image {
	if maxEdge <= 0 {
		return img
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= 0 || h <= 0 || (w <= maxEdge && h <= maxEdge) {
		return img
	}

	dw, dh := w, h
	if w >= h {
		dw = maxEdge
		dh = int(float64(h)*float64(maxEdge)/float64(w) + 0.5)
	} else {
		dh = maxEdge
		dw = int(float64(w)*float64(maxEdge)/float64(h) + 0.5)
	}
	if dw < 1 {
		dw = 1
	}
	if dh < 1 {
		dh = 1
	}
	return resizeBox(img, b, dw, dh)
}

// resizeBox averages every source pixel that maps into a destination pixel.
// Accumulating in float64 keeps rounding error from drifting across a large
// downscale.
func resizeBox(src image.Image, sb image.Rectangle, dw, dh int) *image.RGBA {
	sw, sh := sb.Dx(), sb.Dy()
	n := dw * dh

	sumR := make([]float64, n)
	sumG := make([]float64, n)
	sumB := make([]float64, n)
	sumA := make([]float64, n)
	cnt := make([]float64, n)

	for y := 0; y < sh; y++ {
		dy := y * dh / sh
		row := dy * dw
		for x := 0; x < sw; x++ {
			i := row + x*dw/sw
			r, g, b, a := src.At(sb.Min.X+x, sb.Min.Y+y).RGBA()
			sumR[i] += float64(r)
			sumG[i] += float64(g)
			sumB[i] += float64(b)
			sumA[i] += float64(a)
			cnt[i]++
		}
	}

	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for i := 0; i < n; i++ {
		if cnt[i] == 0 {
			continue
		}
		c := cnt[i]
		a := sumA[i] / c
		var r, g, b float64
		if a > 0 {
			// image.Image hands back alpha-premultiplied values, so undo the
			// premultiplication before writing an RGBA pixel.
			r = sumR[i] / c * 65535 / a
			g = sumG[i] / c * 65535 / a
			b = sumB[i] / c * 65535 / a
		}
		dst.SetRGBA(i%dw, i/dw, color.RGBA{
			R: to8(r),
			G: to8(g),
			B: to8(b),
			A: to8(a),
		})
	}
	return dst
}

// to8 clamps a 16-bit channel value into the 8-bit range.
func to8(v float64) uint8 {
	if v < 0 {
		v = 0
	}
	if v > 65535 {
		v = 65535
	}
	return uint8(v / 257)
}
