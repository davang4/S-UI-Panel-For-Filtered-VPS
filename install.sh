#!/usr/bin/env bash
# S-UI-Panel-For-Filtered-VPS — s-ui panel + Cloudflare quick tunnels + Workers subscription.
# Isolated install: ~/sui-vpn + units sui-panel / sui-tunnel / sui-panel-tunnel /
# sui-sync(.timer). Panel binds 127.0.0.1 only and is reachable from the
# internet only through its own quick tunnel under a secret base path
# (webPath, generated on-server). Inbound binds 127.0.0.1 only.
# Opens NO public ports, changes NO firewall, touches nothing else on the server.
# Ports are overridable: PANEL_PORT / SUB_PORT / IN_PORT env vars.
# s-ui is fetched from its GitHub releases and defaults to the NEWEST
# release (latest/download), so a fresh install always gets the current
# version. Set SUI_VERSION=x.y.z to pin one deliberately instead, e.g.
# after a new release breaks something. cloudflared stays pinned
# (CFD_VERSION) with a checksum check, because it never needs features.
set -u

PANEL_PORT="${PANEL_PORT:-2095}"
SUB_PORT="${SUB_PORT:-2096}"
IN_PORT="${IN_PORT:-10087}"
CFD_VERSION="2026.11.2"
if [ -n "${SUI_VERSION:-}" ]; then
  SUI_URL="https://github.com/alireza0/s-ui/releases/download/v${SUI_VERSION}/s-ui-linux-amd64.tar.gz"
else
  SUI_URL="https://github.com/alireza0/s-ui/releases/latest/download/s-ui-linux-amd64.tar.gz"
fi
CFD_URL="https://github.com/cloudflare/cloudflared/releases/download/${CFD_VERSION}/cloudflared-linux-amd64"
CFD_SHA_URL="${CFD_URL}.sha256"
CF_API="https://api.cloudflare.com/client/v4"
WORKER_NAME="sui-sub"
KV_TITLE="sui-sub"

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  TARGET_HOME=$(eval echo "~${SUDO_USER}")
else
  TARGET_HOME="${HOME:-/root}"
fi
DIR="${TARGET_HOME}/sui-vpn"
BIN="${DIR}/bin"
STATE="${DIR}/state.env"
TLOG="${DIR}/tunnel.log"
PTLOG="${DIR}/panel-tunnel.log"
DBFILE="${DIR}/db/s-ui.db"
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_UNIT="/etc/systemd/system/sui-panel.service"
TUN_UNIT="/etc/systemd/system/sui-tunnel.service"
PANEL_TUN_UNIT="/etc/systemd/system/sui-panel-tunnel.service"
SYNC_UNIT="/etc/systemd/system/sui-sync.service"
TIMER_UNIT="/etc/systemd/system/sui-sync.timer"

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run with sudo: sudo bash install.sh $*"
  fi
}

preflight() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) : ;;
      *) die "only Ubuntu/Debian supported (found ID=${ID:-unknown})" ;;
    esac
  else
    die "cannot read /etc/os-release"
  fi
  local avail_kb
  avail_kb=$(df -Pk "${TARGET_HOME}" | awk 'NR==2{print $4}')
  [ -n "${avail_kb}" ] || die "cannot check free disk"
  if [ "${avail_kb}" -lt 1048576 ]; then
    die "less than 1GB free disk on ${TARGET_HOME} (free: $((avail_kb/1024))MB)"
  fi
  local p
  for p in "${PANEL_PORT}" "${SUB_PORT}" "${IN_PORT}"; do
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${p} "; then
      if systemctl is-active --quiet sui-panel 2>/dev/null; then
        echo "port ${p} already used by sui-panel (re-run OK)"
      else
        die "port ${p} already in use by another process; aborting without changes"
      fi
    fi
  done
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
}

download_sui() {
  # Fetch the newest s-ui release from GitHub into ${BIN}/sui.new and
  # verify it runs. Does NOT swap it in — the caller does that, so a
  # failed download can never leave a broken or missing binary behind.
  # Returns 0 on success, 1 on failure.
  local tmptgz="${DIR}/s-ui.tar.gz"
  mkdir -p "${BIN}" "${DIR}"
  curl -fL --retry 3 -o "${tmptgz}" "${SUI_URL}" || { echo "s-ui download failed: ${SUI_URL}" >&2; return 1; }
  tar xzf "${tmptgz}" -C "${DIR}" s-ui/sui >/dev/null 2>&1 || { echo "s-ui extract failed" >&2; return 1; }
  mv "${DIR}/s-ui/sui" "${BIN}/sui.new"
  rmdir "${DIR}/s-ui" 2>/dev/null || true
  chmod +x "${BIN}/sui.new"
  rm -f "${tmptgz}"
  "${BIN}/sui.new" -v >/dev/null 2>&1 || { echo "downloaded sui binary does not run" >&2; rm -f "${BIN}/sui.new"; return 1; }
  echo "downloaded s-ui: $("${BIN}/sui.new" -v 2>/dev/null | head -1)"
  return 0
}

download_binaries() {
  mkdir -p "${BIN}"
  if [ ! -x "${BIN}/sui" ]; then
    echo "downloading s-ui (latest release)..."
    download_sui || die "s-ui download failed"
    mv "${BIN}/sui.new" "${BIN}/sui"
  fi
  if [ ! -x "${BIN}/cloudflared" ]; then
    echo "downloading cloudflared ${CFD_VERSION}..."
    curl -fL --retry 3 -o "${BIN}/cloudflared" "${CFD_URL}" || die "cloudflared download failed"
    chmod +x "${BIN}/cloudflared"
    # cloudflared publishes a .sha256 sidecar; verify when it is available.
    if curl -fsL --retry 2 -o "${BIN}/cloudflared.sha256" "${CFD_SHA_URL}" 2>/dev/null; then
      (cd "${BIN}" && sha256sum -c cloudflared.sha256 >/dev/null 2>&1) \
        || die "cloudflared checksum mismatch — refusing to install"
      rm -f "${BIN}/cloudflared.sha256"
      echo "cloudflared checksum OK"
    else
      echo "warning: cloudflared checksum file unavailable, skipping verification"
    fi
  fi
  "${BIN}/sui" -v >/dev/null 2>&1 || die "sui binary does not run"
  "${BIN}/cloudflared" --version >/dev/null 2>&1 || die "cloudflared binary does not run"
  echo "binaries OK: s-ui $("${BIN}/sui" -v 2>/dev/null | head -1) / $("${BIN}/cloudflared" --version 2>/dev/null | head -1)"
}

gen_state() {
  if [ -f "${STATE}" ]; then
    echo "keeping existing state from ${STATE}"
    return 0
  fi
  local uuid rand pass user basepath secret first_client
  uuid=$(cat /proc/sys/kernel/random/uuid)
  rand=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)
  user="admin$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-4)"
  pass=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-20)
  basepath="/p-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)/"
  # Shared secret for subscription links (worker.js SUB_SECRET): s-ui builds
  # panel links from the client NAME, and plain names are guessable, so the
  # panel's subURI carries this secret and the worker rejects links without
  # it. Override with SUB_SECRET env, or empty it to keep plain /sub/<id>.
  secret="${SUB_SECRET:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16)}"
  first_client="${FIRST_CLIENT_NAME:-main}"
  mkdir -p "${DIR}"
  {
    echo "WS_PATH=/${rand}-ws"
    echo "CLIENT_UUID=${uuid}"
    echo "CLIENT_NAME=${first_client}"
    echo "PANEL_USER=${user}"
    echo "PANEL_PASS=${pass}"
    echo "PANEL_BASE_PATH=${basepath}"
    echo "SUB_SECRET=${secret}"
  } > "${STATE}"
  chmod 600 "${STATE}"
  echo "generated state (stored in ${STATE}, mode 600)"
}

load_state() {
  [ -f "${STATE}" ] || die "not installed yet (no ${STATE}); run: sudo bash install.sh install"
  . "${STATE}"
}

set_state() {
  # set_state KEY VALUE — update or append in state.env (keeps mode 600)
  local key="$1" val="$2"
  if grep -q "^${key}=" "${STATE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${STATE}"
  else
    echo "${key}=${val}" >> "${STATE}"
  fi
  chmod 600 "${STATE}"
}

ensure_base_path() {
  # Secret panel base path: generate once, keep across re-runs.
  # Covers state.env files written before this feature existed.
  load_state
  if [ -z "${PANEL_BASE_PATH:-}" ]; then
    PANEL_BASE_PATH="/p-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)/"
    set_state PANEL_BASE_PATH "${PANEL_BASE_PATH}"
    echo "generated secret panel base path (stored in ${STATE}, mode 600)"
  fi
  case "${PANEL_BASE_PATH}" in
    /*/) : ;;
    /*) PANEL_BASE_PATH="${PANEL_BASE_PATH}/" ;;
    *) PANEL_BASE_PATH="/${PANEL_BASE_PATH}/" ;;
  esac
  export PANEL_BASE_PATH
}

init_panel_db() {
  mkdir -p "${DIR}/db"
  # Creates the DB and sets first-admin credentials (idempotent).
  SUI_DB_FOLDER="${DIR}/db" "${BIN}/sui" admin -username "${PANEL_USER}" -password "${PANEL_PASS}" >/dev/null 2>&1 \
    || die "s-ui admin init failed"
  # Bind panel + built-in sub server to localhost only, and move the panel
  # under the secret base path (s-ui setting key: webPath, default /app/).
  python3 - "${DBFILE}" "${PANEL_PORT}" "${SUB_PORT}" "${PANEL_BASE_PATH}" <<'PYEOF' || die "failed to set localhost bindings in s-ui DB"
import sqlite3, sys
db, web_port, sub_port, web_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
con = sqlite3.connect(db)
for k, v in (("webListen", "127.0.0.1"), ("subListen", "127.0.0.1"),
             ("webPort", web_port), ("subPort", sub_port),
             ("webPath", web_path)):
    cur = con.execute("UPDATE settings SET value=? WHERE key=?", (v, k))
    if cur.rowcount == 0:
        con.execute("INSERT INTO settings(key,value) VALUES(?,?)", (k, v))
con.commit(); con.close()
print("panel bindings set to 127.0.0.1")
PYEOF
}

write_units() {
  cat > "${PANEL_UNIT}" <<EOF
[Unit]
Description=s-ui panel (sui-vpn, localhost only)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${DIR}
Environment=SUI_DB_FOLDER=${DIR}/db
ExecStart=${BIN}/sui
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  cat > "${TUN_UNIT}" <<EOF
[Unit]
Description=sui-vpn Cloudflare quick tunnel
After=network-online.target sui-panel.service
Wants=network-online.target

[Service]
ExecStart=${BIN}/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${IN_PORT}
StandardOutput=append:${TLOG}
StandardError=append:${TLOG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  cat > "${PANEL_TUN_UNIT}" <<EOF
[Unit]
Description=sui-vpn panel Cloudflare quick tunnel
After=network-online.target sui-panel.service
Wants=network-online.target

[Service]
ExecStart=${BIN}/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${PANEL_PORT}
StandardOutput=append:${PTLOG}
StandardError=append:${PTLOG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  cat > "${SYNC_UNIT}" <<EOF
[Unit]
Description=sui-vpn sync clients to Workers KV
After=network-online.target sui-tunnel.service

[Service]
Type=oneshot
WorkingDirectory=${DIR}
ExecStart=/usr/bin/python3 ${DIR}/sync.py
EOF
  cat > "${TIMER_UNIT}" <<EOF
[Unit]
Description=sui-vpn sync timer (every 60s, writes only on change)

[Timer]
OnBootSec=45
OnUnitActiveSec=60
Unit=sui-sync.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

_url_from_log() {
  [ -f "$1" ] || return 1
  python3 - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], errors="replace").read()
idx = text.rfind("Requesting new quick Tunnel")
seg = text[idx:] if idx >= 0 else text
urls = re.findall(r"https://[a-z0-9-]+\.trycloudflare\.com", seg)
print(urls[-1] if urls else "")
PYEOF
}

tunnel_url() { _url_from_log "${TLOG}"; }

panel_tunnel_url() { _url_from_log "${PTLOG}"; }

wait_url() {
  local i u
  for i in $(seq 1 45); do
    u=$(tunnel_url)
    [ -n "${u}" ] && return 0
    sleep 1
  done
  return 1
}

wait_panel_url() {
  local i u
  for i in $(seq 1 45); do
    u=$(panel_tunnel_url)
    [ -n "${u}" ] && return 0
    sleep 1
  done
  return 1
}

wait_panel() {
  local i code
  for i in $(seq 1 30); do
    code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}login" 2>/dev/null || echo 000)
    [ "${code}" != "000" ] && return 0
    sleep 1
  done
  return 1
}

cf_api() {
  # cf_api METHOD PATH [json-body] -> response body on stdout
  local method="$1" path="$2" body="${3:-}"
  if [ -n "${body}" ]; then
    curl -s --max-time 30 -X "${method}" "${CF_API}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" --data "${body}"
  else
    curl -s --max-time 30 -X "${method}" "${CF_API}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}"
  fi
}

deploy_worker() {
  # Prompts for CF token + account id (hidden), deploys worker + KV.
  # On any failure: print fallback steps and return 1 (install continues).
  load_state
  if [ -z "${CF_API_TOKEN:-}" ]; then
    echo ""
    echo "Cloudflare API token needed for the Workers subscription."
    echo "Create it at: dash.cloudflare.com -> My Profile -> API Tokens -> Create Token"
    echo "Permissions: Account > Workers Scripts > Edit, Account > Workers KV Storage > Edit"
    read -r -s -p "Paste Cloudflare API token (hidden): " CF_API_TOKEN; echo ""
    [ -n "${CF_API_TOKEN}" ] || { echo "no token given; skipping worker deploy"; return 1; }
    set_state CF_API_TOKEN "${CF_API_TOKEN}"
  fi
  if [ -z "${CF_ACCOUNT_ID:-}" ]; then
    read -r -p "Cloudflare Account ID (dash.cloudflare.com -> Workers & Pages, right sidebar): " CF_ACCOUNT_ID
    [ -n "${CF_ACCOUNT_ID}" ] || { echo "no account id given; skipping worker deploy"; return 1; }
    set_state CF_ACCOUNT_ID "${CF_ACCOUNT_ID}"
  fi
  export CF_API_TOKEN CF_ACCOUNT_ID

  # KV namespace (create or reuse). Re-deploying must reuse the namespace
  # the worker is already bound to — creating a second "sui-sub" namespace
  # would leave the worker reading the old, now-stale one.
  local resp ns_id
  if [ -n "${KV_NAMESPACE_ID:-}" ]; then
    ns_id="${KV_NAMESPACE_ID}"
    echo "reusing KV namespace: ${ns_id}"
  else
  resp=$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" "{\"title\":\"${KV_TITLE}\"}")
  ns_id=$(printf '%s' "${resp}" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('result') or {}).get('id',''))" 2>/dev/null)
  if [ -z "${ns_id}" ]; then
    resp=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
    ns_id=$(printf '%s' "${resp}" | KV_TITLE="${KV_TITLE}" python3 -c "
import sys,json,os
d=json.load(sys.stdin)
for n in d.get('result') or []:
    if n.get('title')==os.environ['KV_TITLE']:
        print(n.get('id','')); break
" 2>/dev/null)
  fi
  fi
  [ -n "${ns_id}" ] || { echo "KV namespace create failed: ${resp}"; return 1; }
  set_state KV_NAMESPACE_ID "${ns_id}"
  export KV_NAMESPACE_ID="${ns_id}"
  echo "KV namespace ready: ${ns_id}"

  # Upload worker (multipart: metadata + module). The SUB_SECRET is sent
  # as a plain-text variable binding so the worker can require it in
  # /sub/<secret>/<id> links (see worker.js); it is a URL-path secret,
  # not an API credential, and lives in state.env (mode 600) too.
  local meta="${DIR}/worker-meta.json"
  if [ -n "${SUB_SECRET:-}" ]; then
    python3 - "${meta}" "${ns_id}" "${SUB_SECRET}" <<'PYEOF'
import json, sys
meta, ns_id, secret = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {"main_module": "worker.js",
       "bindings": [{"type": "kv_namespace", "name": "SUB_KV", "namespace_id": ns_id},
                    {"type": "plain_text", "name": "SUB_SECRET", "text": secret}],
       "compatibility_date": "2025-01-01"}
open(meta, "w").write(json.dumps(doc))
PYEOF
  else
    cat > "${meta}" <<EOF
{"main_module":"worker.js","bindings":[{"type":"kv_namespace","name":"SUB_KV","namespace_id":"${ns_id}"}],"compatibility_date":"2025-01-01"}
EOF
  fi
  resp=$(curl -s --max-time 60 -X PUT "${CF_API}/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -F "metadata=@${meta};type=application/json" \
    -F "worker.js=@${DIR}/worker.js;type=application/javascript+module")
  rm -f "${meta}"
  local ok
  ok=$(printf '%s' "${resp}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('success'))" 2>/dev/null)
  [ "${ok}" = "True" ] || { echo "worker upload failed: ${resp}"; return 1; }
  echo "worker uploaded: ${WORKER_NAME}"

  # Enable workers.dev route + get account subdomain
  cf_api POST "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" '{"enabled":true}' >/dev/null
  resp=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/workers/subdomain")
  local sub
  sub=$(printf '%s' "${resp}" | python3 -c "import sys,json;print((json.load(sys.stdin).get('result') or {}).get('subdomain',''))" 2>/dev/null)
  [ -n "${sub}" ] || { echo "could not read workers.dev subdomain: ${resp}"; return 1; }
  set_state WORKER_URL "https://${WORKER_NAME}.${sub}.workers.dev"
  echo "worker URL: https://${WORKER_NAME}.${sub}.workers.dev"

  # Point the panel's subscription links at the worker (with the secret,
  # when set): s-ui composes each client's link as subURI + client name,
  # so this is what makes panel-generated links work without editing.
  # The panel reads settings from the DB per request; restart it so the
  # new value is picked up for sure.
  if [ -n "${SUB_SECRET:-}" ]; then
    local sub_uri="https://${WORKER_NAME}.${sub}.workers.dev/sub/${SUB_SECRET}/"
    python3 - "${DBFILE}" "${sub_uri}" <<'PYEOF' || { echo "warning: could not set panel subURI in DB"; return 0; }
import sqlite3, sys
db, uri = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.execute("UPDATE settings SET value=? WHERE key='subURI'", (uri,))
if cur.rowcount == 0:
    con.execute("INSERT INTO settings(key,value) VALUES('subURI',?)", (uri,))
con.commit(); con.close()
print(f"panel subscription URI set to {uri}")
PYEOF
    systemctl restart sui-panel >/dev/null 2>&1 || true
  fi
  return 0
}

worker_fallback_steps() {
  cat <<EOF

----- WORKER DEPLOY FAILED — manual fallback (panel + tunnel still work) -----
1. dash.cloudflare.com -> Workers & Pages -> Create -> Worker, name: ${WORKER_NAME}
2. Paste the contents of ${DIR}/worker.js, Deploy.
3. Worker -> Settings -> Bindings -> KV namespace: variable SUB_KV,
   create namespace "${KV_TITLE}" and bind it.
4. Worker -> Settings -> Domains & Routes: enable the workers.dev route.
5. On this server, save the values into ${STATE} (mode 600):
   CF_API_TOKEN=..., CF_ACCOUNT_ID=..., KV_NAMESPACE_ID=..., WORKER_URL=https://${WORKER_NAME}.<your-subdomain>.workers.dev
6. Run: sudo bash install.sh sync-now
------------------------------------------------------------------------------
EOF
}

run_checks() {
  echo "----- checks -----"
  if systemctl is-active --quiet sui-panel; then echo "PASS panel service active"; else echo "FAIL panel service not active"; fi
  if systemctl is-active --quiet sui-tunnel; then echo "PASS tunnel service active"; else echo "FAIL tunnel service not active"; fi
  if systemctl is-active --quiet sui-panel-tunnel; then echo "PASS panel tunnel service active"; else echo "FAIL panel tunnel service not active"; fi
  local code
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}login" 2>/dev/null || echo 000)
  if [ "${code}" = "200" ]; then echo "PASS panel login page on secret path (HTTP 200)"; else echo "FAIL panel login page on secret path (HTTP ${code})"; fi
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT}/" 2>/dev/null || echo 000)
  if [ "${code}" = "404" ]; then echo "PASS panel root path returns 404 (panel hidden)"; else echo "FAIL panel root path (HTTP ${code}, expected 404)"; fi
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${IN_PORT}/" 2>/dev/null || echo 000)
  if [ "${code}" != "000" ]; then echo "PASS sing-box inbound responds on 127.0.0.1:${IN_PORT} (HTTP ${code})"; else echo "FAIL sing-box inbound not responding on 127.0.0.1:${IN_PORT}"; fi
  local u
  u=$(tunnel_url)
  if [ -n "${u}" ]; then echo "PASS tunnel URL: ${u}"; else echo "FAIL tunnel URL not found yet (see: sudo bash install.sh status)"; fi
  u=$(panel_tunnel_url)
  if [ -n "${u}" ]; then echo "PASS panel URL: ${u}${PANEL_BASE_PATH}"; else echo "FAIL panel tunnel URL not found yet (see: sudo bash install.sh status)"; fi
  if [ -n "${WORKER_URL:-}" ]; then
    code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "${WORKER_URL}/health" 2>/dev/null || echo 000)
    if [ "${code}" = "200" ]; then echo "PASS worker /health OK: ${WORKER_URL}"; else echo "FAIL worker /health (HTTP ${code}): ${WORKER_URL}"; fi
  else
    echo "SKIP worker check (not deployed)"
  fi
  echo "------------------"
}

cmd_install() {
  need_root install
  preflight
  mkdir -p "${DIR}" "${BIN}"
  download_binaries
  gen_state
  ensure_base_path
  # ship runtime scripts next to state (sync.py / sui_setup.py read state.env beside them)
  cp "${BUNDLE_DIR}/sync.py" "${BUNDLE_DIR}/sui_setup.py" "${BUNDLE_DIR}/worker.js" "${DIR}/" \
    || die "bundle scripts not found next to install.sh"
  chmod 700 "${DIR}/sync.py" "${DIR}/sui_setup.py"
  init_panel_db
  write_units
  : >> "${TLOG}"
  : >> "${PTLOG}"
  # restart (not just enable --now) so a changed webPath takes effect on re-run
  systemctl enable sui-panel >/dev/null 2>&1 || true
  systemctl restart sui-panel >/dev/null 2>&1 || die "failed to start sui-panel"
  wait_panel || die "panel did not come up on 127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH} (journalctl -u sui-panel)"
  python3 "${DIR}/sui_setup.py" || die "inbound/client setup failed"
  systemctl enable --now sui-tunnel >/dev/null 2>&1 || die "failed to start sui-tunnel"
  echo "waiting for tunnel URL (up to 45s)..."
  wait_url || echo "URL not ready yet; check again with: sudo bash install.sh show"
  systemctl enable --now sui-panel-tunnel >/dev/null 2>&1 || die "failed to start sui-panel-tunnel"
  echo "waiting for panel tunnel URL (up to 45s)..."
  wait_panel_url || echo "Panel URL not ready yet; check again with: sudo bash install.sh show"
  if deploy_worker; then
    load_state
  else
    worker_fallback_steps
  fi
  systemctl enable --now sui-sync.timer >/dev/null 2>&1 || true
  python3 "${DIR}/sync.py" || echo "first sync failed (see above); timer will retry every 60s"
  load_state
  run_checks
  local pu
  pu=$(panel_tunnel_url)
  echo ""
  echo "================= SAVE THESE (shown once) ================="
  if [ -n "${pu}" ]; then
    echo "Panel (internet, secret path): ${pu}${PANEL_BASE_PATH}"
  else
    echo "Panel (internet): URL not ready yet; get it with: sudo bash install.sh show"
  fi
  echo "Panel (via SSH forward, see README): http://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"
  echo "Panel username: ${PANEL_USER}"
  echo "Panel password: ${PANEL_PASS}"
  echo "Panel internet access on/off: sudo bash install.sh panel-on | panel-off"
  if [ -n "${WORKER_URL:-}" ]; then
    if [ -n "${SUB_SECRET:-}" ]; then
      echo "Your subscription URL: ${WORKER_URL}/sub/${SUB_SECRET}/${CLIENT_UUID}"
    else
      echo "Your subscription URL: ${WORKER_URL}/sub/${CLIENT_UUID}"
    fi
  fi
  echo "State file (mode 600): ${STATE}"
  echo "==========================================================="
  echo "done. Details anytime: sudo bash install.sh show"
}

cmd_show() {
  load_state
  local u host pu
  u=$(tunnel_url)
  pu=$(panel_tunnel_url)
  if [ -n "${pu}" ]; then
    echo "Panel (internet): ${pu}${PANEL_BASE_PATH:-/app/}"
  else
    echo "Panel (internet): not available (panel tunnel off or URL not ready; sudo bash install.sh panel-on)"
  fi
  echo "Panel (SSH forward): http://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH:-/app/}"
  echo "Panel username: ${PANEL_USER}"
  echo "Panel password: ${PANEL_PASS}"
  echo "Tunnel URL: ${u:-not found yet}"
  if [ -n "${u}" ]; then
    host="${u#https://}"
    echo "Direct link (current tunnel):"
    echo "vless://${CLIENT_UUID}@${host}:443?encryption=none&security=tls&sni=${host}&type=ws&path=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "${WS_PATH}")&host=${host}&fp=chrome#${CLIENT_NAME}"
  fi
  if [ -n "${WORKER_URL:-}" ]; then
    if [ -n "${SUB_SECRET:-}" ]; then
      echo "Subscription (fixed, auto-updates): ${WORKER_URL}/sub/${SUB_SECRET}/${CLIENT_UUID}"
    else
      echo "Subscription (fixed, auto-updates): ${WORKER_URL}/sub/${CLIENT_UUID}"
    fi
  else
    echo "Subscription: worker not deployed yet (see README fallback)"
  fi
}

cmd_status() {
  load_state
  echo "sui-panel:  $(systemctl is-active sui-panel 2>/dev/null || echo unknown)"
  echo "sui-tunnel: $(systemctl is-active sui-tunnel 2>/dev/null || echo unknown)"
  echo "sui-panel-tunnel: $(systemctl is-active sui-panel-tunnel 2>/dev/null || echo unknown)"
  echo "sui-sync.timer: $(systemctl is-active sui-sync.timer 2>/dev/null || echo unknown)"
  local u pu
  u=$(tunnel_url)
  pu=$(panel_tunnel_url)
  echo "tunnel URL: ${u:-not found yet}"
  if [ -n "${pu}" ]; then
    echo "panel URL: ${pu}${PANEL_BASE_PATH:-/app/}"
  else
    echo "panel URL: not found yet"
  fi
  echo "----- last tunnel log lines -----"
  tail -15 "${TLOG}" 2>/dev/null || echo "(no log yet)"
  echo "----- last panel tunnel log lines -----"
  tail -15 "${PTLOG}" 2>/dev/null || echo "(no log yet)"
  echo "----- last sync -----"
  systemctl status sui-sync.service --no-pager -n 5 2>/dev/null | tail -5 || true
}

cmd_panel_on() {
  need_root panel-on
  load_state
  systemctl enable --now sui-panel-tunnel >/dev/null 2>&1 || die "failed to start sui-panel-tunnel"
  echo "waiting for panel tunnel URL (up to 45s)..."
  wait_panel_url || true
  local pu
  pu=$(panel_tunnel_url)
  if [ -n "${pu}" ]; then
    echo "Panel (internet): ${pu}${PANEL_BASE_PATH:-/app/}"
  else
    echo "Panel tunnel started but URL not ready yet; check: sudo bash install.sh show"
  fi
}

cmd_panel_off() {
  need_root panel-off
  systemctl disable --now sui-panel-tunnel >/dev/null 2>&1 || true
  echo "panel internet access is OFF (panel still reachable via SSH forward)."
  echo "Turn it back on with: sudo bash install.sh panel-on"
}

cmd_update_sui() {
  need_root update-sui
  load_state
  local old_ver backup
  old_ver=$("${BIN}/sui" -v 2>/dev/null | head -1 || echo "(none)")
  echo "current: ${old_ver}"
  echo "fetching latest s-ui from GitHub..."
  download_sui || die "update failed; current binary untouched"
  backup="${BIN}/sui.bak-$(date +%Y%m%d-%H%M)"
  if [ -x "${BIN}/sui" ]; then
    cp "${BIN}/sui" "${backup}" && echo "backup of old binary: ${backup}"
  fi
  mv "${BIN}/sui.new" "${BIN}/sui"
  echo "new: $("${BIN}/sui" -v 2>/dev/null | head -1)"
  systemctl restart sui-panel >/dev/null 2>&1 || die "failed to restart sui-panel"
  echo "panel restarted on the new s-ui. If anything misbehaves, restore the backup:"
  echo "  sudo cp ${backup} ${BIN}/sui && sudo systemctl restart sui-panel"
  echo "or pin a known version and re-run: SUI_VERSION=1.6.8 sudo bash install.sh update-sui"
  echo "then check: sudo bash install.sh status"
}

cmd_deploy_worker() {
  need_root deploy-worker
  load_state
  deploy_worker || die "worker deploy failed"
  load_state
  echo "worker redeployed: ${WORKER_URL:-}"
  echo "then sync panel routing + clients: sudo bash install.sh sync-now"
}

cmd_sync_now() {
  need_root sync-now
  load_state
  python3 "${DIR}/sync.py" "$@"
}

cmd_backup() {
  need_root backup
  load_state
  local stamp dest
  stamp=$(date +%Y%m%d-%H%M)
  dest="${TARGET_HOME}/sui-vpn-backup-${stamp}.tar.gz"
  # state.env (panel password, CF token, client UUIDs) + the s-ui DB are
  # the only copies of the secrets: without them a dead VPS means new
  # UUIDs and new subscription links for every client. Keep this file
  # OFF the server (it contains secrets — treat it like a password).
  tar czf "${dest}" -C "${TARGET_HOME}" sui-vpn 2>/dev/null \
    || die "backup failed"
  chmod 600 "${dest}"
  echo "backup written: ${dest} (mode 600)"
  echo "copy it OFF this server now; it contains all secrets."
}

cmd_uninstall() {
  need_root uninstall
  systemctl disable --now sui-sync.timer >/dev/null 2>&1 || true
  systemctl disable --now sui-panel-tunnel >/dev/null 2>&1 || true
  systemctl disable --now sui-tunnel >/dev/null 2>&1 || true
  systemctl disable --now sui-panel >/dev/null 2>&1 || true
  rm -f "${PANEL_UNIT}" "${TUN_UNIT}" "${PANEL_TUN_UNIT}" "${SYNC_UNIT}" "${TIMER_UNIT}"
  systemctl daemon-reload
  rm -f "${PTLOG}"
  rm -rf "${DIR}"
  echo "removed sui units and ${DIR} only. Old test units/files (vpntest-*, ~/vpn-test) and everything else untouched."
  echo "Note: the Cloudflare Worker + KV namespace were NOT deleted; remove them in the dashboard if wanted."
}

case "${1:-install}" in
  install) cmd_install ;;
  show) cmd_show ;;
  status) cmd_status ;;
  sync-now) shift; cmd_sync_now "$@" ;;
  deploy-worker) cmd_deploy_worker ;;
  update-sui) cmd_update_sui ;;
  panel-on) cmd_panel_on ;;
  panel-off) cmd_panel_off ;;
  backup) cmd_backup ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: bash install.sh [install|show|status|sync-now|deploy-worker|update-sui|panel-on|panel-off|backup|uninstall]" >&2; exit 1 ;;
esac
