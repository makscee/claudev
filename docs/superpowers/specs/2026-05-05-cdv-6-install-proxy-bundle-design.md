# CDV-6: install.sh Proxy Bundle + Periodic Shipper — Design Spec

**Date:** 2026-05-05
**Task:** CDV-6
**Milestone:** claudev-usage-tracking

---

## Context

CDV-4 added proxy lifecycle (gen-ca.js, proxy.js). CDV-5 added ship-usage.js with orphan sweep and offset-based partial-batch resume. Neither wired the proxy files into install.sh — a fresh machine has no proxy directory.

CDV-6 is the final leaf: make install.sh self-sufficient and add in-session periodic shipping so long sessions don't lose usage data on crash.

---

## Scope

1. `install.sh` fetches proxy files alongside `claudev.sh`
2. `claudev.sh` spawns a background periodic shipper during active sessions

Out of scope: cron, launchd, Task Scheduler, daemon mode. Windows periodic scheduling deferred to `claudev-windows-support` milestone.

---

## Design

### 1. Proxy File Delivery

`install.sh` fetches three files individually from `auth.makscee.ru`, using the same pattern as the existing `claudev.sh` fetch (curl -fsS + sha256 verify):

```
gen-ca.js     → ~/.local/lib/claudev/proxy/gen-ca.js
proxy.js      → ~/.local/lib/claudev/proxy/proxy.js
ship-usage.js → ~/.local/lib/claudev/proxy/ship-usage.js
```

`install.sh` creates `~/.local/lib/claudev/proxy/` if it does not exist.

Each file: `curl -fsS <url> -o <dest>` then sha256 check against a hardcoded expected hash embedded in install.sh. On mismatch: print error and exit 1 (same behavior as claudev.sh fetch failure today).

**Prerequisite:** proxy files must be deployed to `auth.makscee.ru` before install.sh can fetch them. This is a server-side deploy step outside install.sh itself.

**Maintenance:** sha256 hashes in install.sh must be updated whenever proxy files change. This is the same burden as the existing claudev.sh hash — accepted pattern.

`claudev.sh` already resolves proxy files relative to its install location — no path changes needed there.

### 2. In-Session Periodic Shipper

After `start_proxy` spawns the proxy process, `claudev.sh` spawns a background loop:

```sh
(
  while sleep 900; do
    node "$PROXY_DIR/ship-usage.js" "$SESSION_FILE" 2>/dev/null || true
  done
) &
PERIODIC_SHIPPER_PID=$!
```

- Interval: 900 seconds (15 minutes)
- Calls `ship-usage.js <session-file>` — ships events since last offset, safe to call on active file
- Failures are silent (best-effort, loop continues)
- `PERIODIC_SHIPPER_PID` stored in claudev.sh scope

`stop_proxy` extended:

```sh
kill "$PERIODIC_SHIPPER_PID" 2>/dev/null || true
```

Added before the existing final `ship-usage.js` call. Order: kill loop → final ship → kill proxy.

### 3. Startup Sweep

No change. `sweep_orphan_jsonl` on startup (CDV-5) handles prior crashed sessions.

---

## Data Flow

```
install.sh
  → fetch claudev.sh (existing)
  → fetch gen-ca.js, proxy.js, ship-usage.js → ~/.local/lib/claudev/proxy/

claudev.sh session
  → sweep_orphan_jsonl (orphans from prior crashes)
  → start_proxy (gen-ca.js → proxy.js)
  → spawn periodic loop (every 15min: ship-usage.js <session-file>)
  → run claude ...
  → EXIT trap: stop_proxy
      → kill periodic loop
      → final ship-usage.js <session-file>
      → kill proxy
```

---

## Error Handling

| Failure | Behavior |
|---|---|
| curl fetch fails in install.sh | exit 1, print error (same as claudev.sh today) |
| sha256 mismatch | exit 1, print error |
| Periodic ship-usage.js call fails | silent, loop continues |
| PERIODIC_SHIPPER_PID kill fails | `|| true`, non-fatal |

---

## Testing

Extend `test/proxy-lifecycle.bats`:

- `install.sh` test: mock HTTP server serves proxy files; verify all three land at correct paths with correct content
- Periodic shipper test: set `SHIP_INTERVAL=1` env override in test; verify ship-usage.js called at least once during a short session; verify PERIODIC_SHIPPER_PID killed on stop_proxy

---

## Windows Compatibility

The periodic shipper lives inside claudev.sh session — no OS scheduler involved. `claudev-windows-support` milestone handles native Windows scheduling separately. CDV-6 makes no cross-platform compromises.

---

## Acceptance Criteria (from task)

- [ ] install.sh fetches/installs proxy files alongside claudev.sh on a clean machine
- [ ] Periodic shipper runs and ships pending usage JSONL every 15 minutes during active session
- [ ] Fresh install on a clean machine works first try; shipper tick clears orphan JSONL on next session start
