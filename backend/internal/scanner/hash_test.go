package scanner

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// vectorFill produces the deterministic byte sequence shared by this test and
// the Dart counterpart (client/test/content_hash_test.dart).
//
// It is deliberately arithmetic rather than random: both languages must be able
// to rebuild the exact same bytes without shipping a binary fixture.
func vectorFill(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte((i*37 + 11) % 256)
	}
	return b
}

// contentHashVectors pins the content fingerprint.
//
// The same constants appear verbatim in the Dart client, and that duplication is
// the point. Instant upload (秒传) only fires when both sides compute a
// byte-identical hash. A drift between them would not raise an error anywhere —
// it would just quietly make every backup re-upload files the server already
// had, which looks like "dedup is slow" rather than like a bug.
//
// The sizes straddle 256 KiB, where the algorithm switches from "head only" to
// "head + tail", and the 1 KiB scanner floor.
func TestContentHashVectors(t *testing.T) {
	cases := []struct {
		size int
		want string
	}{
		{0, "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc"},
		{1, "62e7e02ebe7b1ee4cd2120090bc09b8baf24b40c2bb5ef15aa3ad054b1b57412"},
		{1023, "9e20c018bdc8331d1f488eacd97f58f795359518bc6040d054c583ea4f738c18"},
		{1024, "14fac5fe7015bcbf8d0af8d27c2c637e1f59633c49fc41c7daf4acb5c088c04e"},
		{262143, "b90fbed02d9e51a1bc7b0c9617660fb4a958731a606ac229a3cfafff6cf9cafb"},
		{262144, "b681453aedfd522f2b202a4718254c8425a85df37626088a0a79dd6814503b95"},
		{262145, "12c8c9e0a2b54df9a743c21b20ccb3ead735b47dda8fdb9e9c2a67c2530c2383"},
		{524288, "532137cd71fbb1c59f03ddeb059e498116928183567b37fc9411422cfacf5614"},
		{1048576, "c12e90efb667b07ff4d8fdab0cdc31a9490c6e41f056c8db8c020cd03079bab4"},
		{3000000, "7d266d141a819b0e1a42df3f9f94e7ab570529502b76a1fb561d4ea46cacd2e5"},
	}

	dir := t.TempDir()
	for _, tc := range cases {
		p := filepath.Join(dir, "f"+strconv.Itoa(tc.size)+".bin")
		if err := os.WriteFile(p, vectorFill(tc.size), 0o644); err != nil {
			t.Fatal(err)
		}
		got, err := ContentHash(p, int64(tc.size))
		if err != nil {
			t.Fatalf("size %d: %v", tc.size, err)
		}
		if got != tc.want {
			t.Errorf("size %d:\n got %s\nwant %s", tc.size, got, tc.want)
		}
	}
}

// TestContentHashIgnoresTheMiddle documents the trade-off rather than
// discovering it later.
//
// The fingerprint is size + first 256 KiB + last 256 KiB (D4). Two files that
// agree on all three but differ in the middle hash identically. That is
// intentional: hashing a 4 GB video end-to-end would dominate scan time, and the
// identity exists to survive moves and renames, not to detect tampering.
//
// This test exists so the property is a decision someone can read, not a
// surprise. If it ever fails, the hash changed — and every client that had
// already computed hashes against the old one silently lost instant upload.
func TestContentHashIgnoresTheMiddle(t *testing.T) {
	const size = 1024 * 1024
	dir := t.TempDir()

	a := vectorFill(size)
	b := vectorFill(size)
	b[size/2] ^= 0xFF // one byte in the untouched middle

	pa := filepath.Join(dir, "a.bin")
	pb := filepath.Join(dir, "b.bin")
	if err := os.WriteFile(pa, a, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pb, b, 0o644); err != nil {
		t.Fatal(err)
	}

	ha, err := ContentHash(pa, size)
	if err != nil {
		t.Fatal(err)
	}
	hb, err := ContentHash(pb, size)
	if err != nil {
		t.Fatal(err)
	}
	if ha != hb {
		t.Errorf("头尾指纹应忽略中间字节，但哈希不同：\n a=%s\n b=%s", ha, hb)
	}

	// The size is part of the identity, so changing it must change the hash.
	if h, err := ContentHash(pa, size-1); err != nil {
		t.Fatal(err)
	} else if h == ha {
		t.Error("大小参与了身份计算，改变 size 参数应当改变哈希")
	}
}
