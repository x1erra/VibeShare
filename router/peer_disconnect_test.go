package main

import (
	"testing"
	"time"

	"github.com/pion/webrtc/v3"
)

func TestOldDisconnectTimerCannotCloseRecoveredSession(t *testing.T) {
	var guard disconnectGuard
	closed := make(chan struct{})
	firstExpiry := make(chan time.Time)
	secondExpiry := make(chan time.Time)
	finished := make(chan struct{}, 2)
	closes := 0
	state := webrtc.PeerConnectionStateDisconnected
	check := func(expiry <-chan time.Time, generation uint64) {
		closeIfStillDisconnected(func() webrtc.PeerConnectionState { return state }, closed, expiry, &guard, generation, func() { closes++ })
		finished <- struct{}{}
	}

	first := guard.changed()
	go check(firstExpiry, first)
	guard.changed()           // recovered
	second := guard.changed() // disconnected again before the first grace period ends
	go check(secondExpiry, second)

	firstExpiry <- time.Now()
	<-finished
	if closes != 0 {
		t.Fatal("an old disconnect timer closed a session during a newer drop")
	}
	secondExpiry <- time.Now()
	<-finished
	if closes != 1 {
		t.Fatalf("latest disconnect timer closed %d times, want 1", closes)
	}
}

func TestDisconnectTimerIgnoresRecoveredOrClosedSession(t *testing.T) {
	var guard disconnectGuard
	generation := guard.changed()
	expiry := make(chan time.Time, 1)
	expiry <- time.Now()
	closed := make(chan struct{})
	closes := 0
	closeIfStillDisconnected(func() webrtc.PeerConnectionState {
		return webrtc.PeerConnectionStateConnected
	}, closed, expiry, &guard, generation, func() { closes++ })
	if closes != 0 {
		t.Fatal("a recovered session was closed")
	}
}
