package main

import "testing"

func TestHostAvailableWhenHeartbeatExpiresButChannelIsLive(t *testing.T) {
	const now int64 = 1_700_000_000
	if !hostAvailable(now-61, true, now) {
		t.Fatal("an authenticated live channel must remain routable after a missed heartbeat")
	}
	if hostAvailable(now-61, false, now) {
		t.Fatal("a stale heartbeat without a live channel must not be routable")
	}
	if !hostAvailable(now-59, false, now) {
		t.Fatal("a fresh heartbeat must remain routable before the channel is opened")
	}
}
