// Command vibeshare-router is the engine behind the VibeShare menu-bar app.
//
// It exposes a local OpenAI-compatible endpoint, forwards local-model requests
// to the bundled cli-proxy-api, and shares/borrows models with friends over
// WebRTC (signaled through public Nostr relays — no central server). The Swift
// UI drives it entirely through the loopback control API.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	storeDir := flag.String("store", defaultStoreDir(), "state directory (~/.vibeshare)")
	frontPort := flag.Int("front-port", 0, "override front OpenAI endpoint port")
	controlPort := flag.Int("control-port", 0, "override control API port")
	upstreamURL := flag.String("upstream", "", "override cli-proxy-api base URL")
	name := flag.String("name", "", "override identity name shown to friends")
	relays := flag.String("nostr-relays", "", "comma-separated Nostr relay URLs")
	parentPID := flag.Int("parent-pid", 0, "exit when this parent process disappears (orphan guard)")
	flag.Parse()

	store, err := openStore(*storeDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}

	cfg := store.Config()
	if *frontPort != 0 {
		cfg.FrontPort = *frontPort
	}
	if *controlPort != 0 {
		cfg.ControlPort = *controlPort
	}
	if *upstreamURL != "" {
		cfg.UpstreamURL = *upstreamURL
	}
	if *name != "" {
		cfg.IdentityName = *name
	}
	if *relays != "" {
		var list []string
		for _, p := range strings.Split(*relays, ",") {
			if p = strings.TrimSpace(p); p != "" {
				list = append(list, p)
			}
		}
		if len(list) > 0 {
			cfg.NostrRelays = list
		}
	}
	_ = store.SetConfig(cfg)
	cfg = store.Config()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Orphan guard: if the launching app vanishes (force-quit/crash) without a
	// clean shutdown, don't keep running headless.
	if *parentPID > 0 {
		go func() {
			t := time.NewTicker(2 * time.Second)
			defer t.Stop()
			for range t.C {
				if syscall.Kill(*parentPID, 0) != nil {
					log.Println("parent process gone; shutting down")
					os.Exit(0)
				}
			}
		}()
	}

	bus := newEventBus()
	upstream := newUpstream(store.Config)
	activity := newActivityLog(bus.Notify)
	// Polls the host's own provider subscription limits (5-hour + weekly) by
	// reusing the OAuth tokens cli-proxy-api keeps in its default auth dir.
	subUsage := newSubscriptionMonitor("~/.cli-proxy-api")

	nostr := newNostrClient(cfg.NostrRelays)
	nostr.Start(ctx)

	hostMgr := newHostManager(ctx, store, nostr, upstream, bus.Notify, activity)
	guestMgr := newGuestManager(ctx, store, nostr, bus.Notify, activity)
	hostMgr.Reconcile()
	guestMgr.Reconcile()

	front := newFrontServer(store, upstream, guestMgr)
	control := &ControlServer{
		store:    store,
		host:     hostMgr,
		guest:    guestMgr,
		upstream: upstream,
		nostr:    nostr,
		bus:      bus,
		activity: activity,
		subUsage: subUsage,
	}

	frontSrv := startHTTP(ctx, cfg.FrontPort, front.handler())
	controlSrv := startHTTP(ctx, cfg.ControlPort, control.handler())

	go serve("front", frontSrv)
	go serve("control", controlSrv)

	log.Printf("VibeShare router online")
	log.Printf("  OpenAI endpoint : http://127.0.0.1:%d/v1", cfg.FrontPort)
	log.Printf("  control API     : http://127.0.0.1:%d/api", cfg.ControlPort)
	log.Printf("  upstream        : %s", cfg.UpstreamURL)
	log.Printf("  identity        : %q", cfg.IdentityName)

	// Periodic reconcile keeps presence/online state fresh in the UI.
	go func() {
		t := time.NewTicker(15 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				hostMgr.Reconcile()
				guestMgr.Reconcile()
				bus.Notify()
			}
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("shutting down...")
	cancel()
	time.Sleep(300 * time.Millisecond)
}

func serve(name string, srv *http.Server) {
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("%s server: %v", name, err)
	}
}
