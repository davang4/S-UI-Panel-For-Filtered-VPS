# S-UI-Panel-For-Filtered-VPS

**A self-hosted VPN for a VPS whose IP is filtered.**

If your VPS IP is blocked on some (or all) networks, pointing any VPN
protocol straight at it fails — the block is at the IP level, so the IP
itself has to disappear behind Cloudflare. This setup does exactly that,
with no Iranian server, no custom domain, and no public port:

- **s-ui panel** on the VPS to create users with per-user traffic volume
  and expiry dates (localhost only, never exposed directly).
- **Two Cloudflare quick tunnels** (`trycloudflare.com`): one in front of
  the VLESS inbound, one in front of the panel. The tunnel hostnames
  change on every restart — nothing below depends on them staying fixed.
- **A Cloudflare Worker** (`workers.dev`) as the one fixed address your
  clients ever need: it serves each user's subscription and always points
  at the *current* tunnel hostname, and it proxies the panel at a fixed
  URL too. A sync timer on the VPS keeps the Worker up to date every
  60 seconds.
- **Split routing for Iranian traffic** (optional, editable): Iranian
  domains and IPs go direct, everything else goes through the VPN.
  The panel's own routing settings are synced into the client profile
  automatically.

Clients: **Hiddify / v2rayNG** (base64 subscription link) and the
**official sing-box app** (full JSON profile, served automatically when
its user-agent is detected). Protocol: **VLESS + WebSocket + TLS** —
plain WireGuard / OpenVPN / Shadowsocks do not survive DPI here, and
XHTTP stream-up does not survive the Cloudflare tunnel (tested).

> Tested on Ubuntu 22.04 (RackNerd US VPS) with s-ui 1.6.8,
> cloudflared 2026.11.2 and sing-box 1.14 clients (Android/iOS).

## One-command install

On a fresh Ubuntu/Debian VPS, as root (or with `sudo`):

```bash
curl -fsSL https://github.com/davang4/S-UI-Panel-For-Filtered-VPS/archive/refs/heads/main.tar.gz \
  | tar xz && cd S-UI-Panel-For-Filtered-VPS-main && sudo bash install.sh install
```

Or clone it first if you prefer to read the scripts before running them
(please do — see [SECURITY.md](docs/SECURITY.md)):

```bash
git clone https://github.com/davang4/S-UI-Panel-For-Filtered-VPS.git
cd S-UI-Panel-For-Filtered-VPS
sudo bash install.sh install
```

The installer asks once for a Cloudflare API token (typed hidden, stored
in `~/sui-vpn/state.env`, mode 600, never printed). Create it with this
one-click link — the permissions are already ticked, just press
"Continue to summary" and "Create Token":

[Create the Cloudflare API token](https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22workers_kv_storage%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22account_settings%22%2C%22type%22%3A%22read%22%7D%5D&accountId=*&zoneId=all&name=SUI-Panel-Sub)

Or create it manually at dash.cloudflare.com → My Profile → API Tokens
→ Create Token, with:

- Account → **Workers Scripts → Edit**
- Account → **Workers KV Storage → Edit**
- Account → **Account Settings → Read**

No zone permissions are needed. A token with these two permissions
cannot touch your domains, DNS records, or tunnels.

That token is the **only manual Cloudflare step**. Everything else on
the Cloudflare side is automatic: the installer verifies the token,
picks the account (asking only if the token sees several), registers
a `workers.dev` subdomain if the account has none, creates or reuses
the KV namespace, uploads the Worker, and enables its `workers.dev`
route. The one thing no script can do for you is create that first
token — Cloudflare needs a human to create the first credential.

It also asks for nothing else: usernames, passwords, the panel's secret
path, the WS path and the subscription secret are all generated
on-server. **Save the block printed at the end** — the panel password
and your subscription URL are shown once.

## What gets installed — and what does not

| Installed | Untouched |
|---|---|
| `~/sui-vpn` (binaries, DB, state, logs) | Everything else on the server |
| systemd units: `sui-panel`, `sui-tunnel`, `sui-panel-tunnel`, `sui-sync(.timer)` | No firewall changes, no public ports |
| Cloudflare: one Worker (`sui-sub`), one KV namespace (`sui-sub`), one API token | Your domains, DNS, existing tunnels |
| s-ui panel on `127.0.0.1:2095`, inbound on `127.0.0.1:10087` | — |

Ports are overridable: `PANEL_PORT=12095 SUB_PORT=12096 IN_PORT=11087 sudo bash install.sh install`.
The first client name defaults to `main`; override with `FIRST_CLIENT_NAME=alice`.
To pass the Cloudflare token without the interactive prompt (e.g. inside
tmux, where hidden `read` can fail), export `CF_API_TOKEN` and
`CF_ACCOUNT_ID` before running the installer.

## Using it

```bash
sudo bash install.sh show        # panel URL, current tunnel link, fixed subscription URL
sudo bash install.sh status      # service states + tunnel logs
sudo bash install.sh sync-now    # sync clients to the Worker right now
sudo bash install.sh sync-now --dry-run   # show what would sync (links included)
sudo bash install.sh deploy-worker        # re-upload worker.js after editing it
sudo bash install.sh update-sui           # replace s-ui with the newest GitHub release (backs up the old binary)
sudo bash install.sh panel-on    # allow panel access from the internet
sudo bash install.sh panel-off   # panel reachable only via SSH forward
sudo bash install.sh backup      # tarball of ~/sui-vpn (contains secrets — copy it off-server)
sudo bash install.sh uninstall   # removes the install (Worker + KV stay in Cloudflare)
```

**Add a user:** open the panel (fixed Worker URL + secret path, or
`install.sh show`), Clients → add. Set Volume (GB, `0` = unlimited)
and Expiry. Within ~60 s the sync writes their subscription to the
Worker; their subscription URL is
`https://<worker>.workers.dev/sub/<secret>/<name>` — the panel builds
this link itself from the Subscription URI the installer set, so just
copy it from the panel. Volume and expiry are enforced by the sync:
expired or over-quota users disappear from the Worker automatically.

**Update a client:** in Hiddify / v2rayNG / sing-box, update the remote
subscription. The URL never changes, even when the tunnel restarts.

## How it works

```
phone --TLS--> Cloudflare edge (trycloudflare.com)
                   --WS--> cloudflared on VPS --> 127.0.0.1:10087 (s-ui VLESS)
phone --HTTPS--> Worker (workers.dev)
                   --KV--> current tunnel hostname + per-user links
                   --HTTPS--> panel tunnel --> 127.0.0.1:2095 (s-ui panel)
VPS --every 60s--> sync.py reads s-ui DB + tunnel logs --> Cloudflare KV
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture,
[docs/SECURITY.md](docs/SECURITY.md) for the threat model (including the
subscription-link secret), and
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the failures we
already hit and fixed.

## The Iran split-routing (and how to change it)

The Worker builds the sing-box JSON profile with an inline rule-set
(`site-ir`: every `.ir` domain plus the big Iranian services on
`.com`/`.org`) and the `geoip-ir` rule-set for Iranian IPs; both route
`direct`. The panel's own routing (its Subscription JSON Extension,
`subJsonExt`) is synced into the profile too, and the built-in bypass
is always evaluated first, so a panel template can never silently
route Iranian traffic back through the VPN.

This list is Iran-specific. If you need a different country's split,
edit the `domain_suffix` list in `worker.js` (`site-ir` rule-set) and
the `geoip-ir` URL, then `install.sh deploy-worker`.

Hiddify / v2rayNG only receive a base64 vless link, which carries no
routing at all — no panel setting can reach them. For those apps,
configure the split inside the app itself (Hiddify → Settings →
Routing / GeoIP rules).

## Known limits

- **Quick tunnels have no SLA.** Cloudflare can throttle or kill a
  `trycloudflare.com` tunnel, and its hostname changes on restart
  (the Worker hides that from clients). If you want a stable hostname,
  replace the quick tunnel with a **named tunnel + a cheap separate
  domain** — the Worker/subscription design stays the same.
- **Hysteria2 does not work through a Cloudflare tunnel** (UDP/QUIC
  cannot pass it). It only works direct to the VPS IP, i.e. only on
  networks that do not filter that IP, and it needs a public UDP port
  plus a TLS certificate. VLESS+WS is the all-networks path.
- **Exit IP is the VPS IP.** The tunnel hides the VPS IP from the
  networks that filter it; traffic still exits from that IP.
- Cloudflare free tier: 100k Worker requests/day, 100k KV reads/day,
  1k KV writes/day — far above what a panel + a few dozen users need.
  The sync writes to KV only when something actually changed.

## License

MIT — see [LICENSE](LICENSE).
