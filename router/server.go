package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// FrontServer is the OpenAI-compatible endpoint clients point their tools at.
// It routes each request either to the local upstream or to an online friend.
type FrontServer struct {
	store    *Store
	upstream *Upstream
	guest    *GuestManager
	subUsage *SubscriptionMonitor

	cacheMu sync.Mutex
	cacheAt time.Time
	cacheID map[string]bool
	cacheM  []modelObject
}

func newFrontServer(store *Store, upstream *Upstream, guest *GuestManager, subUsage *SubscriptionMonitor) *FrontServer {
	return &FrontServer{store: store, upstream: upstream, guest: guest, subUsage: subUsage}
}

func (s *FrontServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	mux.HandleFunc("GET /v1/models", s.handleModels)
	mux.HandleFunc("POST /v1/chat/completions", s.handleCompletion)
	mux.HandleFunc("POST /v1/completions", s.handleCompletion)
	mux.HandleFunc("POST /v1/embeddings", s.handleCompletion)
	// Anthropic Messages API — what Claude Code speaks. Same routing: the body
	// carries a top-level `model`, so local-vs-friend routing works unchanged.
	mux.HandleFunc("POST /v1/messages", s.handleCompletion)
	// Anything else is forwarded to the local upstream unchanged.
	mux.HandleFunc("/", s.handlePassthrough)
	return loopbackGuard(mux)
}

// localModels returns the upstream model objects and an id set, cached briefly.
func (s *FrontServer) localModels() ([]modelObject, map[string]bool) {
	s.cacheMu.Lock()
	if time.Since(s.cacheAt) < 12*time.Second && s.cacheID != nil {
		m, id := s.cacheM, s.cacheID
		s.cacheMu.Unlock()
		return m, id
	}
	s.cacheMu.Unlock()

	models, err := s.upstream.ListModels()
	idset := map[string]bool{}
	for _, m := range models {
		idset[m.ID] = true
	}
	if err == nil {
		s.cacheMu.Lock()
		s.cacheM, s.cacheID, s.cacheAt = models, idset, time.Now()
		s.cacheMu.Unlock()
	}
	return models, idset
}

func (s *FrontServer) handleModels(w http.ResponseWriter, r *http.Request) {
	if connID := r.Header.Get("X-VibeShare-Connection-ID"); connID != "" {
		st := s.guest.Status(connID)
		data := make([]modelObject, 0, len(st.Models))
		if st.Online && !st.Revoked {
			for _, id := range st.Models {
				data = append(data, modelObject{ID: id, Object: "model", OwnedBy: "friend:" + st.HostName})
			}
		}
		writeJSON(w, http.StatusOK, modelList{Object: "list", Data: data})
		return
	}
	local, localIDs := s.localModels()
	data := make([]modelObject, 0, len(local))
	for _, m := range local {
		if m.Object == "" {
			m.Object = "model"
		}
		if m.OwnedBy == "" {
			m.OwnedBy = "local"
		}
		data = append(data, m)
	}
	for _, rm := range s.guest.RemoteModels() {
		if localIDs[rm.ID] {
			continue // local wins on collision
		}
		owner := rm.Owner
		if owner == "" {
			owner = "friend"
		}
		data = append(data, modelObject{ID: rm.ID, Object: "model", OwnedBy: "friend:" + owner})
	}
	writeJSON(w, http.StatusOK, modelList{Object: "list", Data: data})
}

func (s *FrontServer) handleCompletion(w http.ResponseWriter, r *http.Request) {
	body, err := readLimitedBody(r.Body, maxRequestBodyBytes)
	if err != nil {
		if errors.Is(err, errRequestBodyTooLarge) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errBody("request body too large"))
			return
		}
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	var probe struct {
		Model string `json:"model"`
	}
	_ = json.Unmarshal(body, &probe)
	if connID := r.Header.Get("X-VibeShare-Connection-ID"); connID != "" {
		_ = s.guest.RouteConnection(r.Context(), connID, probe.Model, r.Method, r.URL.Path, r.Header, body, w)
		return
	}

	_, localIDs := s.localModels()
	if preferRemote(s.store.Config(), s.guest.CanRoute(probe.Model)) {
		log.Printf("front: preferring friend for %s", probe.Model)
		_ = s.guest.RouteRequest(r.Context(), probe.Model, r.Method, r.URL.Path, r.Header, body, w)
		return
	}

	// 1. Local model -> forward to upstream.
	if localIDs[probe.Model] {
		if provider, exhausted := s.localSessionExhausted(probe.Model); exhausted &&
			s.guest.CanRouteWithBudget(probe.Model) {
			log.Printf("front: local %s session exhausted for %s; routing to friend", provider, probe.Model)
			_ = s.guest.RouteRequest(r.Context(), probe.Model, r.Method, r.URL.Path, r.Header, body, w)
			return
		}
		// The local engine advertises the model, but the credential behind it can
		// be dead (expired OAuth) or too old for it (Anthropic gates new models on
		// the caller's claude-cli version). Both answer before a single byte of
		// content, so a friend who shares the model can still serve the request.
		if s.guest.CanRoute(probe.Model) {
			if reason, retry := s.forwardLocalRetryable(w, r, body); retry {
				log.Printf("front: local %s for %s; routing to friend", reason, probe.Model)
				_ = s.guest.RouteRequest(r.Context(), probe.Model, r.Method, r.URL.Path, r.Header, body, w)
			}
			return
		}
		s.forwardLocal(w, r, body)
		return
	}
	// 2. A friend shares it -> route over WebRTC.
	if s.guest.CanRoute(probe.Model) {
		if err := s.guest.RouteRequest(r.Context(), probe.Model, r.Method, r.URL.Path, r.Header, body, w); err != nil {
			// RouteRequest writes the response itself unless it failed before headers.
			return
		}
		return
	}
	// 3. Unknown locally but upstream is up -> let upstream decide (model list may be partial).
	if s.upstream.Reachable() {
		s.forwardLocal(w, r, body)
		return
	}
	online, sharing := s.guest.OnlineFriends()
	msg := "model '" + probe.Model + "' is not available locally and no online friend shares it"
	if online > 0 && sharing == 0 {
		msg = "model '" + probe.Model + "': " + strconv.Itoa(online) +
			" friend(s) online but sharing 0 models — their provider engine (cli-proxy-api) may be off or have no provider connected"
	} else if online > 0 {
		msg = "model '" + probe.Model + "' is not shared by any online friend (it may not be in what they shared)"
	}
	writeJSON(w, http.StatusNotFound, map[string]any{
		"error": map[string]any{"message": msg, "type": "model_not_found"},
	})
}

func preferRemote(cfg Config, friendSharesModel bool) bool {
	return cfg.PreferBorrowedModels && friendSharesModel
}

func (s *FrontServer) handlePassthrough(w http.ResponseWriter, r *http.Request) {
	var body []byte
	if r.Body != nil {
		var err error
		body, err = readLimitedBody(r.Body, maxRequestBodyBytes)
		if err != nil {
			if errors.Is(err, errRequestBodyTooLarge) {
				writeJSON(w, http.StatusRequestEntityTooLarge, errBody("request body too large"))
				return
			}
			http.Error(w, "read error", http.StatusBadRequest)
			return
		}
	}
	s.forwardLocal(w, r, body)
}

func (s *FrontServer) localSessionExhausted(model string) (provider string, exhausted bool) {
	if s.subUsage == nil {
		return "", false
	}
	key := monitoredProviderForModel(model)
	if key == "" {
		return "", false
	}
	util, known := s.subUsage.SessionUtilization(key)
	return providerDisplayName(key), known && util >= 100
}

// forwardLocal streams a request through to the local cli-proxy-api.
func (s *FrontServer) forwardLocal(w http.ResponseWriter, r *http.Request, body []byte) {
	_, _ = s.forwardLocalMaybeRetry(w, r, body, false)
}

// forwardLocalRetryable forwards to the local engine but, instead of relaying an
// unusable-credential error, reports it so the caller can try a friend. retry is
// true only when nothing was written to w, so the caller is free to re-route.
func (s *FrontServer) forwardLocalRetryable(w http.ResponseWriter, r *http.Request, body []byte) (reason string, retry bool) {
	return s.forwardLocalMaybeRetry(w, r, body, true)
}

func (s *FrontServer) forwardLocalMaybeRetry(w http.ResponseWriter, r *http.Request, body []byte, mayRetry bool) (string, bool) {
	resp, err := s.upstream.doWithHeaders(r.Context(), r.Method, r.URL.RequestURI(), body, r.Header)
	if err != nil {
		if mayRetry {
			return "engine unreachable (" + err.Error() + ")", true
		}
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error": map[string]any{
				"message": "upstream (cli-proxy-api) unreachable: " + err.Error(),
				"type":    "upstream_unreachable",
			},
		})
		return "", false
	}
	defer resp.Body.Close()

	if mayRetry {
		// Only a small error body is worth buffering; anything larger is a real
		// response and must stream untouched.
		if reason, ok := unusableLocalCredential(resp); ok {
			return reason, true
		}
	}

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)

	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 16*1024)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := w.Write(buf[:n]); err != nil {
				return "", false
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if readErr != nil {
			return "", false
		}
	}
}

// maxErrorBodyBytes bounds how much of a failed local response we buffer while
// deciding whether a friend should get the request instead.
const maxErrorBodyBytes = 64 * 1024

// unusableLocalCredential reports whether a local response means "this engine
// cannot serve this model right now" rather than "your request was wrong".
// 401/403 (dead or unauthorised credential), a 503 whose body says
// auth_unavailable (no usable local sign-in), and Anthropic's
// claude_code_version_too_old gate qualify: all three are properties of the
// local install, not of the request, so an identical request can succeed at a
// friend. A plain 400, a 429, or any other 5xx (real quota or provider trouble)
// must NOT fail over — retrying elsewhere would either repeat a client error or
// spend a friend's quota on our own overload.
//
// The response body is consumed on a match; callers must not stream it after.
func unusableLocalCredential(resp *http.Response) (string, bool) {
	switch resp.StatusCode {
	case http.StatusUnauthorized, http.StatusForbidden:
		return "credential rejected (HTTP " + strconv.Itoa(resp.StatusCode) + ")", true
	case http.StatusBadRequest, http.StatusServiceUnavailable:
		peek, err := io.ReadAll(io.LimitReader(resp.Body, maxErrorBodyBytes))
		if err != nil {
			return "", false
		}
		// Restore the body so a non-matching response still streams to the client.
		resp.Body = io.NopCloser(io.MultiReader(bytes.NewReader(peek), resp.Body))
		if resp.StatusCode == http.StatusBadRequest && bytes.Contains(peek, []byte("claude_code_version_too_old")) {
			return "engine is too old for this model (claude_code_version_too_old)", true
		}
		if resp.StatusCode == http.StatusServiceUnavailable && bytes.Contains(peek, []byte("auth_unavailable")) {
			return "local credential unavailable (auth_unavailable)", true
		}
		return "", false
	}
	return "", false
}

// errBody builds an error envelope clients understand (OpenAI/Anthropic shape).
func errBody(msg string) map[string]any {
	return map[string]any{"error": map[string]any{"message": msg, "type": "vibeshare_error"}}
}

var errRequestBodyTooLarge = errors.New("request body too large")

func readLimitedBody(r io.Reader, limit int) ([]byte, error) {
	if r == nil {
		return nil, nil
	}
	body, err := io.ReadAll(io.LimitReader(r, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(body) > limit {
		return nil, errRequestBodyTooLarge
	}
	return body, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func loopbackGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// The Swift UI (URLSession) and CLI tools never send an Origin header;
		// only browsers do. Rejecting it kills cross-site reads/writes + preflight.
		if r.Header.Get("Origin") != "" {
			http.Error(w, "cross-origin requests are not allowed", http.StatusForbidden)
			return
		}
		// Require a loopback Host to defeat DNS-rebinding.
		if !isLoopbackHost(r.Host) {
			http.Error(w, "request Host is not loopback", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isLoopbackHost(host string) bool {
	if host == "" {
		return true // HTTP/1.0 client without a Host header — local tooling only
	}
	hostname := host
	if h, _, err := net.SplitHostPort(host); err == nil {
		hostname = h
	}
	hostname = strings.TrimSuffix(strings.TrimPrefix(hostname, "["), "]")
	if strings.EqualFold(hostname, "localhost") {
		return true
	}
	if ip := net.ParseIP(hostname); ip != nil {
		return ip.IsLoopback()
	}
	return false
}

// startHTTP starts an HTTP server on 127.0.0.1:port and returns it.
func startHTTP(ctx context.Context, port int, handler http.Handler) *http.Server {
	srv := &http.Server{
		Addr:    "127.0.0.1:" + strconv.Itoa(port),
		Handler: handler,
		// Slowloris resistance. No Read/WriteTimeout — they'd break SSE streaming.
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutCtx)
	}()
	return srv
}
