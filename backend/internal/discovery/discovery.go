// Package discovery advertises the server on the local network over mDNS, so a
// client can find it without anyone typing an IP address.
//
// Two deliberate choices are baked in here:
//
//  1. The access token is NOT advertised. mDNS TXT records are readable by
//     every device on the same network, including guest Wi-Fi. Discovery tells
//     a client where the server is; it must still prove it is allowed in.
//
//  2. Only real LAN interfaces are advertised. This one is not cosmetic.
//     zeroconf.Register flattens the addresses of every interface handed to it
//     into a single A-record set, and appendAddrs puts that whole set in every
//     response it sends, no matter which link the query arrived on. Advertising
//     on a VM bridge therefore does not just add a redundant announcement: it
//     teaches every phone on the real Wi-Fi a second, unreachable address for
//     this host. Clients that pick that address simply fail to connect, with no
//     useful error. So the filter below has to be strict.
package discovery

import (
	"fmt"
	"log"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/grandcat/zeroconf"
	"golang.org/x/net/ipv4"

	"mediacenter/internal/config"
)

// ServiceType is the mDNS service the client browses for.
const ServiceType = "_mediacenter._tcp"

// Domain is the mDNS domain. "local." is the only one that matters on a LAN.
const Domain = "local."

// mDNSGroup is the IPv4 multicast group every mDNS implementation listens on.
var mDNSGroup = net.IPv4(224, 0, 0, 251)

// probePort is deliberately not 5353. Routing depends only on the destination
// address, so a discard port exercises exactly the same path while guaranteeing
// that a stray probe can never be mistaken for real mDNS traffic by the other
// responders on the network.
const probePort = 9

// addressRecheckInterval is how often the advertised address set is compared
// against reality. 15s is far more frequent than any DHCP renewal or Wi-Fi
// roam, and costs one net.Interfaces() call, which is a few microseconds.
const addressRecheckInterval = 15 * time.Second

// Advertiser owns the mDNS registration so it can be withdrawn on shutdown.
//
// It also owns a watcher: the registration captures the machine's addresses at
// start-up, so a server that runs for days silently advertises whatever was
// true when it booted. DHCP renewal, Wi-Fi roam, sleep/wake and docking all
// change the address, and a stale one is worse than none - the client happily
// connects to an IP that no longer exists. The watcher re-registers when the
// set of routable addresses changes.
type Advertiser struct {
	mu      sync.Mutex
	server  *zeroconf.Server
	cfg     *config.Config
	txt     []string
	sig     string
	sigFn   func() string
	every   time.Duration
	stop    chan struct{}
	stopped bool
	wg      sync.WaitGroup
}

// Start registers the service and returns a handle for Shutdown.
//
// A failure here is never fatal: discovery is a convenience, and a server the
// user can still reach by typing an address is far better than a server that
// refuses to boot because the network would not cooperate.
func Start(cfg *config.Config, version string, apiVersion int) (*Advertiser, error) {
	txt := []string{
		fmt.Sprintf("name=%s", cfg.ServerName),
		fmt.Sprintf("version=%s", version),
		fmt.Sprintf("api=%d", apiVersion),
		// Lets a future client discover the status page path without guessing.
		"path=/",
	}

	ifaces := advertisableInterfaces()
	if len(ifaces) == 0 {
		return nil, fmt.Errorf("no advertisable network interface found")
	}

	server, err := zeroconf.Register(cfg.ServerName, ServiceType, Domain, cfg.Port, txt, ifaces)
	if err != nil {
		return nil, err
	}

	a := &Advertiser{
		server: server,
		cfg:    cfg,
		txt:    txt,
		sig:    interfaceSignature(),
		sigFn:  interfaceSignature,
		every:  addressRecheckInterval,
		stop:   make(chan struct{}),
	}

	// Log the interface *and* the address, because the address is the part
	// that can be wrong in a way nobody notices until a client cannot connect.
	// Since zeroconf advertises all of them together, this line is the only
	// place the full advertised set is visible.
	logBanner(cfg, ifaces)

	// Now check whether those packets can actually leave. Registration above
	// reports success even when every send fails, so without this the banner
	// would promise a service that nobody can discover.
	var blocked []string
	for _, i := range ifaces {
		if err := checkMulticastSend(i); err != nil {
			blocked = append(blocked, fmt.Sprintf("%s: %v", i.Name, err))
		}
	}
	if len(blocked) > 0 {
		log.Printf("  提示     : 组播发送不通，客户端可能无法自动发现本机，需手动输入地址")
		for _, b := range blocked {
			log.Printf("             %s", b)
		}
	}

	a.wg.Add(1)
	go a.watchAddresses()

	return a, nil
}

// logBanner prints the one line that shows what is actually being advertised.
func logBanner(cfg *config.Config, ifaces []net.Interface) {
	parts := make([]string, 0, len(ifaces))
	for _, i := range ifaces {
		parts = append(parts, fmt.Sprintf("%s (%s)", i.Name, strings.Join(routableIPv4(i), ", ")))
	}
	log.Printf("  mDNS     : 广播 %s.%s 于 %s", cfg.ServerName, ServiceType, strings.Join(parts, "  "))
}

// interfaceSignature is a comparable fingerprint of the advertised address set.
//
// It is deliberately built from the same filter the registration uses, so a
// change the client would notice - an address appearing, disappearing,
// changing, or an interface being replaced - always changes the signature, and
// nothing else does.
func interfaceSignature() string {
	return signatureOf(advertisableInterfaces())
}

// signatureOf is interfaceSignature split out so the ordering and identity
// rules can be tested without a network.
//
// Determinism is the whole point: if this returned a different string for the
// same interfaces, the watcher would re-register every single tick, and the
// log would fill with "address changed" lines on a machine whose address never
// changed at all.
func signatureOf(ifaces []net.Interface) string {
	parts := make([]string, 0, len(ifaces))
	for _, i := range ifaces {
		addrs := append([]string(nil), routableIPv4(i)...)
		sort.Strings(addrs)
		// The index is part of the identity: unplugging and re-plugging an
		// adapter usually reuses the name but not the index.
		parts = append(parts, fmt.Sprintf("%s#%d=%s", i.Name, i.Index, strings.Join(addrs, ",")))
	}
	sort.Strings(parts)
	return strings.Join(parts, ";")
}

// watchAddresses re-registers the service whenever the advertised address set
// stops matching reality, and withdraws it when there is nothing left to
// advertise.
//
// Two reasons this is a timer and not a netlink subscription: Go has no
// portable interface-change notification, and polling net.Interfaces() is
// cheap enough that the honest but boring approach wins.
func (a *Advertiser) watchAddresses() {
	defer a.wg.Done()

	t := time.NewTicker(a.every)
	defer t.Stop()

	for {
		select {
		case <-a.stop:
			return
		case <-t.C:
		}

		sig := a.sigFn()

		a.mu.Lock()
		if a.stopped || sig == a.sig {
			a.mu.Unlock()
			continue
		}
		old, cfg, txt := a.server, a.cfg, a.txt
		a.mu.Unlock()

		ifaces := advertisableInterfaces()
		if len(ifaces) == 0 {
			// Every LAN interface went away. Withdraw rather than keep
			// answering with addresses that no longer exist.
			log.Printf("  提示     : 没有可广播的网卡了，已撤销 mDNS 广播")
			if old != nil {
				old.Shutdown()
			}
			a.mu.Lock()
			a.server, a.sig = nil, sig
			a.mu.Unlock()
			continue
		}

		// Shutdown the old registration *before* registering the new one:
		// two responders answering for the same instance name is exactly the
		// kind of thing mDNS resolves unpredictably.
		if old != nil {
			old.Shutdown()
		}

		server, err := zeroconf.Register(cfg.ServerName, ServiceType, Domain, cfg.Port, txt, ifaces)
		if err != nil {
			// Leave a.sig alone so the next tick tries again - a failed
			// re-registration is usually transient (port still held by the
			// responder that is going away).
			log.Printf("  提示     : 本机地址变了，但重新广播失败，下个周期重试：%v", err)
			continue
		}

		logBanner(cfg, ifaces)
		log.Printf("  mDNS     : 本机地址发生变化，已按新地址重新广播")

		a.mu.Lock()
		if a.stopped {
			// Shutdown raced us. Do not leave an orphan responder behind.
			a.mu.Unlock()
			server.Shutdown()
			return
		}
		a.server, a.sig = server, sig
		a.mu.Unlock()
	}
}

// checkMulticastSend reports whether a packet addressed to the mDNS group can
// actually be sent out of iface.
//
// This check exists because the library hides the answer. zeroconf's
// multicastResponse discards every WriteTo error and returns nil, so a machine
// where multicast is blocked - by a VPN, a firewall, or a network policy -
// still logs a cheerful "broadcasting on ..." line and then discovers nothing.
// From the outside that is indistinguishable from working. Probing first turns
// the silent lie into a warning the user can act on.
//
// The failure is real and common enough to be worth the extra socket: several
// VPN clients route all traffic, including multicast, away from the LAN
// interface, and the user's only symptom is that the phone cannot find the
// server.
func checkMulticastSend(iface net.Interface) error {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return err
	}
	defer conn.Close()

	pc := ipv4.NewPacketConn(conn)
	if err := pc.SetMulticastInterface(&iface); err != nil {
		return err
	}
	if _, err := pc.WriteTo([]byte{0}, nil, &net.UDPAddr{IP: mDNSGroup, Port: probePort}); err != nil {
		return err
	}
	return nil
}

// Shutdown withdraws the advertisement (sends the goodbye packets) so clients
// drop the entry immediately instead of waiting for the TTL to expire.
//
// It also stops the address watcher, and waits for it: leaving a goroutine
// running that re-registers a service nobody asked for is the kind of leak
// that only shows up on a machine that has been up for a week.
func (a *Advertiser) Shutdown() {
	if a == nil {
		return
	}

	a.mu.Lock()
	if a.stopped {
		a.mu.Unlock()
		return
	}
	a.stopped = true
	close(a.stop)
	server := a.server
	a.server = nil
	a.mu.Unlock()

	if server != nil {
		server.Shutdown()
	}
	// Wait outside the lock - the watcher needs the lock to finish.
	a.wg.Wait()
}

// LANIPv4 returns the IPv4 addresses a peer on the local network can reach
// this machine at.
//
// This is the single source of truth for both the startup banner and the mDNS
// advertisement. They used to each carry their own copy of the filter, which
// drifted apart the moment one of them changed - so the address a user copied
// out of the banner was no longer the address a client could discover. Keeping
// one function means they cannot disagree.
func LANIPv4() []string {
	var out []string
	for _, iface := range advertisableInterfaces() {
		out = append(out, routableIPv4(iface)...)
	}
	return out
}

// virtualInterfacePrefixes names interface families that look like LAN links
// but are not, and must never be advertised on. See the package comment for
// why a mistake here breaks clients on the *real* network rather than just
// wasting packets on the virtual one.
//
// Matching is by name prefix because the kernel offers no portable flag that
// distinguishes a bridge from an Ethernet port - both are UP, BROADCAST,
// MULTICAST and RUNNING. Names are the only signal available.
var virtualInterfacePrefixes = []string{
	// macOS
	"bridge", // VM bridges: bridge0, bridge100, bridge101, ...
	"vmenet", // NICs handed to VM guests
	"vmnet",  // VMware / UTM host side
	"utun",   // VPN and userspace tunnels
	"gif",    // IPv6-in-IPv4 transition tunnels
	"stf",    // 6to4 tunnels
	"anpi",   // Apple internal network processor NICs
	"awdl",   // Apple Wireless Direct Link (AirDrop) - never carries HTTP
	"llw",    // low-latency WLAN, the AWDL companion
	// Linux containers and virtualisation
	"docker",
	"veth",
	"virbr",
	"br", // br0 (libvirt) and br-xxxxxxxxxxxx (Docker)
	"tun",
	"tap",
}

// advertisableInterfaces picks the interfaces worth advertising on.
//
// An interface qualifies only if a client on the same link could actually open
// a TCP connection to it: it must be up, not loopback, not point-to-point, not
// a known virtual family, and it must carry a routable IPv4 address.
func advertisableInterfaces() []net.Interface {
	all, err := net.Interfaces()
	if err != nil {
		return nil
	}

	var out []net.Interface
	for _, iface := range all {
		if iface.Flags&net.FlagUp == 0 ||
			iface.Flags&net.FlagLoopback != 0 ||
			iface.Flags&net.FlagMulticast == 0 ||
			// Point-to-point links (utun, tun, gif) have no "same link" for a
			// client to be on. This flag is portable, unlike the name list.
			iface.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		if isVirtualInterface(iface.Name) {
			continue
		}
		if len(routableIPv4(iface)) == 0 {
			continue
		}
		out = append(out, iface)
	}
	return out
}

func isVirtualInterface(name string) bool {
	lower := strings.ToLower(name)
	for _, prefix := range virtualInterfacePrefixes {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

// routableIPv4 returns the IPv4 addresses of iface that a client on the same
// link could actually connect to.
//
// The service is plain HTTP over IPv4, so an IPv6-only link is of no use to a
// client. Link-local (169.254.x.x) and unspecified addresses are dropped too:
// the kernel reports them, but nothing can be reached through them.
func routableIPv4(iface net.Interface) []string {
	addrs, err := iface.Addrs()
	if err != nil {
		return nil
	}
	var out []string
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip4 := ipnet.IP.To4()
		if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() || ip4.IsUnspecified() {
			continue
		}
		out = append(out, ip4.String())
	}
	return out
}
