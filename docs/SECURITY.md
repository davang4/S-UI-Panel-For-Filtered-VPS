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
  releases over HTTPS, pinned to tested versions (`SUI_VERSION`,
  `CFD_VERSION`). `cloudflared`'s published `.sha256` is verified
  when available; s-ui publishes no checksum, so the version pin is
  the protection — bump it deliberately, after testing.
- `sync.py` and `sui_setup.py` are Python stdlib only; `worker.js` has
  no dependencies.
- The installer opens no public ports and changes no firewall rules;
  the panel and the inbound bind `127.0.0.1` only.

## Backups

`install.sh backup` tars `~/sui-vpn` (state + DB) to
`~/sui-vpn-backup-<date>.tar.gz` (mode 600). **Copy it off the server.**
It contains every secret; without it, a dead VPS means new UUIDs and
new subscription links for every client. There is no automatic backup
— schedule the copy yourself.
