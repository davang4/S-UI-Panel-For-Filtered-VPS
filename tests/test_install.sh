#!/usr/bin/env bash
# Tests for install.sh — run from the repo root:  bash tests/test_install.sh
# Covers the behaviours added 2026-11-25: the real end-to-end health
# check (worker /sub, panel via tunnel, last sync state), the pre-change
# backup before update/reinstall, and the sui-sync.path unit.
# The functions are extracted from install.sh (the file's own dispatch
# at the bottom must never run in a test), with systemctl/curl stubbed.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { # check <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing: $3)"; fi
}
check_not() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpected: $3)"; fi
}

extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" {
      print
      if ($0 ~ "\\}$") exit   # one-line function: tunnel_url() { ...; }
      on=1
      next
    }
    on { print }
    on && /^}$/ { exit }
  ' "${REPO}/install.sh"
}
FN_TMP="${TMP}/fns.sh"
: > "${FN_TMP}"
for fn in die sync_state_info run_checks backup_before_change write_units \
          _url_from_log tunnel_url panel_tunnel_url server_code \
          local_client_uuids panel_sub_secret kv_get_value \
          find_own_namespace worker_own_namespace guard_namespace_owner; do
  extract_fn "${fn}" >> "${FN_TMP}"
done
# shellcheck disable=SC1090
source "${FN_TMP}"

# ---- fake install dir ----
DIR="${TMP}/sui-vpn"
BIN="${DIR}/bin"
mkdir -p "${DIR}/db" "${BIN}"
STATE="${DIR}/state.env"
DBFILE="${DIR}/db/s-ui.db"
TLOG="${DIR}/tunnel.log"
PTLOG="${DIR}/panel-tunnel.log"
echo "db" > "${DBFILE}"
echo "state" > "${STATE}"
PANEL_PORT=12095; SUB_PORT=12096; IN_PORT=11087
PANEL_BASE_PATH="/app-xyz/"
WORKER_URL="https://sui-sub-3.test.workers.dev"
CLIENT_UUID="5c0b21ef-178a-4b3e-b0f3-4a813e7073ee"
SUB_SECRET=""
PANEL_UNIT="${TMP}/sui-panel.service"
TUN_UNIT="${TMP}/sui-tunnel.service"
PANEL_TUN_UNIT="${TMP}/sui-panel-tunnel.service"
SYNC_UNIT="${TMP}/sui-sync.service"
TIMER_UNIT="${TMP}/sui-sync.timer"
PATH_UNIT="${TMP}/sui-sync.path"
printf 'Requesting new quick Tunnel\nhttps://abc-try-123.trycloudflare.com\n' > "${TLOG}"
printf 'Requesting new quick Tunnel\nhttps://panel-try-456.trycloudflare.com\n' > "${PTLOG}"

# ---- stubs ----
systemctl() { return 0; }
curl() {
  local url="${@: -1}"
  if [[ "${url}" == "http://127.0.0.1:${PANEL_PORT}/" ]]; then printf '404'; else printf '200'; fi
}

# ---- backup_before_change ----
mkdir -p "${DIR}/backups"
for i in 1 2 3 4 5 6; do
  touch "${DIR}/backups/pre-change-2026010${i}-000000.tar.gz"
done
echo '{"last_run": 1764090000, "last_error": null}' > "${DIR}/sync-state.json"
out="$(backup_before_change)"
check "backup prints its path" "${out}" "pre-change backup:"
count=$(ls "${DIR}"/backups/pre-change-*.tar.gz | wc -l)
[ "${count}" = "5" ] && ok "backup keeps only the last 5 snapshots" \
  || bad "backup keeps only the last 5 snapshots (got ${count})"
newest=$(ls -t "${DIR}"/backups/pre-change-*.tar.gz | head -1)
tar tzf "${newest}" > "${TMP}/contents.txt" 2>/dev/null
check "backup contains the DB" "$(cat "${TMP}/contents.txt")" "db/s-ui.db"
check "backup contains state.env" "$(cat "${TMP}/contents.txt")" "state.env"
check "backup contains sync-state.json" "$(cat "${TMP}/contents.txt")" "sync-state.json"

# ---- run_checks: healthy ----
now=$(date +%s)
echo "{\"last_run\": ${now}, \"last_error\": null}" > "${DIR}/sync-state.json"
out="$(run_checks)"
check "health: worker /sub serves the client" "${out}" "PASS worker /sub serves this client (HTTP 200)"
check "health: panel via tunnel" "${out}" "PASS panel login page via tunnel (HTTP 200)"
check "health: last sync fresh" "${out}" "PASS last sync"
check "health: worker /health" "${out}" "PASS worker /health OK"

# ---- run_checks: last sync error ----
echo "{\"last_run\": ${now}, \"last_error\": \"KV PUT failed for davang: [{}]\"}" > "${DIR}/sync-state.json"
out="$(run_checks)"
check "health: last sync error shown" "${out}" "FAIL last sync error: KV PUT failed for davang"

# ---- run_checks: stale sync ----
echo "{\"last_run\": $((now - 3600)), \"last_error\": null}" > "${DIR}/sync-state.json"
out="$(run_checks)"
check "health: stale sync flagged" "${out}" "FAIL last sync stale:"

# ---- run_checks: no sync yet ----
rm -f "${DIR}/sync-state.json"
out="$(run_checks)"
check "health: no sync yet is a skip" "${out}" "SKIP last sync state (no sync has run yet)"

# ---- write_units: path unit ----
write_units
check "path unit exists" "$(ls "${PATH_UNIT}" 2>/dev/null)" "${PATH_UNIT}"
check "path unit watches the tunnel log" "$(cat "${PATH_UNIT}")" "PathChanged=${TLOG}"
check "path unit watches the panel tunnel log" "$(cat "${PATH_UNIT}")" "PathChanged=${PTLOG}"
check "path unit triggers the sync service" "$(cat "${PATH_UNIT}")" "Unit=sui-sync.service"
check "timer still written" "$(ls "${TIMER_UNIT}" 2>/dev/null)" "${TIMER_UNIT}"

# ---- server code + self-recognition ----
UUID1="5c0b21ef-178a-4b3e-b0f3-4a813e7073ee"
UUID2="6d1c32f0-289b-5c4f-c104-5b924f8184ff"
OTHER_UUID="aaaaaaaa-1111-2222-3333-444444444444"
CLIENT_UUID="${UUID1}"
CF_API="https://api.cloudflare.com/client/v4"
CF_ACCOUNT_ID="acct1"
CF_API_TOKEN="fake-token"
# A real panel DB: two clients + a subURI carrying a secret.
PANEL_DB="${TMP}/panel.db"
python3 - "${PANEL_DB}" <<'PYEOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE clients (name TEXT, enable INTEGER, config TEXT, volume INTEGER, expiry INTEGER, up INTEGER, down INTEGER)")
for name, uuid in (("davang", "5c0b21ef-178a-4b3e-b0f3-4a813e7073ee"), ("friend", "6d1c32f0-289b-5c4f-c104-5b924f8184ff")):
    con.execute("INSERT INTO clients VALUES (?,?,?,?,?,?,?)",
                (name, 1, json.dumps({"vless": {"uuid": uuid}}), 0, 0, 0, 0))
con.execute("CREATE TABLE settings (key TEXT, value TEXT)")
con.execute("INSERT INTO settings VALUES ('subURI', 'https://sui-sub-3.test.workers.dev/sub/abcdef1234567890/')")
con.commit(); con.close()
PYEOF
DBFILE="${PANEL_DB}"

[ "$(server_code)" = "5c0b21ef" ] && ok "server code is the first 8 chars of the identity UUID" \
  || bad "server code (got $(server_code))"
uuids="$(local_client_uuids)"
check "local client UUIDs from the panel DB" "${uuids}" "${UUID1}"
check "local client UUIDs include the second client" "${uuids}" "${UUID2}"
[ "$(panel_sub_secret)" = "abcdef1234567890" ] && ok "SUB_SECRET recovered from the panel subURI" \
  || bad "SUB_SECRET recovery (got $(panel_sub_secret))"

# Stubs for the Cloudflare calls the recognition helpers make.
CURL_MODE="id"
cf_api() {
  case "$2" in
    *"/storage/kv/namespaces?per_page=100"*)
      printf '%s' '{"success":true,"result":[{"id":"ns-own","title":"sui-sub-3"},{"id":"ns-other","title":"sui-sub-2"}]}' ;;
    *) printf '%s' '{"success":true,"result":[]}' ;;
  esac
}
curl() {
  local url="" a
  for a in "$@"; do case "${a}" in https://*) url="${a}" ;; esac; done
  case "${url}" in
    *"ns-own/values/server:id"*)
      if [ "${CURL_MODE}" = "code-only" ]; then printf '\n404'; else printf '%s\n200' "${UUID1}"; fi ;;
    *"ns-other/values/server:id"*) printf '%s\n200' "${OTHER_UUID}" ;;
    *"ns-own/values/server:code"*) printf '5c0b21ef\n200' ;;
    *"ns-other/values/server:code"*) printf 'aaaaaaaa\n200' ;;
    *) printf '\n404' ;;
  esac
}

found="$(find_own_namespace)"
[ "${found}" = "ns-own sui-sub-3" ] && ok "find_own_namespace finds this server's namespace by server:id" \
  || bad "find_own_namespace (got '${found}')"
CURL_MODE="code-only"
found="$(find_own_namespace)"
[ "${found}" = "ns-own sui-sub-3" ] && ok "find_own_namespace falls back to server:code" \
  || bad "find_own_namespace by code (got '${found}')"
CURL_MODE="id"
own_ns="$(worker_own_namespace "sui-sub-3")"
[ "${own_ns}" = "ns-own" ] && ok "worker_own_namespace adopts our own worker" \
  || bad "worker_own_namespace own (got '${own_ns}')"
worker_own_namespace "sui-sub-2" >/dev/null 2>&1 \
  && bad "worker_own_namespace must not adopt another server's worker" \
  || ok "worker_own_namespace refuses another server's worker"
guard_namespace_owner "ns-own" >/dev/null 2>&1 \
  && ok "guard allows our own namespace" \
  || bad "guard blocked our own namespace"
if guard_namespace_owner "ns-other" >/tmp/guard_out.txt 2>&1; then
  bad "guard must stop on another server's namespace"
else
  check "guard names the other server" "$(cat /tmp/guard_out.txt)" "already belongs to another server"
fi

echo "---"
echo "install tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = "0" ]
