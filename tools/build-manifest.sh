#!/bin/sh
# build-manifest.sh — regenerate claudev/version.json with sha256 of bundled files.
#
# `version` field is a manifest format identifier (not a release tag) and is
# preserved as-is. This script does NOT auto-bump it.
#
# Refuses to run on a dirty working tree: hashing uncommitted edits would
# ship a "released" sha that desyncs the void-auth mirror from claudev HEAD.
#
# Hashed files: claudev.sh + proxy/{gen-ca,proxy,ship-usage,cert}.js.
# install.sh is the bootstrap (`curl ... | sh`) and is intentionally not hashed.

set -eu

cd "$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"

git diff --quiet HEAD -- claudev.sh proxy/ version.json 2>/dev/null || {
  echo "build-manifest: working tree dirty for tracked claudev assets — commit or stash first" >&2
  exit 1
}

sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "build-manifest: neither shasum nor sha256sum found" >&2
    exit 1
  fi
}

for f in claudev.sh proxy/gen-ca.js proxy/proxy.js proxy/ship-usage.js proxy/cert.js; do
  [ -f "$f" ] || { echo "build-manifest: missing $f" >&2; exit 1; }
done

VERSION=$(awk -F'"' '/"version"/{print $4; exit}' version.json)
[ -n "$VERSION" ] || { echo "build-manifest: cannot read version field from version.json" >&2; exit 1; }

SHA_SH=$(sha claudev.sh)
SHA_GEN_CA=$(sha proxy/gen-ca.js)
SHA_PROXY=$(sha proxy/proxy.js)
SHA_SHIP=$(sha proxy/ship-usage.js)
SHA_CERT=$(sha proxy/cert.js)

cat > version.json <<EOF
{
  "version": "$VERSION",
  "sha256_sh": "$SHA_SH",
  "sha256_proxy_gen_ca": "$SHA_GEN_CA",
  "sha256_proxy_proxy": "$SHA_PROXY",
  "sha256_proxy_ship_usage": "$SHA_SHIP",
  "sha256_proxy_cert": "$SHA_CERT"
}
EOF

echo "build-manifest: wrote version.json (v=$VERSION)"
