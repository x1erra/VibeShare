package main

import (
	"context"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// signalKind is the Nostr event kind VibeShare (and SeedShell) use for
// signaling + presence. Ephemeral-ish; relays forward but need not store.
const signalKind = 25050

// NostrClient maintains connections to a set of relays and lets callers
// subscribe/publish to "rooms" (the #d tag). It reconnects dropped relays and
// re-subscribes active rooms automatically.
type NostrClient struct {
	urls []string
	sk   string
	pk   string

	mu     sync.Mutex
	relays map[string]*nostr.Relay        // url -> connected relay
	rooms  map[string]func(*nostr.Event)  // roomID -> handler
	subs   map[string]*nostr.Subscription // "url|room" -> active subscription, nil while connecting
	seen   map[string]bool                // event id dedupe
	ctx    context.Context
}

func newNostrClient(urls []string) *NostrClient {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	return &NostrClient{
		urls:   urls,
		sk:     sk,
		pk:     pk,
		relays: map[string]*nostr.Relay{},
		rooms:  map[string]func(*nostr.Event){},
		subs:   map[string]*nostr.Subscription{},
		seen:   map[string]bool{},
	}
}

func (n *NostrClient) Start(ctx context.Context) {
	n.ctx = ctx
	go n.maintain()
}

// ConnectedRelays returns the URLs currently connected (for status reporting).
func (n *NostrClient) ConnectedRelays() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	var out []string
	for url := range n.relays {
		out = append(out, url)
	}
	return out
}

// AddRoom registers (or replaces) a handler for a room and subscribes on all
// currently-connected relays.
func (n *NostrClient) AddRoom(roomID string, handler func(*nostr.Event)) {
	n.mu.Lock()
	n.rooms[roomID] = handler
	relays := make(map[string]*nostr.Relay, len(n.relays))
	for url, r := range n.relays {
		relays[url] = r
	}
	n.mu.Unlock()

	for url, r := range relays {
		n.ensureSub(url, r, roomID, handler)
	}
}

// RemoveRoom stops handling a room and closes any live relay subscriptions.
func (n *NostrClient) RemoveRoom(roomID string) {
	var toClose []*nostr.Subscription
	n.mu.Lock()
	delete(n.rooms, roomID)
	for k, sub := range n.subs {
		if strings.HasSuffix(k, "|"+roomID) {
			delete(n.subs, k)
			if sub != nil {
				toClose = append(toClose, sub)
			}
		}
	}
	n.mu.Unlock()
	for _, sub := range toClose {
		sub.Unsub()
	}
}

// Publish seals nothing — callers pass already-encrypted content. It signs and
// sends to every connected relay.
func (n *NostrClient) Publish(roomID, tType, content string) {
	ev := nostr.Event{
		PubKey:    n.pk,
		CreatedAt: nostr.Now(),
		Kind:      signalKind,
		Tags:      nostr.Tags{{"d", roomID}, {"t", tType}},
		Content:   content,
	}
	if err := ev.Sign(n.sk); err != nil {
		log.Printf("nostr: sign failed: %v", err)
		return
	}

	n.mu.Lock()
	relays := make([]*nostr.Relay, 0, len(n.relays))
	for _, r := range n.relays {
		relays = append(relays, r)
	}
	n.mu.Unlock()

	for _, r := range relays {
		go func(r *nostr.Relay) {
			ctx, cancel := context.WithTimeout(n.ctx, 8*time.Second)
			defer cancel()
			if err := r.Publish(ctx, ev); err != nil {
				log.Printf("nostr: publish t=%s to %s FAILED: %v", tType, r.URL, err)
			}
		}(r)
	}
}

func (n *NostrClient) maintain() {
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	n.reconnectAll()
	for {
		select {
		case <-n.ctx.Done():
			return
		case <-t.C:
			n.reconnectAll()
		}
	}
}

func (n *NostrClient) reconnectAll() {
	for _, url := range n.urls {
		n.mu.Lock()
		_, connected := n.relays[url]
		n.mu.Unlock()
		if connected {
			continue
		}

		ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
		relay, err := nostr.RelayConnect(ctx, url)
		cancel()
		if err != nil {
			continue
		}

		n.mu.Lock()
		n.relays[url] = relay
		rooms := make(map[string]func(*nostr.Event), len(n.rooms))
		for id, h := range n.rooms {
			rooms[id] = h
		}
		n.mu.Unlock()

		log.Printf("nostr: connected %s", url)
		for roomID, handler := range rooms {
			n.ensureSub(url, relay, roomID, handler)
		}
	}
}

func (n *NostrClient) ensureSub(url string, relay *nostr.Relay, roomID string, handler func(*nostr.Event)) {
	key := subKey(url, roomID)
	n.mu.Lock()
	if _, ok := n.subs[key]; ok {
		n.mu.Unlock()
		return
	}
	n.subs[key] = nil
	n.mu.Unlock()

	since := nostr.Timestamp(time.Now().Add(-30 * time.Second).Unix())
	filters := nostr.Filters{{
		Kinds: []int{signalKind},
		Tags:  nostr.TagMap{"d": []string{roomID}},
		Since: &since,
	}}

	sub, err := relay.Subscribe(n.ctx, filters)
	if err != nil {
		n.mu.Lock()
		delete(n.subs, key)
		n.mu.Unlock()
		return
	}

	n.mu.Lock()
	if _, ok := n.subs[key]; !ok {
		n.mu.Unlock()
		sub.Unsub()
		return
	}
	n.subs[key] = sub
	n.mu.Unlock()

	go func() {
		defer func() {
			n.mu.Lock()
			if n.subs[key] == sub {
				// Relay/subscription died unexpectedly — drop it so maintain()
				// reconnects and re-subscribes active rooms.
				delete(n.subs, key)
				delete(n.relays, url)
			}
			n.mu.Unlock()
		}()
		for {
			select {
			case <-n.ctx.Done():
				return
			case ev, ok := <-sub.Events:
				if !ok {
					return
				}
				if ev.PubKey == n.pk {
					continue // ignore our own events
				}
				if n.markSeen(ev.ID) {
					continue
				}
				// Re-read the current handler (room may have been replaced).
				n.mu.Lock()
				h := n.rooms[roomID]
				n.mu.Unlock()
				if h != nil {
					h(ev)
				}
			}
		}
	}()
}

func subKey(url, roomID string) string {
	return url + "|" + roomID
}

func (n *NostrClient) markSeen(id string) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.seen[id] {
		return true
	}
	if len(n.seen) > 20000 {
		n.seen = map[string]bool{}
	}
	n.seen[id] = true
	return false
}
