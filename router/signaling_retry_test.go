package main

import (
	"encoding/json"
	"testing"
	"time"
)

func TestOfferRetryStopsAfterAnswerAndIsBounded(t *testing.T) {
	ticks := make(chan time.Time, 3)
	answered := make(chan struct{})
	authed := make(chan struct{})
	closed := make(chan struct{})
	ctxDone := make(chan struct{})
	resent := make(chan struct{}, 3)
	done := make(chan struct{})
	go func() {
		retryOfferOnTicks(ctxDone, answered, authed, closed, ticks, 2, func() { resent <- struct{}{} })
		close(done)
	}()
	ticks <- time.Now()
	select {
	case <-resent:
	case <-time.After(time.Second):
		t.Fatal("lost first offer was not retried")
	}
	close(answered)
	ticks <- time.Now()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("offer retries did not stop after an answer")
	}
	if len(resent) != 0 {
		t.Fatal("offer was resent after answer arrived")
	}

	// Without an answer, retry only the configured number of times.
	ticks = make(chan time.Time, 3)
	for i := 0; i < 3; i++ {
		ticks <- time.Now()
	}
	count := 0
	retryOfferOnTicks(ctxDone, make(chan struct{}), authed, closed, ticks, 2, func() { count++ })
	if count != 2 {
		t.Fatalf("sent %d retries, want 2", count)
	}
}

func TestCachedAnswerIsCopiedForDuplicateOffer(t *testing.T) {
	hs := &hostSession{answer: json.RawMessage(`{"type":"answer"}`)}
	copy := hs.cachedAnswer()
	copy[0] = 'X'
	if got := string(hs.cachedAnswer()); got != `{"type":"answer"}` {
		t.Fatalf("cached answer mutated: %s", got)
	}
}
