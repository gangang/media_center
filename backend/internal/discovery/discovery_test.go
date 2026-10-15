package discovery

import "testing"

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
