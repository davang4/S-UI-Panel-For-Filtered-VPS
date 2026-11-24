# Changelog

All notable changes to this project, in reverse chronological order.
Dates are in Asia/Tehran time.

## 2026-11-24

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
