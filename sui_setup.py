#!/usr/bin/env python3
"""Create the VLESS-WS inbound + first client in s-ui via its panel API.

Idempotent: if an inbound with our tag already exists, nothing is changed.
Stdlib only. Reads PANEL_USER/PANEL_PASS/WS_PATH/CLIENT_UUID/CLIENT_NAME/
PANEL_BASE_PATH/PANEL_PORT/IN_PORT from state.env next to this script
(or environment). The panel API lives under the secret base path:
<base>api (default /app/api).
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar

DIR = os.path.dirname(os.path.abspath(__file__))
TAG = "vless-ws-tunnel"


def load_state():
    env = {}
    p = os.path.join(DIR, "state.env")
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    env.update({k: v for k, v in os.environ.items() if k in
                ("PANEL_USER", "PANEL_PASS", "WS_PATH", "CLIENT_UUID",
                 "CLIENT_NAME", "PANEL_BASE_PATH", "PANEL_PORT", "IN_PORT")})
    return env


def panel_api_base(env):
    base = env.get("PANEL_BASE_PATH") or "/app/"
    if not base.startswith("/"):
        base = "/" + base
    if not base.endswith("/"):
        base += "/"
    port = env.get("PANEL_PORT") or "2095"
    return f"http://127.0.0.1:{port}" + base + "api"


def inbound_port(env):
    try:
        return int(env.get("IN_PORT") or 10087)
    except ValueError:
        return 10087


def main():
    env = load_state()
    base = panel_api_base(env)
    origin = "http://127.0.0.1:" + (env.get("PANEL_PORT") or "2095")
    ws_path = env.get("WS_PATH", "")
    if not ws_path.startswith("/"):
        ws_path = "/" + ws_path
    cj = CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    def call(method, path, form=None):
        data = urllib.parse.urlencode(form).encode() if form else None
        req = urllib.request.Request(base + path, data=data, method=method)
        # s-ui's SameOrigin guard rejects POSTs whose Origin host differs
        # from the Host header, so it must match the panel's real address.
        req.add_header("Origin", origin)
        req.add_header("X-Requested-With", "XMLHttpRequest")
        with opener.open(req, timeout=30) as r:
            return json.loads(r.read().decode())

    r = call("POST", "/login", {"user": env["PANEL_USER"], "pass": env["PANEL_PASS"]})
    if not r.get("success"):
        print(f"setup: panel login failed: {r}")
        return 1

    existing = call("GET", "/inbounds")
    inbounds = (existing.get("obj") or {}).get("inbounds") or []
    inbound_id = None
    for ib in inbounds:
        if ib.get("tag") == TAG:
            inbound_id = ib.get("id")
            break

    if inbound_id is None:
        inbound = {
            "type": "vless",
            "tag": TAG,
            "listen": "127.0.0.1",
            "listen_port": inbound_port(env),
            "transport": {"type": "ws", "path": ws_path},
        }
        r = call("POST", "/save", {
            "object": "inbounds", "action": "new",
            "data": json.dumps(inbound), "initUsers": "",
        })
        if not r.get("success"):
            print(f"setup: inbound save failed: {r}")
            return 1
        existing = call("GET", "/inbounds")
        for ib in (existing.get("obj") or {}).get("inbounds") or []:
            if ib.get("tag") == TAG:
                inbound_id = ib.get("id")
        if inbound_id is None:
            print("setup: inbound created but id not found")
            return 1
        print(f"setup: inbound {TAG} created (id={inbound_id})")
    else:
        print(f"setup: inbound {TAG} already exists (id={inbound_id})")

    clients_r = call("GET", "/clients")
    clients = (clients_r.get("obj") or {}).get("clients") or []
    if any(c.get("name") == env["CLIENT_NAME"] for c in clients):
        print(f"setup: client {env['CLIENT_NAME']} already exists")
        return 0

    client = {
        "name": env["CLIENT_NAME"],
        "enable": True,
        "config": {"vless": {"uuid": env["CLIENT_UUID"]}},
        "inbounds": [inbound_id],
        "links": [],
        "volume": 0,
        "expiry": 0,
    }
    r = call("POST", "/save", {
        "object": "clients", "action": "new", "data": json.dumps(client),
    })
    if not r.get("success"):
        print(f"setup: client save failed: {r}")
        return 1
    print(f"setup: client {env['CLIENT_NAME']} created")
    return 0


if __name__ == "__main__":
    sys.exit(main())
