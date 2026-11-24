// sui-sub worker: fixed workers.dev endpoint for the s-ui VPN.
// GET /sub/<uuid-or-name>          -> base64 vless subscription for that user
// GET /sub/<secret>/<uuid-or-name> -> same, when a SUB_SECRET worker
//                     variable is set (see below). From KV key sub:<uuid>
//                     or sub:<name>; s-ui builds the panel subscription
//                     link from the client NAME, so sync.py publishes both
//                     keys for every client.
//                     sing-box official apps (UA contains "sing-box"/"sfa") instead
//                     get a full sing-box JSON profile built from the same link,
//                     because SFA remote profiles need JSON, not a base64 blob.
// SUB_SECRET: plain client names are guessable, so without a secret
// anyone who knows this worker's address can try common names (admin,
// test, ...) and download a working VPN config. When the SUB_SECRET
// variable is set, only /sub/<secret>/<id> works. The installer
// generates the secret, deploys it as a worker variable, and writes it
// into the panel's subURI, so panel links carry it automatically.
// GET /health      -> plain "ok"
// Any other path   -> reverse-proxy to the s-ui panel's current quick-tunnel
//                     hostname (KV key panel:host, written by sync.py on the VPS).
//                     The panel itself enforces its secret webPath and returns
//                     404 for every path outside it, so the panel stays hidden.
// KV values are written by sync.py on the VPS whenever the tunnel hostname,
// the panel hostname, the client set, or the panel routing changes. This
// worker never sees the VPS IP. Panel routing lives in KV panel:subjson:
// sync.py reads s-ui setting `subJsonExt` (the subscription JSON extension)
// — falling back to the core `config` route/dns when the extension is empty
// — and the worker merges it into the sing-box profile, translating s-ui's
// "proxy" outbound tag to the client's real outbound tag.
// Panel rules use s-ui's outbound tags ("proxy" for the VPN, "direct",
// legacy "block"/"dns"); our profile names the VPN outbound after the
// client, so translate those tags when merging panel rules in.
function translatePanelTags(value, name) {
  if (Array.isArray(value)) return value.map((v) => translatePanelTags(v, name));
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if ((k === "outbound" || k === "detour" || k === "download_detour") && v === "proxy") out[k] = name;
      else if (k === "final" && v === "proxy") out[k] = name;
      else if (k === "outbound" && (v === "block" || v === "dns")) continue; // handled by translatePanelRule
      else out[k] = translatePanelTags(v, name);
    }
    return out;
  }
  return value;
}

function translatePanelRule(rule, name) {
  if (!rule || typeof rule !== "object" || Array.isArray(rule)) return null;
  const r = translatePanelTags(rule, name);
  if (rule.outbound === "block") r.action = "reject";
  if (rule.outbound === "dns") r.action = "hijack-dns";
  return r;
}

// Merge the panel's routing (KV key panel:subjson, written by sync.py
// from s-ui setting `subJsonExt`, falling back to the core `config`
// route/dns) into the profile s-ui itself would have built. The built-in
// Iran bypass comes FIRST: a panel template can route the Iran lists to
// the proxy (seen in practice), which would silently undo the bypass,
// so panel rules only apply to traffic the bypass does not match. When
// there is no panel routing, the built-in bypass is the whole story.
function applyPanelRoutes(profile, ext, name) {
  if (!ext || typeof ext !== "object") return;
  if (ext.dns && typeof ext.dns === "object" && Array.isArray(ext.dns.servers)
      && ext.dns.servers.length
      && ext.dns.servers.every((s) => s && typeof s === "object" && typeof s.type === "string")) {
    // New (sing-box >= 1.12) DNS format only: a legacy address-string
    // server would make SFA reject the whole profile, so keep ours then.
    profile.dns = translatePanelTags(ext.dns, name);
    const serverTags = ext.dns.servers.map((s) => s.tag).filter(Boolean);
    if (typeof ext.default_domain_resolver === "string" && serverTags.includes(ext.default_domain_resolver)) {
      profile.route.default_domain_resolver = ext.default_domain_resolver;
    } else if (serverTags.length) {
      // No resolver named: fall back to the last DNS server, as s-ui
      // does (jsonService.go fallbackDomainResolver) — otherwise the
      // route would point at our "local" server, which no longer exists.
      profile.route.default_domain_resolver = serverTags[serverTags.length - 1];
    }
  }
  if (Array.isArray(ext.rule_set) && ext.rule_set.length) {
    const seen = new Set();
    const merged = [];
    for (const rs of [...ext.rule_set, ...profile.route.rule_set]) {
      const tag = rs && rs.tag;
      if (tag && seen.has(tag)) continue;
      if (tag) seen.add(tag);
      const t = translatePanelTags(rs, name);
      // A remote rule-set without an explicit HTTP client falls back to
      // the route's default_http_client (implicit since sing-box 1.14
      // removed download_detour). Make it explicit so a missing default
      // can never break rule-set downloads at client startup.
      if (t && t.type === "remote" && !t.http_client && !t.download_detour) {
        t.http_client = "proxy-http";
      }
      merged.push(t);
    }
    profile.route.rule_set = merged;
  }
  if (Array.isArray(ext.rules) && ext.rules.length) {
    const panelRules = ext.rules.map((r) => translatePanelRule(r, name)).filter(Boolean);
    if (panelRules.length) {
      profile.route.rules = [
        { protocol: "dns", action: "hijack-dns" },
        { rule_set: ["site-ir", "geoip-ir"], outbound: "direct" },
        ...panelRules,
        { ip_is_private: true, outbound: "direct" },
        { ip_cidr: ["224.0.0.0/3", "ff00::/8"], action: "reject" },
      ];
    }
  }
  if (typeof ext.final === "string" && ext.final) {
    if (ext.final === "proxy") profile.route.final = name;
    else if (ext.final === "direct") profile.route.final = "direct";
  }
}

// Build a full sing-box client profile from one base64-encoded vless:// link.
function singboxProfile(b64, panelExt) {
  try {
    const link = atob(b64.trim()).trim();
    const u = new URL(link);
    if (u.protocol !== "vless:") return null;
    const uuid = decodeURIComponent(u.username);
    const host = u.hostname;
    const path = u.searchParams.get("path") || "/";
    const sni = u.searchParams.get("sni") || host;
    const name = decodeURIComponent(u.hash ? u.hash.slice(1) : "proxy");
    const profile = {
      log: { level: "info" },
      // sing-box 1.14: rule-set downloads go through a named HTTP client,
      // not the deprecated download_detour (removed in 1.16).
      http_clients: [{ tag: "proxy-http", detour: name }],
      dns: {
        // New (sing-box >= 1.12) DNS server format: legacy address strings
        // were removed in 1.14, so servers must carry an explicit "type".
        servers: [
          // detour must be the real vless outbound tag (the client name),
          // not a literal "proxy" — there is no outbound with that tag.
          { tag: "remote", type: "https", server: "1.1.1.1", detour: name },
          { tag: "local", type: "local", detour: "direct" },
        ],
        // 1.12+ dns rules use action-based routing (no "outbound" field).
        // Iranian domains resolve through the local resolver (direct),
        // everything else through the remote DoH server (via proxy).
        rules: [
          { rule_set: "site-ir", action: "route", server: "local" },
          { action: "route", server: "remote" },
        ],
        final: "local",
      },
      inbounds: [
        { type: "tun", tag: "tun-in", address: ["172.19.0.1/30"], auto_route: true, strict_route: true, stack: "mixed" },
        { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 },
      ],
      outbounds: [
        {
          type: "vless",
          tag: name,
          server: host,
          server_port: 443,
          uuid,
          tls: {
            enabled: true,
            server_name: sni,
            utls: { enabled: true, fingerprint: "chrome" },
          },
          transport: { type: "ws", path, headers: { Host: host } },
        },
        { type: "direct", tag: "direct" },
      ],
      route: {
        // Iran bypass (sing-box >= 1.12 only knows rule-sets: the old
        // geosite/geoip databases were removed in 1.12, and there is no
        // geosite-ir.srs file — verified 404 — so domains are matched by
        // an inline rule-set: every .ir domain plus the big Iranian
        // services on .com/.org, and IPs by the geoip-ir .srs, which
        // does exist). Iranian traffic goes direct, never via the VPN.
        rule_set: [
          { tag: "site-ir", type: "inline", rules: [{ domain_suffix: [".ir", "digikala.com", "aparat.com", "filimo.com", "torob.com", "sheypoor.com", "varzesh3.com", "tgju.org", "snapptrip.com", "flightio.com", "zarinpal.com", "tamasha.com", "telewebion.com", "bale.ai", "gap.im", "igap.net", "eitaa.com"] }] },
          { tag: "geoip-ir", type: "remote", format: "binary", url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ir.srs", http_client: "proxy-http" },
        ],
        // sing-box >= 1.11 rule actions: the legacy "dns" and "block"
        // special outbounds were removed in 1.13, so DNS is intercepted
        // with hijack-dns and multicast is rejected with a rule action.
        rules: [
          { protocol: "dns", action: "hijack-dns" },
          { rule_set: ["site-ir", "geoip-ir"], outbound: "direct" },
          { ip_is_private: true, outbound: "direct" },
          { ip_cidr: ["224.0.0.0/3", "ff00::/8"], action: "reject" },
        ],
        final: name,
        default_domain_resolver: "local",
        default_http_client: "proxy-http",
        auto_detect_interface: true,
      },
    };
    applyPanelRoutes(profile, panelExt, name);
    return profile;
  } catch {
    return null;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return new Response("ok\n", { headers: { "content-type": "text/plain" } });
    }
    const m = url.pathname.match(/^\/sub\/([^/]+)(?:\/([^/]+))?$/);
    if (m) {
      // UUIDs are stored lowercase; names are stored exactly as typed in
      // the panel (percent-decoded from the URL path).
      let id;
      if (m[2] !== undefined) {
        if (!env.SUB_SECRET || m[1] !== env.SUB_SECRET) {
          return new Response("not found\n", { status: 404 });
        }
        id = decodeURIComponent(m[2]);
      } else {
        if (env.SUB_SECRET) {
          return new Response("not found\n", { status: 404 });
        }
        id = decodeURIComponent(m[1]);
      }
      const key = /^[0-9a-fA-F-]{36}$/.test(id)
        ? "sub:" + id.toLowerCase()
        : "sub:" + id;
      const value = await env.SUB_KV.get(key);
      if (!value) {
        return new Response("not found\n", { status: 404 });
      }
      const ua = (request.headers.get("user-agent") || "").toLowerCase();
      if (ua.includes("sing-box") || ua.includes("sfa")) {
        // Panel routing (KV panel:subjson, synced from s-ui by sync.py
        // every 60s) merges into the profile; without it the built-in
        // Iran bypass below is used unchanged.
        let panelExt = null;
        try {
          const raw = await env.SUB_KV.get("panel:subjson");
          if (raw) panelExt = JSON.parse(raw);
        } catch {
          panelExt = null;
        }
        const profile = singboxProfile(value, panelExt);
        if (profile) {
          return new Response(JSON.stringify(profile), {
            headers: {
              "content-type": "application/json; charset=utf-8",
              "cache-control": "no-store",
            },
          });
        }
        // fall through to the base64 form if the link cannot be parsed
      }
      return new Response(value, {
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "no-store",
        },
      });
    }
    // Panel proxy: everything else goes to the panel tunnel hostname.
    const panelHost = await env.SUB_KV.get("panel:host");
    if (!panelHost) {
      return new Response("panel not available\n", { status: 503 });
    }
    const target = "https://" + panelHost + url.pathname + url.search;
    // s-ui's SameOrigin guard rejects POSTs whose Origin host differs from
    // the Host header, so rewrite Origin/Referer to the panel hostname.
    const headers = new Headers(request.headers);
    if (headers.has("origin")) {
      headers.set("origin", "https://" + panelHost);
    }
    if (headers.has("referer")) {
      headers.set("referer", headers.get("referer").replace(url.origin, "https://" + panelHost));
    }
    const init = {
      method: request.method,
      headers,
      redirect: "manual",
    };
    if (request.method !== "GET" && request.method !== "HEAD") {
      init.body = request.body;
    }
    const resp = await fetch(target, init);
    // WebSocket upgrade (101) and everything else pass through as-is.
    return resp;
  },
};
