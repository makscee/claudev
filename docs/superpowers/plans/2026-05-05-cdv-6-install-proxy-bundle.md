# CDV-6: install.sh Proxy Bundle + Periodic Shipper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** install.sh fetches proxy files (gen-ca.js, proxy.js, ship-usage.js) on a clean machine; claudev.sh runs an in-session periodic shipper every 15 min so long sessions don't lose usage data on crash.

**Architecture:** Extend install.sh's existing curl + sha256 fetch pattern (same as claudev.sh fetch) to three additional files installed under `~/.local/lib/claudev/proxy/`. In `claudev.sh`, spawn a background `while sleep` loop after `start_proxy` that calls `ship-usage.js` against the active session file; `stop_proxy` kills + waits for the loop before the existing final ship.

**Tech Stack:** POSIX sh (install.sh, claudev.sh), node.js (proxy files), bats (tests), python3 (test mock server).

**Spec:** `docs/superpowers/specs/2026-05-05-cdv-6-install-proxy-bundle-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `install.sh` | Modify | Add proxy file fetch + sha256 verify loop. Reuse existing `CLAUDEV_AUTH_HOST` env var. |
| `claudev.sh` | Modify | `start_proxy` spawns periodic shipper; `stop_proxy` kills + waits for it before final ship. |
| `test/proxy-lifecycle.bats` | Modify | Add periodic shipper test (uses `SHIP_INTERVAL=1` env override). |
| `test/install-proxy-fetch.bats` | Create | New test file for install.sh proxy fetch (uses `python3 -m http.server` fixture + `CLAUDEV_AUTH_HOST` override). |

**Server-side prerequisite (out of scope for this plan):** `auth.makscee.ru/claudev/version.json` manifest must add `sha256_proxy_gen_ca`, `sha256_proxy_proxy`, `sha256_proxy_ship_usage` keys; `auth.makscee.ru/claudev/proxy/{gen-ca,proxy,ship-usage}.js` must serve the files. install.sh assumes both exist; tests use a local fixture instead.

---

## Task 1: install.sh — Proxy directory + manifest hash extraction

**Files:**
- Modify: `install.sh:20-44`

- [ ] **Step 1: Add proxy install dir constant**

After line 21 (`BIN_DIR="${HOME}/.local/bin"`), add:

```sh
PROXY_DIR="${HOME}/.local/lib/claudev/proxy"
```

- [ ] **Step 2: Extend manifest hash extractor to handle multiple keys**

The existing manifest parser at line 34 extracts a single `sha256_sh` field via awk. Replace with a reusable shell function. Insert after line 21 additions, before line 28:

```sh
# Extract a sha256_<key> field from version.json (best-effort, single line awk).
extract_sha() {
  printf "%s" "$1" | awk -F\" -v key="$2" '
    { for (i=1;i<=NF;i++) if ($i==key) { print $(i+2); exit } }'
}
```

Then update the existing claudev.sh sha extraction (line 34) from:
```sh
expected_sha=$(printf "%s" "$manifest" | awk -F\" '/sha256_sh/{ for (i=1;i<=NF;i++) if ($i=="sha256_sh") { print $(i+2); exit } }')
```
to:
```sh
expected_sha=$(extract_sha "$manifest" sha256_sh)
```

- [ ] **Step 3: Verify nothing else broke — run existing install (dry, against current manifest)**

Run: `sh install.sh --dry-run` if supported, else manually inspect with `sh -n install.sh` for syntax.
Expected: no syntax errors. (Full install verified by Task 4 test.)

- [ ] **Step 4: Commit**

```sh
git add install.sh
git commit -m "feat(CDV-6): factor sha extractor + add PROXY_DIR constant"
```

---

## Task 2: install.sh — Fetch proxy files with sha256 verify

**Files:**
- Modify: `install.sh` (after the existing claudev.sh fetch+verify block ending around line 42)

- [ ] **Step 1: Add proxy fetch loop**

After the existing claudev.sh sha256 verify block (after line 42, before the BIN_DIR install at line ~46), insert:

```sh
mkdir -p "$PROXY_DIR"
for f in gen-ca.js proxy.js ship-usage.js; do
  echo "claudev: downloading proxy/$f from $CLAUDEV_AUTH_HOST" >&2
  proxy_tmp=$(mktemp)
  curl -fsSL "$CLAUDEV_AUTH_HOST/claudev/proxy/$f" -o "$proxy_tmp"

  if [ "${CLAUDEV_INSTALL_SKIP_VERIFY:-0}" != 1 ]; then
    # Manifest key: sha256_proxy_<basename-with-_-not-->
    key=$(printf "sha256_proxy_%s" "$f" | sed 's/[.-]/_/g; s/_js$//')
    expected_sha=$(extract_sha "$manifest" "$key")
    actual_sha=$(shasum -a 256 "$proxy_tmp" 2>/dev/null | awk '{print $1}')
    [ -z "$actual_sha" ] && actual_sha=$(sha256sum "$proxy_tmp" | awk '{print $1}')
    if [ -z "$expected_sha" ] || [ "$actual_sha" != "$expected_sha" ]; then
      echo "claudev: sha256 mismatch for proxy/$f (got $actual_sha, want $expected_sha) — aborting" >&2
      rm -f "$proxy_tmp"
      exit 1
    fi
  fi

  mv "$proxy_tmp" "$PROXY_DIR/$f"
  chmod 644 "$PROXY_DIR/$f"
done
```

Manifest key mapping: `gen-ca.js` → `sha256_proxy_gen_ca`, `proxy.js` → `sha256_proxy_proxy`, `ship-usage.js` → `sha256_proxy_ship_usage`.

- [ ] **Step 2: Syntax check**

Run: `sh -n install.sh`
Expected: no output (no errors).

- [ ] **Step 3: Commit**

```sh
git add install.sh
git commit -m "feat(CDV-6): fetch proxy bundle in install.sh with sha256 verify"
```

---

## Task 3: install.sh test — proxy fetch via local fixture server

**Files:**
- Create: `test/install-proxy-fetch.bats`
- Read for reference: `test/_mock-server.sh` (helper used by proxy-lifecycle.bats)

- [ ] **Step 1: Write the failing test**

Create `test/install-proxy-fetch.bats`:

```bats
#!/usr/bin/env bats

setup() {
  TEST_TMP="$BATS_TEST_TMPDIR"
  FIXTURE_DIR="$TEST_TMP/fixture"
  mkdir -p "$FIXTURE_DIR/claudev/proxy"

  # Fixture proxy files (small, deterministic content)
  printf '// gen-ca\n' > "$FIXTURE_DIR/claudev/proxy/gen-ca.js"
  printf '// proxy\n'  > "$FIXTURE_DIR/claudev/proxy/proxy.js"
  printf '// ship\n'   > "$FIXTURE_DIR/claudev/proxy/ship-usage.js"
  printf '// claudev.sh\n' > "$FIXTURE_DIR/claudev/claudev.sh"

  # Compute hashes for manifest
  sha_for() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
  sh_sha=$(sha_for "$FIXTURE_DIR/claudev/claudev.sh")
  ca_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/gen-ca.js")
  px_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/proxy.js")
  sh2_sha=$(sha_for "$FIXTURE_DIR/claudev/proxy/ship-usage.js")

  cat > "$FIXTURE_DIR/claudev/version.json" <<EOF
{
  "sha256_sh": "$sh_sha",
  "sha256_proxy_gen_ca": "$ca_sha",
  "sha256_proxy_proxy": "$px_sha",
  "sha256_proxy_ship_usage": "$sh2_sha"
}
EOF

  # Start python http server on free port
  cd "$FIXTURE_DIR"
  python3 -m http.server 0 --bind 127.0.0.1 >"$TEST_TMP/server.log" 2>&1 &
  SERVER_PID=$!
  cd - >/dev/null

  # Read port from server log (python prints "Serving HTTP on 127.0.0.1 port NNNN")
  for _ in 1 2 3 4 5; do
    sleep 0.2
    PORT=$(grep -oE 'port [0-9]+' "$TEST_TMP/server.log" | head -1 | awk '{print $2}')
    [ -n "$PORT" ] && break
  done
  [ -n "$PORT" ] || { echo "server failed to start" >&2; cat "$TEST_TMP/server.log"; return 1; }

  export FAKE_HOME="$TEST_TMP/home"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

@test "install.sh fetches proxy files into ~/.local/lib/claudev/proxy/" {
  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="http://127.0.0.1:$PORT" sh "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/gen-ca.js" ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/proxy.js" ]
  [ -f "$FAKE_HOME/.local/lib/claudev/proxy/ship-usage.js" ]
  grep -q '// gen-ca' "$FAKE_HOME/.local/lib/claudev/proxy/gen-ca.js"
  grep -q '// proxy'  "$FAKE_HOME/.local/lib/claudev/proxy/proxy.js"
  grep -q '// ship'   "$FAKE_HOME/.local/lib/claudev/proxy/ship-usage.js"
}

@test "install.sh aborts on sha256 mismatch for proxy file" {
  # Corrupt the served gen-ca.js after manifest is written
  printf '// corrupted\n' > "$FIXTURE_DIR/claudev/proxy/gen-ca.js"
  run env HOME="$FAKE_HOME" CLAUDEV_AUTH_HOST="http://127.0.0.1:$PORT" sh "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'sha256 mismatch'
}
```

- [ ] **Step 2: Run test to verify the happy path passes and corruption is caught**

Run: `cd /Users/admin/hub-wt/CDV-6/workspace/claudev && bats test/install-proxy-fetch.bats`
Expected: both tests PASS.

If the happy-path test fails because install.sh's existing post-fetch logic (e.g., shell rc append) errors with `FAKE_HOME`, scope `install.sh` to the proxy fetch portion only by setting `CLAUDEV_INSTALL_SKIP_VERIFY=0` (default) and verify only that the proxy files land. If install.sh has a strict no-rc-modify mode, use it; otherwise add a `CLAUDEV_INSTALL_SKIP_RC=1` env guard to install.sh and use it in tests.

- [ ] **Step 3: Commit**

```sh
git add test/install-proxy-fetch.bats install.sh
git commit -m "test(CDV-6): proxy fetch + sha256 mismatch via local fixture server"
```

---

## Task 4: claudev.sh — periodic shipper in start_proxy

**Files:**
- Modify: `claudev.sh:529-559` (start_proxy function)

- [ ] **Step 1: Add periodic shipper var declaration**

After line 515 (`PROXY_PID=""`), add:

```sh
PERIODIC_SHIPPER_PID=""
```

- [ ] **Step 2: Spawn the periodic loop after the proxy spawn line**

In `start_proxy` (around line 539), immediately after:

```sh
CLAUDEV_SESSION_ID=$$ node "$CLAUDEV_PROXY_DIR/proxy.js" "$proxy_ready" &
PROXY_PID=$!
```

add:

```sh
# Periodic shipper: every SHIP_INTERVAL seconds (default 900), ship pending usage
# events from the active session file. Calls are best-effort; ship-usage.js handles
# offset-based partial-batch resume so concurrent reads on the active file are safe.
session_file="$CLAUDEV_HOME/usage/session-$$.jsonl"
(
  while sleep "${SHIP_INTERVAL:-900}"; do
    [ -f "$session_file" ] && node "$CLAUDEV_PROXY_DIR/ship-usage.js" "$session_file" 2>/dev/null || true
  done
) &
PERIODIC_SHIPPER_PID=$!
```

- [ ] **Step 3: Syntax check**

Run: `sh -n claudev.sh`
Expected: no output.

- [ ] **Step 4: Commit**

```sh
git add claudev.sh
git commit -m "feat(CDV-6): spawn in-session periodic shipper in start_proxy"
```

---

## Task 5: claudev.sh — kill + wait shipper in stop_proxy

**Files:**
- Modify: `claudev.sh:560-576` (stop_proxy function)

- [ ] **Step 1: Add kill + wait before the existing final ship-usage.js call**

In `stop_proxy`, immediately before line 568 (the `if [ -f "$CLAUDEV_HOME/usage/session-$$.jsonl" ] ...` block), add:

```sh
# Stop periodic shipper: kill subshell, wait for it (and any in-flight node ship)
# to fully exit. Guarantees the final ship below never races against a periodic
# ship on the same offset file.
if [ -n "$PERIODIC_SHIPPER_PID" ]; then
  kill "$PERIODIC_SHIPPER_PID" 2>/dev/null || true
  wait "$PERIODIC_SHIPPER_PID" 2>/dev/null || true
  PERIODIC_SHIPPER_PID=""
fi
```

- [ ] **Step 2: Syntax check**

Run: `sh -n claudev.sh`
Expected: no output.

- [ ] **Step 3: Commit**

```sh
git add claudev.sh
git commit -m "feat(CDV-6): kill+wait periodic shipper in stop_proxy"
```

---

## Task 6: bats test — periodic shipper fires + reaped

**Files:**
- Modify: `test/proxy-lifecycle.bats` (append new test after the existing tests)

- [ ] **Step 1: Add the new test**

Append to `test/proxy-lifecycle.bats`:

```bats
@test "periodic shipper: fires during session, reaped on exit" {
  mock_keys_200

  # Replace ship-usage.js stub with one that records each invocation
  # (the mock server already replaces ship-usage.js for assertion purposes;
  # if not, adapt: install a wrapper that appends to a marker file).
  ship_marker="$HOME/.claudev/ship-marker"
  : > "$ship_marker"

  cat > "$HOME/proxy-stub/ship-usage.js" <<EOF
const fs = require('fs');
fs.appendFileSync("$ship_marker", "tick\n");
process.exit(0);
EOF

  # Run claudev with SHIP_INTERVAL=1 and a claude stub that sleeps long enough
  # for ≥2 ticks. Use a session that takes ~3 seconds.
  cat > "$HOME/bin/claude" <<'EOF'
#!/bin/sh
sleep 3
EOF
  chmod +x "$HOME/bin/claude"

  run sh -c "PATH=$HOME/bin:\$PATH SHIP_INTERVAL=1 \
    CLAUDEV_KEYS_HOST=http://127.0.0.1:$MOCK_PORT \
    CLAUDEV_PROXY_DIR=$HOME/proxy-stub \
    $CLAUDEV --print hello"
  [ "$status" -eq 0 ]

  # Assert ≥2 periodic ticks (1s, 2s, 3s) plus 1 final ship
  ticks=$(wc -l < "$ship_marker")
  [ "$ticks" -ge 2 ]

  # Assert no orphan shipper subshell remains
  ! pgrep -f 'sleep' >/dev/null 2>&1 || {
    pgrep -f 'sleep'
    return 1
  }
}
```

- [ ] **Step 2: Run the new test**

Run: `cd /Users/admin/hub-wt/CDV-6/workspace/claudev && bats test/proxy-lifecycle.bats -f "periodic shipper"`
Expected: PASS.

If the test fails because the existing test harness does not provide `$HOME/proxy-stub` or env override for `CLAUDEV_PROXY_DIR`, inspect `test/_mock-server.sh` and the existing setup() in proxy-lifecycle.bats. Adapt the test to match — probably need to:
  - Create `$HOME/.local/lib/claudev/proxy/` in setup with the stub ship-usage.js
  - Drop the `CLAUDEV_PROXY_DIR=` env override

The pgrep `sleep` assertion may match unrelated `sleep` processes on a busy machine; restrict it via `pgrep -f "sleep ${SHIP_INTERVAL:-900}"` or check by parent PID.

- [ ] **Step 3: Run the full bats suite to confirm no regressions**

Run: `cd /Users/admin/hub-wt/CDV-6/workspace/claudev && bats test/`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```sh
git add test/proxy-lifecycle.bats
git commit -m "test(CDV-6): periodic shipper fires + reaped on exit"
```

---

## Task 7: Manual smoke test on a clean directory

**Files:** none

- [ ] **Step 1: Smoke install on a temp HOME**

Run:

```sh
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" sh /Users/admin/hub-wt/CDV-6/workspace/claudev/install.sh
ls "$TMPHOME/.local/lib/claudev/proxy/"
```

Expected: `gen-ca.js`, `proxy.js`, `ship-usage.js` listed. (Will fail unless server-side manifest has been updated — flag this to user as a deploy prerequisite.)

- [ ] **Step 2: Document deploy prerequisite in Work Log**

Append to task file `vault/work/tasks/active/CDV-6-install-sh-proxy-bundle.md`:

```markdown
- DEPLOY PREREQUISITE: server at auth.makscee.ru must add proxy file routes (/claudev/proxy/{gen-ca,proxy,ship-usage}.js) and extend version.json with sha256_proxy_{gen_ca,proxy,ship_usage} keys before install.sh works against prod. CDV-6 code lands ahead of server config; gated by manifest deploy.
```

- [ ] **Step 3: Commit (if Work Log entry made via worktree — use sw_run for canonical writes)**

Per hub workflow, task file lives on master; use `tools/state-write/sw` from canonical hub for the Work Log append, not a direct git commit in the worktree.

---

## Self-Review Checklist

**Spec coverage:**
- ✅ install.sh fetches proxy files (Task 2)
- ✅ Periodic shipper fires every 15 min (Task 4)
- ✅ Fresh install + shipper tick clears orphans (Tasks 2, 4 + existing CDV-5 startup sweep)
- ✅ kill + wait race avoidance (Task 5)
- ✅ SHIP_INTERVAL test override (Task 4 code, Task 6 test)
- ✅ CLAUDEV_AUTH_HOST test override (Task 3 — note: spec said CLAUDEV_INSTALL_BASE_URL but existing var CLAUDEV_AUTH_HOST is reused)

**Placeholder scan:** none.

**Type/identifier consistency:**
- `PERIODIC_SHIPPER_PID` defined in claudev.sh:515-ish (Task 4 step 1), used in stop_proxy (Task 5)
- `session_file` local to start_proxy (Task 4)
- `extract_sha` defined in install.sh (Task 1), used in Task 2

---

## Acceptance (mirrors task file)

- [ ] install.sh fetches/installs proxy files alongside claudev.sh on a clean machine
- [ ] Periodic shipper runs and ships pending usage JSONL every 15 minutes during active session
- [ ] Fresh install on a clean machine works first try; shipper tick clears orphan JSONL on next session start
