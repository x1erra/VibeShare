package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// EventBus is a tiny fan-out used to push "something changed" to SSE clients.
type EventBus struct {
	mu   sync.Mutex
	subs map[chan struct{}]bool
}

func newEventBus() *EventBus {
	return &EventBus{subs: map[chan struct{}]bool{}}
}

func (e *EventBus) Subscribe() (chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	e.mu.Lock()
	e.subs[ch] = true
	e.mu.Unlock()
	return ch, func() {
		e.mu.Lock()
		delete(e.subs, ch)
		e.mu.Unlock()
	}
}

func (e *EventBus) Notify() {
	e.mu.Lock()
	defer e.mu.Unlock()
	for ch := range e.subs {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// ControlServer exposes the local management API consumed by the Swift app.
type ControlServer struct {
	store    *Store
	host     *HostManager
	guest    *GuestManager
	upstream *Upstream
	nostr    *NostrClient
	bus      *EventBus
}

func (c *ControlServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/status", c.getStatus)
	mux.HandleFunc("GET /api/grants", c.listGrants)
	mux.HandleFunc("POST /api/grants", c.createGrant)
	mux.HandleFunc("DELETE /api/grants/{id}", c.deleteGrant)
	mux.HandleFunc("GET /api/connections", c.listConnections)
	mux.HandleFunc("POST /api/connections", c.createConnection)
	mux.HandleFunc("DELETE /api/connections/{id}", c.deleteConnection)
	mux.HandleFunc("GET /api/config", c.getConfig)
	mux.HandleFunc("PUT /api/config", c.putConfig)
	mux.HandleFunc("GET /api/events", c.events)
	return withCORS(mux)
}

type relayStatus struct {
	URL       string `json:"url"`
	Connected bool   `json:"connected"`
}

func (c *ControlServer) getStatus(w http.ResponseWriter, r *http.Request) {
	cfg := c.store.Config()
	connected := map[string]bool{}
	for _, u := range c.nostr.ConnectedRelays() {
		connected[u] = true
	}
	relays := make([]relayStatus, 0, len(cfg.NostrRelays))
	for _, u := range cfg.NostrRelays {
		relays = append(relays, relayStatus{URL: u, Connected: connected[u]})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"running":        true,
		"frontPort":      cfg.FrontPort,
		"controlPort":    cfg.ControlPort,
		"identityName":   cfg.IdentityName,
		"sharingEnabled": cfg.EnableSharing,
		"upstream": map[string]any{
			"url":       cfg.UpstreamURL,
			"reachable": c.upstream.Reachable(),
		},
		"nostr":       map[string]any{"relays": relays},
		"localModels": c.upstream.ListModelIDs(),
	})
}

type grantView struct {
	ID               string   `json:"id"`
	Label            string   `json:"label"`
	Code             string   `json:"code"`
	Providers        []string `json:"providers"`
	Models           []string `json:"models"`
	CreatedAt        int64    `json:"createdAt"`
	Revoked          bool     `json:"revoked"`
	Online           bool     `json:"online"`
	Routing          bool     `json:"routing"`
	AdvertisedModels []string `json:"advertisedModels"`
	TotalReqs        int      `json:"totalReqs"`
}

func (c *ControlServer) listGrants(w http.ResponseWriter, r *http.Request) {
	out := []grantView{}
	for _, g := range c.store.Grants() {
		st := c.host.Status(g.ID)
		out = append(out, grantView{
			ID:               g.ID,
			Label:            g.Label,
			Code:             formatCode(g.Code),
			Providers:        nonNil(g.Providers),
			Models:           nonNil(g.Models),
			CreatedAt:        g.CreatedAt,
			Revoked:          g.Revoked,
			Online:           st.Online,
			Routing:          st.Routing,
			AdvertisedModels: nonNil(st.Models),
			TotalReqs:        st.TotalReqs,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (c *ControlServer) createGrant(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Label     string   `json:"label"`
		Providers []string `json:"providers"`
		Models    []string `json:"models"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	code, err := newGrantCode()
	if err != nil {
		http.Error(w, "code gen failed", http.StatusInternalServerError)
		return
	}
	label := in.Label
	if label == "" {
		label = "Friend"
	}
	g := Grant{
		ID:        randomID(8),
		Label:     label,
		Code:      code,
		Providers: in.Providers,
		Models:    in.Models,
		CreatedAt: time.Now().Unix(),
	}
	if err := c.store.AddGrant(g); err != nil {
		http.Error(w, "save failed", http.StatusInternalServerError)
		return
	}
	c.host.Reconcile()
	c.bus.Notify()
	writeJSON(w, http.StatusOK, grantView{
		ID:               g.ID,
		Label:            g.Label,
		Code:             formatCode(g.Code),
		Providers:        nonNil(g.Providers),
		Models:           nonNil(g.Models),
		CreatedAt:        g.CreatedAt,
		AdvertisedModels: []string{},
	})
}

func (c *ControlServer) deleteGrant(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := c.store.RevokeGrant(id); err != nil {
		http.Error(w, "save failed", http.StatusInternalServerError)
		return
	}
	c.host.Reconcile()
	c.bus.Notify()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type connectionView struct {
	ID         string   `json:"id"`
	Label      string   `json:"label"`
	RedeemedAt int64    `json:"redeemedAt"`
	Online     bool     `json:"online"`
	Routing    bool     `json:"routing"`
	HostName   string   `json:"hostName"`
	Models     []string `json:"models"`
	TotalReqs  int      `json:"totalReqs"`
}

func (c *ControlServer) listConnections(w http.ResponseWriter, r *http.Request) {
	out := []connectionView{}
	for _, conn := range c.store.Connections() {
		st := c.guest.Status(conn.ID)
		out = append(out, connectionView{
			ID:         conn.ID,
			Label:      conn.Label,
			RedeemedAt: conn.RedeemedAt,
			Online:     st.Online,
			Routing:    st.Routing,
			HostName:   st.HostName,
			Models:     nonNil(st.Models),
			TotalReqs:  st.TotalReqs,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (c *ControlServer) createConnection(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Code  string `json:"code"`
		Label string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	if _, err := deriveGrantKeys(in.Code); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid code"})
		return
	}
	label := in.Label
	if label == "" {
		label = "Friend"
	}
	conn := Connection{
		ID:         randomID(8),
		Label:      label,
		Code:       normalizeCode(in.Code),
		RedeemedAt: time.Now().Unix(),
	}
	if err := c.store.AddConnection(conn); err != nil {
		http.Error(w, "save failed", http.StatusInternalServerError)
		return
	}
	c.guest.Reconcile()
	c.bus.Notify()
	writeJSON(w, http.StatusOK, connectionView{
		ID:         conn.ID,
		Label:      conn.Label,
		RedeemedAt: conn.RedeemedAt,
		Models:     []string{},
	})
}

func (c *ControlServer) deleteConnection(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := c.store.RemoveConnection(id); err != nil {
		http.Error(w, "save failed", http.StatusInternalServerError)
		return
	}
	c.guest.Reconcile()
	c.bus.Notify()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (c *ControlServer) getConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, c.store.Config())
}

func (c *ControlServer) putConfig(w http.ResponseWriter, r *http.Request) {
	cfg := c.store.Config()
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	if err := c.store.SetConfig(cfg); err != nil {
		http.Error(w, "save failed", http.StatusInternalServerError)
		return
	}
	c.bus.Notify()
	writeJSON(w, http.StatusOK, cfg)
}

func (c *ControlServer) events(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "stream unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch, unsub := c.bus.Subscribe()
	defer unsub()

	fmt.Fprintf(w, "data: {\"type\":\"hello\"}\n\n")
	flusher.Flush()

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ch:
			fmt.Fprintf(w, "data: {\"type\":\"changed\"}\n\n")
			flusher.Flush()
		case <-heartbeat.C:
			fmt.Fprintf(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}
