## Context

`shutdown_all` (`src-tauri/src/handlers.rs:3916`) does the right shape: stop tracked containers, stop infra (router, proxy, inference, git-services), then orphan-sweep by `tillandsias-` prefix. Each stop hits `ContainerLauncher::stop` (`crates/tillandsias-podman/src/launch.rs:140`), which sends SIGTERM with a 12-second `tokio::time::timeout`, falling back to `podman kill` (default SIGTERM, **not** SIGKILL despite the function name) on timeout. The forge profile already sets `--init` (`src-tauri/src/launch.rs:49`), so PID 1 inside the container is a real init that propagates signals.

Despite all this, observed behavior on `Quit` is occasional `tillandsias-*` containers left running on the host, with `conmon` parent processes still alive. The likely failure modes:

1. **Silent stop failure**: `client.stop_container` swallows non-zero exits at `crates/tillandsias-podman/src/client.rs:240–247` (`Ok(())` returned with only a warning). If podman fails for a transient reason (lock contention, OCI runtime ENOENT, tmpfs full), `shutdown_all` declares success and moves on while the container is still alive.
2. **`kill_container` does not actually KILL**: `kill_container` at `client.rs:251` invokes `podman kill <name>` with no `--signal` flag — podman defaults to SIGTERM. If the container ignored the first SIGTERM (or its main process is mid-syscall), the second SIGTERM may also be ignored. SIGKILL is what we actually need at that point.
3. **No verification**: `shutdown_all` never re-checks `podman ps` before returning. `app_handle.exit(0)` runs immediately afterward, orphaning whatever survived.
4. **Conmon-as-daemon hack**: `conmon` is podman's container monitor. It holds the container's stdio, reaps its main process, and writes the exit status file. Even when `podman stop`/`podman rm` succeeds in podman's view, a conmon process can briefly outlive the container (it flushes logs and writes the exit code). Under contention (a busy IO subsystem, a slow `journald` consuming log fd), the exit-flush window can be long enough that another podman command sees a "still running" view, and the orphan sweep races with the cleanup. We can't always trust podman alone — we need a last-resort `pkill` against `conmon` processes whose `--name` argument matches a `tillandsias-*` container.

The fix is purely additive: keep the existing graceful path, then add a verification phase that escalates only if necessary.

## Goals / Non-Goals

**Goals:**
- After `shutdown_all` returns, `podman ps --filter name=tillandsias- --format '{{.Names}}'` SHALL return zero rows. Hard guarantee, not best-effort.
- Total verification budget is bounded — at most 5 seconds of polling after the existing shutdown path completes.
- Escalation is observable in the accountability log: every escalation step (kill-with-SIGKILL, conmon-pkill) emits an `accountability = true, category = "enclave"` event with the offending container name.
- The existing 10-second graceful SIGTERM grace per container is preserved — escalation only kicks in when graceful failed.

**Non-Goals:**
- Changing the in-tray `Maintenance` flow, the forge entrypoint, or the `--init` flag (already set).
- Adding container restart logic — this is purely a teardown path.
- Adding a UI surface to the user. Stragglers are reported in logs, not as desktop notifications.

## Decisions

### Decision 1: Keep `launcher.stop` graceful; add verify-and-escalate AFTER the existing sweep

**Choice**: The existing per-container loop in `shutdown_all` (lines 3958–3990) is unchanged. The orphan sweep (lines 4023–4045) is unchanged. After both complete, run `verify_shutdown_clean()`, which:

1. Polls `podman ps --filter name=tillandsias- --format '{{.Names}}'` every 200 ms for up to 5 s, stops as soon as the result is empty.
2. For any container still listed at the end of the budget: invoke `podman kill --signal=KILL <name>` (force SIGKILL, regardless of what `kill_container` defaults to), wait 500 ms, then `podman rm -f <name>`.
3. Re-check `podman ps`. For any container STILL listed (rare — kernel is usually decisive about SIGKILL): invoke `pkill -TERM -f 'conmon.*--name tillandsias-'` and re-check one more time. Anything beyond that is a host-level pathology we surface via `error!` accountability log and return — we don't block exit indefinitely.

**Why**: Three escalation tiers cover the realistic failure modes without ever delaying the happy path. When everything works (the typical case), the verification poll sees zero rows on the first iteration and returns within 200 ms.

**Alternative rejected**: Replace `launcher.stop` with `podman kill --signal=KILL` from the start. Loses the 10s graceful window for in-flight writes (e.g., a forge container flushing the git mirror), and the user explicitly asked for graceful termination.

### Decision 2: Extend `kill_container` to accept an explicit signal

**Choice**: `kill_container` becomes `kill_container(name, signal)` where `signal: Option<&str>`. `None` preserves today's default-SIGTERM behavior; `Some("KILL")` translates to `--signal=KILL`. The verification loop always passes `Some("KILL")` because by the time we get there, graceful has already been tried.

**Why**: Don't change today's caller behavior (the timeout fallback in `launcher.stop`); only the new verification path opts in to SIGKILL. Smallest possible API change.

### Decision 3: `pkill` is the absolute last resort, scoped narrowly

**Choice**: The conmon `pkill` runs only after `podman kill --signal=KILL` + `podman rm -f` failed to clear the container. The pattern is `'conmon.*--name tillandsias-'` (substring match against the conmon process command line). We send SIGTERM (not SIGKILL) — conmon catches SIGTERM and exits cleanly after writing the container's exit status file. SIGKILL on conmon would leave podman's state inconsistent (no exit-status file written → `podman ps -a` shows a zombie).

**Why**: This is the layer below podman. We use it because podman is failing us, but we still respect podman's invariants (give conmon a chance to flush state).

**Alternative rejected**: `pkill -KILL` on conmon. Causes podman to see permanently-zombie containers on next start; can require manual `podman system reset` to recover. Not worth it for a corner-case escalation.

### Decision 4: Verification budget is 5 s total, not per-container

**Choice**: The 5-second cap covers the entire verification phase across all stragglers. Polling backoff is 200 ms (no exponential). Each escalation step (SIGKILL, pkill) is bounded individually but the global budget caps everything.

**Why**: User clicked Quit. They want the app gone. A 5-second cap on top of the existing shutdown is acceptable; longer than that and we're just delaying the inevitable orphan investigation. The whole shutdown spec (`Quit always serviceable within 5 seconds` from the existing `tray-app` spec) is about getting from the click to the start of `shutdown_all`. The verification phase is a separate budget within the cleanup itself, so total worst-case shutdown is roughly 5 s (Quit budget) + 12 s (per-container graceful) + 5 s (verification) ≈ 22 s. Under normal conditions it's ≪ 1 s end-to-end.

## Risks / Trade-offs

- **Risk**: `pkill` is process-name-pattern-based and could in theory match an unrelated `conmon` if a user has a non-tillandsias container named `tillandsias-something` outside our flow. → **Mitigation**: The existing orphan sweep (`tillandsias-` prefix on `podman ps`) already has this property; we inherit no new exposure. Document the pattern requirement in the spec.
- **Risk**: SIGKILL on the container can leak temporary mounts (the forge mounts a tmpfs scratch space). Podman's `--rm` should clean these but skips on SIGKILL. → **Mitigation**: The `podman rm -f` after the kill is what triggers mount teardown; podman handles it correctly even after SIGKILL. The `--rm` flag is a separate auto-removal trigger, not the only path.
- **Risk**: A misbehaving container that catches SIGTERM and ignores it for 30 s would never escalate without this change today; with it, escalation happens at second 12 (graceful timeout) + 5 (verification) = 17 s. The previous behavior was an indefinite-survival container. → **Trade-off accepted**.
- **Risk**: On Windows, `pkill -f` is unavailable and the conmon pattern doesn't apply (Windows uses HCS, not conmon). → **Mitigation**: Cargo-cfg the conmon-pkill path to `cfg(unix)` only. On Windows we still get the SIGKILL escalation via `podman kill --signal=KILL`, which is enough — Windows containers don't have the conmon-as-daemon hack.
- **Trade-off**: The verification log spam grows during a clean shutdown by exactly one `info!` line ("verify_shutdown_clean: zero stragglers"). Acceptable: the line is the proof we kept the contract.
