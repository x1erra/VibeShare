package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
	"github.com/pion/webrtc/v3"
)

// authWindow bounds how stale a data-channel auth/presence timestamp may be.
// Kept small to limit replay even though the channel is already DTLS-encrypted.
const authWindow = 90 * time.Second

// allowedProxyPaths are the only upstream paths a guest may reach through a host.
// /v1/models is deliberately excluded: guests learn the shared model list from
// presence, so there is no reason to let them enumerate the host's full catalog.
var allowedProxyPaths = map[string]bool{
	"/v1/chat/completions": true,
	"/v1/completions":      true,
	"/v1/embeddings":       true,
	"/v1/messages":         true, // Anthropic Messages API (Claude Code)
}

// providerModelHints maps a provider key to substrings that identify its models.
// Best-effort: used only when a grant shares by provider rather than explicit ids.
var providerModelHints = map[string][]string{
	"claude":         {"claude"},
	"codex":          {"gpt", "o1", "o3", "o4", "codex"},
	"gemini":         {"gemini"},
	"qwen":           {"qwen"},
	"kimi":           {"kimi", "moonshot"},
	"github-copilot": {"copilot"},
	"antigravity":    {"gemini", "antigravity"},
	"zai":            {"glm"},
}

// HostManager runs the host side of every active grant.
type HostManager struct {
	store    *Store
	nostr    *NostrClient
	upstream *Upstream
	ctx      context.Context
	notify   func() // called when host-visible state changes (for SSE)

	mu     sync.Mutex
	grants map[string]*hostGrant
}

type hostGrant struct {
	grant  Grant
	keys   grantKeys
	cancel context.CancelFunc

	mu            sync.Mutex
	sessions      map[string]*hostSession
	allowedModels []string
	allowAll      bool
	models        []string // advertised list (what guests see)
	lastGuestSeen int64
	activeReqs    int
}

type hostSession struct {
	id string
	pc *webrtc.PeerConnection

	mu     sync.Mutex // guards dc + authed (written/read from pion callback goroutines)
	dc     *webrtc.DataChannel
	authed bool

	// inbound accumulates chunked request bodies keyed by request id. Only
	// touched from pion's single per-channel OnMessage goroutine, so no lock.
	inbound map[string]*inboundReq
}

type inboundReq struct {
	method string
	path   string
	body   []byte
}

func (hs *hostSession) setChannel(dc *webrtc.DataChannel) {
	hs.mu.Lock()
	hs.dc = dc
	hs.mu.Unlock()
}

func (hs *hostSession) channel() *webrtc.DataChannel {
	hs.mu.Lock()
	defer hs.mu.Unlock()
	return hs.dc
}

func (hs *hostSession) markAuthed() {
	hs.mu.Lock()
	hs.authed = true
	hs.mu.Unlock()
}

func (hs *hostSession) isAuthed() bool {
	hs.mu.Lock()
	defer hs.mu.Unlock()
	return hs.authed
}

func newHostManager(ctx context.Context, store *Store, nostr *NostrClient, upstream *Upstream, notify func()) *HostManager {
	return &HostManager{
		store:    store,
		nostr:    nostr,
		upstream: upstream,
		ctx:      ctx,
		notify:   notify,
		grants:   map[string]*hostGrant{},
	}
}

// Reconcile starts workers for newly active grants and stops revoked ones.
func (h *HostManager) Reconcile() {
	active := map[string]Grant{}
	for _, g := range h.store.ActiveGrants() {
		active[g.ID] = g
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	for id, g := range active {
		if _, ok := h.grants[id]; !ok {
			h.startGrant(g)
		}
	}
	for id, hg := range h.grants {
		if _, ok := active[id]; !ok {
			hg.cancel()
			h.nostr.RemoveRoom(hg.keys.roomID)
			delete(h.grants, id)
		}
	}
}

// caller holds h.mu
func (h *HostManager) startGrant(g Grant) {
	keys, err := deriveGrantKeys(g.Code)
	if err != nil {
		log.Printf("host: bad grant %s: %v", g.ID, err)
		return
	}
	ctx, cancel := context.WithCancel(h.ctx)
	hg := &hostGrant{
		grant:    g,
		keys:     keys,
		cancel:   cancel,
		sessions: map[string]*hostSession{},
	}
	h.grants[g.ID] = hg
	// Model recomputation does a blocking HTTP call to the upstream, so it runs
	// inside presenceLoop — never while holding h.mu (which Reconcile/Status need).

	h.nostr.AddRoom(keys.roomID, func(ev *nostr.Event) { h.onEvent(hg, ev) })
	go h.presenceLoop(ctx, hg)
	log.Printf("host: serving grant %q (room %s)", g.Label, keys.roomID[:8])
}

func (h *HostManager) recomputeModels(hg *hostGrant) {
	upstreamModels, _ := h.upstream.ListModels()
	models, allowAll := computeSharedModels(hg.grant, upstreamModels)
	hg.mu.Lock()
	hg.allowAll = allowAll
	hg.models = models
	hg.allowedModels = models
	hg.mu.Unlock()
}

func computeSharedModels(g Grant, upstream []modelObject) (models []string, allowAll bool) {
	available := map[string]bool{}
	var availIDs []string
	for _, m := range upstream {
		available[m.ID] = true
		availIDs = append(availIDs, m.ID)
	}

	// Explicit model list wins.
	if len(g.Models) > 0 {
		if len(available) == 0 {
			return append([]string(nil), g.Models...), false
		}
		var out []string
		for _, m := range g.Models {
			if available[m] {
				out = append(out, m)
			}
		}
		return out, false
	}

	// Provider filter.
	if len(g.Providers) > 0 {
		var out []string
		for _, id := range availIDs {
			if matchesAnyProvider(id, g.Providers) {
				out = append(out, id)
			}
		}
		return out, false
	}

	// Nothing specified: share everything available.
	return availIDs, true
}

func matchesAnyProvider(modelID string, providers []string) bool {
	lid := strings.ToLower(modelID)
	for _, p := range providers {
		for _, hint := range providerModelHints[strings.ToLower(p)] {
			if strings.Contains(lid, hint) {
				return true
			}
		}
	}
	return false
}

func (h *HostManager) presenceLoop(ctx context.Context, hg *hostGrant) {
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	h.recomputeModels(hg)
	h.sendPresence(hg)
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			h.recomputeModels(hg)
			h.sendPresence(hg)
		}
	}
}

func (h *HostManager) sendPresence(hg *hostGrant) {
	if !h.store.Config().EnableSharing {
		return
	}
	hg.mu.Lock()
	models := append([]string(nil), hg.models...)
	hg.mu.Unlock()
	content, err := sealJSON(hg.keys.announceKey, presenceContent{
		Role:   "host",
		Name:   h.store.Config().IdentityName,
		Models: models,
		TS:     time.Now().Unix(),
	})
	if err != nil {
		return
	}
	h.nostr.Publish(hg.keys.roomID, "presence", content)
}

func (h *HostManager) onEvent(hg *hostGrant, ev *nostr.Event) {
	switch tagValue(ev, "t") {
	case "presence":
		var pc presenceContent
		if !openJSON(hg.keys.announceKey, ev.Content, &pc) {
			return
		}
		if pc.Role == "guest" && freshTimestamp(pc.TS, authWindow) {
			hg.mu.Lock()
			hg.lastGuestSeen = time.Now().Unix()
			hg.mu.Unlock()
			h.notify()
		}
	case "signal":
		var sc signalContent
		if !openJSON(hg.keys.announceKey, ev.Content, &sc) {
			return
		}
		switch sc.Kind {
		case "offer":
			h.handleOffer(hg, sc)
		case "ice":
			h.handleICE(hg, sc)
		}
	}
}

func (h *HostManager) handleOffer(hg *hostGrant, sc signalContent) {
	var offer webrtc.SessionDescription
	if err := json.Unmarshal(sc.Payload, &offer); err != nil {
		return
	}
	session := sc.Session
	if session == "" {
		session = sc.From
	}

	hg.mu.Lock()
	if _, exists := hg.sessions[session]; exists {
		hg.mu.Unlock()
		return // duplicate offer (seen via another relay)
	}
	pc, err := webrtc.NewPeerConnection(webrtcConfig())
	if err != nil {
		hg.mu.Unlock()
		return
	}
	hs := &hostSession{id: session, pc: pc, inbound: map[string]*inboundReq{}}
	hg.sessions[session] = hs
	hg.mu.Unlock()

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		cand, _ := json.Marshal(c.ToJSON())
		h.sendSignal(hg, session, "ice", cand)
	})

	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		if s == webrtc.PeerConnectionStateFailed ||
			s == webrtc.PeerConnectionStateClosed ||
			s == webrtc.PeerConnectionStateDisconnected {
			h.closeSession(hg, session)
		}
	})

	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		hs.setChannel(dc)
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			h.onFrame(hg, hs, msg.Data)
		})
		dc.OnClose(func() { h.closeSession(hg, session) })
	})

	if err := pc.SetRemoteDescription(offer); err != nil {
		h.closeSession(hg, session)
		return
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		h.closeSession(hg, session)
		return
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		h.closeSession(hg, session)
		return
	}
	ansJSON, _ := json.Marshal(answer)
	h.sendSignal(hg, session, "answer", ansJSON)
}

func (h *HostManager) handleICE(hg *hostGrant, sc signalContent) {
	hg.mu.Lock()
	hs, ok := hg.sessions[sc.Session]
	hg.mu.Unlock()
	if !ok || hs.pc == nil {
		return
	}
	var cand webrtc.ICECandidateInit
	if err := json.Unmarshal(sc.Payload, &cand); err != nil {
		return
	}
	_ = hs.pc.AddICECandidate(cand)
}

func (h *HostManager) sendSignal(hg *hostGrant, session, kind string, payload json.RawMessage) {
	content, err := sealJSON(hg.keys.announceKey, signalContent{
		Session: session,
		Kind:    kind,
		Payload: payload,
	})
	if err != nil {
		return
	}
	h.nostr.Publish(hg.keys.roomID, "signal", content)
}

func (h *HostManager) closeSession(hg *hostGrant, session string) {
	hg.mu.Lock()
	hs, ok := hg.sessions[session]
	if ok {
		delete(hg.sessions, session)
	}
	hg.mu.Unlock()
	if ok && hs.pc != nil {
		_ = hs.pc.Close()
	}
}

func (h *HostManager) onFrame(hg *hostGrant, hs *hostSession, data []byte) {
	var f frame
	if err := json.Unmarshal(data, &f); err != nil {
		return
	}
	dc := hs.channel()
	if dc == nil {
		return
	}
	switch f.T {
	case "auth":
		var ap authPayload
		if !openJSON(hg.keys.channelKey, f.Payload, &ap) || !freshTimestamp(ap.TS, authWindow) {
			_ = sendFrame(dc, frame{T: "auth_err", Msg: "unauthorized"})
			return
		}
		hs.markAuthed()
		hg.mu.Lock()
		hg.lastGuestSeen = time.Now().Unix()
		hg.mu.Unlock()
		_ = sendFrame(dc, frame{T: "auth_ok"})
		h.notify()
	case "req":
		if !hs.isAuthed() {
			_ = sendFrame(dc, frame{T: "err", ID: f.ID, Msg: "not authenticated"})
			return
		}
		if hs.inbound == nil {
			hs.inbound = map[string]*inboundReq{}
		}
		hs.inbound[f.ID] = &inboundReq{method: f.Method, path: f.Path}
	case "reqdata":
		if ir := hs.inbound[f.ID]; ir != nil {
			chunk, err := base64.StdEncoding.DecodeString(f.B64)
			if err == nil {
				ir.body = append(ir.body, chunk...)
			}
		}
	case "reqend":
		if ir := hs.inbound[f.ID]; ir != nil {
			delete(hs.inbound, f.ID)
			go h.proxyRequest(hg, hs, f.ID, ir.method, ir.path, ir.body)
		}
	}
}

func (h *HostManager) proxyRequest(hg *hostGrant, hs *hostSession, id, method, path string, body []byte) {
	dc := hs.channel()
	if dc == nil {
		return
	}
	if !allowedProxyPaths[path] {
		_ = sendFrame(dc, frame{T: "err", ID: id, Msg: "path not allowed"})
		return
	}

	// Every allowed path is a completion-style POST carrying a model; enforce
	// the grant's allow-list before touching the upstream.
	var probe struct {
		Model string `json:"model"`
	}
	_ = json.Unmarshal(body, &probe)
	if !h.grantAllowsModel(hg, probe.Model) {
		_ = sendFrame(dc, frame{T: "err", ID: id, Msg: "model not shared: " + probe.Model})
		return
	}

	if method == "" {
		method = http.MethodPost
	}

	hg.mu.Lock()
	hg.activeReqs++
	hg.mu.Unlock()
	h.notify()
	defer func() {
		hg.mu.Lock()
		hg.activeReqs--
		hg.mu.Unlock()
		h.notify()
	}()

	ctx, cancel := context.WithCancel(h.ctx)
	defer cancel()

	resp, err := h.upstream.do(ctx, method, path, body)
	if err != nil {
		_ = sendFrame(dc, frame{T: "err", ID: id, Msg: "upstream error: " + err.Error()})
		return
	}
	defer resp.Body.Close()

	// The request reached the provider — count it and tally its tokens (parsed
	// from the response as it streams past), persisted so it survives restarts.
	tracker := newUsageTracker(resp.Header.Get("Content-Type"))
	defer func() {
		in, out := tracker.Finish()
		h.store.AddUsage(hg.grant.ID, 1, in, out)
		h.notify()
	}()

	_ = sendFrame(dc, frame{
		T:      "head",
		ID:     id,
		Status: resp.StatusCode,
		Ctype:  resp.Header.Get("Content-Type"),
	})

	buf := make([]byte, 8*1024)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			tracker.Write(buf[:n])
			_ = sendFrame(dc, frame{
				T:   "data",
				ID:  id,
				B64: base64.StdEncoding.EncodeToString(buf[:n]),
			})
		}
		if readErr != nil {
			if readErr != io.EOF {
				_ = sendFrame(dc, frame{T: "err", ID: id, Msg: readErr.Error()})
				return
			}
			break
		}
	}
	_ = sendFrame(dc, frame{T: "end", ID: id})
}

func (h *HostManager) grantAllowsModel(hg *hostGrant, model string) bool {
	hg.mu.Lock()
	defer hg.mu.Unlock()
	if hg.allowAll {
		return true
	}
	for _, m := range hg.allowedModels {
		if m == model {
			return true
		}
	}
	return false
}

// GrantStatus is the host-side runtime view of one grant, for the control API.
type GrantStatus struct {
	Online       bool     `json:"online"`
	Routing      bool     `json:"routing"`
	Models       []string `json:"models"`
	TotalReqs    int      `json:"totalReqs"`
	InputTokens  int64    `json:"inputTokens"`
	OutputTokens int64    `json:"outputTokens"`
}

func (h *HostManager) Status(grantID string) GrantStatus {
	// Usage is persisted, so it is reported even for a stopped/revoked grant.
	u := h.store.Usage(grantID)
	st := GrantStatus{
		TotalReqs:    int(u.Requests),
		InputTokens:  u.InputTokens,
		OutputTokens: u.OutputTokens,
	}

	h.mu.Lock()
	hg, ok := h.grants[grantID]
	h.mu.Unlock()
	if !ok {
		return st
	}
	hg.mu.Lock()
	defer hg.mu.Unlock()
	online := time.Now().Unix()-hg.lastGuestSeen < 60
	for _, s := range hg.sessions {
		if s.isAuthed() {
			online = true
		}
	}
	st.Online = online
	st.Routing = hg.activeReqs > 0
	st.Models = append([]string(nil), hg.models...)
	return st
}

func tagValue(ev *nostr.Event, name string) string {
	for _, t := range ev.Tags {
		if len(t) >= 2 && t[0] == name {
			return t[1]
		}
	}
	return ""
}
