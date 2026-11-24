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

**Ports.** The installer uses three localhost ports: panel `2095`,
subscription server `2096`, inbound `10087`. If one is already taken
by another program, the installer says so and lets you type a
different one — press Enter to take the random free port it suggests.
When stdin is not a terminal (e.g. the install is pasted into a
detached tmux session), it picks a random free port itself and tells
you which one. A port already used by our own s-ui is kept silently,
so re-running the installer never moves the panel. To choose the ports
yourself up front:

```bash
PANEL_PORT=12095 SUB_PORT=12096 IN_PORT=11087 sudo -E bash install.sh install
```

The resolved ports are saved in `~/sui-vpn/state.env`, so re-runs and
`sui_setup.py` keep using them.

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

## Management

After install, every command also works from any directory — no `cd`
needed:

```bash
sudo sui-vpn show
sudo sui-vpn status
```

`sudo bash install.sh help` (in the install directory) prints the
same list.

### Command reference

| Command | What it does |
|---|---|
| `install` | Full install (panel + tunnels + Worker + sync timer). Re-running it is safe: it keeps existing state and only fills in what is missing. |
| `show` | Panel URL, current tunnel URL, fixed subscription URL, panel login. |
| `status` | Service states, tunnel URLs, last tunnel log lines, last sync run. Start here when something is wrong. |
| `sync-now` | Sync clients to the Worker right now (the timer does this every 60 s anyway). |
| `sync-now --dry-run` | Preview what would sync, including the full links. Writes nothing. |
| `sync-now --force` | Rewrite everything to KV even if nothing changed locally (use after a Worker/KV move, or when another server overwrote this server's `panel:host`). |
| `deploy-worker` | Re-upload `worker.js` to Cloudflare after editing it. |
| `update-sui` | Replace s-ui with the newest GitHub release. Verifies the new binary runs first and keeps a timestamped backup of the old one. |
| `panel-on` / `panel-off` | Allow / stop panel access from the internet. Off means the panel is reachable only via SSH forward. |
| `backup` | Tarball of `~/sui-vpn` (mode 600). Contains every secret — copy it off the server. |
| `restore <file>` | Restore `~/sui-vpn` from a backup tarball and restart the services. On a fresh server, run `install` afterwards (it keeps the restored state). |
| `uninstall` | Remove the install from the server (below). |
| `help` | Show the command list. |

### Users

Open the panel (fixed Worker URL + secret path, or `install.sh
show`), Clients → add. Set Volume (GB, `0` = unlimited) and Expiry.
Within ~60 s the sync writes their subscription to the Worker; their
subscription URL is `https://<worker>.workers.dev/sub/<secret>/<name>`
— the panel builds this link itself from the Subscription URI the
installer set, so just copy it from the panel. Volume and expiry are
enforced by the sync: expired or over-quota users disappear from the
Worker automatically.

- **Disable / delete a user:** toggle Enable off, or delete the client
  in the panel. The next sync (≤ 60 s) removes their keys from the
  Worker, so their subscription stops working. To revoke a leaked
  link immediately, delete the client and run `sync-now`.
- **Rename a user:** the old name key is deleted and the new one is
  published on the next sync. Hand out the new link from the panel.
- **Update a client app:** in Hiddify / v2rayNG / sing-box, update the
  remote subscription. The URL never changes, even when the tunnel
  restarts.

### Logs and health

```bash
sudo bash install.sh status                 # services + tunnel logs + last sync
sudo journalctl -u sui-panel -n 50          # panel log
sudo journalctl -u sui-tunnel -n 50         # tunnel log
sudo journalctl -u sui-sync.service -n 20   # last sync runs
curl -s https://<worker>.workers.dev/health   # Worker alive? prints "ok"
sudo bash install.sh sync-now --dry-run     # what the Worker currently serves
```

### Backup and restore

```bash
sudo bash install.sh backup                              # -> ~/sui-vpn-backup-<date>.tar.gz
sudo bash install.sh restore ~/sui-vpn-backup-<date>.tar.gz
```

The backup holds `state.env` (panel password, Cloudflare token,
client UUIDs, subscription secret) and the s-ui database — everything
needed to rebuild the exact same install with the same subscription
links. **Copy it off the server**; a backup that only exists on the
VPS dies with the VPS. To move to a new server: copy the backup over,
run `install` (it keeps the restored state), then `restore` the file
— or restore first and `install` after; both orders work.

### Uninstall

```bash
sudo bash install.sh uninstall
```

This stops and removes the four systemd units and deletes `~/sui-vpn`
from the server, and nothing else. The Cloudflare side stays — remove
it by hand if you want it fully gone:

1. dash.cloudflare.com → Workers & Pages → `sui-sub` → Settings →
   Delete (this also deletes the `workers.dev` address).
2. Workers & Pages → KV → `sui-sub` → Delete.
3. My Profile → API Tokens → `SUI-Panel-Sub` → Delete.

Revoking the token alone already stops all syncing, so step 3 is the
one that matters most.

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

## Multiple servers

One Worker + KV namespace serves exactly **one** server — but one
Cloudflare account and one API token serve any number of panels. A
fresh install always creates **new** resources: it checks whether
`sui-sub` is already used and, if so, takes the next free name
(`sui-sub-2`, `sui-sub-3`, …) and tells you which one it picked. If
you want a specific name, set it explicitly:

```bash
WORKER_NAME=my-panel KV_TITLE=my-panel sudo -E bash install.sh install
```

If that name is already taken, the installer says so and either
suggests the next free one (press Enter to take it, when interactive)
or picks it automatically (when stdin is not a terminal). A re-install
of the same server keeps its stored names and never re-checks them.

If two servers ever share one Worker + KV, they overwrite each
other's `panel:host` (the fixed panel URL flips between the two
panels), `panel:subjson`, the `SUB_SECRET` variable, and any
client-name keys they both have — the classic symptom is a panel that
"doesn't come up" while the VPN configs keep working. The installer
guards against this: `sync.py` stamps each namespace with `server:id`,
and `deploy-worker` warns loudly (and waits 10 s) if the namespace
already belongs to another server.

Already sharing one by mistake? On the second server, re-run the
install — it now detects the collision, creates a separate Worker +
KV, re-syncs that server's clients there, and points its panel links
at the new address. Then fix the first server's fixed panel URL: its
sync only writes when something changed locally, so the stale
`panel:host` left by the other server stays until forced:

```bash
sudo sui-vpn sync-now --force
```

(And if a server never got a fixed address at all, `show` says
"worker not deployed yet" — re-run `deploy-worker` and watch for the
"worker URL" line; the deploy fails loudly if the token, account, or
KV step breaks.)

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
  1k KV writes/day. Only requests that actually hit the Worker count
  toward the 100k — subscription fetches and panel page loads, a few
  hundred a day at most. **VPN data traffic through the quick tunnel is
  not a Worker request and does not count at all**: it goes client →
  Cloudflare edge → `cloudflared` and never touches the Worker. The
  sync writes to KV only when something actually changed.

## License

MIT — see [LICENSE](LICENSE).

See [CHANGELOG.md](CHANGELOG.md) for what's new, and
[CONTRIBUTING.md](CONTRIBUTING.md) if you want to help improve it.
