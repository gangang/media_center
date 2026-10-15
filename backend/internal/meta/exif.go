// Package meta extracts capture metadata from media files.
//
// Image dimensions come from the Go standard library when the format is
// supported, and from ffprobe otherwise. Video metadata always comes from
// ffprobe. EXIF capture time is read by a small self-contained JPEG parser so
// the project does not depend on an unmaintained third-party EXIF library.
package meta

import (
	"encoding/binary"
	"time"
)

// JPEGTakenAt reads EXIF DateTimeOriginal from a JPEG byte slice.
//
// The value is returned in the camera's local wall clock, which is what a user
// expects to see in a timeline: a photo shot at 19:30 in Paris should read
// 19:30 regardless of where the server is running.
func JPEGTakenAt(b []byte) (time.Time, bool) {
	if len(b) < 4 || b[0] != 0xFF || b[1] != 0xD8 {
		return time.Time{}, false
	}

	off := 2
	for off+4 <= len(b) {
		if b[off] != 0xFF {
			return time.Time{}, false
		}
		marker := b[off+1]

		// Standalone markers carry no payload.
		if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8) {
			off += 2
			continue
		}
		// Start of scan or end of image: EXIF would have come earlier.
		if marker == 0xDA || marker == 0xD9 {
			return time.Time{}, false
		}

		segLen := int(binary.BigEndian.Uint16(b[off+2 : off+4]))
		if segLen < 2 || off+2+segLen > len(b) {
			return time.Time{}, false
		}

		if marker == 0xE1 {
			seg := b[off+4 : off+2+segLen]
			if len(seg) >= 6 && string(seg[:6]) == "Exif\x00\x00" {
				return parseTIFF(seg[6:])
			}
		}
		off += 2 + segLen
	}
	return time.Time{}, false
}

// parseTIFF walks the TIFF structure that follows the "Exif\0\0" header and
// pulls out DateTimeOriginal, falling back to the older DateTime tag.
func parseTIFF(t []byte) (time.Time, bool) {
	if len(t) < 8 {
		return time.Time{}, false
	}

	var order binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		order = binary.LittleEndian
	case "MM":
		order = binary.BigEndian
	default:
		return time.Time{}, false
	}
	if order.Uint16(t[2:4]) != 42 {
		return time.Time{}, false
	}

	ifd0 := int(order.Uint32(t[4:8]))
	var fallback string
	var exifIFD int

	readIFD(ifd0, t, order, func(tag, typ uint16, count uint32, entryOff int) {
		switch tag {
		case 0x8769: // ExifIFD pointer
			if v, ok := readUint32(t, order, entryOff); ok {
				exifIFD = int(v)
			}
		case 0x0132: // DateTime
			if s, ok := readASCII(t, order, typ, count, entryOff); ok && fallback == "" {
				fallback = s
			}
		}
	})

	found := ""
	if exifIFD > 0 {
		readIFD(exifIFD, t, order, func(tag, typ uint16, count uint32, entryOff int) {
			if tag == 0x9003 { // DateTimeOriginal
				if s, ok := readASCII(t, order, typ, count, entryOff); ok {
					found = s
				}
			}
		})
	}
	if found == "" {
		found = fallback
	}
	if len(found) < 19 {
		return time.Time{}, false
	}

	// EXIF format is "2006:01:02 15:04:05"; some writers append a subsecond.
	tm, err := time.ParseInLocation("2006:01:02 15:04:05", found[:19], time.Local)
	if err != nil || tm.Year() < 1970 {
		return time.Time{}, false
	}
	return tm, true
}

// readIFD invokes fn for every 12-byte entry in the IFD at off.
func readIFD(off int, t []byte, order binary.ByteOrder, fn func(tag, typ uint16, count uint32, entryOff int)) {
	if off <= 0 || off+2 > len(t) {
		return
	}
	n := int(order.Uint16(t[off : off+2]))
	for i := 0; i < n; i++ {
		e := off + 2 + i*12
		if e+12 > len(t) {
			return
		}
		tag := order.Uint16(t[e : e+2])
		typ := order.Uint16(t[e+2 : e+4])
		count := order.Uint32(t[e+4 : e+8])
		fn(tag, typ, count, e)
	}
}

// typeSize returns the byte width of an EXIF field type, or 0 when unknown.
func typeSize(typ uint16) int {
	switch typ {
	case 1, 2, 6, 7: // BYTE, ASCII, SBYTE, UNDEFINED
		return 1
	case 3, 8: // SHORT, SSHORT
		return 2
	case 4, 9: // LONG, SLONG
		return 4
	case 5, 10: // RATIONAL, SRATIONAL
		return 8
	case 11: // FLOAT
		return 4
	case 12: // DOUBLE
		return 8
	}
	return 0
}

// entryValue resolves an entry to its raw bytes, following the offset when the
// value does not fit in the 4-byte inline field.
func entryValue(t []byte, order binary.ByteOrder, typ uint16, count uint32, entryOff int) ([]byte, bool) {
	size := typeSize(typ)
	if size == 0 || count == 0 {
		return nil, false
	}
	n := int(count) * size
	if n <= 4 {
		if entryOff+8+n > len(t) {
			return nil, false
		}
		return t[entryOff+8 : entryOff+8+n], true
	}
	ptr := int(order.Uint32(t[entryOff+8 : entryOff+12]))
	if ptr <= 0 || ptr+n > len(t) {
		return nil, false
	}
	return t[ptr : ptr+n], true
}

func readUint32(t []byte, order binary.ByteOrder, entryOff int) (uint32, bool) {
	if entryOff+12 > len(t) {
		return 0, false
	}
	return order.Uint32(t[entryOff+8 : entryOff+12]), true
}

func readASCII(t []byte, order binary.ByteOrder, typ uint16, count uint32, entryOff int) (string, bool) {
	if typ != 2 {
		return "", false
	}
	v, ok := entryValue(t, order, typ, count, entryOff)
	if !ok {
		return "", false
	}
	// Trim the trailing NUL terminator.
	for len(v) > 0 && v[len(v)-1] == 0 {
		v = v[:len(v)-1]
	}
	return string(v), true
}
