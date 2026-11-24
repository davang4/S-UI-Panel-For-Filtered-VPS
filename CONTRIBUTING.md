# Contributing

Issues and pull requests are welcome. Please keep the project's
promises: one-command install, no public ports, no domain required,
and no secret ever committed.

## Before opening a PR

- Read `docs/ARCHITECTURE.md` and `docs/SECURITY.md` first.
- `bash -n install.sh` must pass; Python files must compile
  (`python3 -m py_compile sync.py sui_setup.py`).
- If you touch `worker.js`, test it with the harness pattern in the
  repo history: import the module in Node with a mocked KV env and
  check `/health`, `/sub/<id>` (base64 and sing-box JSON), and the
  `SUB_SECRET` behaviour.
- If you touch the installer, test a fresh install on a throwaway
  Ubuntu/Debian VPS — never on a server that runs a live panel.
- Never commit `state.env`, tokens, UUIDs, passwords, or tunnel
  hostnames. The `.gitignore` covers the generated files; keep it
  that way.
- Update the README (EN **and** FA), `CHANGELOG.md`, and the relevant
  doc under `docs/` in the same PR.
- Keep the one-command install working: the installer must still run
  end-to-end from a bare `tar.gz` download with nothing but the
  Cloudflare token asked interactively.

## Reporting a problem

Open an issue with: what you ran (exact command), what you expected,
what happened (exact output or log lines from `install.sh status`),
your OS, and the s-ui version (`install.sh status` does not show it —
run `~/sui-vpn/bin/sui -v`). Do not paste secrets, tokens, UUIDs, or
subscription links in issues.
