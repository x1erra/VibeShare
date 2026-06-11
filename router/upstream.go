package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

// Upstream is a thin client for the local cli-proxy-api (the provider engine).
type Upstream struct {
	cfg    func() Config
	client *http.Client
}

func newUpstream(cfg func() Config) *Upstream {
	return &Upstream{
		cfg: cfg,
		// No client-level timeout: chat completions stream for a long time and
		// we cancel via context instead. The transport bounds connection use so
		// a flood of proxied requests can't exhaust sockets.
		client: &http.Client{
			Transport: &http.Transport{
				Proxy:               http.ProxyFromEnvironment,
				MaxIdleConns:        64,
				MaxIdleConnsPerHost: 16,
				MaxConnsPerHost:     64,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}
}

func (u *Upstream) base() string {
	return strings.TrimRight(u.cfg().UpstreamURL, "/")
}

// do issues a request to the upstream, attaching the API key if configured.
// The caller owns resp.Body and must close it.
func (u *Upstream) do(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	return u.doWithHeaders(ctx, method, path, body, nil)
}

// doWithHeaders issues a request to the upstream while preserving safe client
// headers. Client credentials are deliberately stripped; the local upstream key,
// if any, is supplied from VibeShare's own config.
func (u *Upstream) doWithHeaders(ctx context.Context, method, path string, body []byte, headers http.Header) (*http.Response, error) {
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.base()+path, r)
	if err != nil {
		return nil, err
	}
	for k, vals := range cloneForwardHeaders(headers) {
		req.Header[k] = vals
	}
	if req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if req.Header.Get("Accept") == "" {
		req.Header.Set("Accept", "*/*")
	}
	if key := u.cfg().UpstreamAPIKey; key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	return u.client.Do(req)
}

func cloneForwardHeaders(src http.Header) http.Header {
	out := http.Header{}
	for k, vals := range src {
		if skipForwardHeader(k) {
			continue
		}
		out[k] = append([]string(nil), vals...)
	}
	return out
}

func skipForwardHeader(name string) bool {
	switch strings.ToLower(name) {
	case "authorization", "x-api-key", "api-key",
		"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
		"te", "trailer", "transfer-encoding", "upgrade",
		"content-length", "host", "accept-encoding":
		return true
	default:
		return false
	}
}

// Reachable reports whether the upstream answers /v1/models quickly.
func (u *Upstream) Reachable() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp, err := u.do(ctx, http.MethodGet, "/v1/models", nil)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode < 500
}

type modelObject struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	OwnedBy string `json:"owned_by,omitempty"`
}

type modelList struct {
	Object string        `json:"object"`
	Data   []modelObject `json:"data"`
}

// ListModels returns the model objects exposed by the upstream.
func (u *Upstream) ListModels() ([]modelObject, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	resp, err := u.do(ctx, http.MethodGet, "/v1/models", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	var list modelList
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, err
	}
	return list.Data, nil
}

// ListModelIDs is a convenience wrapper returning just the ids.
func (u *Upstream) ListModelIDs() []string {
	models, err := u.ListModels()
	if err != nil {
		return nil
	}
	ids := make([]string, 0, len(models))
	for _, m := range models {
		ids = append(ids, m.ID)
	}
	return ids
}
