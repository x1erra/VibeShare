package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// localEngine stands in for cli-proxy-api: it advertises one model and answers
// completions with a canned status/body.
func localEngine(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/models" {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"object":"list","data":[{"id":"claude-fable-5-1"}]}`)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// frontWith builds a FrontServer pointed at engine, with no friends connected.
func frontWith(t *testing.T, engine *httptest.Server) *FrontServer {
	t.Helper()
	store := &Store{config: Config{UpstreamURL: engine.URL}}
	up := newUpstream(func() Config { return store.config })
	return newFrontServer(store, up, &GuestManager{store: store}, nil)
}

func postCompletion(f *FrontServer) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8788/v1/messages",
		strings.NewReader(`{"model":"claude-fable-5-1"}`))
	rec := httptest.NewRecorder()
	f.handler().ServeHTTP(rec, req)
	return rec
}

// A local model whose credential is dead must not be "fixed" by failover when
// there is no friend to fail over to — the real error still reaches the client.
func TestLocalErrorRelayedWithoutFriend(t *testing.T) {
	f := frontWith(t, localEngine(t, http.StatusUnauthorized, `{"error":{"message":"OAuth access token has expired"}}`))
	rec := postCompletion(f)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 relayed", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "expired") {
		t.Fatalf("body = %q, want the upstream error", rec.Body.String())
	}
}

func TestUnusableLocalCredential(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   bool
	}{
		{"expired oauth", http.StatusUnauthorized, `{"error":"expired"}`, true},
		{"forbidden", http.StatusForbidden, `{"error":"nope"}`, true},
		{"version gate", http.StatusBadRequest, `{"error":{"type":"claude_code_version_too_old"}}`, true},
		{"client error", http.StatusBadRequest, `{"error":{"message":"messages: at least one message is required"}}`, false},
		{"rate limited", http.StatusTooManyRequests, `{"error":"slow down"}`, false},
		{"provider outage", http.StatusInternalServerError, `{"error":"boom"}`, false},
		{"auth unavailable", http.StatusServiceUnavailable, `{"error":{"type":"auth_unavailable","message":"no auth available"}}`, true},
		{"other 503", http.StatusServiceUnavailable, `{"error":{"type":"overloaded","message":"busy"}}`, false},
		{"success", http.StatusOK, `{"content":"hi"}`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := &http.Response{
				StatusCode: tc.status,
				Body:       io.NopCloser(strings.NewReader(tc.body)),
			}
			reason, got := unusableLocalCredential(resp)
			if got != tc.want {
				t.Fatalf("retry = %v (%q), want %v", got, reason, tc.want)
			}
			// A non-matching response must still stream its body intact.
			if !got {
				rest, _ := io.ReadAll(resp.Body)
				if string(rest) != tc.body {
					t.Fatalf("body after peek = %q, want %q", rest, tc.body)
				}
			}
		})
	}
}

// A 400 that is not the version gate must reach the client untouched, body and
// all — the peek used to classify it must not consume the response.
func TestClientErrorBodySurvivesPeek(t *testing.T) {
	const msg = `{"error":{"message":"messages: at least one message is required"}}`
	f := frontWith(t, localEngine(t, http.StatusBadRequest, msg))
	rec := postCompletion(f)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if rec.Body.String() != msg {
		t.Fatalf("body = %q, want %q", rec.Body.String(), msg)
	}
}

// Success streams through unchanged on the retryable path too.
func TestSuccessStreamsThrough(t *testing.T) {
	f := frontWith(t, localEngine(t, http.StatusOK, `{"content":"hello"}`))
	rec := postCompletion(f)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "hello") {
		t.Fatalf("status=%d body=%q", rec.Code, rec.Body.String())
	}
}
