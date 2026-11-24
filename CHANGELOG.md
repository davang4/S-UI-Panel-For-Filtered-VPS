# Changelog

All notable changes to this project, in reverse chronological order.
Dates are in Asia/Tehran time.

## 2026-11-24

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
