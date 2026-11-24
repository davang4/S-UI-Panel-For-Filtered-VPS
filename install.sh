#!/usr/bin/env bash
# S-UI-Panel-For-Filtered-VPS — s-ui panel + Cloudflare quick tunnels + Workers subscription.
# Isolated install: ~/sui-vpn + units sui-panel / sui-tunnel / sui-panel-tunnel /
# sui-sync(.timer). Panel binds 127.0.0.1 only and is reachable from the
# internet only through its own quick tunnel under a secret base path
# (webPath, generated on-server). Inbound binds 127.0.0.1 only.
# Opens NO public ports, changes NO firewall, touches nothing else on the server.
# Ports are overridable: PANEL_PORT / SUB_PORT / IN_PORT env vars.
# If a port is already taken by another program, the installer says so
# and lets you type a different one (Enter = a random free port), or
# picks one itself when stdin is not a terminal (e.g. pasted into tmux).
# Resolved ports are saved in state.env, so re-runs keep them.
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
# One Worker + KV namespace serves exactly ONE server. A second server
# MUST use different names (same account and token are fine):
#   WORKER_NAME=my-panel-2 KV_TITLE=my-panel-2 sudo -E bash install.sh install
# Sharing one Worker + KV between servers mixes their panel URLs,
# subscription keys and SUB_SECRET — the symptom is a panel that
# "doesn't come up" while the VPN configs keep working.
# Names are custom and per-user on purpose: the Worker name and the
# workers.dev subdomain are the two labels of the fixed address, so a
# shared default (the same name for every repo user) would be one
# filter rule away from blocking all of them at once. Fresh installs
# ask the user for a custom Worker name (or take a random one), and
# register a custom workers.dev subdomain the same way.
WORKER_NAME_REQ="${WORKER_NAME:-}"
KV_TITLE_REQ="${KV_TITLE:-}"
# Fallback only — a fresh install replaces this via prompt_worker_name
# (custom or random); a re-install uses the stored names.
WORKER_NAME="${WORKER_NAME_REQ:-sui-sub}"
KV_TITLE="${KV_TITLE_REQ:-sui-sub}"
# Global command: after install, `sudo sui-vpn <command>` works from any
# directory (no cd). Overridable for tests: SUI_VPN_LINK.
GLOBAL_LINK="${SUI_VPN_LINK:-/usr/local/bin/sui-vpn}"
# One-click token creation: opens the dashboard with the exact permissions
# this installer needs already ticked (Workers Scripts Edit, Workers KV
# Storage Edit, Account Settings Read, all accounts, all zones) — the
# user only presses "Continue to summary" and "Create Token", then pastes
# the token below. Same link format used successfully since 2026-11-23.
TOKEN_LINK="https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22workers_kv_storage%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22account_settings%22%2C%22type%22%3A%22read%22%7D%5D&accountId=*&zoneId=all&name=SUI-Panel-Sub"
CF_API="https://api.cloudflare.com/client/v4"

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
# Resolve symlinks: when run as `sui-vpn` (/usr/local/bin/sui-vpn ->
# ~/sui-vpn/install.sh), $0 points at the link, not the real script.
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
BUNDLE_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
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

port_in_use() {
  # port_in_use PORT — 0 if something listens on it (TCP). No ss → assume free.
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | grep -q ":${1} "
}

port_listener() {
  # port_listener PORT — process name listening on it, or empty.
  ss -ltnp 2>/dev/null | grep ":${1} " | head -1 \
    | sed -n 's/.*users:(("\([^"]*\)".*/\1/p'
}

valid_free_port() {
  # valid_free_port CANDIDATE OTHER1 OTHER2 — numeric, 1024-65535,
  # not listening, and not one of the other two ports.
  local c="$1"
  case "${c}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${c}" -ge 1024 ] && [ "${c}" -le 65535 ] || return 1
  [ "${c}" != "${2:-}" ] && [ "${c}" != "${3:-}" ] || return 1
  port_in_use "${c}" && return 1
  return 0
}

random_free_port() {
  # random_free_port OTHER1 OTHER2 — print a random free port (20000-59999).
  local i p
  for i in $(seq 1 100); do
    p=$((20000 + RANDOM % 40000))
    if valid_free_port "${p}" "${1:-}" "${2:-}"; then echo "${p}"; return 0; fi
  done
  return 1
}

resolve_port() {
  # resolve_port VAR LABEL OTHER1 OTHER2 — if $VAR is taken by a foreign
  # process, ask for another port (interactive) or auto-pick a random
  # free one (non-interactive, e.g. pasted into tmux). A port our own
  # s-ui listens on is kept silently (re-run safety).
  local var="$1" label="$2" o1="$3" o2="$4" port owner suggestion answer
  port="${!var}"
  port_in_use "${port}" || return 0
  owner=$(port_listener "${port}")
  case "${owner}" in
    sui|sing-box|xray)
      echo "port ${port} (${label}) already used by our s-ui — keeping it"
      return 0 ;;
  esac
  echo "port ${port} (${label}) is already in use${owner:+ by ${owner}}; the install needs a different one."
  suggestion=$(random_free_port "${o1}" "${o2}") \
    || die "could not find a free port for ${label}; set one explicitly, e.g. ${var}=12345 sudo -E bash install.sh install"
  if [ -t 0 ]; then
    while :; do
      printf 'Enter a different port for %s (1024-65535), or press Enter to use %s: ' "${label}" "${suggestion}"
      read -r answer || answer=""
      if [ -z "${answer}" ]; then port="${suggestion}"; else port="${answer}"; fi
      if valid_free_port "${port}" "${o1}" "${o2}"; then break; fi
      echo "port ${port} is not usable (must be 1024-65535, free, and different from ${o1}/${o2})."
      suggestion=$(random_free_port "${o1}" "${o2}") \
        || die "could not find a free port for ${label}; set one explicitly, e.g. ${var}=12345 sudo -E bash install.sh install"
    done
  else
    echo "non-interactive shell: using free port ${suggestion} for ${label} automatically."
    port="${suggestion}"
  fi
  printf -v "${var}" '%s' "${port}"
  echo "${label} port: ${port}"
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
  resolve_port PANEL_PORT panel "${SUB_PORT}" "${IN_PORT}"
  resolve_port SUB_PORT "subscription server" "${PANEL_PORT}" "${IN_PORT}"
  resolve_port IN_PORT "VLESS inbound" "${PANEL_PORT}" "${SUB_PORT}"
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
    echo "PANEL_PORT=${PANEL_PORT}"
    echo "SUB_PORT=${SUB_PORT}"
    echo "IN_PORT=${IN_PORT}"
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

load_db_ports() {
  # Best-effort: on a re-run with a state file from before ports were
  # stored, keep the panel bindings already in the s-ui DB instead of
  # falling back to the defaults (which would move the panel). Anything
  # it cannot read simply stays at the current value.
  [ -f "${DBFILE}" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local out web sub inb
  out=$(python3 - "${DBFILE}" <<'PYEOF' 2>/dev/null || true
import sqlite3, json, sys
con = sqlite3.connect(sys.argv[1])
def get(k):
    r = con.execute("SELECT value FROM settings WHERE key=?", (k,)).fetchone()
    return r[0] if r else ""
web, sub = get("webPort"), get("subPort")
inb = ""
try:
    for (cfg,) in con.execute("SELECT config FROM inbounds"):
        j = json.loads(cfg)
        if j.get("protocol") == "vless" and j.get("port"):
            inb = str(j["port"]); break
except Exception:
    pass
print(web, sub, inb)
PYEOF
)
  read -r web sub inb <<< "${out}"
  [ -n "${web}" ] || return 1
  PANEL_PORT="${web}"
  [ -n "${sub}" ] && SUB_PORT="${sub}"
  [ -n "${inb}" ] && IN_PORT="${inb}"
  echo "keeping panel ports from the existing install: ${PANEL_PORT}/${SUB_PORT}/${IN_PORT}"
  return 0
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

resolve_worker_names() {
  # Effective Worker/KV names: an explicit env value wins, then the names
  # stored from a previous deploy (state.env), then the defaults.
  # Sets WORKER_NAME / KV_TITLE and remembers the stored KV title in
  # STORED_KV_TITLE for the reuse decision below.
  # NOTE: the stored values are read from the state FILE, not the shell
  # variables — an env value given on the command line is already in the
  # shell variables at this point, and mistaking it for "stored" made
  # the installer reuse the old shared namespace when moving a server
  # to new names (the worker got the new name, the KV did not).
  local stored_name="" stored_title=""
  if [ -f "${STATE}" ]; then
    stored_name=$(grep '^WORKER_NAME=' "${STATE}" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    stored_title=$(grep '^KV_TITLE=' "${STATE}" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  fi
  WORKER_NAME="${WORKER_NAME_REQ:-${stored_name:-sui-sub}}"
  KV_TITLE="${KV_TITLE_REQ:-${stored_title:-sui-sub}}"
  STORED_WORKER_NAME="${stored_name}"
  STORED_KV_TITLE="${stored_title}"
}

random_name() {
  # A random, prefix-free name: a letter + 10 hex chars, e.g. w687a1a960e.
  # No shared string, so no two repo users share a fingerprint in
  # their fixed address.
  printf 'w%s' "$(head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

valid_subdomain() {
  # Cloudflare workers.dev subdomain: lowercase letters, digits,
  # hyphens; 1-63 chars; must not start or end with a hyphen.
  [ -n "$1" ] || return 1
  [ "${#1}" -le 63 ] || return 1
  case "$1" in *[!a-z0-9-]*) return 1 ;; esac
  case "$1" in -*) return 1 ;; esac
  case "$1" in *-) return 1 ;; esac
  return 0
}

valid_worker_name() {
  # Worker name: starts with a letter; letters, digits, hyphens,
  # underscores; 1-63 chars.
  [ -n "$1" ] || return 1
  [ "${#1}" -le 63 ] || return 1
  case "$1" in *[!a-zA-Z0-9_-]*) return 1 ;; esac
  case "$1" in [!a-zA-Z]*) return 1 ;; esac
  return 0
}

prompt_worker_name() {
  # Fresh install, no explicit name: let the user pick a custom Worker
  # name (interactive), or take a random one (non-interactive). The name
  # is the first label of the fixed address, so a shared default would
  # be a fingerprint one filter rule could block for every repo user.
  # Sets WORKER_NAME (and KV_TITLE, unless explicitly requested).
  local suggestion answer
  suggestion=$(random_name)
  if [ -t 0 ]; then
    echo "Pick a Worker name for this server — it is the first part of your fixed address."
    echo "Choose something unique (not 'sui-sub'), or press Enter to use ${suggestion}."
    printf 'Worker name (Enter for %s): ' "${suggestion}"
    read -r answer || answer=""
    if [ -z "${answer}" ]; then
      WORKER_NAME="${suggestion}"
    else
      WORKER_NAME="$(printf '%s' "${answer}" | tr 'A-Z' 'a-z')"
    fi
    if ! valid_worker_name "${WORKER_NAME}"; then
      echo "'${WORKER_NAME}' is not a valid Worker name (starts with a letter; letters, digits, hyphens, underscores; up to 63 chars); using ${suggestion} instead."
      WORKER_NAME="${suggestion}"
    fi
  else
    echo "no Worker name given; using '${suggestion}' for this server (set WORKER_NAME to choose your own)."
    WORKER_NAME="${suggestion}"
  fi
  if [ -z "${KV_TITLE_REQ}" ]; then KV_TITLE="${WORKER_NAME}"; fi
  set_state WORKER_NAME "${WORKER_NAME}"
  set_state KV_TITLE "${KV_TITLE}"
}

register_subdomain() {
  # Sets SUBDOMAIN (global) to the account's workers.dev subdomain.
  # If the account has none, registers one — an explicit
  # WORKERS_SUBDOMAIN, a custom name the user types, or a random one.
  # Never a shared/predictable name: one filter rule on a shared
  # address would block every repo user at once. Returns 0 on success.
  local resp candidate ok tries suggestion answer
  resp=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/workers/subdomain")
  SUBDOMAIN=$(printf '%s' "${resp}" | python3 -c "import sys,json;print((json.load(sys.stdin).get('result') or {}).get('subdomain',''))" 2>/dev/null)
  [ -n "${SUBDOMAIN}" ] && return 0
  if [ -n "${WORKERS_SUBDOMAIN:-}" ]; then
    candidate="$(printf '%s' "${WORKERS_SUBDOMAIN}" | tr 'A-Z' 'a-z')"
    if valid_subdomain "${candidate}"; then
      resp=$(cf_api PUT "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" "{\"subdomain\":\"${candidate}\"}")
      ok=$(printf '%s' "${resp}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('success'))" 2>/dev/null)
      if [ "${ok}" = "True" ]; then
        SUBDOMAIN="${candidate}"; echo "registered workers.dev subdomain: ${SUBDOMAIN}"; return 0
      fi
      echo "WORKERS_SUBDOMAIN '${candidate}' was not accepted (taken or invalid)."
    else
      echo "WORKERS_SUBDOMAIN '${candidate}' is not a valid subdomain; ignoring it."
    fi
  fi
  if [ -t 0 ]; then
    echo "This Cloudflare account has no workers.dev subdomain yet. It becomes part of your fixed address — pick a custom, unique name, not 'suisub' or anything from this repo, so one filter rule can't block every user at once."
  fi
  tries=0
  while [ "${tries}" -lt 8 ]; do
    tries=$((tries + 1))
    if [ -t 0 ]; then
      suggestion=$(random_name)
      printf 'workers.dev subdomain (Enter for %s): ' "${suggestion}"
      read -r answer || answer=""
      if [ -z "${answer}" ]; then
        candidate="${suggestion}"
      else
        candidate="$(printf '%s' "${answer}" | tr 'A-Z' 'a-z')"
      fi
      if ! valid_subdomain "${candidate}"; then
        echo "'${candidate}' is not a valid subdomain (lowercase letters, digits, hyphens; 1-63 chars)."
        continue
      fi
    else
      candidate=$(random_name)
    fi
    resp=$(cf_api PUT "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" "{\"subdomain\":\"${candidate}\"}")
    ok=$(printf '%s' "${resp}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('success'))" 2>/dev/null)
    if [ "${ok}" = "True" ]; then
      SUBDOMAIN="${candidate}"; echo "registered workers.dev subdomain: ${SUBDOMAIN}"; return 0
    fi
    echo "subdomain '${candidate}' was not accepted (taken or invalid); trying another..."
  done
  echo "could not register a workers.dev subdomain: ${resp}"
  echo "Register one in the dashboard (Workers & Pages) and re-run deploy-worker."
  return 1
}

worker_name_taken() {
  # worker_name_taken NAME — 0 if a Worker with that name already exists.
  local code
  code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' \
    "${CF_API}/accounts/${CF_ACCOUNT_ID}/workers/scripts/${1}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null || echo 000)
  [ "${code}" = "200" ]
}

kv_title_taken() {
  # kv_title_taken TITLE — 0 if a KV namespace with that title exists.
  local found
  found=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100" 2>/dev/null \
    | KV_TITLE="$1" python3 -c "
import sys,json,os
d=json.load(sys.stdin)
print(1 if any(n.get('title')==os.environ['KV_TITLE'] for n in d.get('result') or []) else 0)
" 2>/dev/null)
  [ "${found}" = "1" ]
}

names_free() {
  # names_free NAME — 0 if BOTH the Worker name and the KV title are free.
  worker_name_taken "$1" && return 1
  kv_title_taken "$1" && return 1
  return 0
}

suggest_worker_names() {
  # Print the first free Worker/KV name, starting from the requested one
  # (sui-sub -> sui-sub-2 -> sui-sub-3 ...; sui-sub-2 -> sui-sub-3 ...).
  local stem tail suffix candidate
  tail="${WORKER_NAME##*-}"
  case "${tail}" in
    ''|*[!0-9]*) stem="${WORKER_NAME}"; suffix=1 ;;
    *) stem="${WORKER_NAME%-*}"; suffix="${tail}" ;;
  esac
  candidate="${WORKER_NAME}"
  while :; do
    if names_free "${candidate}"; then echo "${candidate}"; return 0; fi
    suffix=$((suffix + 1))
    [ "${suffix}" -gt 60 ] && return 1
    candidate="${stem}-${suffix}"
  done
}

ensure_unique_worker_names() {
  # A fresh install must never silently reuse another server's Worker +
  # KV: if the requested names are taken, say so and pick the next free
  # pair — or let the user type a name when interactive. One API token
  # can therefore serve any number of panels (sui-sub, sui-sub-2, ...).
  local suggestion answer requested="${WORKER_NAME}"
  if [ -t 0 ]; then
    while ! names_free "${WORKER_NAME}"; do
      suggestion=$(suggest_worker_names) \
        || die "could not find a free Worker/KV name; set WORKER_NAME and KV_TITLE explicitly"
      echo "Worker name '${WORKER_NAME}' (or KV title '${KV_TITLE}') is already used by another install."
      printf 'Enter a Worker name for this server, or press Enter to use %s: ' "${suggestion}"
      read -r answer || answer=""
      if [ -z "${answer}" ]; then
        WORKER_NAME="${suggestion}"; KV_TITLE="${suggestion}"
      else
        WORKER_NAME="${answer}"; KV_TITLE="${answer}"
      fi
    done
  else
    if ! names_free "${WORKER_NAME}"; then
      suggestion=$(suggest_worker_names) \
        || die "could not find a free Worker/KV name; set WORKER_NAME and KV_TITLE explicitly"
      echo "Worker name '${WORKER_NAME}' (or KV title '${KV_TITLE}') is already used by another install."
      echo "non-interactive shell: using '${suggestion}' for this server automatically."
      WORKER_NAME="${suggestion}"; KV_TITLE="${suggestion}"
    fi
  fi
  if [ "${WORKER_NAME}" != "${requested}" ]; then
    set_state WORKER_NAME "${WORKER_NAME}"
    set_state KV_TITLE "${KV_TITLE}"
    echo "this server will use Worker '${WORKER_NAME}' and KV '${KV_TITLE}'"
  fi
}

stored_ns_title() {
  # stored_ns_title NS_ID — print the title of that KV namespace (or empty).
  cf_api GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${1}" 2>/dev/null \
    | python3 -c "import sys,json;print((json.load(sys.stdin).get('result') or {}).get('title',''))" 2>/dev/null
}

kv_reuse_allowed() {
  # 0 (reuse the stored KV namespace id) when the stored title matches
  # the effective one, or when neither an explicit title nor a stored
  # title exists (legacy same-server re-deploy).
  [ "${STORED_KV_TITLE}" = "${KV_TITLE}" ] && return 0
  [ -z "${KV_TITLE_REQ}" ] && [ -z "${STORED_KV_TITLE}" ] && return 0
  return 1
}

install_global_command() {
  # Copy the installer next to the state (so it survives the bundle dir
  # being deleted) and link it into PATH: `sudo sui-vpn <command>`
  # works from any directory afterwards.
  if [ "${BUNDLE_DIR}" != "${DIR}" ]; then
    cp "${BUNDLE_DIR}/install.sh" "${DIR}/install.sh" || return 1
  fi
  chmod +x "${DIR}/install.sh" || return 1
  ln -sf "${DIR}/install.sh" "${GLOBAL_LINK}" || return 1
  echo "global command installed: sudo sui-vpn <command> (works from any directory)"
  return 0
}

remove_global_command() {
  rm -f "${GLOBAL_LINK}"
}

deploy_worker() {
  # Prompts for CF token + account id (hidden), deploys worker + KV.
  # On any failure: print fallback steps and return 1 (install continues).
  load_state
  if [ -z "${CF_API_TOKEN:-}" ]; then
    echo ""
    echo "Cloudflare API token needed for the Workers subscription."
    echo "Create it with one click (permissions pre-filled; just press"
    echo "\"Continue to summary\" and \"Create Token\"):"
    echo "  ${TOKEN_LINK}"
    echo "Or create it manually at: dash.cloudflare.com -> My Profile -> API Tokens -> Create Token"
    echo "Permissions: Account > Workers Scripts > Edit, Account > Workers KV Storage > Edit,"
    echo "Account > Account Settings > Read"
    read -r -s -p "Paste Cloudflare API token (hidden): " CF_API_TOKEN; echo ""
    [ -n "${CF_API_TOKEN}" ] || { echo "no token given; skipping worker deploy"; return 1; }
    set_state CF_API_TOKEN "${CF_API_TOKEN}"
  fi
  export CF_API_TOKEN

  # Verify the token before doing anything else, so a wrong token or a
  # token without Workers permissions fails here with a clear message
  # instead of halfway through the deploy.
  local verify tok_ok
  verify=$(cf_api GET "/user/tokens/verify")
  tok_ok=$(printf '%s' "${verify}" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('success'))" 2>/dev/null)
  if [ "${tok_ok}" != "True" ]; then
    echo "Cloudflare token check failed: ${verify}"
    echo "Check the token and its permissions (Account > Workers Scripts > Edit,"
    echo "Account > Workers KV Storage > Edit), then re-run deploy-worker."
    return 1
  fi

  # Pick the account automatically: most tokens see exactly one account.
  # With several, list them and ask which one; with none, the token is
  # useless for this deploy.
  if [ -z "${CF_ACCOUNT_ID:-}" ]; then
    local accts count
    accts=$(cf_api GET "/accounts?per_page=100")
    count=$(printf '%s' "${accts}" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('result') or []))" 2>/dev/null)
    if [ "${count}" = "1" ]; then
      CF_ACCOUNT_ID=$(printf '%s' "${accts}" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('result') or [{}])[0].get('id',''))" 2>/dev/null)
      echo "using Cloudflare account: ${CF_ACCOUNT_ID}"
    elif [ -n "${count}" ] && [ "${count}" -gt 1 ]; then
      echo "this token can see ${count} accounts:"
      printf '%s' "${accts}" | python3 -c "import sys,json;d=json.load(sys.stdin);[print('  '+str(a.get('id'))+'  '+str(a.get('name',''))) for a in d.get('result') or []]" 2>/dev/null
      read -r -p "Cloudflare Account ID: " CF_ACCOUNT_ID
    else
      echo "this token cannot see any Cloudflare account: ${accts}"
      return 1
    fi
    [ -n "${CF_ACCOUNT_ID}" ] || { echo "no account id given; skipping worker deploy"; return 1; }
    set_state CF_ACCOUNT_ID "${CF_ACCOUNT_ID}"
  fi
  export CF_ACCOUNT_ID

  # Effective Worker/KV names (explicit env > stored > defaults). A
  # second server needs different names — see the comment at the top.
  resolve_worker_names
  set_state WORKER_NAME "${WORKER_NAME}"
  set_state KV_TITLE "${KV_TITLE}"

  # Fresh install, no explicit name: never use a shared default Worker
  # name — it would be the first label of every user's fixed address.
  if [ -z "${STORED_WORKER_NAME}" ] && [ -z "${WORKER_NAME_REQ}" ]; then
    prompt_worker_name
  fi

  # Fresh install (no stored names) or a request for different names:
  # never silently reuse another server's Worker + KV. A re-install of
  # this same server keeps its stored names and skips this check.
  if [ -z "${STORED_WORKER_NAME}" ] \
     || { [ -n "${WORKER_NAME_REQ}" ] && [ "${WORKER_NAME_REQ}" != "${STORED_WORKER_NAME}" ]; } \
     || { [ -n "${KV_TITLE_REQ}" ] && [ "${KV_TITLE_REQ}" != "${STORED_KV_TITLE}" ]; }; then
    ensure_unique_worker_names
  fi

  # KV namespace (create or reuse). Re-deploying must reuse the namespace
  # the worker is already bound to — creating a second namespace with
  # the same title would leave the worker reading the old, now-stale
  # one. So: look up by title FIRST, create only if absent.
  local resp ns_id old_ns_id
  old_ns_id="${KV_NAMESPACE_ID:-}"
  if [ -n "${KV_NAMESPACE_ID:-}" ] && kv_reuse_allowed; then
    # Verify the stored id really is the namespace with this title —
    # an earlier buggy deploy could have recorded a mismatched id.
    if [ "$(stored_ns_title "${KV_NAMESPACE_ID}")" = "${KV_TITLE}" ]; then
      ns_id="${KV_NAMESPACE_ID}"
      echo "reusing KV namespace: ${ns_id}"
    else
      echo "stored KV namespace id is not the '${KV_TITLE}' namespace; looking it up by title instead"
    fi
  fi
  if [ -z "${ns_id:-}" ]; then
    resp=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
    ns_id=$(printf '%s' "${resp}" | KV_TITLE="${KV_TITLE}" python3 -c "
import sys,json,os
d=json.load(sys.stdin)
for n in d.get('result') or []:
    if n.get('title')==os.environ['KV_TITLE']:
        print(n.get('id','')); break
" 2>/dev/null)
    if [ -z "${ns_id}" ]; then
      resp=$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" "{\"title\":\"${KV_TITLE}\"}")
      ns_id=$(printf '%s' "${resp}" | python3 -c "import sys,json;d=json.load(sys.stdin);print((d.get('result') or {}).get('id',''))" 2>/dev/null)
    fi
  fi
  [ -n "${ns_id}" ] || { echo "KV namespace create failed: ${resp}"; return 1; }
  if [ -n "${old_ns_id}" ] && [ "${ns_id}" != "${old_ns_id}" ]; then
    # Moved to a different namespace: the sync digest does not cover the
    # namespace, so drop the old sync state — otherwise the next sync
    # would report "unchanged" and never write to the new namespace.
    rm -f "${DIR}/sync-state.json"
    echo "moved to a new KV namespace; sync state reset so the next sync writes everything there"
  fi
  set_state KV_NAMESPACE_ID "${ns_id}"
  export KV_NAMESPACE_ID="${ns_id}"
  echo "KV namespace ready: ${ns_id}"

  # Guard: one Worker + KV serves exactly one server. sync.py stamps
  # each namespace with server:id (this install's CLIENT_UUID). If this
  # namespace already belongs to another server, say so loudly instead
  # of silently taking over its panel URL and subscriptions.
  local kv_body kv_code existing_server
  kv_body=$(curl -s --max-time 15 -w '\n%{http_code}' \
    "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/values/server:id" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null || echo "000")
  kv_code=$(printf '%s' "${kv_body}" | tail -1)
  existing_server=$(printf '%s' "${kv_body}" | head -n -1)
  if [ "${kv_code}" = "200" ] && [ -n "${existing_server}" ] \
     && [ -n "${CLIENT_UUID:-}" ] && [ "${existing_server}" != "${CLIENT_UUID}" ]; then
    echo "WARNING: this KV namespace already belongs to another server (server:id ${existing_server})."
    echo "Sharing one Worker + KV between servers mixes their panel URLs and subscriptions."
    echo "Give this server its own names and re-run, e.g.:"
    echo "  WORKER_NAME=sui-sub-2 KV_TITLE=sui-sub-2 sudo -E bash install.sh deploy-worker"
    echo "Continuing with the shared namespace in 10s (Ctrl-C to stop)..."
    sleep 10
  fi

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

  # Enable workers.dev route + get account subdomain (a custom/random
  # one is registered if the account has none — see register_subdomain;
  # without a subdomain the worker has no fixed address at all).
  cf_api POST "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" '{"enabled":true}' >/dev/null
  register_subdomain || return 1
  set_state WORKER_URL "https://${WORKER_NAME}.${SUBDOMAIN}.workers.dev"
  echo "worker URL: https://${WORKER_NAME}.${SUBDOMAIN}.workers.dev"

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
  if [ -f "${STATE}" ]; then
    load_state
    if ! grep -q '^PANEL_PORT=' "${STATE}" 2>/dev/null; then
      load_db_ports || true
    fi
  fi
  preflight
  mkdir -p "${DIR}" "${BIN}"
  download_binaries
  gen_state
  # Persist the (possibly re-resolved) ports so re-runs and sui_setup.py
  # use the same ones instead of falling back to the defaults.
  set_state PANEL_PORT "${PANEL_PORT}"
  set_state SUB_PORT "${SUB_PORT}"
  set_state IN_PORT "${IN_PORT}"
  ensure_base_path
  # ship runtime scripts next to state (sync.py / sui_setup.py read state.env beside them)
  cp "${BUNDLE_DIR}/sync.py" "${BUNDLE_DIR}/sui_setup.py" "${BUNDLE_DIR}/worker.js" "${DIR}/" \
    || die "bundle scripts not found next to install.sh"
  chmod 700 "${DIR}/sync.py" "${DIR}/sui_setup.py"
  install_global_command \
    || echo "warning: could not install the global sui-vpn command (use bash install.sh from this directory)"
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
  if [ -n "${WORKER_URL:-}" ]; then
    echo "Panel (fixed): ${WORKER_URL}${PANEL_BASE_PATH:-/app/}"
  else
    echo "Panel (fixed): worker not deployed yet (see README fallback)"
  fi
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

cmd_restore() {
  need_root restore
  local file="${1:-}"
  [ -n "${file}" ] || die "usage: sudo bash install.sh restore <backup-file.tar.gz>"
  [ -f "${file}" ] || die "backup file not found: ${file}"
  tar tzf "${file}" 2>/dev/null | grep -qx "sui-vpn/state.env" \
    || die "not a sui-vpn backup (no sui-vpn/state.env inside)"
  if [ -d "${DIR}" ]; then
    echo "current ${DIR} will be replaced by the backup."
    read -r -p "Continue? [y/N] " ans
    case "${ans}" in y|Y) : ;; *) echo "aborted"; return 0 ;; esac
    systemctl stop sui-panel sui-tunnel sui-panel-tunnel sui-sync.timer 2>/dev/null || true
  fi
  tar xzf "${file}" -C "${TARGET_HOME}" \
    || die "restore failed while extracting"
  chmod 600 "${STATE}" 2>/dev/null || true
  # systemd units live outside the backup; on a fresh server run install
  # first (it keeps the restored state instead of generating a new one).
  if [ -f "${PANEL_UNIT}" ]; then
    systemctl daemon-reload
    systemctl restart sui-panel sui-tunnel sui-panel-tunnel 2>/dev/null || true
    systemctl enable --now sui-sync.timer >/dev/null 2>&1 || true
    python3 "${DIR}/sync.py" || echo "sync will retry every 60s"
    echo "restored ${DIR} from ${file}; services restarted."
    echo "check: sudo bash install.sh status"
  else
    echo "restored ${DIR} from ${file}, but no sui units are installed."
    echo "run: sudo bash install.sh install   (it keeps the restored state)"
  fi
}

cmd_uninstall() {
  need_root uninstall
  remove_global_command
  systemctl disable --now sui-sync.timer >/dev/null 2>&1 || true
  systemctl disable --now sui-panel-tunnel >/dev/null 2>&1 || true
  systemctl disable --now sui-tunnel >/dev/null 2>&1 || true
  systemctl disable --now sui-panel >/dev/null 2>&1 || true
  rm -f "${PANEL_UNIT}" "${TUN_UNIT}" "${PANEL_TUN_UNIT}" "${SYNC_UNIT}" "${TIMER_UNIT}"
  systemctl daemon-reload
  rm -f "${PTLOG}"
  rm -rf "${DIR}"
  echo "removed sui units and ${DIR} only. Everything else untouched."
  echo "Note: the Cloudflare Worker + KV namespace were NOT deleted;"
  echo "remove them in the dashboard if wanted (see README: Uninstall)."
}

cmd_help() {
  cat <<'EOF'
usage: bash install.sh <command>
       (after install, from any directory: sudo sui-vpn <command>)
  install        full install (panel + tunnels + worker + sync timer)
  show           panel URL, tunnel URL, fixed subscription URL
  status         service states + tunnel logs + last sync
  sync-now       sync clients to the Worker now [--dry-run to preview]
  deploy-worker  re-upload worker.js to Cloudflare
  update-sui     replace s-ui with the newest GitHub release
  panel-on       allow panel access from the internet
  panel-off      panel reachable only via SSH forward
  backup         tarball of ~/sui-vpn (contains secrets)
  restore <file> restore ~/sui-vpn from a backup tarball
  uninstall      remove the install (Worker + KV stay in Cloudflare)
  help           show this list
EOF
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
  restore) shift; cmd_restore "$@" ;;
  uninstall) cmd_uninstall ;;
  help) cmd_help ;;
  *) cmd_help >&2; exit 1 ;;
esac
