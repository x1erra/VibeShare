package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPinnedConnectionNeverUsesLocalOrOtherFriend(t *testing.T) {
	engine := localEngine(t, http.StatusOK, `{"content":"personal account"}`)
	f := frontWith(t, engine)
	f.guest.conns = map[string]*guestConn{
		"friend": {conn: Connection{ID: "friend"}, hostModels: []string{"claude-fable-5-1"}, lastSeen: time.Now().Unix()},
	}
	req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8788/v1/messages",
		strings.NewReader(`{"model":"claude-fable-5-1"}`))
	req.Header.Set("X-VibeShare-Connection-ID", "dad")
	rec := httptest.NewRecorder()
	f.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable || strings.Contains(rec.Body.String(), "personal account") {
		t.Fatalf("pinned request escaped to another account: %d %s", rec.Code, rec.Body.String())
	}
}

func TestPinnedModelListIsConnectionSpecific(t *testing.T) {
	f := frontWith(t, localEngine(t, http.StatusOK, `{}`))
	f.guest.conns = map[string]*guestConn{
		"dad": {conn: Connection{ID: "dad"}, hostName: "Dad", hostModels: []string{"gpt-6-sol"}, lastSeen: time.Now().Unix()},
	}
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8788/v1/models", nil)
	req.Header.Set("X-VibeShare-Connection-ID", "dad")
	rec := httptest.NewRecorder()
	f.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "gpt-6-sol") || strings.Contains(rec.Body.String(), "claude-fable") {
		t.Fatalf("wrong pinned model list: %d %s", rec.Code, rec.Body.String())
	}
}
