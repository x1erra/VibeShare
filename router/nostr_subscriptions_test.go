package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/nbd-wtf/go-nostr"
)

func TestClosedRoomSubscriptionIsRetried(t *testing.T) {
	reqs := make(chan string, 4)
	var closedOnce atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, _, err := ws.UpgradeHTTP(r, w)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			message, err := wsutil.ReadClientText(conn)
			if err != nil {
				return
			}
			var parts []json.RawMessage
			if json.Unmarshal(message, &parts) != nil || len(parts) < 2 {
				continue
			}
			var kind, id string
			_ = json.Unmarshal(parts[0], &kind)
			_ = json.Unmarshal(parts[1], &id)
			if kind != "REQ" {
				continue
			}
			reqs <- id
			if !closedOnce.Swap(true) {
				_ = wsutil.WriteServerText(conn, []byte(fmt.Sprintf(`["CLOSED",%q,"temporary failure"]`, id)))
			}
		}
	}))
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	relay, err := nostr.RelayConnect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	n := newNostrClient([]string{url})
	n.ctx = ctx
	n.relays[url] = relay
	n.rooms["room"] = func(*nostr.Event) {}
	go n.ensureSub(url, relay, "room")

	select {
	case <-reqs:
	case <-time.After(2 * time.Second):
		t.Fatal("first room subscription was not sent")
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		n.mu.Lock()
		_, pending := n.subs[subKey(url, "room")]
		n.mu.Unlock()
		if !pending {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("closed subscription was not removed for retry")
		}
		time.Sleep(5 * time.Millisecond)
	}
	n.repairSubscriptions()
	select {
	case <-reqs:
	case <-time.After(2 * time.Second):
		t.Fatal("missing room subscription was not retried")
	}
}
