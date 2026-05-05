#!/bin/sh
# sync-bundle.sh — atomic publish of claudev bundle to a target dir.
#
# Stages 6 files to a tmpdir, recomputes sha256 of the 4 hashed files
# (claudev.sh + 3 proxy js) and verifies them against the staged
# version.json. Only on full match does it `mv` files into the target tree.
#
# Usage: sync-bundle.sh <target-dir>
#   e.g. sync-bundle.sh /Users/admin/hub-wt/CDV_VAU-1/workspace/void-auth/public/claudev

set -eu

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "sync-bundle: usage: $0 <target-dir>" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "sync-bundle: target dir not found: $TARGET" >&2; exit 1; }

cd "$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else echo "sync-bundle: neither shasum nor sha256sum found" >&2; exit 1
  fi
}

extract() {  # extract sha256_<key> from a manifest file
  awk -F'"' "/\"$2\"/{print \$4; exit}" "$1"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/proxy"
cp install.sh claudev.sh version.json "$TMP/"
cp proxy/gen-ca.js proxy/proxy.js proxy/ship-usage.js "$TMP/proxy/"

# Verify staged hashes against staged manifest before publishing.
for pair in "claudev.sh:sha256_sh" \
            "proxy/gen-ca.js:sha256_proxy_gen_ca" \
            "proxy/proxy.js:sha256_proxy_proxy" \
            "proxy/ship-usage.js:sha256_proxy_ship_usage"; do
  file="${pair%%:*}"
  key="${pair##*:}"
  got=$(sha "$TMP/$file")
  want=$(extract "$TMP/version.json" "$key")
  if [ "$got" != "$want" ]; then
    echo "sync-bundle: hash mismatch for $file ($key): staged=$got manifest=$want" >&2
    exit 1
  fi
done

mkdir -p "$TARGET/proxy"
mv "$TMP/install.sh" "$TMP/claudev.sh" "$TMP/version.json" "$TARGET/"
mv "$TMP/proxy/gen-ca.js" "$TMP/proxy/proxy.js" "$TMP/proxy/ship-usage.js" "$TARGET/proxy/"

echo "sync-bundle: published 6 files to $TARGET"
( cd "$TARGET" && git status --short )
