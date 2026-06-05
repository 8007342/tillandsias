# Wave 1: Linux-Only Critical Path (Iteration 4+)

**Date:** 2026-05-14
**Status:** Ready for implementation
**Scope:** Browser/session/routing on Linux only

## Context

Cross-platform work (Windows, WSL, macOS) is now deferred. All Wave 1 effort focuses on completing the Linux browser isolation + session management story end-to-end.

See: `plan/issues/deferral-windows-macos-2026-05-14.md` for deferred specs and reasoning.

## Ready Tasks (Highest → Lowest Priority)

### Task 1: browser/session-otp (HIGH PRIORITY)

**Status:** pending / ready for immediate implementation
**Dependency:** `browser/launcher-contract` (47% complete as of last note)
**File Scope:**
- `openspec/specs/opencode-web-session-otp/spec.md` (spec definition)
- `images/default/entrypoint-forge-opencode-web.sh` (forge entrypoint)
- `images/default/entrypoint-forge-opencode.sh` (code environment setup)
- `crates/tillandsias-headless/src/main.rs` (tray router OTP delivery)

**What it does:**
- Wires router OTP token delivery end-to-end
- Currently: browser gets data-URI login form (✓ in launcher)
- Missing: tray ↔ router ↔ forge cookie/token flow
- Required for: secure session ownership in OpenCode Web

**Why first after launcher:**
- Unblocks session security model
- Enables window-registry and routing-allowlist work downstream
- Small, focused scope (tray ↔ router ↔ forge handshake)

**Evidence of readiness:**
- Launcher already emits data-URI with OTP placeholder
- Router sidecar transport exists (cookie path, needs OTP variant)
- Spec exists and is detailed

### Task 2: browser/window-registry (MEDIUM-HIGH)

**Status:** pending / ready after session-otp
**Dependency:** `browser/launcher-contract`
**File Scope:**
- `crates/tillandsias-core/src/state.rs` (registry type definitions)
- `crates/tillandsias-headless/src/tray/mod.rs` (lifecycle handling)

**What it does:**
- In-memory window registry tied to tray state machine
- Currently: partial unit coverage in browser-mcp server
- Missing: tray-level ownership, persistent state across launches
- Required for: CDP bridge wiring and lifecycle cleanup

**Why after session-otp:**
- Depends on understanding OTP flow (session binding)
- Can run in parallel with CDP bridge work
- Separate from routing (allowlist work independent)

**Evidence of readiness:**
- Unit tests exist in browser-mcp
- State.rs already has Container/Project types
- Clear interface between launcher and registry expected

### Task 3: browser/cdp-bridge (MEDIUM)

**Status:** pending / ready after window-registry
**Dependency:** `browser/window-registry`
**File Scope:**
- `crates/tillandsias-browser-mcp/src/server.rs` (real CDP methods)
- `images/chromium/chromium-framework-launch.sh` (Chromium attach)

**What it does:**
- Replace placeholder methods with real CDP bridge
- Currently: `browser.screenshot`, `browser.click`, `browser.type` return "follow-up"
- Missing: actual Chrome Devtools Protocol attach/watcher loop
- Required for: functional browser automation in OpenCode Web

**Why third:**
- Depends on window-registry (process tracking)
- Blocks OpenCode Web CLI integration testing
- Can run in parallel with routing work

**Evidence of readiness:**
- MCP server shell exists
- Chromium launch script has launch path
- CDP library (chromedriver/puppeteer equiv) available in forge

### Task 4: browser/routing-allowlist (MEDIUM)

**Status:** pending / ready after session-otp
**Dependency:** `browser/session-otp`
**File Scope:**
- `openspec/specs/subdomain-naming-flip/spec.md` (URL scheme)
- `openspec/specs/subdomain-routing-via-reverse-proxy/spec.md` (proxy wiring)
- Forge reverse proxy container or Linux host tray proxy

**What it does:**
- Subdomain routing for OpenCode Web (project-name.localhost:8xxx → forge)
- Currently: allowlist in MCP server (accept/reject path only)
- Missing: reverse proxy wiring on host or tray side
- Required for: practical session isolation + multi-project browsing

**Why parallel with cdp-bridge:**
- Independent of window-registry (orthogonal to process tracking)
- Depends on OTP understanding (session binding for allowlist checks)
- Can be tested with static curl before full integration

**Evidence of readiness:**
- MCP server allowlist logic complete (unit tests 17/17)
- Spec exists and detailed
- Linux tray can host reverse proxy (no macOS/Windows complexity)

### Task 5: browser/legacy-session-tombstone (LOW)

**Status:** pending / ready after routing-allowlist
**Dependency:** `browser/routing-allowlist`
**File Scope:**
- `openspec/specs/opencode-web-session/spec.md` (old spec)
- `openspec/litmus-bindings.yaml` (marker)

**What it does:**
- Formal retirement of old session spec
- Replace with: new `opencode-web-session-otp` spec
- Idempotent: retains old spec in archive for trace references

**Why last in browser work:**
- Cleanup task, not functionality
- Depends on new OTP path fully wired
- Signals full migration complete

**Evidence of readiness:**
- Old spec already identified for replacement
- Tombstone methodology documented in CLAUDE.md

## Execution Order (Recommended)

```
Week 1-2:
  - browser/session-otp (router OTP wiring)
  
Week 2-3:
  - browser/window-registry (tray lifecycle)
  - (parallel) browser/routing-allowlist (proxy wiring)
  
Week 3-4:
  - browser/cdp-bridge (real CDP methods)
  
Week 4+:
  - browser/legacy-session-tombstone (formal retirement)
```

## Verification Checkpoints

After each task, run:

```bash
cargo test -p tillandsias-otp
cargo test -p tillandsias-browser-mcp
cargo test -p tillandsias-headless --features tray

./build.sh --ci --strict --filter browser-bundle
./build.sh --ci-full --install --strict --filter browser-bundle
```

## Next Agent Handoff Notes

1. **Session-OTP is the dependency unlock:** Once wired end-to-end, window-registry and routing work unblocks in parallel
2. **No cross-platform complexity:** All five tasks are Linux-only; simplifies tray/proxy/forge wiring
3. **Tray state machine is stable:** browser/launcher-contract completed at 47% (mostly OTP delivery + registry wiring remains)
4. **Small, reviewable diffs:** Each task ~300-500 LOC per spec
5. **Existing coverage:** Unit tests exist for MCP server, launcher, OTP; integration tests need to be filled in
6. **If blocked:** Check plan/issues/browser-launcher-contract.md for ongoing refinements from the launcher-contract task

## Deferred: Do NOT work on in Wave 1

- ❌ `cross-platform/windows-routing` — deferred
- ❌ `cross-platform/windows-logging` — deferred
- ❌ `cross-platform/wsl-runtime` — deferred
- ❌ `cross-platform/wsl-daemon-orchestration` — deferred
- ❌ `cross-platform/versioning` (cross-platform subset) — deferred
- ❌ `cross-platform/image` (web-image) — deferred
- ❌ `cross-platform/zen-pool` — deferred

Focus entirely on browser/session/routing on Linux.
