package main

import (
	"strings"
	"time"
)

// throttleWindow is how long a relay that rate-limited us only gets a sample of
// presence heartbeats. Several rooms heartbeat every 20s, which is more than
// strict per-IP limits (damus: ~8 notes/min) allow, so without this a relay
// keeps rate-limiting and then bans us.
const throttleWindow = 30 * time.Minute

// relayCandidate is one connected relay considered for a publish.
type relayCandidate struct {
	URL       string
	FailUntil time.Time
	Soft      bool      // cooldown came only from slow acks, not a refusal
	Throttled time.Time // relay rate-limited us recently; sample presence until then
}

// applyPublishFailure records a refused publish. A non-zero duration means this
// relay should be skipped until then. Ordinary single timeouts only count
// toward a cooldown so one slow relay does not silence the room.
func applyPublishFailure(h relayHealth, reason string, now time.Time) (relayHealth, time.Duration) {
	switch {
	case strings.Contains(reason, "banned"), strings.Contains(reason, "403"):
		h.deadlines = 0
		h.soft = false
		h.failUntil = now.Add(15 * time.Minute)
		h.throttledUntil = now.Add(15*time.Minute + throttleWindow)
		return h, 15 * time.Minute
	case strings.Contains(reason, "rate-limited") || strings.Contains(reason, "rate limited"):
		h.deadlines = 0
		h.soft = false
		h.failUntil = now.Add(2 * time.Minute)
		h.throttledUntil = now.Add(2*time.Minute + throttleWindow)
		return h, 2 * time.Minute
	case strings.Contains(reason, "deadline"):
		h.deadlines++
		if h.deadlines >= 3 {
			h.deadlines = 0
			// A missed ack is not a refusal: slow relays (nos.lol) still deliver
			// and ack late. Keep a hard refusal's cooldown if one is running.
			if !h.failUntil.After(now) {
				h.soft = true
				h.failUntil = now.Add(45 * time.Second)
			}
			return h, 45 * time.Second
		}
	}
	return h, 0
}

// pickRelayURLs returns relays that are allowed to accept a publish now.
// Sending to a banned relay during its cooldown only extends the ban and can
// keep this host unreachable. If all relays are cooling down, wait for one.
//
// Signals (offers/ICE) still go to relays cooling down only for slow acks: the
// peer may listen on nothing else, and a dropped offer is a failed reconnect.
// Presence to a recently rate-limiting relay is sampled via keep, so the room
// heartbeats stay under its per-IP limit instead of escalating to a ban.
func pickRelayURLs(now time.Time, items []relayCandidate, signal bool, keep func() bool) []string {
	healthy := make([]string, 0, len(items))
	for _, it := range items {
		if it.URL == "" {
			continue
		}
		if it.FailUntil.After(now) && !(signal && it.Soft) {
			continue
		}
		if !signal && it.Throttled.After(now) && keep != nil && !keep() {
			continue
		}
		healthy = append(healthy, it.URL)
	}
	if len(healthy) == 0 {
		return nil
	}
	return healthy
}
