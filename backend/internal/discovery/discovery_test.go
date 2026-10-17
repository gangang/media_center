package discovery

import (
	"net"
	"testing"
	"time"

	"mediacenter/internal/config"
)

// The interface filter is the one part of this package that can be tested
// without a network, and it is also the part most likely to rot: it encodes a
// list of names that only a particular OS version produces. These cases are
// taken from real `ifconfig -a` output so a future edit that drops a prefix
// fails loudly here instead of quietly re-introducing unreachable A records.
func TestIsVirtualInterface(t *testing.T) {
	virtual := []string{
		// Observed on macOS with a VM host running.
		"bridge0", "bridge100", "bridge101", "bridge102",
		"vmenet0", "vmenet1", "vmnet1",
		"utun0", "utun3", "gif0", "stf0",
		"anpi0", "awdl0", "llw0",
		// Linux containers and virtualisation.
		"docker0", "veth1a2b3c", "virbr0", "br0", "br-9f2c1d", "tun0", "tap0",
		// Case should not matter.
		"BRIDGE100",
	}
	for _, name := range virtual {
		if !isVirtualInterface(name) {
			t.Errorf("isVirtualInterface(%q) = false, want true", name)
		}
	}

	// Names that must survive the filter. "ap1" is macOS Internet Sharing:
	// devices joined to that hotspot really are on the LAN and should be able
	// to discover the server.
	real := []string{"en0", "en1", "eth0", "eth1", "wlan0", "wlp3s0", "enp0s3", "ap1"}
	for _, name := range real {
		if isVirtualInterface(name) {
			t.Errorf("isVirtualInterface(%q) = true, want false", name)
		}
	}
}

// The address watcher re-registers the service whenever signatureOf changes.
// Two properties matter, and both are easy to break silently:
//
//   - it must be *stable*, or a machine whose address never changed would
//     re-register every tick (a map iteration or an unsorted join does this);
//   - it must *distinguish* the cases a client would notice, chiefly two
//     addresses on the same adapter and a replaced adapter.
func TestSignatureOfStabilityAndIdentity(t *testing.T) {
	synthetic := []net.Interface{
		{Index: 14, Name: "en0"},
		{Index: 15, Name: "en5"},
	}

	first := signatureOf(synthetic)
	for i := 0; i < 50; i++ {
		if got := signatureOf(synthetic); got != first {
			t.Fatalf("signatureOf is not deterministic:\n first = %q\n  call = %q", first, got)
		}
	}

	// Ordering of the input must not matter: the same set of adapters picked
	// up in a different order is the same network.
	reversed := []net.Interface{synthetic[1], synthetic[0]}
	if got := signatureOf(reversed); got != first {
		t.Errorf("signatureOf depends on input order:\n first = %q\n  reversed = %q", first, got)
	}

	// An interface swap is a real event: names get reused, indexes do not.
	swapped := []net.Interface{synthetic[0], {Index: 16, Name: "en5"}}
	if got := signatureOf(swapped); got == first {
		t.Errorf("a replaced adapter produced the same signature %q", first)
	}

	// Fewer interfaces must differ too - this is the Wi-Fi-goes-away case.
	if got := signatureOf(synthetic[:1]); got == first {
		t.Errorf("dropping an adapter produced the same signature %q", first)
	}
}

// interfaceSignature runs against the real machine, so it cannot assert a
// particular value. It can assert the thing that actually breaks: that two
// reads of the same network agree. Without this, a non-deterministic
// signature would only ever show up as a server re-broadcasting forever.
func TestInterfaceSignatureIsStable(t *testing.T) {
	first := interfaceSignature()
	if got := interfaceSignature(); got != first {
		t.Fatalf("interfaceSignature changed between two reads:\n first = %q\n second = %q", first, got)
	}
}

// The watcher is a goroutine that outlives any single request, so the property
// that matters is not what it does but that it stops. A leaked watcher is only
// visible on a machine that has been up for a week, and by then nobody
// connects it to this code.
//
// The signature source is held constant on purpose: a change here would try to
// bind the mDNS port, and only one process on the machine may hold that. This
// test is about the lifecycle, not the registration.
func TestWatcherStopsOnShutdown(t *testing.T) {
	a := &Advertiser{
		sig:   "en0#14=192.168.1.49",
		sigFn: func() string { return "en0#14=192.168.1.49" },
		every: 5 * time.Millisecond,
		stop:  make(chan struct{}),
		cfg:   &config.Config{ServerName: "watcher-test"},
		txt:   []string{"name=watcher-test"},
	}

	a.wg.Add(1)
	go a.watchAddresses()

	// Let it tick a few times first, so a watcher that re-registers on every
	// tick would already have misbehaved.
	time.Sleep(40 * time.Millisecond)

	done := make(chan struct{})
	go func() {
		a.Shutdown()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Shutdown did not return; the watcher goroutine is still running")
	}

	// And it must stay stopped, not merely pause.
	a.Shutdown()
}
