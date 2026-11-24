#!/usr/bin/env python3
"""Sync s-ui clients -> Cloudflare Workers KV subscription values.

Reads the s-ui sqlite DB (clients table) + current quick-tunnel hostname
(parsed from the cloudflared log), builds one vless link per enabled,
non-expired client, base64-encodes it, and PUTs it to KV key sub:<uuid>
via the Cloudflare API. Also PUTs the panel quick-tunnel hostname to KV
key panel:host so the worker can proxy the panel at a fixed address.

Panel routing also syncs: the panel's client-side routing (s-ui setting
`subJsonExt` — the subscription JSON extension that s-ui merges into its
own sing-box JSON in sub/jsonService.go; falling back to the core
`config` setting's route/dns when the extension is empty) is read from
the same DB and PUT to KV key panel:subjson. The worker merges it into
the sing-box profile it builds, so a routing change made in the panel
reaches clients within ~60s + one subscription update, with no manual
step. When neither setting holds routing, the key is deleted and the
worker keeps its built-in Iran bypass. Writes only when a hostname, the
client set, or the panel routing changed (KV free-tier write limits).
Stdlib only.

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


_IR_HINTS = ("geosite-ir", "geoip-ir", "site-ir", "geosite:ir", "geoip:ir",
              "site-iran", "ip-iran", "category-ir")


def _mentions_iran(obj):
    return any(h in json.dumps(obj, ensure_ascii=False).lower()
               for h in _IR_HINTS)


def read_panel_routes():
    """Read the panel's client-side routing for the worker's sing-box JSON.

    First source: setting `subJsonExt` — the subscription JSON extension
    s-ui merges into its own client JSON (sub/jsonService.go addOthers:
    top-level dns / rules / rule_set / default_domain_resolver / final).
    Fallback: the core `config` setting's route/dns, used only when the
    extension is empty AND the core rules actually mention Iran — the
    stock core config only carries sniff + hijack-dns, which must never
    replace the worker's Iran bypass.
    Returns (routes_dict, source) or (None, None). Never raises.
    """
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        rows = dict(con.execute(
            "SELECT key, value FROM settings "
            "WHERE key IN ('subJsonExt','config')"
        ).fetchall())
        con.close()
    except Exception as e:
        print(f"sync: cannot read panel routing settings: {e}")
        return None, None
    ext_raw = (rows.get("subJsonExt") or "").strip()
    if ext_raw:
        try:
            ext = json.loads(ext_raw)
        except Exception:
            print("sync: subJsonExt is not valid JSON, ignoring panel routes")
            return None, None
        out = {}
        for key in ("dns", "rules", "rule_set",
                    "default_domain_resolver", "final"):
            if isinstance(ext, dict) and key in ext:
                out[key] = ext[key]
        return (out, "subJsonExt") if out else (None, None)
    cfg_raw = (rows.get("config") or "").strip()
    if cfg_raw:
        try:
            cfg = json.loads(cfg_raw)
        except Exception:
            return None, None
        route = cfg.get("route") or {} if isinstance(cfg, dict) else {}
        out = {}
        if isinstance(route, dict):
            if route.get("rules"):
                out["rules"] = route["rules"]
            if route.get("rule_set"):
                out["rule_set"] = route["rule_set"]
            if route.get("default_domain_resolver"):
                out["default_domain_resolver"] = route["default_domain_resolver"]
        if isinstance(cfg, dict) and cfg.get("dns"):
            out["dns"] = cfg["dns"]
        if out and _mentions_iran(out):
            return out, "config"
    return None, None


def build_link(client, hostname, ws_path):
    path = urllib.parse.quote(ws_path, safe="")
    remark = urllib.parse.quote(client["name"], safe="")
    return (
        f"vless://{client['uuid']}@{hostname}:443"
        f"?encryption=none&security=tls&sni={hostname}&type=ws"
        f"&path={path}&host={hostname}&fp=chrome#{remark}"
    )


def cf_request(env, method, path, body=None):
    req = urllib.request.Request(
        CF_API + path,
        method=method,
        data=body.encode() if isinstance(body, str) else body,
        headers={
            "Authorization": f"Bearer {env['CF_API_TOKEN']}",
            "Content-Type": "text/plain",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--hostname", default=None)
    args = ap.parse_args()

    env = load_state()
    hostname = args.hostname or tunnel_hostname()
    if not hostname:
        print("sync: no tunnel hostname yet, skipping")
        return 0
    panel_host = tunnel_hostname(PTLOG)
    ws_path = env.get("WS_PATH", "")
    if not ws_path.startswith("/"):
        ws_path = "/" + ws_path

    clients = read_clients()
    # Stable identity of THIS server/install (first client's UUID). The
    # installer reads it back at deploy time: if a KV namespace already
    # carries another server's id, the two servers are sharing one
    # Worker + KV by mistake (see README: Multiple servers).
    server_id = env.get("CLIENT_UUID", "")
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
                    "n": name_keys, "r": routes_json, "s": server_id},
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

    prev = {}
    if os.path.exists(HASHFILE):
        try:
            prev = json.load(open(HASHFILE))
        except Exception:
            prev = {}
    if prev.get("hash") == digest:
        print("sync: unchanged, no KV writes")
        return 0

    for key in ("CF_API_TOKEN", "CF_ACCOUNT_ID", "KV_NAMESPACE_ID"):
        if not env.get(key):
            print(f"sync: missing {key} in state.env, cannot write KV")
            return 1

    ns = f"/accounts/{env['CF_ACCOUNT_ID']}/storage/kv/namespaces/{env['KV_NAMESPACE_ID']}"
    for key, value in list(payload.items()) + list(name_keys.items()):
        r = cf_request(env, "PUT", f"{ns}/values/sub:{key}", value)
        if not r.get("success"):
            print(f"sync: KV PUT failed for {key}: {r.get('errors')}")
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
            print(f"sync: KV PUT server:id failed: {r.get('errors')}")
            return 1
        print(f"sync: server id stamped: {server_id}")
    if panel_host and prev.get("panel_host") != panel_host:
        r = cf_request(env, "PUT", f"{ns}/values/panel:host", panel_host)
        if not r.get("success"):
            print(f"sync: KV PUT panel:host failed: {r.get('errors')}")
            return 1
        print(f"sync: panel host updated: {panel_host}")
    if routes_json and prev.get("subjson") != routes_json:
        r = cf_request(env, "PUT", f"{ns}/values/panel:subjson", routes_json)
        if not r.get("success"):
            print(f"sync: KV PUT panel:subjson failed: {r.get('errors')}")
            return 1
        print(f"sync: panel routes updated (from {routes_source})")
    elif not routes_json and prev.get("subjson"):
        cf_request(env, "DELETE", f"{ns}/values/panel:subjson")
        print("sync: panel routes cleared (worker keeps built-in Iran bypass)")

    with open(HASHFILE, "w") as f:
        json.dump({"hash": digest, "uuids": sorted(payload),
                   "names": sorted(name_keys),
                   "panel_host": panel_host, "subjson": routes_json,
                   "routes_source": routes_source,
                   "server_id": server_id}, f)
    os.chmod(HASHFILE, 0o600)
    print(f"sync: wrote {len(payload)} subscription(s) "
          f"(+{len(name_keys)} name keys) for {hostname}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
