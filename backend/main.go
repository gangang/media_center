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
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
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
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()

	// Printed before anything else touches the disk, so this works on a machine
	// where the data directory cannot be created — which is exactly the
	// situation where someone is asking "which build is this?".
	if *showVersion {
		fmt.Printf("mediacenter %s (api %d)\n", api.Version, api.APIVersion)
		return
	}

	cfg, err := config.Load(*dataDir, *host, *port)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	st, err := store.Open(cfg.DBPath())
	if err != nil {
		log.Fatalf("index: %v", err)
	}
	defer st.Close()

	// The managed library is where the phone backup API writes. Registering it
	// as a scan folder is what makes an upload reach the gallery through the
	// same indexing path as any other file — and what makes a photo deleted
	// from the library get pruned like any other.
	if _, err := st.AddFolder(cfg.LibraryDir()); err != nil {
		log.Printf("library folder: %v", err)
	}

	// A client that crashed mid-transfer left a partially written file behind.
	// Nothing in the UI would show it, so it would simply consume space forever.
	if n, err := sweepStaleUploads(cfg, st); err != nil {
		log.Printf("upload sweep: %v", err)
	} else if n > 0 {
		log.Printf("  清理     : 移除 %d 个未完成的上传会话", n)
	}

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
		// "address already in use" is the overwhelmingly common failure here, and
		// the one case where the raw error leaves the user stuck: it names the
		// symptom but not the fix. Spell out both the workaround and the command
		// that finds the culprit, because INSTALL.md is written for people who
		// will not reach for lsof or netstat on their own.
		//
		// We deliberately do NOT fall back to another port. The user has already
		// been given a specific URL (and the phone may already have it saved), so
		// a server quietly listening somewhere else is indistinguishable from a
		// server that is simply broken.
		if errors.Is(err, syscall.EADDRINUSE) {
			log.Fatalf("端口 %d 已被占用，无法启动。\n"+
				"  换个端口启动： mediacenter -port 8081\n"+
				"  查看谁在占用： macOS/Linux  lsof -nP -iTCP:%d -sTCP:LISTEN\n"+
				"                 Windows      netstat -ano | findstr :%d\n"+
				"  原始错误：%v", cfg.Port, cfg.Port, cfg.Port, err)
		}
		log.Fatalf("监听 %s 失败：%v", cfg.Addr(), err)
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

// sweepStaleUploads removes upload sessions left behind by a client that
// crashed or went away, together with their partially written files.
//
// Only paths inside the upload temp directory are ever unlinked. The paths come
// out of our own database, but this is a delete loop, and a delete loop that
// trusts its input is how a bug becomes data loss.
func sweepStaleUploads(cfg *config.Config, st *store.Store) (int, error) {
	cutoff := time.Now().UTC().Add(-api.UploadSessionTTL).Format(time.RFC3339)
	paths, err := st.DeleteStaleUploads(cutoff)
	if err != nil {
		return 0, err
	}

	tempDir := cfg.UploadTempDir() + string(os.PathSeparator)
	for _, p := range paths {
		if !strings.HasPrefix(p, tempDir) {
			log.Printf("upload sweep: 跳过可疑路径 %s", p)
			continue
		}
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			log.Printf("upload sweep: 无法删除 %s: %v", p, err)
		}
	}
	return len(paths), nil
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
