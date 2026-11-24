# Changelog

All notable changes to this project, in reverse chronological order.
Dates are in Asia/Tehran time.

## 2026-11-24

- **Ask first: a fresh install now asks keep-or-change for an
  existing subdomain.** An account that already had a subdomain used
  to be kept silently, so a user who wanted the old name gone never
  got asked. Now a fresh interactive install shows the current
  subdomain and lets the user keep it (Enter) or type a custom one;
  re-installs and non-interactive runs still keep it silently.
- **New: `change-subdomain [name]` replaces the account's workers.dev
  subdomain.** The fixed address is always
  `<worker>.<subdomain>.workers.dev` — the subdomain belongs to the
  Cloudflare account (all servers on it share it), the worker name to
  one server; there is no single-label `<name>.workers.dev`. An
  account that already has a subdomain kept it silently, so a user who
  wanted the old one gone had no way to change it. The new command
  changes it, refreshes this server's stored worker URL + panel
  subURI, and reminds you to re-run `deploy-worker` on each other
  server. The worker-name prompt now also shows the full address
  shape (including the current subdomain) so the two parts are never
  confused again. The SAVE block now prints the fixed panel address
  as its first line, like `show` already did.
- **Fix: fresh installs crashed after the worker upload
  (`install.sh: line 915: sub: unbound variable`).** The subdomain
  refactor renamed `sub` to `SUBDOMAIN` but missed the panel subURI
  step, so `set -u` killed the install right after printing the
  worker URL (worker + KV were already created; the SAVE block, sync
  timer and first sync never ran). Re-running the installer picks up
  where it left off. Regression test asserts no stale
  `${sub}.workers.dev` reference remains.
- **No shared fingerprint in the fixed address.** The Worker name and
  the workers.dev subdomain are now custom per user: a fresh install
  asks for a Worker name (or takes a random prefix-free one), and the
  first install on an account asks for a workers.dev subdomain the
  same way (`WORKERS_SUBDOMAIN` sets it non-interactively). The old
  auto-generated `sui-<hex>` subdomain and the `sui-sub` default are
  gone. Reason: a shared address or pattern would let one filter rule
  block every repo user at once. See docs/SECURITY.md.
- `show` now prints the fixed panel address (`Panel (fixed):
  <worker URL><secret path>`) as its **first** line, so the address
  you actually use every day is right at the top instead of the
  rotating direct tunnel URL.
- **Fresh installs now auto-pick a free Worker/KV name.** A new server
  never silently reuses another server's Worker + KV: the installer
  checks whether the name is taken and takes the next free one
  (`sui-sub-2`, `sui-sub-3`, …), telling you which one it picked. An
  explicitly requested name that is taken gets announced, with the
  next free one suggested (press Enter to take it when interactive)
  or picked automatically (non-interactive). One API token can now
  serve any number of panels with no env vars needed. A re-install of
  the same server keeps its stored names.
- **Fix: the stored KV id is now verified by title before reuse.**
  An earlier buggy deploy could record a namespace id whose title did
  not match the stored name; reusing it silently kept the server on
  the wrong (shared) namespace. A mismatch now falls through to the
  find-by-title / create path.
- `sync-now --force` rewrites everything to KV even when the digest
  is unchanged — the fix for a first server whose `panel:host` was
  overwritten by a second server sharing its KV (the normal sync only
  writes when something changed locally, so the stale value stayed
  forever). `cf_request` also no longer crashes with a traceback on
  HTTP errors (deleted namespace/account, bad token); it reports a
  clean failure instead.
- **Fix: moving a server to new Worker/KV names did not actually move
  the KV.** `resolve_worker_names` read the "stored" title from the
  shell variables, where the env value given on the command line was
  already sitting — so it looked stored, the old shared namespace was
  reused, and only the Worker got the new name (worker `sui-sub-2`
  existed, no `sui-sub-2` namespace did). Stored names are now read
  from the state file. Regression test covers the exact case.
- **Fix: sync after a namespace move wrote nothing.** The sync digest
  does not cover the namespace, so after a move it reported
  "unchanged" and never wrote to the new namespace. `deploy-worker`
  now resets `sync-state.json` when the namespace changes.
- Multiple servers, one Cloudflare account: `WORKER_NAME` / `KV_TITLE`
  env overrides (stored in `state.env`), so each server gets its own
  Worker + KV namespace. Sharing one Worker + KV between servers used
  to mix their panel URLs, subscription keys and `SUB_SECRET` — the
  symptom was a panel that "doesn't come up" while VPN configs kept
  working. `sync.py` now stamps each namespace with `server:id`, and
  `deploy-worker` warns loudly (10 s pause) if the namespace already
  belongs to another server. KV lookup is now find-by-title-first, so
  a re-deploy can never create a duplicate-title namespace.
- Global command: after install, `sudo sui-vpn <command>` works from
  any directory (no `cd`). The installer copies itself to `~/sui-vpn`
  and links `/usr/local/bin/sui-vpn` to it; `uninstall` removes the
  link.
- Port conflicts no longer abort the install: if a port is taken by
  another program, the installer says so and lets you type a different
  one (Enter = a random free port it suggests), or picks a random free
  port itself when stdin is not a terminal. A port our own s-ui listens
  on is kept silently. Resolved ports are saved in `state.env`, and a
  re-run with an old state file keeps the panel bindings already in
  the s-ui DB instead of falling back to the defaults.
- Installer prints a one-click pre-filled Cloudflare token-creation
  link at the token prompt (same link in both READMEs).
- Installer verifies the Cloudflare token, auto-picks the account
  (asks only if the token sees several), and auto-registers a
  `workers.dev` subdomain when the account has none.
- Clarified in both READMEs: VPN tunnel traffic does not count toward
  the 100k Worker requests/day — only Worker hits do.
- `install.sh update-sui`: replace s-ui with the newest GitHub release
  (verifies the new binary, keeps a timestamped backup). Fresh
  installs now fetch the newest s-ui instead of a pinned version;
  `SUI_VERSION=x.y.z` pins one deliberately.
- Added `install.sh restore <file>` (restore `~/sui-vpn` from a
  backup) and `install.sh help`.
- README (EN + FA) rewritten as a full management guide: command
  reference table, user management, logs and health, backup and
  restore, full uninstall including the Cloudflare side.

## 2026-11-23

- First public release: s-ui panel + two Cloudflare quick tunnels +
  Workers subscription with per-user volume/expiry sync, Iran
  split-routing for sing-box clients, and a subscription secret
  (`SUB_SECRET`) for panel-generated links.
