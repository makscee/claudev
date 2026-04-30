#!/bin/sh
# claudev E2E — runs against real void-auth + void-keys.
#
# Prereqs (set by operator before invoking):
#   CLAUDEV_E2E_TOKEN       admin-minted session token for a throwaway test user
#   CLAUDEV_E2E_SESSION_ID  the session row id (for negative test revoke)
#   CLAUDEV_E2E_USER_ID     the user row id (for cleanup)
#   CLAUDEV_AUTH_HOST       (optional) defaults to https://auth.makscee.ru
#   CLAUDEV_KEYS_HOST       (optional) defaults to https://keys.makscee.ru
#
# Asserts:
#   1. Pool key shape (sk-ant-oat-) — catches placeholder regression
#   2. claudev --print "say hi" → exit 0, non-empty stdout
#   3. negative: revoke session → next claudev call fails with "session revoked"
set -eu

: "${CLAUDEV_E2E_TOKEN:?must be set}"
: "${CLAUDEV_E2E_SESSION_ID:?must be set}"
: "${CLAUDEV_E2E_USER_ID:?must be set}"
: "${CLAUDEV_AUTH_HOST:=https://auth.makscee.ru}"
: "${CLAUDEV_KEYS_HOST:=https://keys.makscee.ru}"
export CLAUDEV_AUTH_HOST CLAUDEV_KEYS_HOST

fail() { echo "E2E FAIL: $*" >&2; exit 1; }
ok()   { echo "E2E ok: $*"; }

# Clean prior state
rm -rf "$HOME/.claudev"
mkdir -p "$HOME/.claudev"
printf "locale=en\nlast_update_check=99999999999\n" > "$HOME/.claudev/config"
printf "%s" "$CLAUDEV_E2E_TOKEN" > "$HOME/.claudev/token"
chmod 600 "$HOME/.claudev/token"

# 1. Independent pool-key shape pre-assert
echo "→ pre-asserting pool key shape"
key_resp=$(curl -fsS -H "Authorization: Bearer $CLAUDEV_E2E_TOKEN" \
  "$CLAUDEV_KEYS_HOST/v1/keys/me") || fail "could not reach $CLAUDEV_KEYS_HOST/v1/keys/me"
echo "$key_resp" | grep -qE '"token":"sk-ant-oat([0-9]{2})?-' \
  || fail "pool returned non-OAuth token shape: $key_resp (placeholder regression?)"
ok "pool serves sk-ant-oat(NN)- token"

# 2. Positive: claudev --print "say hi"
echo "→ claudev --print 'say hi'"
out=$(claudev --print "say hi" 2>&1) || fail "claudev exited non-zero. output: $out"
[ -n "$out" ] || fail "claudev produced empty stdout"
echo "$out" | grep -qE 'OAuth login|not authenticated|paste claudev' \
  && fail "claudev surfaced login-prompt strings (key not injected?)"
ok "claudev positive: $(echo "$out" | head -c 60)..."

# 3. Negative: revoke session, expect failure
echo "→ revoking session $CLAUDEV_E2E_SESSION_ID"
curl -fsS -X DELETE "$CLAUDEV_AUTH_HOST/v1/admin/sessions/$CLAUDEV_E2E_SESSION_ID" >/dev/null \
  || fail "could not revoke session (admin endpoint reachable?)"
out2=$(claudev --print "still alive?" 2>&1) && fail "claudev should have failed after revoke; got: $out2"
echo "$out2" | grep -qE 'session revoked|сессия отозвана' \
  || fail "expected localized 'session revoked' message; got: $out2"
ok "claudev negative: detected revoked session"

# 4. Cleanup
echo "→ cleanup"
claudev logout
curl -fsS -X DELETE "$CLAUDEV_AUTH_HOST/v1/admin/users/$CLAUDEV_E2E_USER_ID" >/dev/null 2>&1 || true
ok "cleanup done"

echo "E2E PASS"
