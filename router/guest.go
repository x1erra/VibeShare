package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/pion/webrtc/v3"
)

// GuestManager runs the guest side of every held connection.
type GuestManager struct {
	store  *Store
	nostr  *NostrClient
	ctx    context.Context
	notify func()

	mu    sync.Mutex
	conns map[string]*guestConn
}

type guestConn struct {
	conn   Connection
	keys   grantKeys
	peerID string
	cancel context.CancelFunc

	mu         sync.Mutex
	hostName   string
	hostModels []string
	lastSeen   int64
	active     int
	session    *guestSession
}

type guestSession struct {
	id       string
	pc       *webrtc.PeerConnection
	dc       *webrtc.DataChannel
	keys     grantKeys
	authOK   chan struct{}
	authErr  string
	authOnce sync.Once
	closed   chan struct{}
	closeMu  sync.Once

	mu      sync.Mutex
	pending map[string]*pendingReq
}

// pendingReq plumbs a single in-flight request's response frames from the pion
// callback goroutine to the RouteRequest goroutine. `done` lets deliver() stop
// blocking the moment the request ends, so frames are never dropped (which would
// corrupt a stream) and never sent on an abandoned channel.
type pendingReq struct {
	ch   chan respEvent
	done chan struct{}
}

type respEvent struct {
	kind   string // head | data | end | err
	status int
	ctype  string
	data   []byte
	msg    string
}

func newGuestManager(ctx context.Context, store *Store, nostr *NostrClient, notify func()) *GuestManager {
	return &GuestManager{
		store:  store,
		nostr:  nostr,
		ctx:    ctx,
		notify: notify,
		conns:  map[string]*guestConn{},
	}
}

func (g *GuestManager) Reconcile() {
	want := map[string]Connection{}
	for _, c := range g.store.Connections() {
		want[c.ID] = c
	}

	g.mu.Lock()
	defer g.mu.Unlock()

	for id, c := range want {
		if _, ok := g.conns[id]; !ok {
			g.startConn(c)
		}
	}
	for id, gc := range g.conns {
		if _, ok := want[id]; !ok {
			gc.cancel()
			g.nostr.RemoveRoom(gc.keys.roomID)
			delete(g.conns, id)
		}
	}
}

// caller holds g.mu
func (g *GuestManager) startConn(c Connection) {
	keys, err := deriveGrantKeys(c.Code)
	if err != nil {
		log.Printf("guest: bad connection %s: %v", c.ID, err)
		return
	}
	ctx, cancel := context.WithCancel(g.ctx)
	gc := &guestConn{
		conn:   c,
		keys:   keys,
		peerID: randomID(6),
		cancel: cancel,
	}
	g.conns[c.ID] = gc
	g.nostr.AddRoom(keys.roomID, func(ev *nostr.Event) { g.onEvent(gc, ev) })
	go g.presenceLoop(ctx, gc)
	log.Printf("guest: connected to %q (room %s)", c.Label, keys.roomID[:8])
}

func (g *GuestManager) presenceLoop(ctx context.Context, gc *guestConn) {
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	g.sendPresence(gc)
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			g.sendPresence(gc)
		}
	}
}

func (g *GuestManager) sendPresence(gc *guestConn) {
	if !g.store.Config().EnableSharing {
		return
	}
	gc.mu.Lock()
	routing := gc.active > 0
	gc.mu.Unlock()
	content, err := sealJSON(gc.keys.announceKey, presenceContent{
		Role:    "guest",
		Peer:    gc.peerID,
		Routing: routing,
		TS:      time.Now().Unix(),
	})
	if err != nil {
		return
	}
	g.nostr.Publish(gc.keys.roomID, "presence", content)
}

func (g *GuestManager) onEvent(gc *guestConn, ev *nostr.Event) {
	switch tagValue(ev, "t") {
	case "presence":
		var pc presenceContent
		if !openJSON(gc.keys.announceKey, ev.Content, &pc) || pc.Role != "host" {
			return
		}
		if !freshTimestamp(pc.TS, authWindow) {
			return // stale/replayed presence
		}
		gc.mu.Lock()
		gc.hostName = pc.Name
		gc.hostModels = pc.Models
		gc.lastSeen = time.Now().Unix()
		gc.mu.Unlock()
		g.notify()
	case "signal":
		var sc signalContent
		if !openJSON(gc.keys.announceKey, ev.Content, &sc) {
			return
		}
		gc.mu.Lock()
		s := gc.session
		gc.mu.Unlock()
		if s == nil || s.id != sc.Session {
			return
		}
		switch sc.Kind {
		case "answer":
			log.Printf("guest[%s]: answer received", s.id)
			var answer webrtc.SessionDescription
			if json.Unmarshal(sc.Payload, &answer) == nil {
				_ = s.pc.SetRemoteDescription(answer)
			}
		case "ice":
			var cand webrtc.ICECandidateInit
			if json.Unmarshal(sc.Payload, &cand) == nil {
				_ = s.pc.AddICECandidate(cand)
			}
		}
	}
}

// RemoteModel is an advertised model from an online host.
type RemoteModel struct {
	ID    string
	Owner string
}

// RemoteModels lists models reachable through currently-online hosts.
func (g *GuestManager) RemoteModels() []RemoteModel {
	g.mu.Lock()
	defer g.mu.Unlock()
	var out []RemoteModel
	seen := map[string]bool{}
	for _, gc := range g.conns {
		gc.mu.Lock()
		online := time.Now().Unix()-gc.lastSeen < 60
		name := gc.hostName
		models := append([]string(nil), gc.hostModels...)
		gc.mu.Unlock()
		if !online {
			continue
		}
		for _, m := range models {
			if seen[m] {
				continue
			}
			seen[m] = true
			out = append(out, RemoteModel{ID: m, Owner: name})
		}
	}
	return out
}

func (g *GuestManager) findHostForModel(model string) *guestConn {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, gc := range g.conns {
		gc.mu.Lock()
		online := time.Now().Unix()-gc.lastSeen < 60
		has := false
		for _, m := range gc.hostModels {
			if m == model {
				has = true
				break
			}
		}
		gc.mu.Unlock()
		if online && has {
			return gc
		}
	}
	return nil
}

// CanRoute reports whether some online host advertises the model.
func (g *GuestManager) CanRoute(model string) bool {
	return g.findHostForModel(model) != nil
}

// OnlineFriends reports how many friend connections are online, and how many of
// those are advertising at least one model — used for clearer routing errors.
func (g *GuestManager) OnlineFriends() (online, sharing int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, gc := range g.conns {
		gc.mu.Lock()
		isOnline := time.Now().Unix()-gc.lastSeen < 60
		hasModels := len(gc.hostModels) > 0
		gc.mu.Unlock()
		if isOnline {
			online++
			if hasModels {
				sharing++
			}
		}
	}
	return
}

// RouteRequest proxies an OpenAI request to an online host over WebRTC, streaming
// the response into w. Returns an error if no host can serve it / setup failed.
func (g *GuestManager) RouteRequest(ctx context.Context, model, method, path string, body []byte, w http.ResponseWriter) error {
	gc := g.findHostForModel(model)
	if gc == nil {
		writeJSON(w, http.StatusServiceUnavailable, errBody("no online friend shares model "+model))
		return errors.New("no online friend shares model " + model)
	}

	s, err := g.ensureSession(ctx, gc)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, errBody("could not connect to friend: "+err.Error()))
		return err
	}

	id := randomID(8)
	pr := &pendingReq{ch: make(chan respEvent, 64), done: make(chan struct{})}
	s.mu.Lock()
	s.pending[id] = pr
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.pending, id)
		s.mu.Unlock()
		close(pr.done) // unblock any in-flight deliver()
	}()

	gc.mu.Lock()
	gc.active++
	gc.mu.Unlock()
	g.notify()
	defer func() {
		gc.mu.Lock()
		gc.active--
		gc.mu.Unlock()
		g.notify()
	}()

	if err := g.sendRequest(s, id, method, path, body); err != nil {
		writeJSON(w, http.StatusBadGateway, errBody("failed to send request to friend: "+err.Error()))
		return err
	}

	// Mirror the host's usage tally on the borrower's side (persisted). Only
	// counted once a response actually starts, so failed routes don't inflate it.
	var tracker *usageTracker
	defer func() {
		if tracker != nil {
			in, out := tracker.Finish()
			g.store.AddUsage(gc.conn.ID, 1, in, out)
			g.notify()
		}
	}()

	flusher, _ := w.(http.Flusher)
	wroteHead := false
	// Abort if the host goes silent (covers a wedged peer the client keeps open).
	idle := time.NewTimer(120 * time.Second)
	defer idle.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.closed:
			if !wroteHead {
				writeJSON(w, http.StatusBadGateway, errBody("connection to friend closed before a response"))
			}
			return errors.New("connection closed")
		case <-idle.C:
			if !wroteHead {
				writeJSON(w, http.StatusGatewayTimeout, errBody("friend did not respond in time"))
			}
			return errors.New("idle timeout")
		case ev := <-pr.ch:
			if !idle.Stop() {
				select {
				case <-idle.C:
				default:
				}
			}
			idle.Reset(120 * time.Second)
			switch ev.kind {
			case "head":
				if ev.ctype != "" {
					w.Header().Set("Content-Type", ev.ctype)
				}
				tracker = newUsageTracker(ev.ctype)
				status := ev.status
				if status == 0 {
					status = http.StatusOK
				}
				w.WriteHeader(status)
				wroteHead = true
			case "data":
				if !wroteHead {
					w.WriteHeader(http.StatusOK)
					wroteHead = true
				}
				if tracker != nil {
					tracker.Write(ev.data)
				}
				if _, err := w.Write(ev.data); err != nil {
					return err
				}
				if flusher != nil {
					flusher.Flush()
				}
			case "end":
				return nil
			case "err":
				if !wroteHead {
					http.Error(w, ev.msg, http.StatusBadGateway)
				}
				return errors.New(ev.msg)
			}
		}
	}
}

// sendRequest streams the request to the host as a `req` frame followed by
// base64 body chunks (so arbitrarily large bodies — Claude Code's system prompt
// + tools easily exceed the data channel's per-message limit) and a `reqend`.
func (g *GuestManager) sendRequest(s *guestSession, id, method, path string, body []byte) error {
	if err := sendFrame(s.dc, frame{T: "req", ID: id, Method: method, Path: path}); err != nil {
		return err
	}
	const chunk = 16 * 1024
	for off := 0; off < len(body); off += chunk {
		end := off + chunk
		if end > len(body) {
			end = len(body)
		}
		if err := sendFrame(s.dc, frame{T: "reqdata", ID: id, B64: base64.StdEncoding.EncodeToString(body[off:end])}); err != nil {
			return err
		}
	}
	return sendFrame(s.dc, frame{T: "reqend", ID: id})
}

func (g *GuestManager) ensureSession(ctx context.Context, gc *guestConn) (*guestSession, error) {
	gc.mu.Lock()
	s := gc.session
	if s != nil && !s.isClosed() {
		gc.mu.Unlock()
	} else {
		var err error
		s, err = g.newSession(gc)
		if err != nil {
			gc.mu.Unlock()
			return nil, err
		}
		gc.session = s
		gc.mu.Unlock()
	}

	select {
	case <-s.authOK:
		if s.authErr != "" {
			return nil, errors.New(s.authErr)
		}
		return s, nil
	case <-s.closed:
		return nil, errors.New("connection closed before auth")
	case <-time.After(25 * time.Second):
		return nil, errors.New("timed out connecting to friend")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// caller holds gc.mu
func (g *GuestManager) newSession(gc *guestConn) (*guestSession, error) {
	pc, err := webrtc.NewPeerConnection(webrtcConfig())
	if err != nil {
		return nil, err
	}
	dc, err := pc.CreateDataChannel(dataChannelLabel, nil)
	if err != nil {
		pc.Close()
		return nil, err
	}
	s := &guestSession{
		id:      randomID(8),
		pc:      pc,
		dc:      dc,
		keys:    gc.keys,
		authOK:  make(chan struct{}),
		closed:  make(chan struct{}),
		pending: map[string]*pendingReq{},
	}

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		cand, _ := json.Marshal(c.ToJSON())
		g.sendSignal(gc, s.id, "ice", cand)
	})
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("guest[%s]: ICE state -> %s", s.id, state)
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("guest[%s]: conn state -> %s", s.id, state)
		if state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed ||
			state == webrtc.PeerConnectionStateDisconnected {
			s.close()
		}
	})
	dc.OnOpen(func() {
		log.Printf("guest[%s]: data channel open, sending auth", s.id)
		payload, err := sealJSON(s.keys.channelKey, authPayload{TS: time.Now().Unix()})
		if err == nil {
			_ = sendFrame(dc, frame{T: "auth", Payload: payload})
		}
	})
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		s.onFrame(msg.Data)
	})

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		pc.Close()
		return nil, err
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		pc.Close()
		return nil, err
	}
	offJSON, _ := json.Marshal(offer)
	g.sendSignal(gc, s.id, "offer", offJSON)
	log.Printf("guest[%s]: offer sent to room", s.id)
	return s, nil
}

func (g *GuestManager) sendSignal(gc *guestConn, session, kind string, payload json.RawMessage) {
	content, err := sealJSON(gc.keys.announceKey, signalContent{
		From:    gc.peerID,
		Session: session,
		Kind:    kind,
		Payload: payload,
	})
	if err != nil {
		return
	}
	g.nostr.Publish(gc.keys.roomID, "signal", content)
}

func (s *guestSession) onFrame(data []byte) {
	var f frame
	if err := json.Unmarshal(data, &f); err != nil {
		return
	}
	switch f.T {
	case "auth_ok":
		s.authOnce.Do(func() { close(s.authOK) })
	case "auth_err":
		s.authErr = f.Msg
		s.authOnce.Do(func() { close(s.authOK) })
	case "head":
		s.deliver(f.ID, respEvent{kind: "head", status: f.Status, ctype: f.Ctype})
	case "data":
		raw, _ := base64.StdEncoding.DecodeString(f.B64)
		s.deliver(f.ID, respEvent{kind: "data", data: raw})
	case "end":
		s.deliver(f.ID, respEvent{kind: "end"})
	case "err":
		s.deliver(f.ID, respEvent{kind: "err", msg: f.Msg})
	}
}

func (s *guestSession) deliver(id string, ev respEvent) {
	s.mu.Lock()
	pr, ok := s.pending[id]
	s.mu.Unlock()
	if !ok {
		return
	}
	// Block until the consumer takes it (back-pressure, never drop a stream
	// frame), but bail the instant the request ends or the session closes so we
	// never wedge pion's read loop.
	select {
	case pr.ch <- ev:
	case <-pr.done:
	case <-s.closed:
	}
}

func (s *guestSession) close() {
	s.closeMu.Do(func() {
		close(s.closed)
		if s.pc != nil {
			_ = s.pc.Close()
		}
	})
}

func (s *guestSession) isClosed() bool {
	select {
	case <-s.closed:
		return true
	default:
		return false
	}
}

// ConnStatus is the guest-side runtime view of one connection.
type ConnStatus struct {
	Online       bool     `json:"online"`
	Routing      bool     `json:"routing"`
	HostName     string   `json:"hostName"`
	Models       []string `json:"models"`
	TotalReqs    int      `json:"totalReqs"`
	InputTokens  int64    `json:"inputTokens"`
	OutputTokens int64    `json:"outputTokens"`
}

func (g *GuestManager) Status(connID string) ConnStatus {
	u := g.store.Usage(connID)
	st := ConnStatus{
		TotalReqs:    int(u.Requests),
		InputTokens:  u.InputTokens,
		OutputTokens: u.OutputTokens,
	}

	g.mu.Lock()
	gc, ok := g.conns[connID]
	g.mu.Unlock()
	if !ok {
		return st
	}
	gc.mu.Lock()
	defer gc.mu.Unlock()
	st.Online = time.Now().Unix()-gc.lastSeen < 60
	st.Routing = gc.active > 0
	st.HostName = gc.hostName
	st.Models = append([]string(nil), gc.hostModels...)
	return st
}
