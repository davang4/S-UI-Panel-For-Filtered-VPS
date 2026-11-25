# Security

## Threat model

- **Adversary:** networks that filter the VPS IP, plus anyone who
  learns a subscription URL (it lives in client apps and can leak).
- **Not in scope:** protecting the VPS itself from compromise, or
  hiding the fact that the user uses a VPN. The exit IP is the VPS IP;
  traffic is attributable to the VPS.

## What is secret, and where it lives

| Secret | Where | Notes |
|---|---|---|
| Panel username/password | `state.env` (600) + s-ui DB | Random 20-char hex password, generated on-server. |
| Panel secret base path (`/p-<12 hex>/`) | `state.env` (600) | The panel returns 404 outside it. |
| Cloudflare API token | `state.env` (600) | Least privilege: Workers Scripts Edit + Workers KV Storage Edit only. No zone permissions — it cannot touch domains, DNS, or tunnels. |
| `SUB_SECRET` | `state.env` (600) + Worker variable | URL-path secret for subscription links (below). |
| Client UUIDs / subscription links | KV (`sub:<uuid>`, `sub:<name>`) | Unguessable 128-bit UUIDs. Treat a link like a password: anyone holding it can use that client's quota. |
| WS path (`/<random>-ws`) | `state.env` (600) | Random per install; not a security boundary, just obscurity. |

**Never** put any of these in git, in chat, or in a screenshot. The
repo contains no secrets; `state.env` is generated on the server and
is `.gitignore`d. If a secret ever appears in chat, rotate it
immediately (panel password: panel UI or `sui admin`; CF token:
dashboard → revoke; client UUID: delete and re-create the client).

## Subscription links and the SUB_SECRET

s-ui builds each client's panel subscription link from the client
**name** (`subURI + name`), so `sync.py` must publish KV keys under
`sub:<name>` too. Plain names are guessable: anyone who knows the
Worker's address can try `admin`, `test`, `user1`, … and download a
working VPN config for every hit. (Verified live: `/sub/<name>`
returned 200 for ordinary names.)

That is why the installer generates a random `SUB_SECRET` (16 hex
chars), deploys it as a Worker variable, and writes the panel's
Subscription URI as `https://<worker>/sub/<secret>/`. Panel links then
carry the secret, and the Worker returns 404 for `/sub/<id>` without
it. If you empty `SUB_SECRET` before installing, the legacy plain
form is used instead — simpler, but enumerable.

Mitigations that remain your job:

- Use non-obvious client names anyway (defense in depth).
- If a link leaks, delete that client in the panel (the sync removes
  its KV keys within 60 s) and create a fresh one.
- Rotate `SUB_SECRET` by regenerating it in `state.env`, redeploying
  the Worker (`install.sh deploy-worker`), and re-issuing links.

## Panel exposure

The panel is reachable from the whole internet at the fixed Worker
URL + secret path. That is a deliberate trade-off (managing users
without SSH). The layers:

1. Secret base path (48 bits of randomness).
2. Random 20-char password.
3. `install.sh panel-off` kills the panel tunnel entirely when you are
   not managing users (the panel stays reachable via SSH forward).
4. s-ui's SameOrigin guard on POSTs (the Worker rewrites Origin/
   Referer to the panel hostname, which is required for login to work
   at all through the proxy).

If you want stronger protection, put Cloudflare Access (Zero Trust) in
front — it needs a domain, which is exactly what this setup avoids,
so it is documented here, not built in.

## Supply chain

- `install.sh` downloads `s-ui` and `cloudflared` from their GitHub
  releases over HTTPS. `s-ui` defaults to the newest release
  (`releases/latest`); set `SUI_VERSION=x.y.z` to pin a version
  deliberately, e.g. after a new release breaks something.
  `cloudflared` stays pinned (`CFD_VERSION`) with its published
  `.sha256` verified when available; s-ui publishes no checksum, so
  the downloaded binary is verified by running it before it replaces
  the old one (`update-sui` also keeps a timestamped backup).
- `sync.py` and `sui_setup.py` are Python stdlib only; `worker.js` has
  no dependencies.
- The installer opens no public ports and changes no firewall rules;
  the panel and the inbound bind `127.0.0.1` only.

## Address fingerprinting: why names are custom

Your fixed address is `<worker-name>.<subdomain>.workers.dev`. Both
labels are chosen per user — the installer asks you for a custom
Worker name on a fresh install (or takes a random one), and asks for
a custom workers.dev subdomain the first time an account needs one
(`WORKERS_SUBDOMAIN` sets it non-interactively). There is no shared
default name anywhere.

The reason: if every user of this repo had the same address — or the
same predictable pattern, like `sui-sub.*.workers.dev` or
`sui-<hex>.workers.dev` — one filter rule on that string would block
all of them at once. Custom, per-user names mean a censor has to
discover and block each address individually; there is no single
string that takes the whole user base down. This does not protect
against a targeted block of *your* address once it is observed in
traffic — no naming scheme can — but it removes the bulk-blocking
failure mode.

Note the same logic applies to the SUB_SECRET: it is random per
install, never a shared value. And never publish your worker address
anywhere public (a forum post, a GitHub issue, a screenshot): the
address itself is the thing a filter rule would target.

## Backups

`install.sh backup` tars `~/sui-vpn` (state + DB) to
`~/sui-vpn-backup-<date>.tar.gz` (mode 600). **Copy it off the server.**
It contains every secret; without it, a dead VPS means new UUIDs and
new subscription links for every client. There is no automatic backup
— schedule the copy yourself.

Before `update-sui` and before a re-install, the installer also
snapshots the DB + state to `~/sui-vpn/backups/` (last 5 kept, mode
600), so a bad new binary can never take the clients and secrets
with it.

## Key rotation (when something leaks)

Rotation is manual — nothing rotates itself, and nothing in this
repo ever prints a secret to a log (see the audit below). If a secret
does leak (a screenshot, a pasted terminal, a shared backup), rotate
it and revoke the old one:

- **Cloudflare API token.** In the dashboard (My Profile → API
  Tokens) revoke the old token, create a new one with the same
  permissions (Workers Scripts Edit, Workers KV Storage Edit,
  Account Settings Read), then put it in `~/sui-vpn/state.env`
  (`CF_API_TOKEN=…`, file stays mode 600) and run
  `sudo bash install.sh deploy-worker` + `sync-now` to confirm the
  new token works. The old token stops working the moment it is
  revoked — the sync fails loudly until the new one is in place.
- **SUB_SECRET.** Generate a new one and put it in `state.env`
  (`SUB_SECRET=…`), then run `deploy-worker` (uploads the worker
  with the new secret) and `sync-now` (the panel's subURI is rebuilt
  from the new secret). **Every old subscription link stops working**
  — hand out the new links from the panel. The worker variable and
  the panel subURI must match; if they do not, `/sub` returns 404
  for the old links.
- **Panel password.** Change it in the panel (Settings → panel
  account) — or reset it with the panel's own reset flow. The
  installer never stores it anywhere except `state.env` and the
  s-ui DB.
- **Client UUID (one user's link leaked).** Delete the client in the
  panel and re-add them; the sync publishes a new UUID and deletes
  the old key from KV. Only that user gets a new link.

## Secrets audit (what is printed where)

Checked against the code; the rule is: secrets are shown only in the
terminal, on demand, never in a persistent log.

- **Shown (terminal only):** the install SAVE block and `show`
  (panel username/password, subscription URL with secret, fixed panel
  address); `sync-now --dry-run` (full links + UUIDs, only when you
  run it by hand).
- **Masked in the systemd journal:** the sync timer's stdout goes to
  the journal, so its lines print no secret values — a stamped
  server id shows its first 8 characters, a failed KV write names
  the client by name (not by UUID), and a panel-host change is logged
  without the hostname (the address is in `panel-tunnel.log` and
  `show`).
- **Never printed:** the Cloudflare API token (read hidden at the
  prompt, stored only in `state.env` mode 600). The worker has no
  `console.log` at all, so nothing lands in Cloudflare's logs
  either.
