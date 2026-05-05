#!/bin/sh
# claudev — thin shell wrapper around `claude` that fetches a pool token
# from void-auth + void-keys. POSIX sh; mac + linux. v1 minimal.
#
# Spec: docs/superpowers/specs/2026-04-30-claudev-v1-design.md
set -eu

CLAUDEV_VERSION="0.2.8"
CLAUDEV_AUTH_HOST="${CLAUDEV_AUTH_HOST:-https://auth.makscee.ru}"
CLAUDEV_KEYS_HOST="${CLAUDEV_KEYS_HOST:-https://keys.makscee.ru}"
CLAUDEV_HOME="${HOME}/.claudev"
CLAUDEV_CONFIG="${CLAUDEV_HOME}/config"
# shellcheck disable=SC2034 # used by later tasks (T6+ token cache)
CLAUDEV_TOKEN="${CLAUDEV_HOME}/token"

# Resolve script's own directory so we can source locale files even when
# launched via symlink in ~/.local/bin.
script_path() {
  p="$0"
  while [ -L "$p" ]; do
    d=$(cd "$(dirname "$p")" && pwd)
    p=$(readlink "$p")
    case "$p" in
      /*) ;;
      *) p="$d/$p" ;;
    esac
  done
  cd "$(dirname "$p")" && pwd
}
SCRIPT_DIR=$(script_path)

# --- config helpers ---

config_get() {
  # config_get KEY → value or empty
  [ -f "$CLAUDEV_CONFIG" ] || return 0
  awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$CLAUDEV_CONFIG"
}

config_set() {
  # config_set KEY VALUE — overwrites if present, appends if not.
  mkdir -p "$CLAUDEV_HOME"
  k="$1"
  v="$2"
  if [ -f "$CLAUDEV_CONFIG" ] && grep -qE "^${k}=" "$CLAUDEV_CONFIG"; then
    tmp=$(mktemp)
    awk -F= -v k="$k" -v v="$v" '
      BEGIN { OFS="=" }
      $1==k { print k, v; next }
      { print }
    ' "$CLAUDEV_CONFIG" > "$tmp"
    mv -f "$tmp" "$CLAUDEV_CONFIG"
  else
    printf "%s=%s\n" "$k" "$v" >> "$CLAUDEV_CONFIG"
  fi
}

# --- locale ---

refresh_locales() {
  # Best-effort fetch of all locale files into the installed share dir.
  # Used by load_locale to self-heal when self_update brought a newer
  # claudev.sh that references locale strings not in the on-disk files.
  share="${HOME}/.local/share/claudev/locales"
  mkdir -p "$share"
  for _lng in en ru; do
    curl -fsSL "$CLAUDEV_AUTH_HOST/claudev/locales/${_lng}.sh" \
      -o "$share/${_lng}.sh" 2>/dev/null || true
  done
}

load_locale() {
  lang=$(config_get locale)
  if [ -z "$lang" ]; then
    bootstrap_locale
    lang=$(config_get locale)
  fi
  loc_file="${SCRIPT_DIR}/locales/${lang}.sh"
  if [ ! -f "$loc_file" ]; then
    # Installed layout: claudev sits in ~/.local/bin/, locales bundled at
    # ~/.local/share/claudev/locales/. Fall back there.
    loc_file="${HOME}/.local/share/claudev/locales/${lang}.sh"
  fi
  [ -f "$loc_file" ] || { echo "claudev: missing locale file $lang.sh" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$loc_file"
  # Self-heal: if a recent locale key is missing (drift between bumped
  # claudev.sh and on-disk locale files), refresh from auth host once.
  if [ -z "${L_WELCOME:-}" ]; then
    refresh_locales
    # shellcheck disable=SC1090
    [ -f "$loc_file" ] && . "$loc_file"
  fi
}

bootstrap_locale() {
  # If stdin is not a TTY, default silently to en.
  if [ ! -t 0 ]; then
    config_set locale en
    return
  fi
  # Source en.sh just to print the prompt label (chicken-and-egg).
  loc_en="${SCRIPT_DIR}/locales/en.sh"
  [ -f "$loc_en" ] || loc_en="${HOME}/.local/share/claudev/locales/en.sh"
  # shellcheck disable=SC1090
  . "$loc_en"
  printf "%s " "$L_CHOOSE_LANG"
  read -r choice
  case "$choice" in
    1|en|"") config_set locale en ;;
    2|ru) config_set locale ru ;;
    *) config_set locale en ;;
  esac
}

print_header() {
  lang=$(config_get locale)
  # shellcheck disable=SC2059
  printf "${L_HEADER_FMT}\n" "$CLAUDEV_VERSION" "$lang"
}

# --- claude code detect + install ---

have_claude() {
  command -v claude >/dev/null 2>&1
}

bootstrap_node() {
  # Best-effort node 22 install via the platform's package manager.
  printf "%s\n" "$L_NODE_INSTALLING" >&2
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1
  elif command -v brew >/dev/null 2>&1; then
    brew install -q node >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache nodejs npm >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm nodejs npm >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nodejs npm >/dev/null 2>&1
  else
    return 1
  fi
  command -v npm >/dev/null 2>&1
}

install_claude() {
  if ! command -v npm >/dev/null 2>&1; then
    bootstrap_node || { printf "%s\n" "$L_CLAUDE_NEEDS_NODE" >&2; return 1; }
  fi
  npm install -g --include=optional @anthropic-ai/claude-code || return 1
  # Best-effort pre-skip onboarding. Failure (disk full, perms, malformed
  # existing JSON) prints a warning but MUST NOT fail install — user already
  # got claude installed; onboarding-skip is UX polish.
  skip_claude_onboarding || printf "warning: could not pre-skip claude onboarding\n" >&2
  return 0
}

skip_claude_onboarding() {
  cv=$(claude --version 2>/dev/null | awk '{print $1}')
  [ -z "$cv" ] && cv="2.0.0"
  cfg="${HOME}/.claude.json"
  if command -v python3 >/dev/null 2>&1; then
    CLAUDEV_CFG="$cfg" CLAUDEV_VER="$cv" python3 -c '
import json, os
p = os.environ["CLAUDEV_CFG"]
v = os.environ["CLAUDEV_VER"]
try:
    with open(p) as f: d = json.load(f)
except Exception:
    d = {}
d["hasCompletedOnboarding"] = True
d["lastOnboardingVersion"] = v
tmp = p + ".tmp." + str(os.getpid())
with open(tmp, "w") as f: json.dump(d, f, indent=2)
os.replace(tmp, p)
' || return 1
  elif [ ! -f "$cfg" ]; then
    printf '{\n  "hasCompletedOnboarding": true,\n  "lastOnboardingVersion": "%s"\n}\n' "$cv" > "$cfg" || return 1
  fi
  return 0
}

ensure_claude() {
  if have_claude; then
    # Always silence onboarding — friend may have installed claude separately
    # and never completed (or skipped) its first-run wizard.
    skip_claude_onboarding
    return 0
  fi
  printf "%s\n" "$L_CLAUDE_NOT_FOUND" >&2
  printf "%s" "$L_CLAUDE_INSTALL_PROMPT"
  if ! read -r ans; then
    # EOF (e.g. stdin from /dev/null) — treat as decline.
    printf "\n"
    return 1
  fi
  case "$ans" in
    n|N|no|No|NO) return 1 ;;
  esac
  install_claude || true
  if ! have_claude; then
    printf "%s\n" "$L_CLAUDE_INSTALL_FAILED" >&2
    return 1
  fi
  skip_claude_onboarding
  return 0
}

# --- token: load from storage ---

ensure_token() {
  # If a stored token is present, return it immediately. Caller (fetch_key) will
  # bounce back to ensure_token with $TOKEN_FORCE_REPROMPT=1 on 401.
  if [ "${TOKEN_FORCE_REPROMPT:-0}" != 1 ] && [ -f "$CLAUDEV_TOKEN" ]; then
    TOKEN=$(cat "$CLAUDEV_TOKEN")
    [ -n "$TOKEN" ] && return 0
  fi
  # No token (fresh install OR fetch_key just removed a revoked one). Drop into
  # the login flow inline so the user doesn't have to know to run `claudev login`.
  cmd_login || return 1
  TOKEN=$(cat "$CLAUDEV_TOKEN" 2>/dev/null)
  [ -n "$TOKEN" ] || return 1
  return 0
}

# --- access-code login ---

# cmd_login — prompt for an access code, exchange it for a session token.
# Accepts up to 3 attempts (client-side format + server-side errors each count).
cmd_login() {
  load_locale
  mkdir -p "$CLAUDEV_HOME"

  attempts=0
  while [ "$attempts" -lt 3 ]; do
    printf '%s' "$L_ENTER_CODE"
    IFS= read -r code || break
    code_upper=$(printf '%s' "$code" | tr '[:lower:]' '[:upper:]')
    if ! printf '%s' "$code_upper" | grep -Eq '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'; then
      printf '%s\n' "$L_CODE_INVALID_FORMAT" >&2
      attempts=$((attempts + 1))
      continue
    fi
    login_tmp=$(mktemp)
    http_code=$(curl -sS -o "$login_tmp" -w '%{http_code}' \
      -X POST -H 'Content-Type: application/json' \
      -d "{\"code\":\"$code_upper\"}" \
      "$CLAUDEV_AUTH_HOST/v1/auth/access-codes/exchange" 2>/dev/null) || http_code=000
    body=$(cat "$login_tmp" 2>/dev/null); rm -f "$login_tmp"
    case "$http_code" in
      200)
        login_token=$(printf '%s' "$body" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
        if [ -n "$login_token" ]; then
          umask 077
          printf '%s' "$login_token" > "$CLAUDEV_TOKEN"
          chmod 600 "$CLAUDEV_TOKEN"
          printf '%s\n' "$L_LOGIN_OK"
          return 0
        fi
        ;;
      410) printf '%s\n' "$L_CODE_EXPIRED_OR_USED" >&2 ;;
      400) printf '%s\n' "$L_CODE_INVALID_FORMAT" >&2 ;;
      *)   printf '%s\n' "$L_CODE_NOT_FOUND" >&2 ;;
    esac
    attempts=$((attempts + 1))
  done
  printf '%s\n' "$L_TOO_MANY_ATTEMPTS" >&2
  return 1
}

# --- /v1/auth/me + welcome ---

fetch_me() {
  # Best-effort: GET /v1/auth/me, cache username (email local-part) in config.
  # Sets caller-visible USERNAME on success; silent on any failure.
  USERNAME=""
  if [ -z "${TOKEN:-}" ]; then
    TOKEN=$(cat "$CLAUDEV_TOKEN" 2>/dev/null || true)
  fi
  [ -n "${TOKEN:-}" ] || return 0
  me_resp=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$CLAUDEV_AUTH_HOST/v1/auth/me" 2>/dev/null) || return 0
  email=$(printf "%s" "$me_resp" | extract_json_string email)
  [ -n "$email" ] || return 0
  USERNAME="${email%@*}"
  config_set username "$USERNAME"
}

print_welcome() {
  uname=$(config_get username)
  if [ -z "$uname" ]; then
    fetch_me
    uname="${USERNAME:-}"
  fi
  [ -n "$uname" ] || return 0
  fmt="${L_WELCOME:-}"
  [ -n "$fmt" ] || return 0
  # shellcheck disable=SC2059
  printf "${fmt}\n" "$uname"
}

# --- pool key fetch ---

# extract_json_string KEY — reads json on stdin, prints first string-typed
# value for KEY. Tolerant of whitespace; not a full json parser.
extract_json_string() {
  awk -v key="$1" '
    BEGIN { RS=","; FS=":" }
    {
      gsub(/[{}\n\r\t ]/, "")
      if (index($0, "\"" key "\"") == 1) {
        sub(/^[^:]*:/, "")
        gsub(/^"|"$/, "")
        print
        exit
      }
    }
  '
}

fetch_key() {
  resp_file=$(mktemp)
  code=$(curl -s -o "$resp_file" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$CLAUDEV_KEYS_HOST/v1/keys/me" 2>/dev/null) || code="000"
  case "$code" in
    200) ;;
    401)
      rm -f "$CLAUDEV_TOKEN" "$resp_file"
      printf "%s\n" "$L_SESSION_REVOKED" >&2
      return 10  # signal to caller: re-prompt token + retry
      ;;
    503)
      rm -f "$resp_file"
      printf "%s\n" "$L_POOL_EMPTY" >&2
      exit 1
      ;;
    *)
      rm -f "$resp_file"
      # shellcheck disable=SC2059
      printf "${L_NETWORK_ERROR}\n" "$CLAUDEV_KEYS_HOST" >&2
      exit 2
      ;;
  esac
  KEY=$(extract_json_string token < "$resp_file")
  rm -f "$resp_file"
  case "$KEY" in
    sk-ant-oat-*|sk-ant-oat[0-9][0-9]-*) return 0 ;;
    *)
      printf "%s\n" "$L_POOL_BAD_KEY" >&2
      exit 3
      ;;
  esac
}

# --- subcommand dispatcher ---

print_help() {
  cat <<EOF
Usage: claudev [SUBCOMMAND | CLAUDE_ARGS...]

Without arguments, fetches a pool token and exec's \`claude\`.

Subcommands:
  login     wipe stored token and prompt for a new access code
  logout    remove the stored token
  update    force the self-update check (skip 24h cache)
  --help    show this help

Anything else is forwarded to \`claude\` verbatim.

Env overrides:
  CLAUDEV_AUTH_HOST  default $CLAUDEV_AUTH_HOST
  CLAUDEV_KEYS_HOST  default $CLAUDEV_KEYS_HOST

State files: ~/.claudev/{token,config}
EOF
}

dispatch() {
  case "${1:-}" in
    --help|-h|help)
      print_help
      exit 0
      ;;
    logout)
      rm -f "$CLAUDEV_TOKEN"
      config_set username ""
      exit 0
      ;;
    login)
      rm -f "$CLAUDEV_TOKEN"
      config_set username ""
      cmd_login
      exit $?
      ;;
    update)
      load_locale
      print_header
      CLAUDEV_FORCE_UPDATE=1 self_update || true
      exit 0
      ;;
  esac
  return 0  # no subcommand matched → fall through to main
}

# bootstrap_proxy_bundle <stage_dir> <manifest>
# Fetches the 4 proxy js files into <stage_dir>/proxy/ and verifies each against
# sha256_proxy_<key> in <manifest>. Returns 0 on full success, 1 on any failure
# (missing key, fetch error, sha mismatch). Caller is responsible for mv-into-place.
bootstrap_proxy_bundle() {
  bpb_stage="$1"
  bpb_manifest="$2"
  mkdir -p "$bpb_stage/proxy" || return 1
  for bpb_f in gen-ca.js proxy.js ship-usage.js cert.js; do
    if ! curl -fsS "$CLAUDEV_AUTH_HOST/claudev/proxy/$bpb_f" \
              -o "$bpb_stage/proxy/$bpb_f"; then
      echo "claudev: failed to fetch proxy/$bpb_f — aborting" >&2
      return 1
    fi
    bpb_key="sha256_proxy_$(echo "$bpb_f" | sed 's/[.-]/_/g; s/_js$//')"
    bpb_want=$(printf "%s" "$bpb_manifest" | extract_json_string "$bpb_key")
    bpb_got=$(shasum -a 256 "$bpb_stage/proxy/$bpb_f" 2>/dev/null | awk '{print $1}')
    [ -z "$bpb_got" ] && bpb_got=$(sha256sum "$bpb_stage/proxy/$bpb_f" | awk '{print $1}')
    if [ -z "$bpb_want" ] || [ "$bpb_got" != "$bpb_want" ]; then
      echo "claudev: sha256 mismatch for proxy/$bpb_f (got $bpb_got, want $bpb_want) — refusing update" >&2
      return 1
    fi
  done
  return 0
}

# shellcheck disable=SC2120 # $@ used only on the exec path; callers pass none
self_update() {
  # Honor CLAUDEV_FORCE_UPDATE=1 OR cache-miss (1h since last check).
  now=$(date +%s)
  last=$(config_get last_update_check)
  : "${last:=0}"
  cache_age=$(( now - last ))
  if [ "${CLAUDEV_FORCE_UPDATE:-0}" != 1 ] && [ "$cache_age" -lt 3600 ]; then
    return 0
  fi
  manifest=$(curl -fsS "$CLAUDEV_AUTH_HOST/claudev/version.json" 2>/dev/null) || return 0
  remote_version=$(printf "%s" "$manifest" | extract_json_string version)
  remote_sha=$(printf "%s" "$manifest" | extract_json_string sha256_sh)
  config_set last_update_check "$now"
  if [ -z "$remote_version" ]; then return 0; fi
  if [ "$remote_version" = "$CLAUDEV_VERSION" ]; then
    [ "${CLAUDEV_FORCE_UPDATE:-0}" = 1 ] && echo "claudev: up to date ($CLAUDEV_VERSION)"
    return 0
  fi
  # shellcheck disable=SC2059
  printf "${L_UPDATE_AVAILABLE}, " "$CLAUDEV_VERSION" "$remote_version"
  printf "%s" "$L_UPDATE_INSTALL_PROMPT"
  if [ ! -t 0 ] && [ "${CLAUDEV_FORCE_UPDATE:-0}" != 1 ]; then echo "(non-interactive — skipping)"; return 0; fi
  if [ -t 0 ]; then
    read -r ans
    case "$ans" in
      n|N|no|No|NO) return 0 ;;
    esac
  fi

  # Stage all 5 files into a tmpdir; only publish if all sha checks pass.
  stage_dir=$(mktemp -d) || return 1
  trap 'rm -rf "$stage_dir"' EXIT
  if ! curl -fsS "$CLAUDEV_AUTH_HOST/claudev/claudev.sh" -o "$stage_dir/claudev.sh"; then
    echo "claudev: failed to fetch claudev.sh — aborting" >&2
    return 1
  fi
  actual_sha=$(shasum -a 256 "$stage_dir/claudev.sh" 2>/dev/null | awk '{print $1}')
  [ -z "$actual_sha" ] && actual_sha=$(sha256sum "$stage_dir/claudev.sh" | awk '{print $1}')
  if [ "$actual_sha" != "$remote_sha" ]; then
    echo "claudev: sha256 mismatch — refusing update (got $actual_sha, want $remote_sha)" >&2
    return 1
  fi
  bootstrap_proxy_bundle "$stage_dir" "$manifest" || return 1

  # Verification done; staging is now publish payload. Disarm trap so partial-publish
  # leaves staged files for postmortem instead of auto-cleaning.
  trap - EXIT

  proxy_dir="${HOME}/.local/lib/claudev/proxy"
  mkdir -p "$proxy_dir" || {
    echo "claudev: failed to create $proxy_dir — staged files at $stage_dir" >&2
    return 1
  }
  for pf in gen-ca.js proxy.js ship-usage.js cert.js; do
    if ! mv -f "$stage_dir/proxy/$pf" "$proxy_dir/$pf"; then
      echo "claudev: PARTIAL PUBLISH — proxy/$pf failed to install; run install.sh to recover" >&2
      return 1
    fi
  done
  chmod +x "$stage_dir/claudev.sh"
  if ! mv -f "$stage_dir/claudev.sh" "$0"; then
    echo "claudev: PARTIAL PUBLISH — claudev.sh failed to install; run install.sh to recover" >&2
    return 1
  fi
  rm -rf "$stage_dir"
  refresh_locales
  exec "$0" "$@"
}

# --- selftest hooks (used by bats; not user-facing) ---

case "${1:-}" in
  --selftest-locale)
    load_locale
    config_get locale
    exit 0
    ;;
  --selftest-config-get)
    config_get "$2"
    exit 0
    ;;
  --selftest-config-set)
    config_set "$2" "$3"
    exit 0
    ;;
  --selftest-header)
    load_locale
    print_header
    exit 0
    ;;
  --selftest-ensure-claude)
    load_locale
    ensure_claude
    exit $?
    ;;
  --selftest-install-claude)
    load_locale
    install_claude
    exit $?
    ;;
  --selftest-login)
    cmd_login
    exit $?
    ;;
  --selftest-ensure-token)
    load_locale
    ensure_token
    exit $?
    ;;
  --selftest-self-update)
    load_locale
    self_update
    exit $?
    ;;
  --selftest-fetch-key)
    load_locale
    TOKEN=$(cat "$CLAUDEV_TOKEN" 2>/dev/null || true)
    rc=0
    fetch_key || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf "%s\n" "$KEY"
    fi
    exit "$rc"
    ;;
esac

# --- proxy lifecycle ---

CLAUDEV_PROXY_DIR=""
PROXY_PID=""
PERIODIC_SHIPPER_PID=""

find_proxy_dir() {
  if [ -f "$SCRIPT_DIR/proxy/proxy.js" ]; then
    CLAUDEV_PROXY_DIR="$SCRIPT_DIR/proxy"
    return 0
  fi
  if [ -f "$CLAUDEV_HOME/proxy/proxy.js" ]; then
    CLAUDEV_PROXY_DIR="$CLAUDEV_HOME/proxy"
    return 0
  fi
  return 1
}

start_proxy() {
  [ "${CLAUDEV_NO_PROXY:-}" = 1 ] && return 0
  command -v node >/dev/null 2>&1 || return 0
  find_proxy_dir || return 0

  node "$CLAUDEV_PROXY_DIR/gen-ca.js" || return 0

  proxy_ready=$(mktemp)
  rm -f "$proxy_ready"
  CLAUDEV_SESSION_ID=$$ node "$CLAUDEV_PROXY_DIR/proxy.js" "$proxy_ready" &
  PROXY_PID=$!

  # Periodic shipper: every SHIP_INTERVAL seconds (default 900), ship pending usage
  # events from the active session file. Calls are best-effort; ship-usage.js handles
  # offset-based partial-batch resume so concurrent reads on the active file are safe.
  session_file="$CLAUDEV_HOME/usage/session-$$.jsonl"
  (
    while sleep "${SHIP_INTERVAL:-900}"; do
      [ -f "$session_file" ] && node "$CLAUDEV_PROXY_DIR/ship-usage.js" "$session_file" 2>/dev/null || true
    done
  ) </dev/null >/dev/null 2>&1 &
  PERIODIC_SHIPPER_PID=$!

  i=0
  while [ $i -lt 50 ] && [ ! -f "$proxy_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done

  if [ ! -f "$proxy_ready" ]; then
    kill "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
    rm -f "$proxy_ready"
    return 0
  fi

  PROXY_PORT=$(cat "$proxy_ready")
  rm -f "$proxy_ready"
  export HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT"
  export NODE_EXTRA_CA_CERTS="$CLAUDEV_HOME/proxy-ca/ca.pem"
}

stop_proxy() {
  [ -n "$PROXY_PID" ] || return 0
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
  PROXY_PID=""
  # Stop periodic shipper: kill subshell, wait for it (and any in-flight node ship)
  # to fully exit. Guarantees the final ship below never races against a periodic
  # ship on the same offset file.
  if [ -n "$PERIODIC_SHIPPER_PID" ]; then
    # Kill subshell's children first (the sleep) so the subshell can return from wait;
    # then signal the subshell itself; then reap.
    pkill -P "$PERIODIC_SHIPPER_PID" 2>/dev/null || true
    kill "$PERIODIC_SHIPPER_PID" 2>/dev/null || true
    wait "$PERIODIC_SHIPPER_PID" 2>/dev/null || true
    PERIODIC_SHIPPER_PID=""
  fi
  # Ship usage data (5s timeout, silent failure — orphan sweep catches it)
  if [ -f "$CLAUDEV_HOME/usage/session-$$.jsonl" ] && command -v node >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 node "$CLAUDEV_PROXY_DIR/ship-usage.js" "$CLAUDEV_HOME/usage/session-$$.jsonl" 2>/dev/null || true
    else
      node "$CLAUDEV_PROXY_DIR/ship-usage.js" "$CLAUDEV_HOME/usage/session-$$.jsonl" 2>/dev/null || true
    fi
  fi
}

sweep_orphan_jsonl() {
  command -v node >/dev/null 2>&1 || return 0
  [ -n "$CLAUDEV_PROXY_DIR" ] || find_proxy_dir 2>/dev/null || return 0
  node "$CLAUDEV_PROXY_DIR/ship-usage.js" --sweep 2>/dev/null || true
}

# --- main pipeline ---

main() {
  load_locale
  print_header
  self_update      # may exec self and never return
  ensure_claude || exit 1
  ensure_token || exit 1
  print_welcome
  rc=0
  fetch_key || rc=$?
  if [ "$rc" = 10 ]; then
    # Token revoked server-side. Session file already removed by fetch_key.
    # Drop into login inline + retry fetch_key once.
    ensure_token || exit 1
    rc=0
    fetch_key || rc=$?
  fi
  [ "$rc" = 0 ] || exit "$rc"
  sweep_orphan_jsonl
  start_proxy

  trap stop_proxy EXIT

  env CLAUDE_CODE_OAUTH_TOKEN="$KEY" claude "$@" &
  CLAUDE_PID=$!

  trap 'kill -s INT "$CLAUDE_PID" 2>/dev/null; stop_proxy' INT
  trap 'kill -s TERM "$CLAUDE_PID" 2>/dev/null; stop_proxy' TERM

  wait "$CLAUDE_PID" 2>/dev/null
  CLAUDE_RC=$?
  CLAUDE_PID=""
  exit "$CLAUDE_RC"
}

dispatch "$@"
main "$@"
