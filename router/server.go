package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// FrontServer is the OpenAI-compatible endpoint clients point their tools at.
// It routes each request either to the local upstream or to an online friend.
type FrontServer struct {
	store    *Store
	upstream *Upstream
	guest    *GuestManager

	cacheMu sync.Mutex
	cacheAt time.Time
	cacheID map[string]bool
	cacheM  []modelObject
}

func newFrontServer(store *Store, upstream *Upstream, guest *GuestManager) *FrontServer {
	return &FrontServer{store: store, upstream: upstream, guest: guest}
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
	return withCORS(mux)
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
	body, err := io.ReadAll(io.LimitReader(r.Body, 32<<20))
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	var probe struct {
		Model string `json:"model"`
	}
	_ = json.Unmarshal(body, &probe)

	_, localIDs := s.localModels()

	// 1. Local model -> forward to upstream.
	if localIDs[probe.Model] {
		s.forwardLocal(w, r, body)
		return
	}
	// 2. A friend shares it -> route over WebRTC.
	if s.guest.CanRoute(probe.Model) {
		if err := s.guest.RouteRequest(r.Context(), probe.Model, r.Method, r.URL.Path, body, w); err != nil {
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
	writeJSON(w, http.StatusNotFound, map[string]any{
		"error": map[string]any{
			"message": "model '" + probe.Model + "' is not available locally and no online friend shares it",
			"type":    "model_not_found",
		},
	})
}

func (s *FrontServer) handlePassthrough(w http.ResponseWriter, r *http.Request) {
	var body []byte
	if r.Body != nil {
		body, _ = io.ReadAll(io.LimitReader(r.Body, 32<<20))
	}
	s.forwardLocal(w, r, body)
}

// forwardLocal streams a request through to the local cli-proxy-api.
func (s *FrontServer) forwardLocal(w http.ResponseWriter, r *http.Request, body []byte) {
	resp, err := s.upstream.do(r.Context(), r.Method, r.URL.Path, body)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error": map[string]any{
				"message": "upstream (cli-proxy-api) unreachable: " + err.Error(),
				"type":    "upstream_unreachable",
			},
		})
		return
	}
	defer resp.Body.Close()

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
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if readErr != nil {
			return
		}
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// startHTTP starts an HTTP server on 127.0.0.1:port and returns it.
func startHTTP(ctx context.Context, port int, handler http.Handler) *http.Server {
	srv := &http.Server{
		Addr:    "127.0.0.1:" + strconv.Itoa(port),
		Handler: handler,
	}
	go func() {
		<-ctx.Done()
		shutCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutCtx)
	}()
	return srv
}
