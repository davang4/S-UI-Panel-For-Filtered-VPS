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
  `sui-sync.path` unit watching both tunnel logs.

Add a test before changing the behaviour it covers.
