# Troubleshooting

Failures we have already hit in production, and what fixed them.
Check `sudo bash install.sh status` first — it prints service states
and the last tunnel log lines.

## The client connects, then immediately drops / never connects

- **XHTTP transport.** XHTTP stream-up does not survive the Cloudflare
  tunnel: the edge cancels every stream (`stream canceled by remote
  with error code 0`). Use WebSocket (`type=ws`), which is what the
  installer configures.
- **Stale subscription.** After a tunnel restart the hostname changes;
  update the remote subscription in the app (the URL itself never
  changes). Check `install.sh status` shows a fresh tunnel URL, then
  `install.sh sync-now`.

## sing-box (official app) rejects the remote profile

The profile is JSON the Worker builds from your vless link. Errors seen
and fixed (all in `worker.js`, all verified against sing-box 1.14):

| Error | Cause / fix |
|---|---|
| `legacy DNS server formats are deprecated in 1.12, removed in 1.14` | DNS servers must use the new typed format (`{type, server, detour}`), not address strings. |
| `dns outbound is deprecated in 1.11, removed in 1.13` | There are no `dns` / `block` special outbounds anymore; use `action: "hijack-dns"` / `"reject"` in route rules. |
| `route.rules[0].server: unknown field "server"` | `server` belongs in `dns.rules` (`{action: "route", server: ...}`), not in route rules. |
| `outbound detour not found: proxy` | The DNS detour must be the real outbound tag (the client name), not a literal `"proxy"`. |
| `legacy download_detour ... deprecated in 1.14, removed in 1.16` | Remote rule-sets use a named `http_clients` entry (`proxy-http`) and `route.default_http_client`. |
| `geosite database is deprecated in 1.8, removed in 1.12` | No `.db` files. Domains use an inline rule-set; IPs use a remote `.srs`. |
| `geosite-ir: unexpected status: 404` | There is **no** `geosite-ir.srs` in SagerNet's rule-set repo. Use the inline `site-ir` list for domains (and `geoip-ir.srs`, which does exist). |

After any Worker change, update the remote profile in the app — the
app caches the old JSON.

## Iranian sites still go through the VPN

Two possible causes, in order:

1. **The panel template routes Iran to the proxy.** The panel's own
   routing is synced into the profile, and some templates list the
   Iran rule-sets under "Route to Proxy". The Worker evaluates the
   built-in Iran bypass *first*, so this is fixed in current
   `worker.js` — but also fix the template in the panel UI (remove the
   Iran lists from Route to Proxy) so the intent is visible there too.
2. **Hiddify / v2rayNG.** They only receive a base64 vless link, which
   carries no routing at all — no panel setting can reach them.
   Configure the split inside the app (Hiddify → Settings → Routing).

## Panel URL opens without VPN but not with VPN

The panel itself, its tunnel and the Worker are usually all healthy in
this case (check with `install.sh status` and by opening the fixed
panel URL with the VPN off). Get the sing-box log: in the app, turn the
VPN on, reproduce the failure, then copy the last log lines — it shows
whether the failure is DNS, the route, or the connection. Common
suspect: the merged panel DNS (see below).

## Second server: panel "doesn't come up" but VPN configs work

Two servers sharing one Worker + KV overwrite each other's
`panel:host`, `panel:subjson`, `SUB_SECRET` and same-name client keys,
so the fixed panel URL flips between the two panels while the VPN
tunnels keep working. Each server needs its own Worker + KV names
(same account and token are fine):

```bash
WORKER_NAME=sui-sub-2 KV_TITLE=sui-sub-2 sudo -E bash install.sh install
```

`deploy-worker` now warns (and waits 10 s) if the namespace already
belongs to another server — check `sync.py`'s `server:id` stamp in
the KV dashboard to confirm which server owns a namespace. See
README: Multiple servers.

## My address still contains the old subdomain (e.g. suisub)

The fixed address is always `<worker>.<subdomain>.workers.dev` —
the subdomain belongs to the Cloudflare **account** (every server on
it shares it), the worker name to one server. On a fresh install the
installer asks keep-or-change for an existing subdomain; picking a
Worker name does not change it. On an already-installed server, run
on any one server:

```bash
sudo sui-vpn change-subdomain myname42
```

That changes the address of every worker on the account at once, so
afterwards re-run `sudo sui-vpn deploy-worker` on each other server
to refresh its stored worker URL, and hand out the new subscription
links from each panel. (There is no single-label `<name>.workers.dev`
— Cloudflare always puts the account subdomain in the middle.)

## First server's fixed address still wrong after the second moved

The sync only writes when something changed *locally*, so a stale
`panel:host` left by the other server stays in the KV forever. Force
a full rewrite (after re-running the installer once so the server has
the current `sync.py`):

```bash
sudo sui-vpn sync-now --force
```

Then check the fixed panel URL again after ~60 s. If a server never
got a fixed address at all, `show` says "worker not deployed yet" —
re-run `deploy-worker` and look for the "worker URL" line.

## Panel DNS replaced the Worker's DNS

When the panel's `subJsonExt` contains a `dns` section with typed
servers, the Worker uses the panel's DNS wholesale (guard: every
server must have a `type` field, otherwise the Worker's own DoH DNS
is kept). Typical panel DNS: TCP `8.8.8.8:53` via the proxy for
everything, local resolver for Iranian domains. If that breaks a
client, clear the panel's DNS section and re-sync — the Worker's
built-in DNS (DoH `1.1.1.1` via proxy, local for `.ir`) returns.

## `install.sh` fails

- **`port already in use … aborting without changes`** — a port
  (default 2095/2096/10087) is taken by another service. Re-run with
  different ports, e.g. `PANEL_PORT=12095 SUB_PORT=12096 IN_PORT=11087
  sudo bash install.sh install`.
- **`read: read error` at the token prompt inside tmux** — interactive
  hidden `read` fails in a detached tmux session. Export the token
  instead: `CF_API_TOKEN=… CF_ACCOUNT_ID=… sudo -E bash install.sh install`.
- **First sync prints `sync: unchanged`** — normal; it means nothing
  changed since the last run.
- **Worker deploy fails** — the installer prints manual fallback
  steps (create the Worker in the dashboard, paste `worker.js`, bind
  KV `SUB_KV`, enable workers.dev). The panel + tunnel keep working
  without the Worker; only the fixed subscription URL is missing.

## Hysteria2

Hysteria2 cannot pass a Cloudflare tunnel (UDP/QUIC). It only works
direct to the VPS IP — i.e. only on networks that do not filter that
IP — and needs a public UDP port plus a TLS certificate (sing-box
refuses Hysteria2 without TLS). That is a property of the tunnel, not
a bug in this setup; VLESS+WS is the all-networks path.

## `state.env` was deleted / a re-install made a new address

The installer recognises the server by itself: on a re-run with no
stored names it scans the account's KV namespaces for one whose
`server:id` (or `server:code`) matches a client UUID in this panel's
DB, and adopts that Worker + KV — the fixed address stays the same.
It prints `found this server's existing Worker + KV on Cloudflare
(server code …) — reusing them, no new address.` when it does.

- If it instead created new names, the panel DB had no clients yet
  (nothing to match against), or the old namespace was never synced
  (no `server:id` stamped — the first sync stamps it, so this only
  happens within a minute of the very first install). Re-run
  `deploy-worker` after the first sync.
- `ERROR: this KV namespace already belongs to another server` — the
  deploy stopped on purpose (it used to warn and continue after 10 s).
  Give this server its own names and re-run, as the message says.
  Never force two servers onto one Worker + KV.

## `update-sui` wiped the users / settings

`update-sui` itself never touches the s-ui database — it only swaps
the binary and restarts the panel. A wipe after an update means the
new binary started on the old database and its own migration reset
it (a major-version jump is the risky case). The installer now
checks the version first and does nothing when s-ui is already the
latest, and asks before any major-version jump.

Recover on the affected server (diagnose first, restore second):

```bash
sudo -i
cd ~/sui-vpn
./bin/sui -v | head -1
ls -la bin/sui.bak-* backups/ 2>/dev/null
ls -la db/
python3 -c "import sqlite3; c=sqlite3.connect('db/s-ui.db'); print('clients:', c.execute('SELECT COUNT(*) FROM clients').fetchone()[0]); print('inbounds:', c.execute('SELECT COUNT(*) FROM inbounds').fetchone()[0])"
```

- If `db/` holds another database file next to `s-ui.db`, the new
  binary created a fresh one there and the old data is still in
  `s-ui.db` — put the old binary back (`sudo cp bin/sui.bak-<stamp>
  bin/sui && sudo systemctl restart sui-panel`).
- If a `backups/pre-change-*.tar.gz` from just before the update
  exists, its database has the users: stop the panel, extract the
  backup's `db/s-ui.db` over `~/sui-vpn/db/s-ui.db`, put the old
  binary back, restart the panel, and count the clients again.
- If there is no backup and the database file itself is empty, the
  clients are still listed in Cloudflare KV (`sub:<name>` keys hold
  every client UUID) — recreate them in the panel from those keys.
  Do not re-run `update-sui` until the panel shows the users again.

## Where do backups go? How do I download one?

- **Manual backup** (`backup`, menu 10): `${HOME}/sui-vpn-backup-<date>.tar.gz`
  (mode 600). `backup` prints the path, the size, and the `scp`
  command to download it; or download it with SFTP (e.g. in Termius)
  from the home directory.
- **Auto snapshots** (before `update-sui` and re-install):
  `~/sui-vpn/backups/pre-change-<stamp>.tar.gz`, last 5 kept.
- **Restore** (`restore`, menu 11): with no file it lists both kinds
  on this server, newest first, and restores the one you pick by
  number. Give a path only for a backup copied in from outside
  (e.g. after moving to a new server).

## `status` shows FAIL on the last sync

- **`last sync error: …`** — the sync's own error message, e.g. a KV
  PUT failure or a missing token in `state.env`. Fix the cause, then
  `sudo bash install.sh sync-now` (or wait for the next 60 s tick;
  a failed run keeps its old digest, so it retries the writes).
- **`last sync stale: Ns ago`** — the timer has not run a sync in
  over 10 minutes. Check `systemctl status sui-sync.timer` and
  `journalctl -u sui-sync.service -n 20`; a common cause is the timer
  being disabled after a restore (re-run `install` to re-enable it).
- **`/sub` FAIL but `/health` PASS** — the Worker is alive but the
  subscription is not served: usually the KV namespace is wrong (a
  Worker/KV move without `sync-now --force`), or the client's UUID
  was deleted/renamed in the panel. Run `sync-now --force` and check
  `sync-now --dry-run` lists the client.

## A panel routing rule does not apply

- **It was set less than a minute ago** — rules sync on the next 60 s
  tick; update the subscription in the client app after that.
- **The rule routes Iran to `proxy`** — it will not take effect: the
  Worker's built-in Iran bypass is always evaluated first (see README:
  Panel routing). This is deliberate.
- **The rule names an outbound the profile does not have** (a
  server-side tag from the core config, a typo like `outbound:
  "api"`) **or a rule-set that is not defined anywhere** — the Worker
  drops that rule so the profile stays valid. Fix the rule in the
  panel and re-sync; the rest of your rules still apply.
- **Hiddify / v2rayNG** — they receive only a base64 link, which
  carries no routing at all. No panel setting can reach them; set
  the split inside the app itself.
