#!/bin/sh
# claudev — thin shell wrapper around `claude` that fetches a pool token
# from void-auth + void-keys. POSIX sh; mac + linux. v1 minimal.
#
# Spec: docs/superpowers/specs/2026-04-30-claudev-v1-design.md
set -eu

CLAUDEV_VERSION="0.1.0"
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

install_claude() {
  curl -fsSL https://claude.ai/install.sh | bash
}

ensure_claude() {
  have_claude && return 0
  printf "%s\n" "$L_CLAUDE_NOT_FOUND" >&2
  if [ ! -t 0 ]; then
    return 1
  fi
  printf "%s" "$L_CLAUDE_INSTALL_PROMPT"
  read -r ans
  case "$ans" in
    n|N|no|No|NO) return 1 ;;
  esac
  install_claude || true
  if ! have_claude; then
    printf "%s\n" "$L_CLAUDE_INSTALL_FAILED" >&2
    return 1
  fi
  return 0
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
esac

# --- main (placeholder until subsequent tasks fill it in) ---

load_locale
print_header
echo "claudev: not implemented yet (T3 skeleton)" >&2
exit 0
