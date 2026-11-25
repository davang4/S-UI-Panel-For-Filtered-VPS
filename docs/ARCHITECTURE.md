# Architecture

## The problem

The VPS IP is filtered at the IP level on some (or all) networks. Any
protocol pointed directly at that IP fails there — including VLESS,
WireGuard, OpenVPN and Shadowsocks. The IP itself must be hidden, and
the only party that can hide it without an Iranian relay (which this
design refuses) is Cloudflare: clients connect to a Cloudflare edge
address, and Cloudflare forwards the traffic to the VPS over an
outbound tunnel the VPS itself opened.

## Components

```
                          Cloudflare edge
                         +----------------+
                         | trycloudflare  |   quick tunnel #1 (VLESS)
                         | trycloudflare  |   quick tunnel #2 (panel)
                         | Worker + KV    |   fixed workers.dev address
                         +----------------+
                            ^  ^  ^  ^
   clients (Hiddify /      |  |  |  |        VPS (Ubuntu/Debian)
   v2rayNG / sing-box) ----+  |  |  +------> cloudflared --WS--> 127.0.0.1:10087
   (TLS to edge)              |  +---------> cloudflared -------> 127.0.0.1:2095
                              +------------> Worker fetches panel via tunnel #2
   VPS sync timer (60s) -------------------> KV: sub:<uuid>, sub:<name>,
                                              panel:host, panel:subjson
```

### s-ui panel (`sui-panel.service`)
Runs `/root/sui-vpn/bin/sui` with `SUI_DB_FOLDER=~/sui-vpn/db`. It
binds **127.0.0.1 only** (`webListen`/`subListen`), on a configurable
port, under a random secret base path (`webPath`, e.g. `/p-<12 hex>/`).
It owns the client list (SQLite `s-ui.db`: `clients`, `inbounds`,
`settings`) and the VLESS inbound (`vless-ws-tunnel`, also localhost
only). Nothing about the panel is reachable from the internet except
through tunnel #2, and the panel itself returns 404 outside the secret
path.

### Quick tunnels (`sui-tunnel`, `sui-panel-tunnel`)
`cloudflared tunnel --no-autoupdate --url http://127.0.0.1:<port>`.
No account, no domain, no credentials: Cloudflare hands out a random
`https://<words>.trycloudflare.com` hostname, printed into
`tunnel.log` / `panel-tunnel.log`. Both units restart on failure.
**The hostnames change on every restart** — by design, everything
downstream re-reads them.

### Sync (`sui-sync.service` + `sui-sync.timer` every 60 s + `sui-sync.path`)
`sync.py` (stdlib only) reads, read-only, from the s-ui SQLite DB:

- enabled, non-expired, under-quota clients → one base64 `vless://`
  link each, PUT to KV as `sub:<uuid>` **and** `sub:<name>` (s-ui
  builds panel subscription links from the client *name*, so both keys
  are needed);
- the current tunnel hostname from `tunnel.log` (only the segment after
  the last "Requesting new quick Tunnel", so a stale URL is never
  reused);
- the panel tunnel hostname from `panel-tunnel.log` → KV `panel:host`;
- this install's identity (`CLIENT_UUID`) → KV `server:id`, so
  `deploy-worker` can tell when a namespace already belongs to
  another server (see README: Multiple servers);
- the panel's client-side routing, from **all three places** s-ui
  keeps it: `subJsonExt` (the subscription JSON extension), the
  `subJson` template, and the core `config` route/dns. Single-value
  keys (dns, `final`, `default_domain_resolver`) come from the
  highest-priority source that sets them; `rules` and `rule_set` are
  combined from all three → KV `panel:subjson`. The worker keeps its
  built-in Iran bypass first regardless, and drops panel rules naming
  an unknown outbound or an undefined rule-set, so a bad panel rule
  can never break the profile for every client.

It writes to KV **only when the digest changed** (KV free tier allows
1,000 writes/day; a 60 s timer would otherwise burn it). Stale
`sub:<uuid>` / `sub:<name>` keys are deleted when a client is removed
or renamed. `--dry-run` prints everything it would sync, including the
full links.

Two more mechanisms keep the sync honest:

- **`sui-sync.path`** (systemd path unit) triggers a sync the moment a
  tunnel log changes — a quick tunnel gets a new hostname on every
  restart, and waiting for the 60 s timer would leave the old address
  in KV for up to a minute. The timer stays as the safety net.
- **Retries + run state.** Each Cloudflare API call is retried with
  backoff (3 attempts) on transient failure; a 403/404 is reported at
  once, never retried. Every run records `last_run` (epoch) and
  `last_error` in `sync-state.json`, which `status` / `run_checks`
  reads — so a stuck timer or a failing sync is visible instead of
  silent. The journal lines never print secrets: UUIDs are masked,
  the panel host is not repeated, and a failed KV write names the
  client by name, not by UUID.

### Worker (`worker.js`, Cloudflare Workers, module format)
One fixed `https://sui-sub.<subdomain>.workers.dev` address, three jobs:

1. `GET /health` → `ok` (liveness probe).
2. `GET /sub/<secret>/<uuid-or-name>` → the base64 subscription from
   KV. If the request's user-agent contains `sing-box` or `sfa`, it
   instead returns a **full sing-box JSON profile** built by decoding
   that same link (tun + mixed inbounds, VLESS-WS outbound with
   TLS/uTLS-chrome, DNS + routing) — the official sing-box app refuses
   base64 remote profiles. Panel routing from KV `panel:subjson`
   merges in (bypass first; panel rules with an unknown outbound or
   an undefined rule-set are dropped). Without a `SUB_SECRET` variable
   set, the legacy `/sub/<id>` form also works.
3. Any other path → reverse-proxy to the panel: it fetches
   `https://<panel:host><path>` and rewrites `Origin`/`Referer` to the
   panel hostname, because s-ui's SameOrigin guard rejects POSTs whose
   Origin host differs from Host (this is what makes panel *login*
   work through the Worker).

The Worker never sees the VPS IP and holds no secrets except the
optional `SUB_SECRET` variable.

## Request flow (a client connecting)

1. The client resolves `<words>.trycloudflare.com` (from its
   subscription link) and opens TLS to the Cloudflare edge.
2. Inside that TLS: WebSocket to the tunnel → `cloudflared` on the VPS
   → `127.0.0.1:10087` → s-ui's VLESS inbound → internet, exiting
   from the VPS IP.
3. On tunnel restart, the hostname changes; `sync.py` writes the new
   one to KV within 60 s; the client's subscription URL is unchanged,
   so one subscription update in the app reconnects it.

## Why VLESS + WS (and not the alternatives)

| Option | Verdict |
|---|---|
| WireGuard / OpenVPN / Shadowsocks direct to VPS IP | Fail on filtered networks (IP-level block + DPI/UDP). |
| VLESS + XHTTP through the tunnel | Streams are cancelled by the Cloudflare edge (`stream canceled by remote`) — measured, not theoretical. |
| VLESS + WS through the tunnel | Works on all tested networks. |
| Hysteria2 | UDP/QUIC cannot pass a Cloudflare tunnel at all; only direct-to-IP, i.e. only on unfiltered networks. |
| Named tunnel + own domain | Works and is more stable (no rotation, no quick-tunnel limits) — the only reason this repo uses quick tunnels is to need *no* domain at all. |

## Data stored where

- VPS `~/sui-vpn/state.env` (600): WS path, first client UUID/name,
  panel user/pass, secret base path, `SUB_SECRET`, CF token, account
  ID, KV namespace ID, Worker URL.
- VPS `~/sui-vpn/db/s-ui.db`: users, inbounds, panel settings.
- Cloudflare KV `sui-sub`: `sub:<uuid>`, `sub:<name>` (base64 links),
  `panel:host`, `panel:subjson`, `server:id`. No passwords, no tokens.
- Cloudflare Worker: code + optional `SUB_SECRET` variable.
