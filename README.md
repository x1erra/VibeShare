# VibeShare

**Share your AI subscriptions with friends — peer-to-peer, no central server.**

VibeShare is a native macOS menu-bar app. Run it and you get a single local
OpenAI-compatible endpoint (`http://127.0.0.1:8788/v1`) that:

1. **Runs a local OpenAI-spec server** your tools can point at.
2. **Connects your LLM providers** (Claude, ChatGPT/Codex, Gemini, Kimi, …) via
   one-click OAuth — powered by the bundled
   [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), exactly like
   [VibeProxy](https://github.com/automazeio/vibeproxy).
3. **Shares usage with friends** by generating a code they paste in. Sharing is
   one-directional: your code lets them use *your* models; you only get theirs
   if they send you a code.
4. **Shows who's online** and actively routing — discovered over public Nostr
   relays, connected directly over WebRTC (P2P), like
   [SeedShell](https://github.com/Deploydon/seedshell).

When a friend requests a model you don't have, VibeShare auto-routes it to an
online friend who shares it, streaming the response back over a direct,
encrypted WebRTC channel. **No VibeShare server exists** — friends connect
straight to each other.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full design.

---

## How it works (30-second version)

```
your tools ──▶ 127.0.0.1:8788/v1  (VibeShare router)
                      │
        ┌─────────────┴──────────────┐
        ▼                            ▼
  local model?               a friend shares it?
  → cli-proxy-api            → WebRTC to their Mac → their cli-proxy-api
    (your subscription)        (their subscription)         │
                                       └──── streamed back ──┘
```

Connection setup (the WebRTC offer/answer) is signaled through public Nostr
relays. Presence ("I'm online, here are my models") is broadcast as **encrypted**
heartbeats only holders of the grant code can read. Once connected, traffic flows
**directly peer-to-peer** over a DTLS-encrypted data channel.

A grant **code** is the only credential. From it both sides derive the same Nostr
room and encryption keys. **Treat codes like passwords.**

## Requirements

- macOS 13 (Ventura) or later
- To build: [Go](https://go.dev) 1.23+ and Swift / Xcode command-line tools

## Build & run

```bash
# 1. Download the provider engine (cli-proxy-api) into Resources
make fetch-provider

# 2a. Quick dev build + run (debug)
make swift
./src/.build/debug/VibeShare      # menu-bar icon appears

# 2b. …or build a distributable, signed VibeShare.app
make app
open VibeShare.app
```

`make install` copies it to `/Applications`. Without a Developer ID it is
ad-hoc signed (fine locally; right-click → Open the first time).

## Using it

1. Click the menu-bar icon → **Providers** → **Connect** your subscriptions
   (opens a browser OAuth flow; credentials are stored locally in
   `~/.cli-proxy-api`).
2. Point any OpenAI-compatible tool at `http://127.0.0.1:8788/v1` (no API key
   needed locally).

### Share with a friend

- **Share** tab → **New** → name it, pick which providers to share → **Create
  code**. Send them the `VS-…` code.
- They open VibeShare → **Borrow** → **Enter code**. Within seconds you appear
  **online** in their list, and your shared models show up in their
  `/v1/models`.

### Borrow from a friend

- **Borrow** tab → **Enter code** with the code they gave you. Their models now
  resolve through your local endpoint automatically.

## Ports & state

| Port  | What                                                        |
|-------|-------------------------------------------------------------|
| 8788  | VibeShare OpenAI endpoint (point your tools here)           |
| 8799  | Router control API (used by the app UI; loopback only)      |
| 8317  | cli-proxy-api provider engine (internal; loopback only)     |

State lives in `~/.vibeshare/` (config + grants + connections + logs). Grant
files contain secret codes — never commit or share them.

## Project layout

```
router/     Go engine: OpenAI front server + P2P routing (pion/webrtc + go-nostr)
src/        Swift menu-bar app (manages the two Go binaries, drives the UI)
scripts/    fetch-cliproxyapi.sh
```

## Status

This is an initial, working version (P2P routing of streaming completions is
verified end-to-end). Rough edges / planned next steps:

- Provider connection currently relies on cli-proxy-api's OAuth flows; the
  "connected" indicator is inferred from the live model list.
- WebRTC uses public STUN only — very restrictive NATs may need a TURN server.
- Grant codes are bearer credentials; revoking a grant stops the host serving
  it, which ends access.
- One shared relay set; relay changes need a router restart.

## Credits

Built on the shoulders of
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI),
[VibeProxy](https://github.com/automazeio/vibeproxy), and
[SeedShell](https://github.com/Deploydon/seedshell).

## License

MIT
