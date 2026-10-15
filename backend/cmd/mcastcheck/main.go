// Command mcastcheck isolates the mDNS send path, which the zeroconf library
// swallows: its multicastResponse() discards every WriteTo error and returns
// nil, so a denied or unroutable send is indistinguishable from a delivered
// packet.
//
// It tries each way of telling the kernel which interface to send on, because
// they are not equivalent on macOS. When several interfaces carry a route to
// the mDNS group (a real LAN port plus VM bridges), the kernel installs
// per-interface IFSCOPE routes, and an unscoped socket cannot use one - the
// send then fails with EHOSTUNREACH.
//
//	go run ./cmd/mcastcheck -iface en0
//
// This is a diagnostic, not part of the product.
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"golang.org/x/net/ipv4"
)

var (
	port = 5353
)

func main() {
	ifName := flag.String("iface", "en0", "interface to test")
	groupIP := flag.String("group", "224.0.0.251", "multicast group to send to")
	skipBind := flag.Bool("skip-bind", false, "bind an ephemeral port instead of 5353")
	flag.Parse()

	group := net.ParseIP(*groupIP)
	if group == nil {
		fmt.Fprintf(os.Stderr, "无法解析组播地址 %s\n", *groupIP)
		os.Exit(1)
	}
	groupV4 := &net.UDPAddr{IP: group, Port: port}

	iface, err := net.InterfaceByName(*ifName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "找不到网卡 %s: %v\n", *ifName, err)
		os.Exit(1)
	}
	fmt.Printf("网卡: %s (index=%d)  组播组: %s\n\n", iface.Name, iface.Index, groupV4)

	laddr := &net.UDPAddr{IP: net.IPv4zero, Port: port}
	if *skipBind {
		laddr = &net.UDPAddr{IP: net.IPv4zero, Port: 0}
	}
	conn, err := net.ListenUDP("udp4", laddr)
	if err != nil {
		fmt.Printf("bind %s -> 失败: %v\n", laddr, err)
		os.Exit(1)
	}
	defer conn.Close()
	fmt.Printf("bind %s -> 成功（本地 %s）\n\n", laddr, conn.LocalAddr())

	pc := ipv4.NewPacketConn(conn)
	pc.SetControlMessage(ipv4.FlagInterface, true)

	// Joining the group is not only about receiving. On macOS it is also what
	// makes the kernel install a usable multicast route for this socket: skip
	// it and every send below fails with EHOSTUNREACH even though a route for
	// the group is present in the routing table. Leaving this step out is the
	// mistake that makes this diagnostic report a false negative.
	if err := pc.JoinGroup(iface, &net.UDPAddr{IP: group}); err != nil {
		fmt.Printf("JoinGroup(%s, %s) -> 失败: %v\n\n", iface.Name, group, err)
	} else {
		fmt.Printf("JoinGroup(%s, %s) -> 成功\n\n", iface.Name, group)
	}

	// Try every send strategy and report the real error from each.
	type strategy struct {
		name string
		run  func(payload []byte) error
	}
	strategies := []strategy{
		{
			name: "A. 控制消息 IfIndex（zeroconf 的做法）",
			run: func(p []byte) error {
				_, err := pc.WriteTo(p, &ipv4.ControlMessage{IfIndex: iface.Index}, groupV4)
				return err
			},
		},
		{
			name: "B. SetMulticastInterface + 普通 WriteTo",
			run: func(p []byte) error {
				if err := pc.SetMulticastInterface(iface); err != nil {
					return fmt.Errorf("SetMulticastInterface: %w", err)
				}
				_, err := pc.WriteTo(p, nil, groupV4)
				return err
			},
		},
		{
			name: "C. 什么都不指定（交给路由表）",
			run: func(p []byte) error {
				_, err := pc.WriteTo(p, nil, groupV4)
				return err
			},
		},
	}

	for _, s := range strategies {
		err := s.run([]byte("mcastcheck"))
		if err != nil {
			fmt.Printf("%-44s -> 失败: %v\n", s.name, err)
		} else {
			fmt.Printf("%-44s -> 成功\n", s.name)
		}
	}

	// Whichever strategy worked, confirm the packet is actually visible by
	// reading it back on this socket.
	fmt.Println()
	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		fmt.Printf("SetReadDeadline -> %v\n", err)
		return
	}
	buf := make([]byte, 1500)
	for {
		n, cm, src, err := pc.ReadFrom(buf)
		if err != nil {
			fmt.Printf("3 秒内未收到自己的组播包: %v\n", err)
			return
		}
		fmt.Printf("收到来自 %s 的 %d 字节: %q (ifindex=%d)\n", src, n, string(buf[:n]), cm.IfIndex)
	}
}
