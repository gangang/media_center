// Command server runs the local media center backend.
//
// It indexes media folders into a local SQLite file and serves them over HTTP
// on the LAN. Nothing ever leaves the network: there is no cloud component and
// no telemetry.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"mediacenter/internal/api"
	"mediacenter/internal/config"
	"mediacenter/internal/discovery"
	"mediacenter/internal/meta"
	"mediacenter/internal/scanner"
	"mediacenter/internal/store"
)

func main() {
	dataDir := flag.String("data", "", "data directory (default ~/.mediacenter)")
	host := flag.String("host", "", "listen address (default 0.0.0.0)")
	port := flag.Int("port", 0, "listen port (default 8080)")
	scan := flag.Bool("scan", false, "run a full index pass on startup, then keep serving")
	mdns := flag.Bool("mdns", true, "advertise this server on the LAN over mDNS")
	flag.Parse()

	cfg, err := config.Load(*dataDir, *host, *port)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	st, err := store.Open(cfg.DBPath())
	if err != nil {
		log.Fatalf("index: %v", err)
	}
	defer st.Close()

	sc := scanner.New(cfg, st)
	srv := api.NewServer(cfg, st, sc)

	httpSrv := &http.Server{
		Addr:              cfg.Addr(),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// No write timeout: a client may legitimately hold a connection open
		// for the length of a feature film.
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	// Bind before printing anything. If the port is taken, that is the first
	// thing the user should hear about — not a cheerful banner followed by a
	// crash once they have already copied the URL onto their phone.
	ln, err := net.Listen("tcp", cfg.Addr())
	if err != nil {
		log.Fatalf("listen %s: %v", cfg.Addr(), err)
	}
	defer ln.Close()

	printBanner(cfg)

	// Advertise only after the socket is bound: anything that discovers this
	// server must be able to connect to it on the spot.
	//
	// Discovery is best-effort by design. A failure here is logged and
	// ignored, because a server the user can still reach by typing an address
	// beats a server that refuses to start because the network misbehaved.
	var adv *discovery.Advertiser
	if *mdns {
		a, err := discovery.Start(cfg, api.Version, api.APIVersion)
		if err != nil {
			log.Printf("  mDNS     : 未启动（%v）", err)
		} else {
			adv = a
		}
	}
	// Shutdown is nil-safe, so this is correct whether or not we advertised.
	defer adv.Shutdown()

	if *scan {
		if err := sc.Start(0); err != nil {
			log.Printf("initial scan not started: %v", err)
		}
	}

	// Shut down cleanly on Ctrl-C so SQLite checkpoints its WAL.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		if err := httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		log.Fatalf("server: %v", err)
	case <-ctx.Done():
		log.Println("shutting down…")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

// printBanner tells the user exactly how to reach the server, including the
// token they will need to paste into the client.
func printBanner(cfg *config.Config) {
	log.Printf("%s v%s", cfg.ServerName, api.Version)
	log.Printf("  数据目录 : %s", cfg.DataDir)
	log.Printf("  本机访问 : http://localhost:%d/?token=%s", cfg.Port, cfg.Token)
	// Same address set the mDNS advertisement publishes, so the URL printed
	// here is always one a discovered client could have used too.
	for _, ip := range discovery.LANIPv4() {
		log.Printf("  局域网   : http://%s:%d/?token=%s", ip, cfg.Port, cfg.Token)
	}
	log.Printf("  访问令牌 : %s", cfg.Token)
	if !meta.HasTool(cfg.FFmpeg) {
		log.Printf("  提示     : 未检测到 ffmpeg，视频缩略图与元数据将不可用")
	}
}
