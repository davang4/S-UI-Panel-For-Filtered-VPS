#!/usr/bin/env python3
"""Sync s-ui clients -> Cloudflare Workers KV subscription values.

Reads the s-ui sqlite DB (clients table) + current quick-tunnel hostname
(parsed from the cloudflared log), builds one vless link per enabled,
non-expired client, base64-encodes it, and PUTs it to KV key sub:<uuid>
via the Cloudflare API. Also PUTs the panel quick-tunnel hostname to KV
key panel:host so the worker can proxy the panel at a fixed address.

Panel routing also syncs: the panel's client-side routing is read from
the same DB — from all three places s-ui keeps it (`subJsonExt`, the
`subJson` template, the core `config` route/dns) — and PUT to KV key
panel:subjson. The worker merges it into the sing-box profile it
builds, so a routing change made in the panel reaches clients within
~60s + one subscription update, with no manual step. When no source
holds routing, the key is deleted and the worker keeps its built-in
Iran bypass. Writes only when a hostname, the client set, or the panel
routing changed (KV free-tier write limits).

A tunnel URL change triggers a sync at once (systemd path unit), and
every run records `last_run` + `last_error` in sync-state.json for
`install.sh status`. Log lines never print secrets: UUIDs are masked,
a failed KV write names the client by name, and the panel hostname is
not repeated in the journal. Stdlib only.

Usage:
  sync.py [--dry-run] [--hostname HOST]
Env (from state.env, sourced by caller or read via --state):
  CF_API_TOKEN, CF_ACCOUNT_ID, KV_NAMESPACE_ID, WS_PATH,
  WORKER_URL, SUB_SECRET (only used by --dry-run to print full sub links)
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
import urllib.parse
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(DIR, "state.env")
DB = os.path.join(DIR, "db", "s-ui.db")
TLOG = os.path.join(DIR, "tunnel.log")
PTLOG = os.path.join(DIR, "panel-tunnel.log")
HASHFILE = os.path.join(DIR, "sync-state.json")
CF_API = "https://api.cloudflare.com/client/v4"


def load_state():
    env = {}
    if os.path.exists(STATE):
        with open(STATE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("CF_API_TOKEN", "CF_ACCOUNT_ID", "KV_NAMESPACE_ID", "WS_PATH",
              "WORKER_URL", "SUB_SECRET"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def tunnel_hostname(logfile=None):
    logfile = logfile or TLOG
    if not os.path.exists(logfile):
        return None
    with open(logfile, errors="replace") as f:
        text = f.read()
    # Only look after the last quick-tunnel request, so a stale URL from a
    # previous cloudflared run is never reused.
    idx = text.rfind("Requesting new quick Tunnel")
    segment = text[idx:] if idx >= 0 else text
    urls = re.findall(r"https://([a-z0-9-]+\.trycloudflare\.com)", segment)
    return urls[-1] if urls else None


def read_clients():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    now = int(time.time())
    clients = []
    for row in con.execute(
        "SELECT name, enable, config, volume, expiry, up, down FROM clients"
    ):
        if not row["enable"]:
            continue
        if row["expiry"] and row["expiry"] > 0 and row["expiry"] <= now:
            continue
        if row["volume"] and row["volume"] > 0 and (row["up"] + row["down"]) >= row["volume"]:
            continue
        try:
            cfg = json.loads(row["config"] or "{}")
            uuid = (cfg.get("vless") or {}).get("uuid", "")
        except Exception:
            continue
        if not uuid:
            continue
        clients.append({"name": row["name"], "uuid": uuid.lower()})
    con.close()
    return sorted(clients, key=lambda c: c["uuid"])


def _panel_source(raw, keys):
    """Parse one panel routing source. Returns the picked keys or {}.
    `keys` are the top-level sing-box keys sync understands (dns, rules,
    rule_set, default_domain_resolver, final). Never raises.
    """
    if not (raw or "").strip():
        return {}
    try:
        obj = json.loads(raw)
    except Exception:
        return {}
    if not isinstance(obj, dict):
        return {}
    return {k: obj[k] for k in keys if k in obj}


def read_panel_routes():
    """Read the panel's client-side routing for the worker's sing-box JSON.

    Every routing setting made in the panel applies — from all three
    places s-ui keeps it, in this priority order:
      1. `subJsonExt` — the subscription JSON extension (the panel's
         advanced interface / Rules page: dns, rules, rule_set,
         default_domain_resolver, final);
      2. `subJson` — the subscription JSON template, when the panel
         stores routing there instead;
      3. `config` — the core sing-box config's route/dns.
    Single-value keys (dns, final, default_domain_resolver) come from
    the highest-priority source that sets them; `rules` and `rule_set`
    are concatenated from all sources, so a rule set in any place
    reaches the clients. The worker keeps its built-in Iran bypass
    first regardless, so a stock template rule routing Iran to the
    proxy can never undo it. Returns (routes_dict, source) where source
    names the contributing sources (e.g. "subJsonExt+config"), or
    (None, None). Never raises.
    """
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        rows = dict(con.execute(
            "SELECT key, value FROM settings "
            "WHERE key IN ('subJsonExt','subJson','config')"
        ).fetchall())
        con.close()
    except Exception as e:
        print(f"sync: cannot read panel routing settings: {e}")
        return None, None
    single_keys = ("dns", "default_domain_resolver", "final")
    ext = _panel_source(rows.get("subJsonExt"), single_keys + ("rules", "rule_set"))
    tpl = _panel_source(rows.get("subJson"), single_keys + ("rules", "rule_set"))
    cfg = {}
    cfg_raw = (rows.get("config") or "").strip()
    if cfg_raw:
        try:
            cfg_obj = json.loads(cfg_raw)
        except Exception:
            cfg_obj = None
        if isinstance(cfg_obj, dict):
            route = cfg_obj.get("route") or {}
            if isinstance(route, dict):
                for k in ("rules", "rule_set", "default_domain_resolver"):
                    if route.get(k):
                        cfg[k] = route[k]
            if cfg_obj.get("dns"):
                cfg["dns"] = cfg_obj["dns"]
    sources = [name for name, src in
               (("subJsonExt", ext), ("subJson", tpl), ("config", cfg)) if src]
    if not sources:
        return None, None
    out = {}
    for key in single_keys:
        for src in (ext, tpl, cfg):
            if key in src:
                out[key] = src[key]
                break
    rules = []
    for src in (ext, tpl, cfg):
        if isinstance(src.get("rules"), list):
            rules.extend(src["rules"])
    if rules:
        out["rules"] = rules
    rule_sets = []
    seen_tags = set()
    for src in (ext, tpl, cfg):
        if isinstance(src.get("rule_set"), list):
            for rs in src["rule_set"]:
                tag = rs.get("tag") if isinstance(rs, dict) else None
                if tag and tag in seen_tags:
                    continue
                if tag:
                    seen_tags.add(tag)
                rule_sets.append(rs)
    if rule_sets:
        out["rule_set"] = rule_sets
    return (out, "+".join(sources)) if out else (None, None)


def build_link(client, hostname, ws_path):
    path = urllib.parse.quote(ws_path, safe="")
    remark = urllib.parse.quote(client["name"], safe="")
    return (
        f"vless://{client['uuid']}@{hostname}:443"
        f"?encryption=none&security=tls&sni={hostname}&type=ws"
        f"&path={path}&host={hostname}&fp=chrome#{remark}"
    )


def cf_request(env, method, path, body=None, attempts=3):
    # One Cloudflare API call, retried with backoff on transient failure
    # (network blip, 5xx, rate limit). A 404 (deleted namespace/account)
    # or 403 (bad token) is not transient — report it at once instead of
    # crashing with a traceback, so the caller prints a clean error.
    # Never raises: the caller decides what a failed call means.
    last = {"success": False,
            "errors": [{"code": -1, "message": "no attempt made"}]}
    for attempt in range(attempts):
        req = urllib.request.Request(
            CF_API + path,
            method=method,
            data=body.encode() if isinstance(body, str) else body,
            headers={
                "Authorization": f"Bearer {env['CF_API_TOKEN']}",
                "Content-Type": "text/plain",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            try:
                last = json.loads(e.read().decode())
            except Exception:
                last = {"success": False,
                        "errors": [{"code": e.code, "message": str(e)}]}
            if e.code in (403, 404):
                return last
        except Exception as e:  # URLError, timeout, ...
            last = {"success": False,
                    "errors": [{"code": -1, "message": str(e)}]}
        if attempt < attempts - 1:
            time.sleep(2 * (attempt + 1))
    return last


def _mask(value, keep=8):
    # Shorten a credential for log output: first `keep` chars + "…".
    # The sync timer's stdout goes to the systemd journal, a persistent
    # log — full UUIDs, tunnel hostnames and sub links must never land
    # there. The real values stay in state.env, `show`, and --dry-run.
    value = str(value or "")
    return value[:keep] + "…" if len(value) > keep else value


def save_run_state(prev, last_error):
    # Record when the sync last ran and whether it failed, in the same
    # state file the installer/status reads. Preserves the previous
    # hash/uuids/etc. so a failed run still retries its KV writes next
    # time. Never raises.
    try:
        state = dict(prev or {})
        state["last_run"] = int(time.time())
        state["last_error"] = last_error
        with open(HASHFILE, "w") as f:
            json.dump(state, f)
        os.chmod(HASHFILE, 0o600)
    except Exception:
        pass


def _load_prev():
    if os.path.exists(HASHFILE):
        try:
            return json.load(open(HASHFILE))
        except Exception:
            return {}
    return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="write to KV even if the digest is unchanged "
                         "(use after a Worker/KV move, or when the KV was "
                         "overwritten by another server sharing it)")
    ap.add_argument("--hostname", default=None)
    args = ap.parse_args()

    env = load_state()
    prev = _load_prev()
    hostname = args.hostname or tunnel_hostname()
    if not hostname:
        print("sync: no tunnel hostname yet, skipping")
        if not args.dry_run:
            save_run_state(prev, "no tunnel hostname yet")
        return 0
    panel_host = tunnel_hostname(PTLOG)
    ws_path = env.get("WS_PATH", "")
    if not ws_path.startswith("/"):
        ws_path = "/" + ws_path

    clients = read_clients()
    uuid_name = {c["uuid"]: c["name"] for c in clients}

    def describe(key):
        # Log lines name the client by name; a bare UUID is a credential
        # (it is the password inside the vless link), so mask it.
        if key in uuid_name:
            return uuid_name[key]
        if re.fullmatch(r"[0-9a-fA-F-]{36}", key or ""):
            return _mask(key)
        return key

    # Stable identity of THIS server/install (first client's UUID). The
    # installer reads it back at deploy time: if a KV namespace already
    # carries another server's id, the two servers are sharing one
    # Worker + KV by mistake (see README: Multiple servers). The short
    # server code (first 8 chars) is stamped alongside it, so the
    # installer can recognise this server's namespace even when
    # state.env is gone.
    server_id = env.get("CLIENT_UUID", "")
    server_code = server_id[:8] if server_id else ""
    payload = {}
    name_keys = {}
    for c in clients:
        link = build_link(c, hostname, ws_path)
        b64 = base64.b64encode(link.encode()).decode()
        payload[c["uuid"]] = b64
        # s-ui builds the panel subscription link from the client NAME
        # (subURI + name), so publish the same value under sub:<name> too.
        # A name containing "/" would break the /sub/<id> path; skip it.
        if "/" not in c["name"]:
            name_keys[c["name"]] = b64
    routes, routes_source = read_panel_routes()
    routes_json = (json.dumps(routes, sort_keys=True, ensure_ascii=False)
                   if routes else None)

    digest = hashlib.sha256(
        json.dumps({"h": hostname, "ph": panel_host, "p": payload,
                    "n": name_keys, "r": routes_json, "s": server_id,
                    "c": server_code},
                   sort_keys=True).encode()
    ).hexdigest()

    if args.dry_run:
        print(f"hostname: {hostname}")
        print(f"panel host: {panel_host}")
        print(f"clients: {len(clients)}")
        worker_url = env.get("WORKER_URL", "").rstrip("/")
        sub_secret = env.get("SUB_SECRET", "")
        for c in clients:
            print(f"  {c['name']} {c['uuid']}")
            print(f"    link: {build_link(c, hostname, ws_path)}")
            print(f"    sub(b64): {payload[c['uuid']]}")
            if worker_url:
                prefix = f"{worker_url}/sub/"
                if sub_secret:
                    prefix += sub_secret + "/"
                print(f"    sub by uuid: {prefix}{c['uuid']}")
                print(f"    sub by name: {prefix}{c['name']}")
            else:
                print(f"    sub by name: sub:{c['name']}")
        print(f"server id: {server_id or '(none)'}")
        print(f"panel routes: {routes_source or 'none (worker keeps built-in Iran bypass)'}")
        if routes_json:
            print(f"  {routes_json[:500]}")
        print(f"hash: {digest}")
        return 0

    if not args.force and prev.get("hash") == digest:
        print("sync: unchanged, no KV writes")
        if not args.dry_run:
            save_run_state(prev, None)
        return 0

    for key in ("CF_API_TOKEN", "CF_ACCOUNT_ID", "KV_NAMESPACE_ID"):
        if not env.get(key):
            print(f"sync: missing {key} in state.env, cannot write KV")
            save_run_state(prev, f"missing {key} in state.env")
            return 1

    ns = f"/accounts/{env['CF_ACCOUNT_ID']}/storage/kv/namespaces/{env['KV_NAMESPACE_ID']}"
    for key, value in list(payload.items()) + list(name_keys.items()):
        r = cf_request(env, "PUT", f"{ns}/values/sub:{key}", value)
        if not r.get("success"):
            err = f"KV PUT failed for {describe(key)}: {r.get('errors')}"
            print(f"sync: {err}")
            save_run_state(prev, err)
            return 1
    for uuid in prev.get("uuids", []):
        if uuid not in payload:
            cf_request(env, "DELETE", f"{ns}/values/sub:{uuid}")
    for nm in prev.get("names", []):
        if nm not in name_keys:
            cf_request(env, "DELETE", f"{ns}/values/sub:{nm}")
    if server_id and prev.get("server_id") != server_id:
        r = cf_request(env, "PUT", f"{ns}/values/server:id", server_id)
        if not r.get("success"):
            err = f"KV PUT server:id failed: {r.get('errors')}"
            print(f"sync: {err}")
            save_run_state(prev, err)
            return 1
        print(f"sync: server id stamped: {_mask(server_id)}")
    if server_code and prev.get("server_code") != server_code:
        r = cf_request(env, "PUT", f"{ns}/values/server:code", server_code)
        if not r.get("success"):
            err = f"KV PUT server:code failed: {r.get('errors')}"
            print(f"sync: {err}")
            save_run_state(prev, err)
            return 1
        print(f"sync: server code stamped: {server_code}")
    if panel_host and prev.get("panel_host") != panel_host:
        r = cf_request(env, "PUT", f"{ns}/values/panel:host", panel_host)
        if not r.get("success"):
            err = f"KV PUT panel:host failed: {r.get('errors')}"
            print(f"sync: {err}")
            save_run_state(prev, err)
            return 1
        # The address itself stays in panel-tunnel.log (and `show`); the
        # journal only needs to know that it changed.
        print("sync: panel host updated")
    if routes_json and prev.get("subjson") != routes_json:
        r = cf_request(env, "PUT", f"{ns}/values/panel:subjson", routes_json)
        if not r.get("success"):
            err = f"KV PUT panel:subjson failed: {r.get('errors')}"
            print(f"sync: {err}")
            save_run_state(prev, err)
            return 1
        print(f"sync: panel routes updated (from {routes_source})")
    elif not routes_json and prev.get("subjson"):
        cf_request(env, "DELETE", f"{ns}/values/panel:subjson")
        print("sync: panel routes cleared (worker keeps built-in Iran bypass)")

    save_run_state({"hash": digest, "uuids": sorted(payload),
                    "names": sorted(name_keys),
                    "panel_host": panel_host, "subjson": routes_json,
                    "routes_source": routes_source,
                    "server_id": server_id,
                    "server_code": server_code}, None)
    # The hostname is in tunnel.log and `show`; the journal line does
    # not repeat it.
    print(f"sync: wrote {len(payload)} subscription(s) "
          f"(+{len(name_keys)} name keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
