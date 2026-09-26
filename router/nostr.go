package main

import (
	"context"
	"log"
	"math/rand"
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

	mu      sync.Mutex
	relays  map[string]*nostr.Relay       // url -> connected relay
	dialing map[string]bool               // url -> a connect attempt is already running
	health  map[string]relayHealth        // url -> publish backoff
	rooms   map[string]func(*nostr.Event) // roomID -> handler
	subs    map[string]*relaySubscription // "url|room" -> pending or active subscription
	seen    map[string]bool               // event id dedupe
	ctx     context.Context
}

// relayHealth is a local publish backoff. It never changes what a peer sends
// or how a signal is encoded; it only stops this process from hammering a
// relay that has already refused it.
type relayHealth struct {
	failUntil      time.Time
	soft           bool // failUntil came from slow acks only
	throttledUntil time.Time
	deadlines      int
}

type relaySubscription struct {
	relay *nostr.Relay
	sub   *nostr.Subscription // nil while Subscribe is in flight
}

func newNostrClient(urls []string) *NostrClient {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	return &NostrClient{
		urls:    urls,
		sk:      sk,
		pk:      pk,
		relays:  map[string]*nostr.Relay{},
		dialing: map[string]bool{},
		health:  map[string]relayHealth{},
		rooms:   map[string]func(*nostr.Event){},
		subs:    map[string]*relaySubscription{},
		seen:    map[string]bool{},
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
		go n.ensureSub(url, r, roomID)
	}
}

// RemoveRoom stops handling a room and closes any live relay subscriptions.
func (n *NostrClient) RemoveRoom(roomID string) {
	var toClose []*nostr.Subscription
	n.mu.Lock()
	delete(n.rooms, roomID)
	for k, slot := range n.subs {
		if strings.HasSuffix(k, "|"+roomID) {
			delete(n.subs, k)
			if slot.sub != nil {
				toClose = append(toClose, slot.sub)
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

	for _, r := range n.publishTargets(tType == "signal") {
		go func(r *nostr.Relay) {
			ctx, cancel := context.WithTimeout(n.ctx, 8*time.Second)
			defer cancel()
			if err := r.Publish(ctx, ev); err != nil {
				n.noteFailure(r.URL, err.Error())
				log.Printf("nostr: publish t=%s to %s FAILED: %v", tType, r.URL, err)
				return
			}
			n.noteSuccess(r.URL)
		}(r)
	}
}

// publishTargets skips relays that recently refused us. A relay in cooldown
// cannot carry an offer or presence update and retrying can extend its ban.
func (n *NostrClient) publishTargets(signal bool) []*nostr.Relay {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := time.Now()
	byURL := make(map[string]*nostr.Relay, len(n.relays))
	items := make([]relayCandidate, 0, len(n.relays))
	for url, r := range n.relays {
		if !r.IsConnected() {
			continue
		}
		byURL[url] = r
		h := n.health[url]
		items = append(items, relayCandidate{URL: url, FailUntil: h.failUntil, Soft: h.soft, Throttled: h.throttledUntil})
	}
	var out []*nostr.Relay
	for _, url := range pickRelayURLs(now, items, signal, samplePresence) {
		if r := byURL[url]; r != nil {
			out = append(out, r)
		}
	}
	return out
}

func (n *NostrClient) noteFailure(url, reason string) {
	n.mu.Lock()
	h, wait := applyPublishFailure(n.health[url], reason, time.Now())
	n.health[url] = h
	n.mu.Unlock()
	if wait > 0 {
		log.Printf("nostr: %s cooling down for %s", url, wait)
	}
}

func (n *NostrClient) noteSuccess(url string) {
	n.mu.Lock()
	h := n.health[url]
	h.deadlines = 0
	h.failUntil = time.Time{}
	h.soft = false
	n.health[url] = h
	n.mu.Unlock()
}

// samplePresence keeps about a third of heartbeats for a throttled relay:
// ~9 room heartbeats/min become ~3, and random choice spreads them over rooms.
func samplePresence() bool { return rand.Intn(3) == 0 }

// RelayView is one configured relay as the control API reports it.
type RelayView struct {
	URL           string `json:"url"`
	Connected     bool   `json:"connected"`
	CoolingDown   bool   `json:"coolingDown,omitempty"`
	CooldownUntil int64  `json:"cooldownUntil,omitempty"`
}

// RelayViews reports connection and backoff for the configured relay list.
func (n *NostrClient) RelayViews(configured []string) []RelayView {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := time.Now()
	out := make([]RelayView, 0, len(configured))
	for _, u := range configured {
		r, conn := n.relays[u]
		conn = conn && r.IsConnected()
		h := n.health[u]
		v := RelayView{URL: u, Connected: conn}
		if h.failUntil.After(now) {
			v.CoolingDown = true
			v.CooldownUntil = h.failUntil.Unix()
		}
		out = append(out, v)
	}
	return out
}

func (n *NostrClient) maintain() {
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	n.reconnectAll()
	n.repairSubscriptions()
	for {
		select {
		case <-n.ctx.Done():
			return
		case <-t.C:
			n.reconnectAll()
			n.repairSubscriptions()
		}
	}
}

func (n *NostrClient) reconnectAll() {
	// One stuck handshake must not keep the other relays from connecting.
	for _, url := range n.urls {
		n.mu.Lock()
		relay := n.relays[url]
		busy := n.dialing[url]
		cooling := n.health[url].failUntil.After(time.Now())
		n.mu.Unlock()
		if relay != nil && !relay.IsConnected() {
			n.dropRelay(url, relay)
			relay = nil
		}
		if relay != nil || busy || cooling {
			continue
		}
		go n.connectOne(url)
	}
}

func (n *NostrClient) connectOne(url string) {
	n.mu.Lock()
	if n.dialing[url] {
		n.mu.Unlock()
		return
	}
	if _, ok := n.relays[url]; ok {
		n.mu.Unlock()
		return
	}
	n.dialing[url] = true
	n.mu.Unlock()
	defer func() {
		n.mu.Lock()
		delete(n.dialing, url)
		n.mu.Unlock()
	}()

	ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
	relay, err := nostr.RelayConnect(ctx, url)
	cancel()
	if err != nil {
		log.Printf("nostr: connect %s failed: %v", url, err)
		if strings.Contains(err.Error(), "403") {
			n.noteFailure(url, "403")
		}
		return
	}

	n.mu.Lock()
	if _, exists := n.relays[url]; exists {
		n.mu.Unlock()
		relay.Close()
		return
	}
	n.relays[url] = relay
	rooms := make([]string, 0, len(n.rooms))
	for id := range n.rooms {
		rooms = append(rooms, id)
	}
	n.mu.Unlock()

	log.Printf("nostr: connected %s", url)
	for _, roomID := range rooms {
		go n.ensureSub(url, relay, roomID)
	}
}

// Remove every room subscription tied to a dead socket before reconnecting.
// A late callback from an old socket must not remove its replacement.
func (n *NostrClient) dropRelay(url string, relay *nostr.Relay) {
	var toClose []*nostr.Subscription
	n.mu.Lock()
	if n.relays[url] != relay {
		n.mu.Unlock()
		return
	}
	delete(n.relays, url)
	for key, slot := range n.subs {
		if slot.relay == relay {
			delete(n.subs, key)
			if slot.sub != nil {
				toClose = append(toClose, slot.sub)
			}
		}
	}
	n.mu.Unlock()
	for _, sub := range toClose {
		sub.Unsub()
	}
	_ = relay.Close()
}

func (n *NostrClient) repairSubscriptions() {
	n.mu.Lock()
	for url, relay := range n.relays {
		if !relay.IsConnected() {
			continue
		}
		for roomID := range n.rooms {
			if _, ok := n.subs[subKey(url, roomID)]; !ok {
				go n.ensureSub(url, relay, roomID)
			}
		}
	}
	n.mu.Unlock()
}

func (n *NostrClient) ensureSub(url string, relay *nostr.Relay, roomID string) {
	key := subKey(url, roomID)
	n.mu.Lock()
	if n.relays[url] != relay || n.rooms[roomID] == nil {
		n.mu.Unlock()
		return
	}
	if _, ok := n.subs[key]; ok {
		n.mu.Unlock()
		return
	}
	slot := &relaySubscription{relay: relay}
	n.subs[key] = slot
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
		if n.subs[key] == slot {
			delete(n.subs, key)
		}
		n.mu.Unlock()
		log.Printf("nostr: subscribe %s failed: %v", url, err)
		return
	}

	n.mu.Lock()
	if n.subs[key] != slot || n.relays[url] != relay || n.rooms[roomID] == nil {
		n.mu.Unlock()
		sub.Unsub()
		return
	}
	slot.sub = sub
	n.mu.Unlock()

	go func() {
		defer func() {
			n.mu.Lock()
			if n.subs[key] == slot {
				delete(n.subs, key)
			}
			n.mu.Unlock()
			if !relay.IsConnected() {
				n.dropRelay(url, relay)
			}
		}()
		for {
			select {
			case <-n.ctx.Done():
				return
			case reason := <-sub.ClosedReason:
				log.Printf("nostr: subscription %s closed: %s", url, reason)
				sub.Unsub()
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
