// Tests for worker.js — run from the repo root:  node tests/test_worker.mjs
// Covers the rule guards added 2026-11-25: a panel rule naming an
// outbound the profile does not have, or a rule-set that is not defined
// anywhere, is dropped instead of breaking the profile for every client;
// the built-in Iran bypass stays first; valid panel rules still apply.
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const tmp = mkdtempSync(join(tmpdir(), "worker-test-"));
const workerPath = join(tmp, "worker.mjs");
copyFileSync(new URL("../worker.js", import.meta.url), workerPath);
const worker = (await import(workerPath)).default;

const UUID = "5c0b21ef-178a-4b3e-b0f3-4a813e7073ee";
const link = `vless://${UUID}@try.example.com:443?encryption=none&security=tls&sni=try.example.com&type=ws&path=%2Fws#davang`;
const b64 = Buffer.from(link).toString("base64");

function kv(entries) {
  const m = new Map(Object.entries(entries));
  return { get: async (k) => (m.has(k) ? m.get(k) : null) };
}

async function fetchProfile(panelExt) {
  const env = {
    SUB_KV: kv({
      "sub:davang": b64,
      "panel:subjson": panelExt ? JSON.stringify(panelExt) : null,
    }),
  };
  const req = new Request("https://w/sub/davang", {
    headers: { "user-agent": "sing-box SFA/1.0" },
  });
  const res = await worker.fetch(req, env, {});
  assert.equal(res.status, 200);
  return res.json();
}

const panelExt = {
  rule_set: [
    { tag: "ads-list", type: "inline", rules: [{ domain_suffix: ["ads.example"] }] },
  ],
  rules: [
    { domain_suffix: ["ads.example"], outbound: "block" },          // valid: kept
    { domain_suffix: ["api.example"], outbound: "api" },             // unknown outbound: dropped
    { rule_set: ["no-such-set"], outbound: "direct" },               // undefined rule-set: dropped
    { rule_set: ["site-ir"], outbound: "direct" },                   // built-in set: kept
    { domain_suffix: ["cn.example"], outbound: "direct" },           // valid: kept
    { action: "sniff" },                                             // action-only: kept
  ],
};

const profile = await fetchProfile(panelExt);
const rules = profile.route.rules;
const dump = JSON.stringify(rules);

// Bypass first, before any panel rule.
assert.deepEqual(rules[1], { rule_set: ["site-ir", "geoip-ir"], outbound: "direct" });
assert.deepEqual(rules[0], { protocol: "dns", action: "hijack-dns" });
// Valid rules present.
assert.ok(dump.includes("ads.example"), "ads block rule kept");
assert.ok(dump.includes("cn.example"), "direct rule kept");
assert.ok(dump.includes('"action":"sniff"'), "action-only rule kept");
// Bad rules dropped.
assert.ok(!dump.includes("api.example"), "unknown-outbound rule dropped");
assert.ok(!dump.includes("no-such-set"), "undefined rule-set rule dropped");
// The panel rule-set itself merged in.
assert.ok(
  profile.route.rule_set.some((rs) => rs.tag === "ads-list"),
  "panel rule-set merged",
);

// Without panel routing the profile still builds with the bypass only.
const plain = await fetchProfile(null);
assert.deepEqual(plain.route.rules[1], {
  rule_set: ["site-ir", "geoip-ir"], outbound: "direct",
});

// /health answers ok.
const health = await worker.fetch(
  new Request("https://w/health"),
  { SUB_KV: kv({}) }, {},
);
assert.equal(health.status, 200);
assert.equal(await health.text(), "ok\n");

// A plain user-agent still gets the base64 link, not the JSON profile.
const sub = await worker.fetch(
  new Request("https://w/sub/davang", { headers: { "user-agent": "curl/8" } }),
  { SUB_KV: kv({ "sub:davang": b64 }) }, {},
);
assert.equal(await sub.text(), b64);

console.log("worker tests: OK");
