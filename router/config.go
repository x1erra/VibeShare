package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// errGrantNotFound lets callers map a missing grant to an HTTP 404 instead of a
// silent success.
var errGrantNotFound = errors.New("grant not found")

// defaultNostrRelays are public Nostr relays used purely for signaling and
// encrypted presence. They never see plaintext.
var defaultNostrRelays = []string{
	"wss://relay.damus.io",
	"wss://nos.lol",
	"wss://relay.nostr.band",
}

// Config is the router's persisted configuration (~/.vibeshare/config.json).
type Config struct {
	FrontPort      int      `json:"frontPort"`      // OpenAI-compatible endpoint clients point at
	ControlPort    int      `json:"controlPort"`    // local control API for the Swift UI
	UpstreamURL    string   `json:"upstreamUrl"`    // cli-proxy-api base URL
	UpstreamAPIKey string   `json:"upstreamApiKey"` // optional bearer key for cli-proxy-api
	NostrRelays    []string `json:"nostrRelays"`    // signaling relays
	IdentityName   string   `json:"identityName"`   // human label others see ("Brandon's Mac")
	EnableSharing  bool     `json:"enableSharing"`  // master switch for the P2P layer
}

func defaultConfig() Config {
	host, _ := os.Hostname()
	if host == "" {
		host = "My Mac"
	}
	return Config{
		FrontPort:     8788,
		ControlPort:   8799,
		UpstreamURL:   "http://127.0.0.1:8317",
		NostrRelays:   append([]string(nil), defaultNostrRelays...),
		IdentityName:  host,
		EnableSharing: true,
	}
}

// Grant is a share I issued (host role). The secret code is stored so the room
// can be re-derived across restarts.
type Grant struct {
	ID         string   `json:"id"`
	Label      string   `json:"label"`      // friend name, e.g. "Steve"
	Code       string   `json:"code"`       // canonical (compact) grant code — secret
	Providers  []string `json:"providers"`  // provider keys exposed (e.g. ["claude"])
	Models     []string `json:"models"`     // optional explicit model allow-list; empty = derive from providers
	TokenLimit int64    `json:"tokenLimit"` // 0 = unlimited; max total (input+output) tokens this friend may use
	CreatedAt  int64    `json:"createdAt"`
	Revoked    bool     `json:"revoked"`
	Paused     bool     `json:"paused"` // temporarily stop serving without killing the code
}

// Connection is a share I hold (guest role).
type Connection struct {
	ID         string `json:"id"`
	Label      string `json:"label"` // host/friend label
	Code       string `json:"code"`  // redeemed grant code — secret
	RedeemedAt int64  `json:"redeemedAt"`
}

// Usage is the persisted lifetime usage for one grant (host side) or connection
// (guest side), keyed by that id in usage.json.
type Usage struct {
	Requests     int64 `json:"requests"`
	InputTokens  int64 `json:"inputTokens"`
	OutputTokens int64 `json:"outputTokens"`
	LastUsed     int64 `json:"lastUsed"`
}

// Store owns all persisted state and guards it with a mutex.
type Store struct {
	mu          sync.RWMutex
	dir         string
	config      Config
	grants      []Grant
	connections []Connection
	usage       map[string]Usage
}

func defaultStoreDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".vibeshare"
	}
	return filepath.Join(home, ".vibeshare")
}

func openStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, config: defaultConfig(), usage: map[string]Usage{}}
	loadJSON(filepath.Join(dir, "config.json"), &s.config)
	loadJSON(filepath.Join(dir, "grants.json"), &s.grants)
	loadJSON(filepath.Join(dir, "connections.json"), &s.connections)
	loadJSON(filepath.Join(dir, "usage.json"), &s.usage)
	// Backfill any newly-added config fields that were absent on disk.
	if s.config.FrontPort == 0 {
		s.config.FrontPort = 8788
	}
	if s.config.ControlPort == 0 {
		s.config.ControlPort = 8799
	}
	if s.config.UpstreamURL == "" {
		s.config.UpstreamURL = "http://127.0.0.1:8317"
	}
	if len(s.config.NostrRelays) == 0 {
		s.config.NostrRelays = append([]string(nil), defaultNostrRelays...)
	}
	return s, nil
}

func loadJSON(path string, out any) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	_ = json.Unmarshal(data, out)
}

func saveJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *Store) Config() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.config
}

func (s *Store) SetConfig(c Config) error {
	s.mu.Lock()
	s.config = c
	s.mu.Unlock()
	return saveJSON(filepath.Join(s.dir, "config.json"), c)
}

func (s *Store) Grants() []Grant {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]Grant(nil), s.grants...)
}

func (s *Store) ActiveGrants() []Grant {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []Grant
	for _, g := range s.grants {
		if !g.Revoked {
			out = append(out, g)
		}
	}
	return out
}

func (s *Store) AddGrant(g Grant) error {
	s.mu.Lock()
	s.grants = append(s.grants, g)
	grants := append([]Grant(nil), s.grants...)
	s.mu.Unlock()
	return saveJSON(filepath.Join(s.dir, "grants.json"), grants)
}

func (s *Store) RevokeGrant(id string) error {
	s.mu.Lock()
	for i := range s.grants {
		if s.grants[i].ID == id {
			s.grants[i].Revoked = true
		}
	}
	grants := append([]Grant(nil), s.grants...)
	s.mu.Unlock()
	return saveJSON(filepath.Join(s.dir, "grants.json"), grants)
}

// GrantLimit returns the token allotment for a grant (0 = unlimited). Read live
// from the store so a top-up takes effect immediately, without restarting the
// grant's host worker.
func (s *Store) GrantLimit(id string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, g := range s.grants {
		if g.ID == id {
			return g.TokenLimit
		}
	}
	return 0
}

// GrantPaused reports whether a grant is paused. Read live from the store so
// pause/resume takes effect on the next request without restarting the worker.
func (s *Store) GrantPaused(id string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, g := range s.grants {
		if g.ID == id {
			return g.Paused
		}
	}
	return false
}

// SetGrantPaused pauses or resumes a grant (host keeps the code alive but stops
// serving requests while paused) and persists it.
func (s *Store) SetGrantPaused(id string, paused bool) error {
	s.mu.Lock()
	found := false
	for i := range s.grants {
		if s.grants[i].ID == id {
			s.grants[i].Paused = paused
			found = true
		}
	}
	grants := append([]Grant(nil), s.grants...)
	s.mu.Unlock()
	if !found {
		return errGrantNotFound
	}
	return saveJSON(filepath.Join(s.dir, "grants.json"), grants)
}

// SetGrantLimit updates a grant's token allotment (host can raise/lower or
// top-up after the code was issued) and persists it.
func (s *Store) SetGrantLimit(id string, limit int64) error {
	if limit < 0 {
		limit = 0
	}
	s.mu.Lock()
	found := false
	for i := range s.grants {
		if s.grants[i].ID == id {
			s.grants[i].TokenLimit = limit
			found = true
		}
	}
	grants := append([]Grant(nil), s.grants...)
	s.mu.Unlock()
	if !found {
		return errGrantNotFound
	}
	return saveJSON(filepath.Join(s.dir, "grants.json"), grants)
}

func (s *Store) Connections() []Connection {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]Connection(nil), s.connections...)
}

func (s *Store) AddConnection(c Connection) error {
	s.mu.Lock()
	s.connections = append(s.connections, c)
	conns := append([]Connection(nil), s.connections...)
	s.mu.Unlock()
	return saveJSON(filepath.Join(s.dir, "connections.json"), conns)
}

func (s *Store) RemoveConnection(id string) error {
	s.mu.Lock()
	out := s.connections[:0]
	for _, c := range s.connections {
		if c.ID != id {
			out = append(out, c)
		}
	}
	s.connections = out
	conns := append([]Connection(nil), s.connections...)
	s.mu.Unlock()
	return saveJSON(filepath.Join(s.dir, "connections.json"), conns)
}

// Usage returns the persisted lifetime usage for an id (grant or connection).
func (s *Store) Usage(id string) Usage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.usage[id]
}

// AddUsage accumulates one completed request's counters and persists them.
// Request rate is human-paced, so writing the small usage.json each time is fine.
func (s *Store) AddUsage(id string, reqs, inTok, outTok int64) {
	s.mu.Lock()
	if s.usage == nil {
		s.usage = map[string]Usage{}
	}
	u := s.usage[id]
	u.Requests += reqs
	u.InputTokens += inTok
	u.OutputTokens += outTok
	u.LastUsed = time.Now().Unix()
	s.usage[id] = u
	snapshot := make(map[string]Usage, len(s.usage))
	for k, v := range s.usage {
		snapshot[k] = v
	}
	s.mu.Unlock()
	_ = saveJSON(filepath.Join(s.dir, "usage.json"), snapshot)
}
