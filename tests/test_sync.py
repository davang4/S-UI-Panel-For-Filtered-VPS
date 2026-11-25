#!/usr/bin/env python3
"""Tests for sync.py — run from the repo root:  python3 tests/test_sync.py

Covers the behaviours added 2026-11-25: panel routing merged from all
three panel sources (subJsonExt, subJson, config) with no Iran gate;
secrets masked in journal lines; Cloudflare calls retried with
backoff; every run records last_run + last_error in sync-state.json.
No network access: the Cloudflare API is stubbed out.
"""
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import sync  # noqa: E402

UUID1 = "5c0b21ef-178a-4b3e-b0f3-4a813e7073ee"
UUID2 = "6d1c32f0-289b-5c4f-c1g4-5b924f8184ff".replace("g", "0")


def make_env(tmp):
    """A fake install dir with a DB (two clients + routing settings),
    a tunnel log, and a state.env. Module paths are pointed at it."""
    dbdir = os.path.join(tmp, "db")
    os.makedirs(dbdir, exist_ok=True)
    db = os.path.join(dbdir, "s-ui.db")
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE clients "
                "(name TEXT, enable INTEGER, config TEXT, volume INTEGER,"
                " expiry INTEGER, up INTEGER, down INTEGER)")
    for name, uuid in (("davang", UUID1), ("friend", UUID2)):
        con.execute("INSERT INTO clients VALUES (?,?,?,?,?,?,?)",
                    (name, 1, json.dumps({"vless": {"uuid": uuid}}),
                     0, 0, 0, 0))
    con.execute("CREATE TABLE settings (key TEXT, value TEXT)")
    con.commit()
    con.close()
    with open(os.path.join(tmp, "tunnel.log"), "w") as f:
        f.write("Requesting new quick Tunnel\n"
                "https://abc-try-123.trycloudflare.com\n")
    with open(os.path.join(tmp, "panel-tunnel.log"), "w") as f:
        f.write("Requesting new quick Tunnel\n"
                "https://panel-try-456.trycloudflare.com\n")
    with open(os.path.join(tmp, "state.env"), "w") as f:
        f.write("CF_API_TOKEN=fake-token\n"
                "CF_ACCOUNT_ID=acct1\n"
                "KV_NAMESPACE_ID=ns1\n"
                "CLIENT_UUID=%s\n" % UUID1)
    sync.DIR = tmp
    sync.STATE = os.path.join(tmp, "state.env")
    sync.DB = db
    sync.TLOG = os.path.join(tmp, "tunnel.log")
    sync.PTLOG = os.path.join(tmp, "panel-tunnel.log")
    sync.HASHFILE = os.path.join(tmp, "sync-state.json")
    return db


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = make_env(self.tmp)

    def set_settings(self, **kw):
        con = sqlite3.connect(self.db)
        con.execute("DELETE FROM settings")
        for k, v in kw.items():
            con.execute("INSERT INTO settings VALUES (?, ?)",
                        (k, json.dumps(v)))
        con.commit()
        con.close()

    def test_merges_all_three_sources(self):
        self.set_settings(
            subJsonExt={"rules": [{"domain_suffix": ["ads.example"],
                                   "outbound": "block"}],
                        "final": "proxy"},
            subJson={"rules": [{"domain_suffix": ["tpl.example"],
                                "outbound": "direct"}]},
            config={"route": {"rules": [{"domain_suffix": ["core.example"],
                                         "outbound": "direct"}]},
                    "dns": {"servers": [{"tag": "c", "type": "https",
                                          "server": "1.1.1.1"}]}})
        routes, source = sync.read_panel_routes()
        self.assertEqual(source, "subJsonExt+subJson+config")
        self.assertEqual([r["domain_suffix"][0] for r in routes["rules"]],
                         ["ads.example", "tpl.example", "core.example"])
        self.assertEqual(routes["final"], "proxy")
        self.assertEqual(routes["dns"]["servers"][0]["tag"], "c")

    def test_config_only_without_iran_mention_still_flows(self):
        # The old Iran gate is gone: any core-config routing applies.
        self.set_settings(
            config={"route": {"rules": [{"domain_suffix": ["ads.example"],
                                         "outbound": "block"}]}})
        routes, source = sync.read_panel_routes()
        self.assertEqual(source, "config")
        self.assertEqual(len(routes["rules"]), 1)

    def test_single_value_priority(self):
        self.set_settings(
            subJsonExt={"dns": {"servers": [{"tag": "ext"}]}},
            config={"dns": {"servers": [{"tag": "core"}]}})
        routes, _ = sync.read_panel_routes()
        self.assertEqual(routes["dns"]["servers"][0]["tag"], "ext")

    def test_no_routing(self):
        self.set_settings()
        routes, source = sync.read_panel_routes()
        self.assertIsNone(routes)
        self.assertIsNone(source)


class MaskingTests(unittest.TestCase):
    def test_mask(self):
        self.assertEqual(sync._mask(UUID1), "5c0b21ef…")
        self.assertEqual(sync._mask("short"), "short")


class RetryTests(unittest.TestCase):
    def test_retries_transient_failure_then_succeeds(self):
        calls = {"n": 0}
        real = urllib.request.urlopen

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b'{"success": true}'

        def fake(req, timeout=30):
            calls["n"] += 1
            if calls["n"] < 3:
                raise urllib.error.URLError("boom")
            return Resp()

        real_sleep = time.sleep
        time.sleep = lambda s: None  # backoff sleeps are not the test
        urllib.request.urlopen = fake
        try:
            r = sync.cf_request({"CF_API_TOKEN": "x"}, "GET", "/ping",
                                attempts=3)
        finally:
            urllib.request.urlopen = real
            time.sleep = real_sleep
        self.assertTrue(r["success"])
        self.assertEqual(calls["n"], 3)

    def test_403_is_not_retried(self):
        calls = {"n": 0}

        def fake(req, timeout=30):
            calls["n"] += 1
            raise urllib.error.HTTPError(
                req.full_url, 403, "forbidden", {},
                io.BytesIO(b'{"success": false, "errors":'
                           b' [{"code": 1000, "message": "forbidden"}]}'))

        real = urllib.request.urlopen
        urllib.request.urlopen = fake
        try:
            r = sync.cf_request({"CF_API_TOKEN": "x"}, "GET", "/ping")
        finally:
            urllib.request.urlopen = real
        self.assertFalse(r["success"])
        self.assertEqual(calls["n"], 1)


class RunStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = make_env(self.tmp)
        self.calls = []
        self.fail_key = None
        real_cf = sync.cf_request

        def fake_cf(env, method, path, body=None, attempts=3):
            self.calls.append((path, body))
            if self.fail_key and self.fail_key in path:
                return {"success": False,
                        "errors": [{"code": 1000, "message": "kv down"}]}
            return {"success": True}

        self._real_cf = real_cf
        sync.cf_request = fake_cf

    def tearDown(self):
        sync.cf_request = self._real_cf

    def run_main(self, args):
        old_argv, old_out = sys.argv, sys.stdout
        sys.argv = ["sync.py"] + args
        sys.stdout = io.StringIO()
        try:
            code = sync.main()
            return code, sys.stdout.getvalue()
        finally:
            sys.argv, sys.stdout = old_argv, old_out

    def test_success_records_run_and_masks_secrets(self):
        code, out = self.run_main([])
        self.assertEqual(code, 0)
        # No full UUID and no tunnel hostname in the journal lines.
        self.assertNotIn(UUID1, out)
        self.assertNotIn("abc-try-123", out)
        self.assertNotIn("panel-try-456", out)
        state = json.load(open(sync.HASHFILE))
        self.assertIsNone(state["last_error"])
        self.assertLess(abs(state["last_run"] - int(time.time())), 60)

    def test_server_code_stamped_in_kv(self):
        # The server's short code (first 8 chars of its identity UUID)
        # is stamped in KV as server:code next to server:id, so the
        # installer can recognise this server's namespace later.
        code, _ = self.run_main([])
        self.assertEqual(code, 0)
        self.assertTrue(any(p.endswith("values/server:id")
                            for p, _ in self.calls))
        code_puts = [(p, b) for p, b in self.calls
                     if p.endswith("values/server:code")]
        self.assertEqual(len(code_puts), 1)
        self.assertEqual(code_puts[0][1], UUID1[:8])
        state = json.load(open(sync.HASHFILE))
        self.assertEqual(state["server_code"], UUID1[:8])

    def test_kv_failure_names_client_not_uuid(self):
        self.fail_key = "values/sub:" + UUID1
        code, out = self.run_main([])
        self.assertEqual(code, 1)
        self.assertIn("davang", out)
        self.assertNotIn(UUID1, out)
        state = json.load(open(sync.HASHFILE))
        self.assertIn("davang", state["last_error"])
        self.assertNotIn(UUID1, state["last_error"])

    def test_no_hostname_records_error(self):
        with open(sync.TLOG, "w"):
            pass
        code, out = self.run_main([])
        self.assertEqual(code, 0)
        state = json.load(open(sync.HASHFILE))
        self.assertEqual(state["last_error"], "no tunnel hostname yet")

    def test_dry_run_writes_no_state(self):
        code, _ = self.run_main(["--dry-run"])
        self.assertEqual(code, 0)
        self.assertFalse(os.path.exists(sync.HASHFILE))


if __name__ == "__main__":
    unittest.main(verbosity=2)
