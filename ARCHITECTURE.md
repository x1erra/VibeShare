# VibeShare — Architecture

VibeShare is a native macOS menu-bar app that lets you **share your LLM
subscriptions with friends, peer-to-peer, with no central server.** It is the
spiritual sibling of [VibeProxy](https://github.com/automazeio/vibeproxy)
(one local OpenAI-compatible endpoint in front of all your AI subscriptions),
plus a sharing layer borrowed from
[SeedShell](https://github.com/Deploydon/seedshell) (WebRTC P2P with Nostr
relays used only for signaling).

```
┌──────────────────────────────────────────────────────────────────────────┐
│  VibeShare.app  (Swift / SwiftUI menu-bar — thin manager UI)               │
│                                                                            │
│   manages two bundled Go binaries as child processes:                      │
│                                                                            │
│   ┌────────────────────────┐         ┌──────────────────────────────────┐ │
│   │  cli-proxy-api-plus     │  HTTP   │  vibeshare-router  (NEW)         │ │
│   │  (provider engine)      │◄────────┤                                  │ │
│   │  127.0.0.1:8317         │ local   │  Front server   127.0.0.1:8788   │ │ ← point your tools here
│   │  • Claude/Codex/Gemini  │ forward │  Control API    127.0.0.1:8799   │ │ ← Swift UI talks here
│   │    OAuth + API keys     │         │  P2P (pion + go-nostr)           │ │
│   │  • multi-account        │         │                                  │ │
│   │  • OpenAI-compatible     │         └───────────────┬──────────────────┘ │
│   └────────────────────────┘                         │                    │
└──────────────────────────────────────────────────────┼────────────────────┘
                                                        │ WebRTC DataChannel
                              Nostr public relays       │ (DTLS encrypted)
                              (signaling + presence)     ▼
                                              ┌────────────────────────────┐
                                              │  Friend's VibeShare router  │
                                              │  → their cli-proxy-api      │
                                              └────────────────────────────┘
```

## Why this shape

* **Thin Swift, fat Go** — exactly like VibeProxy, whose hard part (provider
  OAuth, token refresh, multi-account round-robin) lives in the `cli-proxy-api`
  Go binary. We bundle that binary unchanged.
* **Reuse SeedShell's proven P2P** — pion/webrtc + go-nostr are pure-Go, so the
  whole P2P layer is a normal Go binary (no 300 MB `WebRTC.xcframework`).
* The **Control API** (JSON over loopback) is the only seam between Swift and
  Go, so the two halves can evolve independently.

## The one-directional "grant" model

Sharing is **one-directional**, by design (per the product spec):

* **Host** (the person who owns the subscription) creates a **grant** — a
  random code — and chooses which providers/models it exposes. They hand the
  code to a friend.
* **Guest** redeems the code. They can now route requests for the shared models
  through the host. They get *only* what that grant exposes — nothing else.
* Reverse access requires the friend to create their *own* grant for you.

A grant code is the **only** credential. Everything (the Nostr "room" the two
parties meet in, the presence-encryption key, and the data-channel auth key) is
derived from it. Knowing the code = being able to use the grant, so treat codes
like passwords.

### Code → keys derivation (`crypto.go`)

```
codeBytes      = base32-decode(code)                 # 16 random bytes
roomID         = base64url( HKDF-SHA256(codeBytes, "vibeshare-grant-room-v1",      16) )
announceKey    =            HKDF-SHA256(codeBytes, "vibeshare-grant-announce-v1",  32)   # secretbox (presence + signaling)
channelKey     =            HKDF-SHA256(codeBytes, "vibeshare-grant-channel-v1",   32)   # secretbox (data-channel auth)
```

Host and guest derive these identically. `roomID` is the Nostr `#d` topic both
sides subscribe/publish to. Presence and SDP/ICE signaling are sealed with
`announceKey`, so Nostr relays only ever see ciphertext.

## P2P protocol

All Nostr events are kind **25050**, tagged `["d", roomID]` plus a `t` type tag.

| `t`        | direction       | sealed with   | content (decrypted JSON)                                   |
|------------|-----------------|---------------|------------------------------------------------------------|
| `presence` | host → room     | `announceKey` | `{role:"host", name, models:[...], ts}`                    |
| `presence` | guest → room    | `announceKey` | `{role:"guest", peer, ts, routing}`                        |
| `signal`   | both            | `announceKey` | `{from, session, kind:"offer"\|"answer"\|"ice", payload}`  |

Once an offer/answer completes, a WebRTC **DataChannel** (reliable, ordered,
DTLS-encrypted) carries the actual traffic. Frames are JSON text messages:

| frame              | direction    | fields                                            |
|--------------------|--------------|---------------------------------------------------|
| `auth`             | guest → host | `{t:"auth", payload}` — `secretbox(channelKey,{ts})` |
| `auth_ok`/`auth_err`| host → guest | `{t, msg?}`                                       |
| `req`              | guest → host | `{t:"req", id, path, body}`                       |
| `head`             | host → guest | `{t:"head", id, status, ctype}`                   |
| `data`             | host → guest | `{t:"data", id, b64}` (response body chunk)       |
| `end` / `err`      | host → guest | `{t, id, msg?}`                                   |

The **host enforces** that `path` is allow-listed (`/v1/chat/completions`,
`/v1/completions`, `/v1/models`, `/v1/embeddings`) and that the requested
`model` is in the grant's shared set, then reverse-proxies to its local
`cli-proxy-api` and streams the response bytes back. Streaming (`stream:true`,
SSE) is transparent — bytes are just forwarded as `data` frames.

## Front server routing (`server.go`)

* `GET /v1/models` → union of **local** models (from `cli-proxy-api`) and
  **remote** models advertised by online hosts. Local wins on collision.
* `POST /v1/chat/completions` → if the model is available locally, forward to
  `cli-proxy-api`; otherwise **auto-route** to an online host that advertises
  it; otherwise `404`.

## Control API (`control.go`) — Swift ⇆ router, `127.0.0.1:8799`

| Method & path              | purpose                                                        |
|----------------------------|----------------------------------------------------------------|
| `GET /api/status`          | router/front/upstream/nostr health, identity, local models     |
| `GET /api/grants`          | grants I issued (host) + each guest's online/routing state     |
| `POST /api/grants`         | create a grant `{label, providers, models}` → returns `code`   |
| `DELETE /api/grants/{id}`  | revoke a grant                                                  |
| `GET /api/connections`     | grants I hold (guest) + host online/models/routing state       |
| `POST /api/connections`    | redeem a code `{code, label}`                                  |
| `DELETE /api/connections/{id}` | drop a held connection                                     |
| `GET /api/config` / `PUT`  | read/update identity name, ports, relays                       |
| `GET /api/events`          | Server-Sent-Events stream of state changes (UI live updates)   |

## On-disk state (`~/.vibeshare/`)

* `config.json` — ports, upstream URL, Nostr relays, identity name, upstream key
* `grants.json` — grants I issued (includes the secret code, so rooms survive restarts)
* `connections.json` — grants I hold (includes the redeemed code)

`cli-proxy-api` keeps its own auth in `~/.cli-proxy-api/` (managed by the Swift
provider UI, exactly like VibeProxy).

## Repository layout

```
VibeShare/
├── ARCHITECTURE.md            ← this file
├── README.md
├── Makefile                   ← build / app / install / run
├── create-app-bundle.sh       ← assembles + signs VibeShare.app
├── entitlements.plist
├── scripts/fetch-cliproxyapi.sh
├── router/                    ← Go module: vibeshare-router
│   ├── main.go  config.go  crypto.go  nostr.go  peer.go
│   ├── host.go  guest.go  server.go  upstream.go  control.go
└── src/                       ← Swift package (menu-bar app)
    ├── Package.swift  Info.plist
    └── Sources/
        ├── main.swift  AppDelegate.swift
        ├── RouterClient.swift  ProcessManager.swift  ProviderManager.swift
        ├── AppState.swift  Models.swift
        ├── Views/  (MenuContentView, GrantsView, ConnectionsView, ProvidersView, StatusView)
        └── Resources/  (cli-proxy-api-plus, vibeshare-router, config.yaml, icons)
```
