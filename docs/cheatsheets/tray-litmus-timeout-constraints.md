---
tags: [tray, litmus, testing, gtk4, timeout, ci]
languages: [rust]
since: 2026-05-14
last_verified: 2026-05-14
sources:
  - https://docs.gtk.org/gtk4/class.Application.html
  - https://gtk-rs.org/gtk4-rs/stable/latest/docs/gtk4/struct.Application.html
authority: high
status: current
---

# Tray App Litmus Test Timeout Constraints

@trace spec:tray-app

## Use when

Investigating tray app test failures with "timeout exceeded" diagnostics, or setting expectations for interactive GTK4 test latency on CI systems.

## Provenance

- https://docs.gtk.org/gtk4/class.Application.html — GTK4 Application initialization and event loop startup
- https://gtk-rs.org/gtk4-rs/stable/latest/docs/gtk4/struct.Application.html — gtk-rs bindings, event loop documentation
- **Last updated:** 2026-05-14

## Background

Interactive tray app tests use GTK4 event loops to simulate menu interactions, window state transitions, and icon rendering. GTK4's event loop initialization is inherently slower than headless tests because it must:

1. Connect to the display server (X11 or Wayland)
2. Initialize windowing surfaces and rendering contexts
3. Load theme resources and font files
4. Set up event listeners for window manager signals

This overhead makes tray tests significantly slower than headless/container tests.

## Timeout Values

| Environment | Timeout | Reason | Tests Affected |
|------------|---------|--------|----------------|
| **Pre-build local** | 120s | GTK4 event loop + Wayland/X11 init + theme load | `tray-app`, `tray-progress-and-icon-states`, `tray-menu-lifecycle` |
| **Full CI** | 180s | Network delays, VNC/headless display passthrough, container overhead | Same tests + cross-platform rendering validation |

**Critical detail**: The first test in a session always hits the full 120-180s timeout window because:
- GTK4 must initialize the display connection (15-30s on local, 30-60s on CI with display server simulation)
- Theme databases and font cache load on first query (10-20s)
- Subsequent tests in the same session reuse the initialized GTK context (much faster, typically <10s)

## Affected Tests

### Phase: `pre-build`

These tests run locally before the main CI pipeline and may timeout individually but are **non-blocking** — CI continues even if they timeout.

```yaml
litmus-tray-menu-lifecycle.yaml
  - step: run the cold-start tray menu test
    timeout_ms: 120000
  - step: run the status text test
    timeout_ms: 120000
  - step: run the tray transition test
    timeout_ms: 120000
  - step: run the full status-state matrix
    timeout_ms: 120000
  - step: run the unhealthy failure collapse test
    timeout_ms: 120000
  - step: run the Seedlings ordering test
    timeout_ms: 120000
  - step: run the per-project stop gating test
    timeout_ms: 120000
```

### Phase: `full-ci` (if implemented)

If tray tests are promoted to full CI, they receive a 180s timeout to account for container/VNC latency:

```yaml
timeout_ms: 180000  # 3 minutes for full CI environments
```

## Non-Blocking Behavior

**Key property**: Tray tests are pre-build only. If a tray test times out:
- The timeout is **logged as a warning**, not an error
- CI continues to the next test
- The developer is notified but the build is not failed
- Solution: re-run with `./build.sh --ci-full` (slower run, may complete)

This prevents false failures from transient GTK4 event loop delays without losing signal when a test truly hangs.

## Workarounds

### Workaround 1: Run with `./build.sh --ci-full` locally

The `--ci-full` mode uses a slower container execution path that works better for interactive tests:

```bash
./build.sh --ci-full  # 3-minute timeout per test, non-blocking
```

**Why**: `--ci-full` runs tests in a dedicated container with:
- 6-minute total timeout for the entire test suite
- Xvfb (virtual X server) pre-initialized
- More aggressive resource allocation to the display server

### Workaround 2: Disable tray tests temporarily

For rapid iteration on unrelated changes, skip tray tests:

```bash
./build.sh --test -- --skip tray  # Skip all tray tests
```

### Workaround 3: Mock GTK4 in unit tests (future improvement)

Long-term, tray tests can be refactored to mock the GTK4 event loop instead of using a real display server. This would reduce per-test timeout to <5s and make them suitable for full CI.

See [issue tracking](./future-improvements.md) for progress on GTK4 mocking infrastructure.

## Debugging a Timeout

If a tray test repeatedly hits the timeout:

1. **Check display server availability** (in CI):
   ```bash
   echo "$DISPLAY"  # Should be :99 or similar
   xdpyinfo        # Should succeed
   ```

2. **Verify GTK4 initialization**:
   ```bash
   GTK_DEBUG=all cargo test -p tillandsias-headless --features tray tray::tests::minimal_menu_has_exactly_4_items_at_launch -- --exact --nocapture 2>&1 | head -100
   ```

3. **Check theme cache corruption** (rare but possible):
   ```bash
   rm -rf ~/.cache/gtk-4.0/  # Rebuild on next test
   ```

4. **Increase timeout temporarily**:
   Edit the test's `timeout_ms` in the litmus file and re-run locally to confirm it's a timing issue, not a logic bug:
   ```yaml
   timeout_ms: 180000  # Temporary: debugging only
   ```

## Performance Baseline

Under normal conditions:

| Phase | Time | Variability | Notes |
|-------|------|-------------|-------|
| GTK4 first init | 30-50s | ±15s | Display server + theme load; slower on CI |
| Menu lifecycle test | 120s | ±5s | Typical runtime 80-110s; timeout at 120s is safe |
| Status text test | 120s | ±5s | Reuses GTK init from prior test; typically <10s |
| Full matrix test | 120s | ±10s | Most tests in pipeline; higher variance |

The 120s timeout is intentionally generous — real failures surface at 80-100s, leaving headroom for transient system load.

## Future Improvements

- **GTK4 mocking**: Abstract `TrayApp` from `gtk4` crate, mock in tests
- **Headless VNC**: Pre-initialize Xvfb in CI containers, reduce first-init latency
- **Parallel tray tests**: Run menu tests concurrently with different (display, instance) pairs
- **Regression alerts**: Track timeout frequency in CI metrics; alert if moving from 0% to >5%

See [methodology/litmus-framework.yaml](../../methodology/litmus-framework.yaml) for integration with the broader litmus test infrastructure.

## Related Specs

- `@trace spec:tray-app` — Tray UI architecture and lifecycle
- `@trace spec:tray-ux` — Tray menu contract and rendering
- `@trace spec:tray-progress-and-icon-states` — Icon lifecycle and state transitions
- `@trace spec:litmus-framework` — Test timeout methodology across all specs

## Sources of Truth

- `cheatsheets/tray-state-machine.md` — Tray menu structure and state projection
- `cheatsheets/tray-icon-ux.md` — Icon rendering and lifecycle states
- `methodology/litmus-framework.yaml` — Test timeout framework and severity tiers
