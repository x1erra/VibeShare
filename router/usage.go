package main

import (
	"bytes"
	"encoding/json"
	"strings"
)

// usageTracker scans an OpenAI- or Anthropic-style response — streaming SSE or a
// single JSON body — and extracts input/output token counts, best-effort. It is
// fed the raw response bytes as they stream past.
type usageTracker struct {
	sse  bool
	line bytes.Buffer // partial SSE line accumulator
	body bytes.Buffer // full body accumulator (non-SSE)
	in   int64
	out  int64
}

func newUsageTracker(contentType string) *usageTracker {
	return &usageTracker{sse: strings.Contains(strings.ToLower(contentType), "event-stream")}
}

// Write feeds response bytes through the scanner.
func (u *usageTracker) Write(p []byte) {
	if !u.sse {
		if u.body.Len() < 8<<20 { // cap memory on huge non-stream bodies
			u.body.Write(p)
		}
		return
	}
	for _, b := range p {
		if b == '\n' {
			u.scanLine(u.line.Bytes())
			u.line.Reset()
		} else {
			u.line.WriteByte(b)
		}
	}
}

// Finish flushes any buffered data and returns the totals.
func (u *usageTracker) Finish() (inTokens, outTokens int64) {
	if u.sse {
		if u.line.Len() > 0 {
			u.scanLine(u.line.Bytes())
		}
	} else {
		u.extract(u.body.Bytes())
	}
	return u.in, u.out
}

func (u *usageTracker) scanLine(line []byte) {
	line = bytes.TrimSpace(line)
	if bytes.HasPrefix(line, []byte("data:")) {
		line = bytes.TrimSpace(line[5:])
	}
	if len(line) == 0 || line[0] != '{' {
		return
	}
	u.extract(line)
}

type usageProbe struct {
	Usage struct {
		InputTokens      int64 `json:"input_tokens"`      // Anthropic
		OutputTokens     int64 `json:"output_tokens"`     // Anthropic
		PromptTokens     int64 `json:"prompt_tokens"`     // OpenAI
		CompletionTokens int64 `json:"completion_tokens"` // OpenAI
	} `json:"usage"`
	Message struct { // Anthropic message_start nests usage under "message"
		Usage struct {
			InputTokens  int64 `json:"input_tokens"`
			OutputTokens int64 `json:"output_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

// extract takes the max of every token figure seen. Anthropic streams emit a
// running (cumulative) output_tokens in message_delta, so max == final total;
// non-stream responses carry a single final usage object.
func (u *usageTracker) extract(b []byte) {
	var p usageProbe
	if json.Unmarshal(b, &p) != nil {
		return
	}
	for _, v := range []int64{p.Usage.InputTokens, p.Usage.PromptTokens, p.Message.Usage.InputTokens} {
		if v > u.in {
			u.in = v
		}
	}
	for _, v := range []int64{p.Usage.OutputTokens, p.Usage.CompletionTokens, p.Message.Usage.OutputTokens} {
		if v > u.out {
			u.out = v
		}
	}
}
