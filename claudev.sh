#!/bin/sh
# claudev — thin shell wrapper around `claude` that fetches a pool token
# from void-auth + void-keys. POSIX sh; mac + linux. v1 minimal.
#
# Spec: docs/superpowers/specs/2026-04-30-claudev-v1-design.md
set -eu

# --- self-update trampoline (CDV-9) ---
# Windows (Git Bash / MSYS / Cygwin) locks the running script file, so
# self_update can't mv-over-self. On those platforms self_update writes the new
# script to claudev.sh.next alongside this file; on the next launch we swap it
# in here (before any other work) and re-exec. Posix unaffected: this block is
# a no-op when no .next is staged. Single-shot: after exec, the second pass
# sees no .next and falls through to the cleanup branch.
_cdv_self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || _cdv_self_dir=""
if [ -n "$_cdv_self_dir" ]; then
  _cdv_self_base=$(basename "$0")
  _cdv_self_path="$_cdv_self_dir/$_cdv_self_base"
  if [ -f "$_cdv_self_dir/$_cdv_self_base.next" ]; then
    mv -f "$_cdv_self_path" "$_cdv_self_dir/$_cdv_self_base.old" 2>/dev/null || true
    if mv -f "$_cdv_self_dir/$_cdv_self_base.next" "$_cdv_self_path"; then
      chmod +x "$_cdv_self_path" 2>/dev/null || true
      unset _cdv_self_dir _cdv_self_base _cdv_self_path
      exec "$0" "$@"
    fi
  else
    [ -f "$_cdv_self_dir/$_cdv_self_base.old" ] && rm -f "$_cdv_self_dir/$_cdv_self_base.old"
  fi
fi
unset _cdv_self_dir _cdv_self_base _cdv_self_path 2>/dev/null || true

CLAUDEV_VERSION="0.2.15"
CLAUDEV_AUTH_HOST="${CLAUDEV_AUTH_HOST:-https://auth.makscee.ru}"
CLAUDEV_KEYS_HOST="${CLAUDEV_KEYS_HOST:-https://keys.makscee.ru}"
CLAUDEV_HOME="${HOME}/.claudev"
CLAUDEV_CONFIG="${CLAUDEV_HOME}/config"
# shellcheck disable=SC2034 # used by later tasks (T6+ token cache)
CLAUDEV_TOKEN="${CLAUDEV_HOME}/token"

# Probe fractional sleep support once. Git Bash on Windows uses a builtin
# `sleep` that rejects fractional seconds; mac/linux coreutils accept them.
command sleep 0.001 2>/dev/null && _SLEEP_FRACTIONAL=1 || _SLEEP_FRACTIONAL=0
_psleep() { if [ "$_SLEEP_FRACTIONAL" = 1 ]; then sleep 0.1; else sleep 1; fi; }

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

_bootstrap_node_macos() {
  if command -v brew >/dev/null 2>&1; then
    brew install -q node >/dev/null 2>&1
  else
    return 1
  fi
  command -v npm >/dev/null 2>&1
}

_bootstrap_node_linux() {
  # Linux: distro pkg managers only; Linuxbrew not supported.
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1
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

_bootstrap_node_windows() {
  # Windows (Git Bash / MSYS / Cygwin): prefer winget (built into Win10 1709+),
  # fall back to chocolatey if installed. Neither manages current-shell PATH —
  # warn after install if `node` still isn't on PATH; a fresh shell will pick it up.
  if command -v winget >/dev/null 2>&1; then
    if winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements; then
      command -v node >/dev/null 2>&1 || \
        printf "node installed via winget; reopen your shell to pick up PATH changes\n" >&2
      return 0
    fi
    return 1
  fi
  if command -v choco >/dev/null 2>&1; then
    if choco install nodejs-lts -y; then
      command -v node >/dev/null 2>&1 || \
        printf "node installed via choco; reopen your shell to pick up PATH changes\n" >&2
      return 0
    fi
    return 1
  fi
  printf "windows install: neither winget nor choco found on PATH.\n" >&2
  printf "  - winget ships with Windows 10 1709+ / Windows 11; run it from a fresh terminal.\n" >&2
  printf "  - choco (Chocolatey) needs manual install: https://chocolatey.org/install\n" >&2
  printf "Install one of them, then re-run claudev.\n" >&2
  return 1
}

bootstrap_node() {
  # Skip path: node ≥ 18 already on PATH OR claude --version succeeds.
  # Claude Code requires node 18+; older node falls through to install.
  # Claude itself bundles its own node, so claude --version skip stays unconditional.
  if command -v node >/dev/null 2>&1; then
    _node_ver=$(node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')
    if [ -n "$_node_ver" ] && [ "$_node_ver" -ge 18 ] 2>/dev/null; then
      printf "node already present (v%s), skipping install\n" "$_node_ver" >&2
      return 0
    fi
    printf "node present but < 18 (v%s), upgrading\n" "${_node_ver:-?}" >&2
  fi
  if command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then
    printf "claude already present, skipping node install\n" >&2
    return 0
  fi

  printf "%s\n" "$L_NODE_INSTALLING" >&2

  # OS detect → dispatch. $OSTYPE is bash-ish but widely set; fall back to uname.
  # SC3028: OSTYPE is intentional — set by bash/zsh/Git-Bash; fallback handles sh.
  # shellcheck disable=SC3028
  _os_marker="${OSTYPE:-}"
  [ -z "$_os_marker" ] && _os_marker=$(uname -s 2>/dev/null || echo unknown)
  case "$_os_marker" in
    msys*|cygwin*|mingw*|MINGW*|MSYS*|CYGWIN*)
      _bootstrap_node_windows
      ;;
    darwin*|Darwin*)
      _bootstrap_node_macos
      ;;
    linux*|Linux*)
      _bootstrap_node_linux
      ;;
    *)
      # Unknown OS — best-effort linux path (matches old behaviour for BSDs etc.)
      _bootstrap_node_linux
      ;;
  esac
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

# Merge two onboarding keys into ~/.claude.json. Portable ladder, since each
# tier fails on some target:
#   1. jq    — preferred; absent on stock Win Git Bash + many minimal Linux.
#   2. python3 — sanity-probed first; on Win the bare name is an MS-Store
#      launcher shim that exits nonzero with "Python was not found".
#   3. POSIX shell — flat-object sed/awk fallback; never fails on the small
#      JSON claudev cares about. Keeps install green even with no jq + no py.
# Per "MUST NOT fail install" contract: on total failure we still return 0
# after a warning (caller already swallows non-zero, but be explicit).
skip_claude_onboarding() {
  cv=$(claude --version 2>/dev/null | awk '{print $1}')
  [ -z "$cv" ] && cv="2.0.0"
  cfg="${HOME}/.claude.json"

  # Tier 1: jq (probe binary AND working install)
  if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
    tmp="$cfg.tmp.$$"
    if [ -f "$cfg" ]; then
      jq --arg v "$cv" '. + {hasCompletedOnboarding: true, lastOnboardingVersion: $v}' \
        "$cfg" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cfg" && return 0
    else
      jq -n --arg v "$cv" '{hasCompletedOnboarding: true, lastOnboardingVersion: $v}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$cfg" && return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi

  # Tier 2: python3 (sanity-probe to dodge Windows MS-Store launcher shim)
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    if CLAUDEV_CFG="$cfg" CLAUDEV_VER="$cv" python3 -c '
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
' 2>/dev/null; then
      return 0
    fi
  fi

  # Tier 3: POSIX shell. Assumes flat top-level object (claudev's case).
  # Reads existing file, replaces or appends the two keys, writes atomically.
  _scc_pure_merge "$cfg" "$cv" && return 0

  printf "warning: skip_claude_onboarding: no jq / python3 / shell merge worked\n" >&2
  return 0
}

# _scc_pure_merge CFG VERSION — flat-object key set/append in pure POSIX shell.
# Strategy: load text (or default {}). For each key, if key exists replace its
# value via sed; else inject `"key": value,` after the opening `{`. Final write
# is atomic via mv. LF line endings only.
_scc_pure_merge() {
  _scc_cfg="$1"
  _scc_ver="$2"
  if [ -f "$_scc_cfg" ]; then
    _scc_text=$(cat "$_scc_cfg") || return 1
  else
    _scc_text='{}'
  fi
  # Strip any CRLF for predictable sed behaviour.
  _scc_text=$(printf '%s' "$_scc_text" | tr -d '\r')
  # Ensure non-empty + has braces; on malformed input start from empty object.
  case "$_scc_text" in
    *'{'*'}'*) ;;
    *) _scc_text='{}' ;;
  esac
  _scc_text=$(_scc_set_key "$_scc_text" hasCompletedOnboarding 'true' raw) || return 1
  _scc_text=$(_scc_set_key "$_scc_text" lastOnboardingVersion "$_scc_ver" string) || return 1
  _scc_tmp="$_scc_cfg.tmp.$$"
  printf '%s\n' "$_scc_text" > "$_scc_tmp" || { rm -f "$_scc_tmp"; return 1; }
  mv -f "$_scc_tmp" "$_scc_cfg" || { rm -f "$_scc_tmp"; return 1; }
  return 0
}

# _scc_set_key TEXT KEY VALUE MODE — emit TEXT with "KEY": VALUE set.
# MODE = "string" (quote+escape value) or "raw" (literal, e.g. true/false/number).
_scc_set_key() {
  _sk_text="$1"; _sk_key="$2"; _sk_val="$3"; _sk_mode="$4"
  if [ "$_sk_mode" = string ]; then
    # Escape backslashes and double-quotes in the value.
    _sk_esc=$(printf '%s' "$_sk_val" | sed 's/\\/\\\\/g; s/"/\\"/g')
    _sk_render="\"$_sk_key\": \"$_sk_esc\""
  else
    _sk_render="\"$_sk_key\": $_sk_val"
  fi
  # If key already present, replace its value via awk (handles string OR raw).
  if printf '%s' "$_sk_text" | grep -q "\"$_sk_key\"[[:space:]]*:"; then
    printf '%s' "$_sk_text" | awk -v k="$_sk_key" -v r="$_sk_render" '
      {
        # Replace "KEY"<ws>:<ws><value-up-to-, or }> with rendered pair.
        # Value can be "..." (string), true|false|null, or a number. Stop at
        # comma or closing brace. Greedy enough for flat objects.
        pat = "\"" k "\"[[:space:]]*:[[:space:]]*(\"([^\"\\\\]|\\\\.)*\"|true|false|null|-?[0-9]+(\\.[0-9]+)?)"
        gsub(pat, r)
        print
      }
    '
    return 0
  fi
  # Key absent: inject after the opening `{`. Empty object `{}` → `{ render }`.
  printf '%s' "$_sk_text" | awk -v r="$_sk_render" '
    BEGIN { done = 0 }
    {
      if (!done) {
        if (match($0, /\{[[:space:]]*\}/)) {
          # Empty object on this line.
          sub(/\{[[:space:]]*\}/, "{" r "}")
          done = 1
        } else if (match($0, /\{/)) {
          # Non-empty: insert `render,` right after `{`.
          sub(/\{/, "{" r ", ")
          done = 1
        }
      }
      print
    }
  '
}

# _recover_claude_msys — Windows-only recovery for the half-trampoline state
# claude-code's own self-update can leave bin/claude.exe missing while
# parking the prior binary as bin/claude.exe.old.<epoch-ms>. command -v still
# finds the npm shim, so have_claude returns true, but exec fails because the
# shim's target is gone. We restore the newest .old.<ts> over claude.exe and
# probe `claude --version`. On non-MSYS this is a no-op (returns 0).
#
# Returns 0 if claude is runnable (after recovery or no-op).
# Returns 1 if Windows + claude still not runnable after probe — caller should
# emit the locale-keyed fatal hint and exit.
_recover_claude_msys() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 0 ;;
  esac

  _rcm_npm_root=$(npm root -g 2>/dev/null) || _rcm_npm_root=""
  if [ -n "$_rcm_npm_root" ]; then
    _rcm_bin="$_rcm_npm_root/@anthropic-ai/claude-code/bin"
    if [ -d "$_rcm_bin" ] && [ ! -e "$_rcm_bin/claude.exe" ]; then
      # Pick newest .old.<epoch-ms>. Suffix is an epoch-ms timestamp, so a
      # numeric sort on the suffix gives the newest. POSIX sh has no `[[`,
      # so we delegate sort+pick to ls + awk (no lex `\>` per SC3012).
      _rcm_newest=$(
        for _rcm_cand in "$_rcm_bin"/claude.exe.old.*; do
          [ -e "$_rcm_cand" ] || continue
          # Print "<suffix> <full-path>"; suffix is everything after .old.
          _rcm_sfx=${_rcm_cand##*.old.}
          printf '%s\t%s\n' "$_rcm_sfx" "$_rcm_cand"
        done | sort -nr -k1,1 | awk 'NR==1 { sub(/^[^\t]*\t/, ""); print; exit }'
      )
      if [ -n "$_rcm_newest" ]; then
        if mv -f "$_rcm_newest" "$_rcm_bin/claude.exe" 2>/dev/null; then
          # shellcheck disable=SC2059
          printf "${L_CLAUDE_BROKEN_RECOVERED}\n" "$(basename "$_rcm_newest")" >&2
        fi
      fi
    fi
  fi

  # Probe with short timeout. `timeout` may not exist on every Git Bash; if absent, skip probe.
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 claude --version >/dev/null 2>&1 || return 1
  else
    claude --version >/dev/null 2>&1 || return 1
  fi
  return 0
}

ensure_claude() {
  if have_claude; then
    # Windows-only: recover from claude-code self-update half-rename state
    # before onboarding-skip touches the (potentially missing) binary.
    if ! _recover_claude_msys; then
      # shellcheck disable=SC2059
      printf "${L_CLAUDE_BROKEN_FATAL}\n" >&2
      return 1
    fi
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

# --- access status ---

print_access_status() {
    token=$(cat "$HOME/.claudev/token" 2>/dev/null || true)
    [ -z "$token" ] && return 0
    body=$(curl -fsS -m 5 -H 'content-type: application/json' \
        -d "{\"token\":\"$token\"}" \
        "$CLAUDEV_AUTH_HOST/v1/auth/verify" 2>/dev/null) || {
        printf "%s\n" "$L_ACCESS_UNAVAILABLE"
        return 0
    }

    grant_section=$(printf '%s' "$body" | awk '/"claudevGrant"/{found=1} found{print}' | head -c 400)

    case "$grant_section" in
        *'"claudevGrant":null'*)
            printf "%s\n" "$L_ACCESS_NO_GRANT"
            return 0
            ;;
        *'"unlimited":true'*)
            printf "%s\n" "$L_ACCESS_UNLIMITED"
            return 0
            ;;
        *'"expired":true'*)
            expires=$(printf '%s' "$grant_section" | awk -F'[:,]' '/"expiresAt":/{print $2; exit}' | tr -d ' ')
            now=$(date +%s)
            days=$(( (now - expires) / 86400 ))
            # shellcheck disable=SC2059
            printf "$L_ACCESS_EXPIRED\n" "$days"
            return 0
            ;;
        *'"expiresAt":'*)
            expires=$(printf '%s' "$grant_section" | awk -F'[:,]' '/"expiresAt":/{print $2; exit}' | tr -d ' ')
            now=$(date +%s)
            secs=$(( expires - now ))
            iso=$(date -u -r "$expires" +%Y-%m-%d 2>/dev/null || date -u -d "@$expires" +%Y-%m-%d 2>/dev/null || echo "")
            if [ "$secs" -ge 86400 ]; then
                days=$(( secs / 86400 ))
                # shellcheck disable=SC2059
                printf "$L_ACCESS_DAYS_LEFT\n" "$days" "$iso"
            else
                hours=$(( secs / 3600 ))
                # shellcheck disable=SC2059
                printf "$L_ACCESS_HOURS_LEFT\n" "$hours" "$iso"
            fi
            return 0
            ;;
        *)
            printf "%s\n" "$L_ACCESS_UNAVAILABLE"
            return 0
            ;;
    esac
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
    5*)
      rm -f "$resp_file"
      # shellcheck disable=SC2059
      printf "${L_SERVER_ERROR}\n" "$code" "$CLAUDEV_KEYS_HOST" >&2
      exit 4
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
  # Always probe the manifest — every claudev launch checks for updates.
  # The probe is one ~500-byte GET; cheap enough to not warrant a TTL.
  manifest=$(curl -fsS "$CLAUDEV_AUTH_HOST/claudev/version.json" 2>/dev/null) || return 0
  remote_version=$(printf "%s" "$manifest" | extract_json_string version)
  remote_sha=$(printf "%s" "$manifest" | extract_json_string sha256_sh)
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
      echo "claudev: PARTIAL PUBLISH — proxy/$pf failed to install (staged files at $stage_dir); run install.sh to recover" >&2
      return 1
    fi
  done
  chmod +x "$stage_dir/claudev.sh"
  # Windows file lock: can't mv-over-self while running. Stage as .next and let
  # the trampoline (top of script) swap on next launch. See CDV-9.
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      _self_dir=$(cd "$(dirname "$0")" && pwd)
      _self_base=$(basename "$0")
      if ! mv -f "$stage_dir/claudev.sh" "$_self_dir/$_self_base.next"; then
        echo "claudev: PARTIAL PUBLISH — claudev.sh.next failed to stage (staged files at $stage_dir); run install.sh to recover" >&2
        return 1
      fi
      rm -rf "$stage_dir"
      refresh_locales
      echo "claudev: update staged — applies on next launch"
      return 0
      ;;
  esac
  if ! mv -f "$stage_dir/claudev.sh" "$0"; then
    echo "claudev: PARTIAL PUBLISH — claudev.sh failed to install (staged files at $stage_dir); run install.sh to recover" >&2
    return 1
  fi
  rm -rf "$stage_dir"
  refresh_locales
  exec "$0" "$@"
}

# Launch `claude` with the fetched OAuth token. OS-dispatched: MSYS Git Bash
# strips the controlling TTY from a backgrounded child node.exe, hanging
# Claude Code's Ink TUI on initial render. On Windows we run claude in the
# foreground (the EXIT trap set by the caller still runs stop_proxy). On
# POSIX we keep the background+wait pattern so SIGINT/SIGTERM can forward
# to claude AND trigger graceful proxy cleanup.
run_claude_session() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      env CLAUDE_CODE_OAUTH_TOKEN="$KEY" claude "$@"
      return $?
      ;;
  esac
  env CLAUDE_CODE_OAUTH_TOKEN="$KEY" claude "$@" &
  CLAUDE_PID=$!
  trap 'kill -s INT "$CLAUDE_PID" 2>/dev/null; stop_proxy' INT
  trap 'kill -s TERM "$CLAUDE_PID" 2>/dev/null; stop_proxy' TERM
  wait "$CLAUDE_PID" 2>/dev/null
  CLAUDE_RC=$?
  CLAUDE_PID=""
  return "$CLAUDE_RC"
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
  --selftest-bootstrap-node)
    load_locale
    bootstrap_node
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
  --selftest-run-claude-session)
    shift
    KEY="selftest-key"
    run_claude_session "$@"
    exit $?
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
  # Default install layout: install.sh drops proxy here while wrapper lives in
  # ~/.local/bin (different parent), so $SCRIPT_DIR/proxy never matches.
  if [ -f "${HOME}/.local/lib/claudev/proxy/proxy.js" ]; then
    CLAUDEV_PROXY_DIR="${HOME}/.local/lib/claudev/proxy"
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
  # Git Bash `sleep` builtin rejects fractional → 10x coarser fallback OK
  # for one-time startup poll. _psleep picks 0.1s vs 1s based on probe.
  while [ $i -lt 50 ] && [ ! -f "$proxy_ready" ]; do
    _psleep
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
  print_access_status
  start_proxy

  trap stop_proxy EXIT

  run_claude_session "$@"
  exit $?
}

dispatch "$@"
main "$@"
