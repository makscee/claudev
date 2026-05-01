#!/bin/sh
# claudev installer. Downloads the main script + locales, verifies sha256
# against the published manifest, drops binary into ~/.local/bin, locales into
# ~/.local/share/claudev/locales/.
#
# Usage (recommended — activates PATH in current shell on first install):
#   eval "$(curl -fsSL https://auth.makscee.ru/claudev/install.sh | sh)"
#
# Plain form (works, but new shell needed for PATH on first install):
#   curl -fsSL https://auth.makscee.ru/claudev/install.sh | sh
#
# All progress messages go to stderr. The single line printed on stdout (if
# any) is the `export PATH=...` needed for the running shell — safe to eval.
#
# Env:
#   CLAUDEV_AUTH_HOST              default https://auth.makscee.ru
#   CLAUDEV_INSTALL_SKIP_VERIFY=1  skip sha256 check (TESTING ONLY)
set -eu

CLAUDEV_AUTH_HOST="${CLAUDEV_AUTH_HOST:-https://auth.makscee.ru}"
BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/claudev"

mkdir -p "$BIN_DIR" "$SHARE_DIR/locales"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "claudev: downloading from $CLAUDEV_AUTH_HOST/claudev/claudev.sh" >&2
curl -fsSL "$CLAUDEV_AUTH_HOST/claudev/claudev.sh" -o "$tmp"

if [ "${CLAUDEV_INSTALL_SKIP_VERIFY:-0}" != 1 ]; then
  echo "claudev: verifying sha256" >&2
  manifest=$(curl -fsSL "$CLAUDEV_AUTH_HOST/claudev/version.json")
  expected_sha=$(printf "%s" "$manifest" | awk -F\" '/sha256_sh/{ for (i=1;i<=NF;i++) if ($i=="sha256_sh") { print $(i+2); exit } }')
  actual_sha=$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')
  [ -z "$actual_sha" ] && actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
  if [ -z "$expected_sha" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo "claudev: sha256 mismatch (got $actual_sha, want $expected_sha) — aborting" >&2
    exit 1
  fi
fi

chmod +x "$tmp"
mv -f "$tmp" "$BIN_DIR/claudev"
trap - EXIT

# Locale files (best-effort — runtime falls back to en if missing).
for lang in en ru; do
  curl -fsSL "$CLAUDEV_AUTH_HOST/claudev/locales/${lang}.sh" \
    -o "$SHARE_DIR/locales/${lang}.sh" 2>/dev/null || true
done

echo "claudev: installed to $BIN_DIR/claudev" >&2

case ":$PATH:" in
  *":$BIN_DIR:"*)
    # Already in PATH — nothing to do.
    ;;
  *)
    # Auto-append export line to the first rc file that exists.
    # Candidate order: ~/.bashrc, ~/.zshrc, ~/.profile.
    # If none exists, create ~/.profile.
    # Single-quotes below are intentional: we want the literal string
    # '$HOME/.local/bin' written into the rc file, not the expanded path.
    # shellcheck disable=SC2016
    EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH" # claudev'
    _rc_append() {
      rc="$1"
      # Idempotent: skip if either quote-style already present.
      # SC2016: intentional — grep for the literal text in the rc file.
      # shellcheck disable=SC2016
      if grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$rc" 2>/dev/null; then
        return 0
      fi
      if grep -qF "export PATH='\$HOME/.local/bin:\$PATH'" "$rc" 2>/dev/null; then
        return 0
      fi
      printf '\n%s\n' "$EXPORT_LINE" >> "$rc"
    }
    rc_updated=""
    for _candidate in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile"; do
      if [ -f "$_candidate" ]; then
        _rc_append "$_candidate"
        rc_updated="${rc_updated:+$rc_updated, }$_candidate"
      fi
    done
    if [ -z "$rc_updated" ]; then
      # No rc file found — pick the right one for the user's shell.
      # zsh (macOS default) ignores ~/.profile; create ~/.zshrc instead.
      case "${SHELL:-}" in
        */zsh)
          _fallback="$HOME/.zshrc" ;;
        */bash)
          _fallback="$HOME/.bashrc" ;;
        *)
          _fallback="$HOME/.profile" ;;
      esac
      printf '%s\n' "$EXPORT_LINE" > "$_fallback"
      rc_updated="$_fallback"
    fi
    # SC2016: $SHELL / $HOME are intentional — literal text in stderr message
    # and in the eval-able stdout line.
    # shellcheck disable=SC2016
    printf 'claudev: PATH updated in %s. New shells pick it up automatically.\n' "$rc_updated" >&2
    # shellcheck disable=SC2016
    printf 'claudev: to use claudev in THIS shell: eval the line below, or re-run install via `eval "$(curl -fsSL %s/claudev/install.sh | sh)"`.\n' "$CLAUDEV_AUTH_HOST" >&2
    # The single stdout line — designed for `eval "$(... | sh)"`.
    printf '%s\n' "$EXPORT_LINE"
    ;;
esac
