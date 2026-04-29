#!/bin/sh
# claudev installer. Downloads the main script + locales, verifies sha256
# against the published manifest, drops binary into ~/.local/bin, locales into
# ~/.local/share/claudev/locales/.
#
# Usage:
#   curl -fsSL https://auth.makscee.ru/claudev/install.sh | sh
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

echo "claudev: downloading from $CLAUDEV_AUTH_HOST/claudev/claudev.sh"
curl -fsSL "$CLAUDEV_AUTH_HOST/claudev/claudev.sh" -o "$tmp"

if [ "${CLAUDEV_INSTALL_SKIP_VERIFY:-0}" != 1 ]; then
  echo "claudev: verifying sha256"
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

echo "claudev: installed to $BIN_DIR/claudev"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    cat <<HINT

NOTE: $BIN_DIR is not in your PATH.
Add it to your shell rc (e.g. ~/.zshrc or ~/.bashrc):

  export PATH="\$HOME/.local/bin:\$PATH"

Then restart your shell, or run \`exec \$SHELL\`.
HINT
    ;;
esac
