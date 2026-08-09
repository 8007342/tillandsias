# low-end-no-local-inference-gate — operator kill switch for the local-inference container

Filed 2026-08-08 from the Intel N100 field host (`Esmeralda`, 16GB RAM, 4
E-cores). Deliverable for the packet of the same id. Operator direction: make
Tillandsias work on very low-end devices, accepting that this likely means
disabling the local inference containers.

trace: spec:inference-container (auto-start scenario — needs a delta spec, see
follow-ups), spec:mcp-on-demand, openspec/specs/inference-container/spec.md

## Why

`tillandsias-inference` is the only local-inference workload: a Fedora-minimal
ollama container that self-installs a ~2.1GB engine on first start, pulls
qwen2.5:0.5b (~400MB), and stays resident with `OLLAMA_KEEP_ALIVE=24h`. It is
started unconditionally at every lane launch (forge, --opencode,
--opencode-web, --status-check) even though nothing consumes it yet ("local
ollama is a FUTURE expert-system feature", readiness is warn-and-continue).
The image supports `TILLANDSIAS_INFERENCE_PRELOAD=off`, but the launcher never
forwards it — before this packet there was NO operator-reachable kill switch.
On an N100 with 16GB shared RAM that footprint is unaffordable.

The control wire itself needs zero containers (VmPhase Ready flips on
/run/podman/podman.sock presence); steady-state supervision re-ensures only
vault + proxy. Gating inference is therefore safe and orthogonal to launch.

## Fix (implemented this session)

- `crates/tillandsias-headless/src/main.rs`: new pure `inference_disable_flag`
  (unit-tested truth table: unset/`0`/whitespace → enabled; anything else set →
  disabled) + `local_inference_disabled()` env wrapper reading
  `TILLANDSIAS_NO_LOCAL_INFERENCE`. Gated sites: `wait_for_inference_ready`
  (short-circuits Ok), status-check `status-inference`, `opencode-inference`,
  `opencode-web-inference` (start + started-event both skipped),
  `forge-launch-inference` inside `ensure_shared_git_and_inference_for_launch`.
  Every skip logs one loud line. Git mirror/vault/proxy/router are untouched.
- `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`: when the TRAY's
  environment carries the flag, `inject_bootstrap_logic` writes
  `Environment=TILLANDSIAS_NO_LOCAL_INFERENCE=1` into
  tillandsias-headless.service, so a low-end Windows host opts its guest out at
  provision/reconcile time. On this host the flag is set as a user-level env
  var (`[Environment]::SetEnvironmentVariable(..., 'User')`).

Safety: every guest-side consumer already degrades — forge startup context
labels inference OPTIONAL, `tellme howto` exits 1 cleanly, opencode entrypoints
probe-and-continue.

## Exit criteria

- [ ] With the flag set, a lane launch on this host creates no
      `tillandsias-inference` container and the launch succeeds.
- [ ] Unit tests green.
- [ ] Follow-ups filed (below) for the durable product surface.

## Follow-ups (each a candidate ready packet; kept here until claimed)

1. **Delta spec**: amend spec:inference-container "Inference auto-start"
   scenario to admit the operator gate (openspec change; UX copy needs
   Tlatoani approval if surfaced in the tray menu).
2. **Auto-detection**: derive a low-power default from the existing
   accel_probe surface (system_ram_gb, cpu_cores, is_battery_present — the
   battery bit currently has no consumer) instead of requiring a manual env.
3. **Plumb `TILLANDSIAS_INFERENCE_PRELOAD` through `build_inference_run_args`**
   so bandwidth-capped hosts can keep the container but skip pulls (the
   documented knob is currently unreachable in production).
4. **`OLLAMA_KEEP_ALIVE` knob**: launcher-pinned 24h residency is wrong for
   low-RAM hosts once anything consumes local inference.

## Evidence / handoff

- Branch: code on windows-next; this note + fragment on linux-next.
- Owned files: crates/tillandsias-headless/src/main.rs,
  crates/tillandsias-windows-tray/src/wsl_lifecycle.rs.
- Next action: e2e on this host (lane launch with flag set), append evidence,
  then completed-event fragment; follow-ups stay ready for any host.
