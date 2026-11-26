# Changelog

All notable changes to this project, in reverse chronological order.
Dates are in Asia/Tehran time.

## 2026-11-26

- **Port-squatter guard (filtersui 1.1.0).** A stray s-ui process
  holding the panel port used to make `sui-panel` crash-loop silently
  (server 2, 2026-11-25: restart counter past 325, secret-path login
  served by the stray instance instead of the real panel). Now
  `status` names the squatter (`FAIL panel port 2095 held by another
  process: 821 (sui)`), and `install` / `update-sui` refuse to
  restart the panel while one holds the port, telling you the exact
  fix (`sudo fuser -k 2095/tcp`, then re-run). Nothing is killed
  automatically — killing is always the operator's call.
- **Client names with a space (or any special character) sync now.**
  The sync PUT the KV key `sub:<name>` into the request URL raw, so
  a name like "Heydari colocrossing" made the request itself invalid
  ("URL can't contain control characters") and aborted the whole sync
  — the new client never reached KV and its subscription did not work.
  The key is now percent-encoded in the URL (`sub:Heydari%20…`); the
  key stored in KV keeps the original name, so the Worker's lookup is
  unchanged. Also, one client's PUT failing no longer blocks the rest:
  the others still sync, the run still reports failure, and the old
  state is kept so the next run retries the failed key.

## 2026-11-25

- **geoip-ir is served by the Worker itself.** `GET /geoip-ir.srs`
  fetches the Iran IP list from GitHub once and keeps it in
  `caches.default` (fresh 24 h, stale copy 30 d); the profile points
  the `geoip-ir` rule-set at the Worker and downloads it directly
  (`direct-http`, no proxy detour), so sing-box startup no longer
  depends on GitHub being reachable at that moment or on the tunnel
  being up. Before this, the phone downloaded the file from GitHub
  through the VPN, so a server reboot or a GitHub 502 made sing-box
  refuse to start at all (seen 2026-11-25 after rebooting server 2).

- **filtersui version + banner + `version` command.** The installer
  has its own version now (`FILTERSUI_VERSION="1.0.0"`, semver: PATCH
  for fixes, MINOR for features, MAJOR for breaking changes).
  `sudo filtersui version` prints it together with the s-ui and
  cloudflared versions. The menu opens with a banner — a filter
  funnel drawn with lines over the boxed name + version (the box
  width follows the version, so it stays aligned); `show`, `status`
  and the SAVE block end with the one-line banner. The menu's item
  descriptions are now in English.
- **Progress bar for backup and restore.** On a terminal, both show
  `backup: [##########----------] 50%` on one line, driven by GNU
  tar `--checkpoint` calling `tar-progress.sh` (shipped to
  `~/sui-vpn/` by install); ~50 updates per run, no extra dependency.
  Off the terminal (or without GNU tar / the helper script) plain
  `tar` runs instead, so nothing breaks. The tar operation uses the
  dashed form (`-czf`/`-xzf`): with long options before it, GNU tar
  only accepts the dashed form as the operation.
- **Restore lists backups; backup says where it went.** `restore`
  with no file lists the backups on this server (auto pre-change
  snapshots + manual backups, newest first, with kind, date and
  size) and restores the one picked by number; a path still works
  for a backup copied in from outside, and with no backups at all it
  says so. `backup` prints the file's path, its size, and the `scp`
  command to download it (SFTP as the fallback).

- **Version check in `update-sui`.** It compares the installed
  s-ui version with the latest GitHub release first (or with the
  pinned `SUI_VERSION`): when s-ui is already the latest it says so
  and does nothing — no download, no restart, no re-install. The
  downloaded binary's version is checked again before the swap, so
  an unreachable GitHub API still cannot re-install the same
  version. A major-version jump (1.x → 2.x) asks first, because a
  new major version can reset the panel database on first start;
  answering N leaves the current binary untouched. `update-sui`
  itself never touches the database — a wipe after an update comes
  from the new binary's own migration (see TROUBLESHOOTING).
- **Menu header: fixed panel address first.** The `filtersui` menu
  prints `Panel (fixed): …` first, then the server code — the same
  order as `show` and the SAVE block.

- **Numbered menu (`filtersui`).** `sudo filtersui` with no command
  opens a numbered menu of every command (install, show, status,
  sync-now, deploy-worker, change-subdomain, update-sui, panel-on/off,
  backup, restore, uninstall) — pick a number, no need to type the
  command name; the menu comes back after each action until 0/q, and
  a number also works as a direct argument (`sudo filtersui 3` runs
  `status`). The menu shows the server code at the top, requires
  root, and exits at once on stdin EOF. `sudo sui-vpn <command>`
  still works from any directory; `filtersui` is a second link to the
  same script. Running with no command used to start a full install —
  now it opens the menu (install explicitly with `install`). The
  destructive actions always ask first, in the menu and on the
  command line: `uninstall`, `change-subdomain` (account-wide) and
  `restore` already did.
- **Server code: every server's Cloudflare identity.** Each server
  now has one short unique code — the first 8 characters of its
  identity UUID (`SERVER_CODE` in state.env, shown by `show` and in
  the SAVE block) — stamped in KV as `server:code` next to
  `server:id`, so everything on Cloudflare for that server is tied
  to that code. A re-run reuses its stored Worker + KV, never creates
  new ones. And if `state.env` is ever lost, `deploy-worker`
  recognises the server by itself before creating anything new: it
  scans the account's KV namespaces for one whose `server:id` (or
  `server:code`) matches a client UUID in this panel's DB, and adopts
  that Worker + KV — recovering the worker name, the namespace id,
  the client UUID and the SUB_SECRET (from the panel's subURI) — so
  the fixed address never changes. A requested Worker name taken by
  this server's own Worker is adopted the same way. The old
  warn-and-wait-10-seconds guard is now a hard stop: a namespace that
  belongs to another server refuses the deploy outright.
- **Real health check in `status`.** `run_checks` used to call a
  process "alive" and stop there. It now also fetches the Worker's
  `/health`, fetches this client's own `/sub` URL from the Worker
  (KV + Worker + the client's key in one call), loads the panel login
  page through its own tunnel, and reports the last sync run (when
  it ran, and its error if it failed). `status` runs the same checks.
- **Auto-backup before a change.** `update-sui` and a re-install now
  snapshot the s-ui DB + state to `~/sui-vpn/backups/` (last 5 kept,
  mode 600) before touching anything, so a bad new binary can never
  take the clients and secrets with it. The manual `backup` command
  is unchanged.
- **Sync is immediate on a tunnel change, and honest about failure.**
  A new `sui-sync.path` unit triggers a sync the moment a tunnel log
  changes (a quick tunnel gets a new hostname on every restart; the
  60 s timer would leave the old address in KV for up to a minute).
  Each Cloudflare API call is retried with backoff (3 attempts) on
  transient failure; 403/404 is reported at once, never retried.
  Every run records `last_run` + `last_error` in `sync-state.json`,
  which `status` reads.
- **Secrets audit + rotation docs.** The sync timer's journal lines
  no longer print secret values: a stamped server id shows its first
  8 characters, a failed KV write names the client by name (not by
  UUID), and a panel-host change is logged without the hostname.
  `docs/SECURITY.md` now documents what is printed where, and how to
  rotate the Cloudflare token, the SUB_SECRET, the panel password, or
  one client's UUID when something leaks. Nothing that the user
  reads — the SAVE block, `show`, `--dry-run` — changed.
- **Panel routing now applies from everywhere in the panel.** The
  sync used to read only `subJsonExt`, falling back to the core
  `config` route/dns only when it mentioned Iran. It now reads all
  three routing sources (`subJsonExt`, the `subJson` template, the
  core `config` route/dns): single-value settings come from the
  highest-priority source, `rules` and `rule_set` are combined from
  all three. The Worker still evaluates its built-in Iran bypass
  first (an explicit Iran→proxy panel rule will not take effect), and
  now drops panel rules naming an unknown outbound or an undefined
  rule-set instead of letting one bad rule break the profile for
  every client. Panel routing still reaches only the sing-box JSON
  profile — Hiddify/v2rayNG get a base64 link with no routing.
- **Docs:** a "Panel routing" guide in both READMEs (where to set
  rules, examples for ads/China/Iran, the bypass exception, the
  base64 limit), a "Supported versions" section, a key-rotation
  section in `docs/SECURITY.md`, and new troubleshooting entries
  (last-sync failures, a panel rule that does not apply).
- **Tests:** `tests/` now ships with the repo — sync routing merge +
  masking + retry, the worker's rule guards, and the installer's
  health check + pre-change backup — so these behaviours are checked
  on every change, not just by hand.

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
