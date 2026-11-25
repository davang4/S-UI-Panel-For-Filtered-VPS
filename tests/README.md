# Tests

Run the whole suite from the repo root — no network access, no root,
no systemd needed (the Cloudflare API and `systemctl`/`curl` are
stubbed):

```bash
python3 tests/test_sync.py    # sync: routing merge, masking, retry, run state
node tests/test_worker.mjs    # worker: panel-rule guards, profile, /health
bash tests/test_install.sh    # installer: health check, pre-change backup, path unit
bash -n install.sh            # installer syntax
```

What is covered:

- `test_sync.py` — panel routing merged from all three panel sources
  (`subJsonExt`, `subJson`, `config`) with no Iran gate; single-value
  priority; secrets masked in journal lines (no full UUID, no tunnel
  hostname); a failed KV write names the client by name; Cloudflare
  calls retried with backoff, 403/404 not retried; every run records
  `last_run` + `last_error`; `--dry-run` writes no state.
- `test_worker.mjs` — the built-in Iran bypass stays first; a valid
  panel block/direct rule applies; a rule naming an unknown outbound
  or an undefined rule-set is dropped; the panel rule-set merges in;
  `/health` answers `ok`; a plain user-agent still gets the base64 link.
- `test_install.sh` — `run_checks` reports the worker `/sub`, the
  panel via its tunnel, and the last sync state (fresh / error /
  stale / none); `backup_before_change` snapshots DB + state +
  sync-state.json and keeps only the last 5; `write_units` writes the
  `sui-sync.path` unit watching both tunnel logs; the server code is
  the first 8 chars of the identity UUID; `find_own_namespace` finds
  this server's namespace by `server:id` (and falls back to
  `server:code`); `worker_own_namespace` adopts our own worker and
  refuses another server's; the namespace-owner guard allows ours
  and stops on another server's; the SUB_SECRET is recovered from
  the panel's subURI; both global links (`sui-vpn`, `filtersui`)
  point at install.sh and are removed together; `uninstall` and
  `change-subdomain` abort on N and apply on y; the menu runs a
  command by number, loops, rejects an invalid number, quits on q,
  and exits at once on EOF; the dispatch maps numbers and names to
  commands and opens the menu with no argument; the menu header
  prints the fixed panel address first, then the server code, and
  shows the banner; the menu labels are in English and it runs
  `restore` with no path (restore lists backups itself) and `version`
  by number 13; the dispatch maps 13/`version` to `version`;
  `update-sui` does nothing when s-ui is already the latest version
  (or the same version after download), swaps in a newer version,
  and asks first on a major-version jump (aborts on N, swaps on y);
  the banner holds the funnel, the boxed name + version, and grows
  with a longer version; `version` prints all three versions;
  `tar-progress.sh` draws the bar at 0/50/100% and clamps; `backup`
  writes the file and prints its path, size and download command;
  `restore` lists on-server backups (auto + manual), restores the
  picked number or a given path, says so when there are none, and
  rejects an out-of-range number.

Add a test before changing the behaviour it covers.
