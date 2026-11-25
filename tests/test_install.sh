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

# ---- menu + global links + destructive confirms ----
for fn in cmd_menu cmd_help install_global_command remove_global_command cmd_uninstall cmd_change_subdomain sui_version_of sui_version_major latest_sui_version cmd_update_sui; do
  extract_fn "${fn}" >> "${FN_TMP}"
done
# shellcheck disable=SC1090
source "${FN_TMP}"

# Global links: both sui-vpn and filtersui point at ~/sui-vpn/install.sh.
BUNDLE_DIR="${TMP}/bundle"
mkdir -p "${BUNDLE_DIR}" "${TMP}/bin"
printf '#!/usr/bin/env bash\n' > "${BUNDLE_DIR}/install.sh"
DIR="${TMP}/home2"
mkdir -p "${DIR}"
GLOBAL_LINK="${TMP}/bin/sui-vpn"
FILTERSUI_LINK="${TMP}/bin/filtersui"
install_global_command >/dev/null
if [ -L "${GLOBAL_LINK}" ] && [ -L "${FILTERSUI_LINK}" ] \
   && [ "$(readlink "${GLOBAL_LINK}")" = "${DIR}/install.sh" ] \
   && [ "$(readlink "${FILTERSUI_LINK}")" = "${DIR}/install.sh" ]; then
  ok "global links: sui-vpn and filtersui both point at install.sh"
else
  bad "global links"
fi
remove_global_command
[ ! -e "${GLOBAL_LINK}" ] && [ ! -e "${FILTERSUI_LINK}" ] \
  && ok "remove_global_command removes both links" \
  || bad "remove_global_command"

# Uninstall asks first.
need_root() { :; }
systemctl() { echo "systemctl $*" >> "${TMP}/systemctl_calls"; }
remove_global_command() { echo "removed" >> "${TMP}/rgc_calls"; }
UN_DIR="${TMP}/uninstall-home"
mkdir -p "${UN_DIR}"
DIR="${UN_DIR}"
PANEL_UNIT="${TMP}/u1"; TUN_UNIT="${TMP}/u2"; PANEL_TUN_UNIT="${TMP}/u3"
SYNC_UNIT="${TMP}/u4"; TIMER_UNIT="${TMP}/u5"; PATH_UNIT="${TMP}/u6"
PTLOG="${TMP}/u7"
out=$(printf 'n\n' | cmd_uninstall 2>&1)
check "uninstall aborts on N" "${out}" "aborted"
[ -d "${UN_DIR}" ] && ok "uninstall on N leaves the dir" || bad "uninstall on N removed the dir"
out=$(printf 'y\n' | cmd_uninstall 2>&1)
[ ! -d "${UN_DIR}" ] && ok "uninstall on y removes the dir" || bad "uninstall on y kept the dir"

# change-subdomain asks first (account-wide, changes every address).
load_state() { :; }
set_state() { :; }
valid_subdomain() { return 0; }
random_name() { echo "w1234567890"; }
current_subdomain() { echo "oldsub"; }
put_subdomain() { echo "$1" >> "${TMP}/put_calls"; return 0; }
set_panel_suburi() { :; }
CF_API_TOKEN="tok"; CF_ACCOUNT_ID="acct"; WORKER_NAME="sui-sub-3"
: > "${TMP}/put_calls"
printf 'n\n' | cmd_change_subdomain newsub >/dev/null 2>&1
[ ! -s "${TMP}/put_calls" ] && ok "change-subdomain aborts on N" || bad "change-subdomain on N still applied"
printf 'y\n' | cmd_change_subdomain newsub >/dev/null 2>&1
check "change-subdomain applies on y" "$(cat "${TMP}/put_calls")" "newsub"

# The menu: numbers (not names) drive it; it loops; EOF exits at once.
id() { echo 0; }
cmd_install() { echo "CALLED:install"; }
cmd_show() { echo "CALLED:show"; }
cmd_status() { echo "CALLED:status"; }
cmd_sync_now() { echo "CALLED:sync-now"; }
cmd_deploy_worker() { echo "CALLED:deploy-worker"; }
cmd_change_subdomain() { echo "CALLED:change-subdomain"; }
cmd_update_sui() { echo "CALLED:update-sui"; }
cmd_panel_on() { echo "CALLED:panel-on"; }
cmd_panel_off() { echo "CALLED:panel-off"; }
cmd_backup() { echo "CALLED:backup"; }
cmd_restore() { echo "CALLED:restore:$1"; }
cmd_uninstall() { echo "CALLED:uninstall"; }
STATE="${TMP}/no-such-state.env"
out=$(printf '3\n0\n' | cmd_menu 2>&1); code=$?
check "menu runs status by number" "${out}" "CALLED:status"
[ "${code}" = "0" ] && ok "menu exits 0 on 0" || bad "menu exit on 0 (got ${code})"
out=$(printf '99\n0\n' | cmd_menu 2>&1)
check "menu rejects an invalid number" "${out}" "invalid choice"
out=$(printf 'q\n' | cmd_menu 2>&1)
check_not "menu quits on q without running anything" "${out}" "CALLED:"
out=$(printf '11\n/tmp/x.tar.gz\n0\n' | cmd_menu 2>&1)
check "menu asks for the backup file on restore" "${out}" "CALLED:restore:/tmp/x.tar.gz"
out=$(cmd_menu </dev/null 2>&1); code=$?
[ "${code}" = "0" ] && ok "menu exits at once on EOF" || bad "menu on EOF (got ${code})"

# Dispatch: numbers and names map to commands; no arg opens the menu.
dispatch_calls() {
  (
    cmd_menu() { echo "menu"; }
    cmd_install() { echo "install"; }
    cmd_show() { echo "show"; }
    cmd_status() { echo "status"; }
    cmd_sync_now() { echo "sync-now:$*"; }
    cmd_deploy_worker() { echo "deploy-worker"; }
    cmd_change_subdomain() { echo "change-subdomain:$*"; }
    cmd_update_sui() { echo "update-sui"; }
    cmd_panel_on() { echo "panel-on"; }
    cmd_panel_off() { echo "panel-off"; }
    cmd_backup() { echo "backup"; }
    cmd_restore() { echo "restore:$*"; }
    cmd_uninstall() { echo "uninstall"; }
    cmd_help() { echo "help"; }
    set -- "$@"
    eval "$(sed -n '/^case "\${1:-menu}" in$/,$p' "${REPO}/install.sh")"
  )
}
[ "$(dispatch_calls)" = "menu" ] && ok "dispatch: no arg opens the menu" || bad "dispatch: no arg"
[ "$(dispatch_calls 3)" = "status" ] && ok "dispatch: 3 runs status" || bad "dispatch: 3"
[ "$(dispatch_calls status)" = "status" ] && ok "dispatch: status by name" || bad "dispatch: status by name"
[ "$(dispatch_calls 4 --dry-run)" = "sync-now:--dry-run" ] && ok "dispatch: 4 passes args to sync-now" || bad "dispatch: 4 --dry-run"
[ "$(dispatch_calls 12)" = "uninstall" ] && ok "dispatch: 12 runs uninstall" || bad "dispatch: 12"
out=$(dispatch_calls bogus 2>&1); code=$?
[ "${code}" = "1" ] && [ "${out}" = "help" ] && ok "dispatch: unknown arg prints help (stderr) and exits 1" || bad "dispatch: bogus (code ${code}, out ${out})"

# ---- update-sui: never re-install the same version ----
# Re-source the real functions: the menu section above stubbed cmd_*,
# which shadows the real cmd_update_sui this section tests.
# shellcheck disable=SC1090
source "${FN_TMP}"
[ "$(sui_version_of "s-ui 1.6.8")" = "1.6.8" ] && ok "version extracted from sui -v output" || bad "sui_version_of sui -v"
[ "$(sui_version_of "v2.0.0")" = "2.0.0" ] && ok "version extracted from a v-tag" || bad "sui_version_of v-tag"
[ -z "$(sui_version_of "no version here")" ] && ok "no version in garbage text" || bad "sui_version_of garbage"
[ "$(sui_version_major "1.6.8")" = "1" ] && [ "$(sui_version_major "2.0.0")" = "2" ] \
  && ok "major version split" || bad "sui_version_major"
LATEST_VER="1.7.0"
curl() {
  local url="" a
  for a in "$@"; do case "${a}" in https://*) url="${a}" ;; esac; done
  case "${url}" in
    *api.github.com*) printf '{"tag_name":"v%s"}' "${LATEST_VER}" ;;
    *) printf '' ;;
  esac
}
[ "$(latest_sui_version)" = "1.7.0" ] && ok "latest version from the GitHub API" || bad "latest_sui_version"
LATEST_VER=""
[ -z "$(latest_sui_version)" ] && ok "latest version empty when the API is silent" || bad "latest_sui_version silent"

# Fake s-ui binaries + stubs for the update flow.
UPD_BIN="${TMP}/upd-bin"; UPD_DIR="${TMP}/upd-home"
mkdir -p "${UPD_BIN}" "${UPD_DIR}"
BIN="${UPD_BIN}"; DIR="${UPD_DIR}"
mk_fake_sui() { printf '#!/usr/bin/env bash\necho "s-ui %s"\n' "$1" > "${BIN}/sui"; chmod +x "${BIN}/sui"; }
: > "${TMP}/upd_calls"
backup_before_change() { echo "backup" >> "${TMP}/upd_calls"; }
download_sui() {
  printf '#!/usr/bin/env bash\necho "s-ui %s"\n' "${NEW_VER}" > "${BIN}/sui.new"
  chmod +x "${BIN}/sui.new"
  echo "downloaded" >> "${TMP}/upd_calls"
  return 0
}
systemctl() { echo "systemctl $*" >> "${TMP}/upd_calls"; }
SUI_VERSION=""
mk_fake_sui "1.6.8"
LATEST_VER="1.6.8"
out=$(cmd_update_sui </dev/null 2>&1); code=$?
check "update-sui: already latest does nothing" "${out}" "already the latest version"
check_not "update-sui: already latest downloads nothing" "$(cat "${TMP}/upd_calls")" "downloaded"
check_not "update-sui: already latest restarts nothing" "$(cat "${TMP}/upd_calls")" "systemctl"
: > "${TMP}/upd_calls"
LATEST_VER="1.7.0"; NEW_VER="1.7.0"
out=$(cmd_update_sui </dev/null 2>&1); code=$?
check "update-sui: newer version swaps in" "${out}" "new: s-ui 1.7.0"
check "update-sui: newer version restarts the panel" "$(cat "${TMP}/upd_calls")" "systemctl restart sui-panel"
[ "$(sui_version_of "$("${BIN}/sui" -v)")" = "1.7.0" ] && ok "update-sui: binary replaced" || bad "update-sui: binary not replaced"
: > "${TMP}/upd_calls"
mk_fake_sui "1.6.8"
LATEST_VER=""
NEW_VER="1.6.8"
out=$(cmd_update_sui </dev/null 2>&1); code=$?
check "update-sui: same version after download does nothing" "${out}" "same as installed"
[ ! -f "${BIN}/sui.new" ] && ok "update-sui: same-version download discarded" || bad "update-sui: sui.new left behind"
check_not "update-sui: same version restarts nothing" "$(cat "${TMP}/upd_calls")" "systemctl"
: > "${TMP}/upd_calls"
mk_fake_sui "1.6.8"
LATEST_VER="2.0.0"; NEW_VER="2.0.0"
out=$(printf 'n\n' | cmd_update_sui 2>&1); code=$?
check "update-sui: major jump warns" "${out}" "major-version jump"
check "update-sui: major jump aborts on N" "${out}" "aborted"
[ "$(sui_version_of "$("${BIN}/sui" -v)")" = "1.6.8" ] && ok "update-sui: major jump on N keeps the old binary" || bad "update-sui: major jump on N swapped"
: > "${TMP}/upd_calls"
out=$(printf 'y\n' | cmd_update_sui 2>&1); code=$?
[ "$(sui_version_of "$("${BIN}/sui" -v)")" = "2.0.0" ] && ok "update-sui: major jump on y swaps" || bad "update-sui: major jump on y did not swap"

# ---- menu header: fixed panel address first, then server code ----
MENU_STATE="${TMP}/menu-state.env"
printf 'WORKER_URL=https://sui-sub-3.test.workers.dev\nPANEL_BASE_PATH=/app-xyz/\nSERVER_CODE=5c0b21ef\nCLIENT_UUID=5c0b21ef-178a-4b3e-b0f3-4a813e7073ee\n' > "${MENU_STATE}"
STATE="${MENU_STATE}"
out=$(printf 'q\n' | cmd_menu 2>&1)
if [[ "${out}" == *"Panel (fixed): https://sui-sub-3.test.workers.dev/app-xyz/"*"server code: 5c0b21ef"* ]]; then
  ok "menu header: fixed panel address first, then server code"
else
  bad "menu header order (got: ${out})"
fi

echo "---"
echo "install tests: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = "0" ]
