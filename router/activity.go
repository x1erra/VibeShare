package main

import (
	"sync"
	"time"
)

// ActivityEntry is one routed request as shown in the UI's activity feed —
// the trust surface for "who used what, when" on both sides of a share.
type ActivityEntry struct {
	ID           int64  `json:"id"`
	TS           int64  `json:"ts"`        // unix seconds, request start
	Direction    string `json:"direction"` // "hosted" (a friend used my account) | "borrowed" (I used a friend's)
	Peer         string `json:"peer"`      // friend label (hosted) or host name (borrowed)
	Model        string `json:"model"`
	Status       string `json:"status"` // "ok" | "error"
	Error        string `json:"error,omitempty"`
	InputTokens  int64  `json:"inputTokens"`
	OutputTokens int64  `json:"outputTokens"`
	DurationMs   int64  `json:"durationMs"`
}

// ActivityLog is an in-memory ring of recent routed requests. Deliberately not
// persisted: it is a live feed, not an audit log (usage.json holds the totals).
type ActivityLog struct {
	mu      sync.Mutex
	entries []ActivityEntry // newest last; trimmed to cap
	nextID  int64
	notify  func() // pokes SSE clients so the feed updates live
}

const activityCap = 200

func newActivityLog(notify func()) *ActivityLog {
	return &ActivityLog{notify: notify}
}

// Add records one finished (or refused) request and wakes SSE clients.
func (a *ActivityLog) Add(e ActivityEntry) {
	a.mu.Lock()
	a.nextID++
	e.ID = a.nextID
	if e.TS == 0 {
		e.TS = time.Now().Unix()
	}
	a.entries = append(a.entries, e)
	if len(a.entries) > activityCap {
		a.entries = a.entries[len(a.entries)-activityCap:]
	}
	a.mu.Unlock()
	if a.notify != nil {
		a.notify()
	}
}

// List returns up to limit entries, newest first.
func (a *ActivityLog) List(limit int) []ActivityEntry {
	a.mu.Lock()
	defer a.mu.Unlock()
	if limit <= 0 || limit > len(a.entries) {
		limit = len(a.entries)
	}
	out := make([]ActivityEntry, 0, limit)
	for i := len(a.entries) - 1; i >= len(a.entries)-limit; i-- {
		out = append(out, a.entries[i])
	}
	return out
}
