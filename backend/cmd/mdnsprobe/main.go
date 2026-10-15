// Command mdnsprobe browses the LAN for media center servers over mDNS.
//
// It exists because "discovery" is a feature that either works on the user's
// actual network or is worthless, and the failure mode is silent: the server
// logs a cheerful line either way. This tool answers the only question that
// matters - can a standard mDNS browser see this server from here?
//
//	go run ./cmd/mdnsprobe
//	go run ./cmd/mdnsprobe -timeout 15s -service _mediacenter._tcp
//
// A correctly running server should show up within a second or two. If nothing
// appears, compare the addresses printed by the server banner with the ones a
// client would need; a mismatch is the usual cause.
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/grandcat/zeroconf"
)

func main() {
	timeout := flag.Duration("timeout", 8*time.Second, "how long to browse before giving up")
	service := flag.String("service", "_mediacenter._tcp", "service type to browse for")
	flag.Parse()

	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建解析器失败: %v\n", err)
		os.Exit(1)
	}

	entries := make(chan *zeroconf.ServiceEntry, 16)
	found := 0

	done := make(chan struct{})
	go func() {
		defer close(done)
		for e := range entries {
			found++
			fmt.Printf("发现 #%d\n", found)
			fmt.Printf("  实例     : %s\n", e.Instance)
			fmt.Printf("  主机名   : %s\n", e.HostName)
			fmt.Printf("  地址     : %s:%d\n", joinAddrs(e.AddrIPv4), e.Port)
			if len(e.Text) > 0 {
				fmt.Printf("  TXT      : %v\n", e.Text)
			}
			fmt.Println()
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	fmt.Printf("正在浏览 %s.local（%s）…\n\n", *service, *timeout)

	if err := resolver.Browse(ctx, *service, "local.", entries); err != nil {
		fmt.Fprintf(os.Stderr, "浏览失败: %v\n", err)
		os.Exit(1)
	}

	<-ctx.Done()
	// Browse closes the channel when the context expires; wait for the
	// printing goroutine to drain so no entry is lost to a race with exit.
	<-done

	if found == 0 {
		fmt.Println("没有发现任何服务。")
		fmt.Println("请确认：服务器已启动且日志中 mDNS 一行不是「未启动」；")
		fmt.Println("客户端与服务器处于同一网段；本机防火墙未拦截 UDP 5353。")
		os.Exit(1)
	}
	fmt.Printf("共发现 %d 个服务。\n", found)
}

func joinAddrs(addrs []net.IP) string {
	if len(addrs) == 0 {
		return "(无)"
	}
	out := addrs[0].String()
	for _, a := range addrs[1:] {
		out += ", " + a.String()
	}
	return out
}
