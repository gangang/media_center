package meta

import (
	"encoding/binary"
	"testing"
	"time"
)

// buildExifJPEG 构造一个只含 EXIF 时间信息的最小 JPEG。
//
// 布局（与真实相机写出的结构一致）:
//
//	0   TIFF 头: 字节序标记 + 42 + IFD0 偏移(8)
//	8   IFD0:  DateTime(0x0132) + ExifIFD 指针(0x8769)
//	38  ExifIFD: DateTimeOriginal(0x9003)
//	56  DateTime 字符串
//	76  DateTimeOriginal 字符串
func buildExifJPEG(t *testing.T, order binary.ByteOrder, dt string) []byte {
	t.Helper()

	ts := append([]byte(dt), 0)
	if len(ts) != 20 {
		t.Fatalf("时间字符串必须是 19 个字符，得到 %d", len(dt))
	}

	tiff := make([]byte, 0, 96)
	// PutUint16 / PutUint32 是 binary.ByteOrder 接口的一部分，
	// 因此大端小端两种实现都能直接复用同一段构造代码。
	var buf16 [2]byte
	var buf32 [4]byte
	put16 := func(v uint16) {
		order.PutUint16(buf16[:], v)
		tiff = append(tiff, buf16[:]...)
	}
	put32 := func(v uint32) {
		order.PutUint32(buf32[:], v)
		tiff = append(tiff, buf32[:]...)
	}

	// TIFF 头
	if order == binary.BigEndian {
		tiff = append(tiff, "MM"...)
	} else {
		tiff = append(tiff, "II"...)
	}
	put16(42)
	put32(8)

	// IFD0
	put16(2)
	put16(0x0132) // DateTime
	put16(2)      // ASCII
	put32(20)
	put32(56)
	put16(0x8769) // ExifIFD 指针
	put16(4)      // LONG
	put32(1)
	put32(38)
	put32(0) // 无下一个 IFD

	if len(tiff) != 38 {
		t.Fatalf("IFD0 结束时偏移应为 38，实际 %d", len(tiff))
	}

	// ExifIFD
	put16(1)
	put16(0x9003) // DateTimeOriginal
	put16(2)
	put32(20)
	put32(76)
	put32(0)

	if len(tiff) != 56 {
		t.Fatalf("ExifIFD 结束时偏移应为 56，实际 %d", len(tiff))
	}
	tiff = append(tiff, ts...) // 56..76
	tiff = append(tiff, ts...) // 76..96

	payload := append([]byte("Exif\x00\x00"), tiff...)

	out := []byte{0xFF, 0xD8} // SOI
	out = append(out, 0xFF, 0xE1)
	var segLen [2]byte
	binary.BigEndian.PutUint16(segLen[:], uint16(len(payload)+2))
	out = append(out, segLen[:]...)
	out = append(out, payload...)
	out = append(out, 0xFF, 0xD9) // EOI
	return out
}

func TestJPEGTakenAt_BigEndian(t *testing.T) {
	raw := buildExifJPEG(t, binary.BigEndian, "2019:07:14 18:30:00")

	got, ok := JPEGTakenAt(raw)
	if !ok {
		t.Fatal("应当解析成功")
	}
	want := time.Date(2019, 7, 14, 18, 30, 0, 0, time.Local)
	if !got.Equal(want) {
		t.Fatalf("期望 %v，得到 %v", want, got)
	}
}

func TestJPEGTakenAt_LittleEndian(t *testing.T) {
	raw := buildExifJPEG(t, binary.LittleEndian, "2023:12:25 09:15:00")

	got, ok := JPEGTakenAt(raw)
	if !ok {
		t.Fatal("应当解析成功")
	}
	want := time.Date(2023, 12, 25, 9, 15, 0, 0, time.Local)
	if !got.Equal(want) {
		t.Fatalf("期望 %v，得到 %v", want, got)
	}
}

// 拍摄时间应当按「相机的墙上时钟」解读，而不是当成 UTC。
// 一张在巴黎 19:30 拍的照片，无论服务器在哪个时区，时间线上都应显示 19:30。
func TestJPEGTakenAt_PreservesWallClock(t *testing.T) {
	raw := buildExifJPEG(t, binary.BigEndian, "2020:01:01 19:30:00")

	got, ok := JPEGTakenAt(raw)
	if !ok {
		t.Fatal("应当解析成功")
	}
	if got.Hour() != 19 || got.Minute() != 30 {
		t.Fatalf("墙上时钟应为 19:30，得到 %02d:%02d", got.Hour(), got.Minute())
	}
	if got.Location() != time.Local {
		t.Fatalf("应当使用本地时区，得到 %v", got.Location())
	}
}

func TestJPEGTakenAt_RejectsGarbage(t *testing.T) {
	cases := map[string][]byte{
		"空输入":          nil,
		"非 JPEG":       []byte("this is not a jpeg at all"),
		"只有 SOI":       {0xFF, 0xD8},
		"截断的段长度":       {0xFF, 0xD8, 0xFF, 0xE1, 0x00},
		"APP1 但无 EXIF": {0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x08, 'X', 'Y', 'Z', 0, 0, 0, 0},
	}

	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			// 关键是不能 panic —— 扫描器会拿任意文件喂进来。
			if _, ok := JPEGTakenAt(raw); ok {
				t.Fatal("不应当解析成功")
			}
		})
	}
}

func TestJPEGTakenAt_TruncatedInsideTIFF(t *testing.T) {
	full := buildExifJPEG(t, binary.BigEndian, "2019:07:14 18:30:00")

	// 逐字节截断，验证任何长度都不会 panic。
	for n := 0; n < len(full); n++ {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("长度 %d 时 panic: %v", n, r)
				}
			}()
			JPEGTakenAt(full[:n])
		}()
	}
}

func TestJPEGTakenAt_SkipsEarlierSegments(t *testing.T) {
	// 真实 JPEG 在 EXIF 之前常有 APP0(JFIF)、APP1(XMP) 等段，
	// 解析器必须能跳过它们继续找。
	jfif := []byte{
		0xFF, 0xE0, 0x00, 0x10,
		'J', 'F', 'I', 'F', 0x00, 0x01, 0x01, 0x00,
		0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
	}
	xmp := append([]byte{0xFF, 0xE1, 0x00, 0x0A}, []byte("XMPnope\000")...)
	exif := buildExifJPEG(t, binary.BigEndian, "2021:06:01 12:00:00")[2:]

	raw := append([]byte{0xFF, 0xD8}, jfif...)
	raw = append(raw, xmp...)
	raw = append(raw, exif...)

	got, ok := JPEGTakenAt(raw)
	if !ok {
		t.Fatal("应当跳过前置段并解析成功")
	}
	if got.Year() != 2021 || got.Month() != 6 || got.Day() != 1 {
		t.Fatalf("期望 2021-06-01，得到 %v", got)
	}
}
