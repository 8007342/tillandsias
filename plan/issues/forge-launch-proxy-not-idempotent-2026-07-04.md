# P0: forge-launch proxy bring-up not idempotent → "name already in use" blocks forge launch — 2026-07-04

- class: bug (P0, forge launch)
- filed: 2026-07-04
- owner: linux
- status: done
- trace: spec:proxy-container, spec:forge-as-only-runtime
- found-by: released v0.3.260704.1 curl-install smoke on the host

## Symptom

After curl-installing v0.3.260704.1 and `--init` (which leaves a healthy
`tillandsias-proxy` running), launching a forge failed at the proxy stage:

```
event:container_launch stage=forge-launch-proxy state=failed container=tillandsias-proxy
Error: creating container storage: the container name "tillandsias-proxy" is already
in use by <id>. ... or use --replace ...
Error: [forge-launch] failed to start proxy
```

The forge never came up. This blocks launching a Codex/Claude/OpenCode session
whenever a proxy already exists (from `--init`, or left by a prior/crashed
session — very common steady state).

## Root cause

The router stage brings itself up idempotently (`ensure_router_running`), and
the standalone `ensure_proxy_running` is idempotent (checks `container_running`,
then `podman rm --ignore`). But the FORGE-LAUNCH proxy sites called
`client.run_container_observed(..., "tillandsias-proxy", ...)` **raw** — no
reuse-if-running check, no stale cleanup — so `podman run --name tillandsias-proxy`
fails "name already in use" when a proxy exists. Three sites had the bug:

- `ensure_enclave_for_project` (`forge-launch-proxy`) — shared by BOTH the tray
  (`launch_forge_agent`) and CLI (`run_forge_agent_cli_mode`) Claude/Codex/
  OpenCode/Maintenance launches.
- the `--opencode` path (`opencode-proxy`).
- the `--opencode-web` path (`opencode-web-proxy`).

State-dependent: a launch from a truly-fresh state (no proxy) succeeds (which is
why it wasn't always seen), but a launch while a proxy is already running fails.

## Fix

Inlined the same idempotency guard as `ensure_proxy_running` at all three sites
(cannot call `ensure_proxy_running` directly — it runs its own tokio runtime and
these sites are already inside a `block_on`):

```rust
if container_running("tillandsias-proxy") {
    // reuse
} else {
    podman rm --ignore tillandsias-proxy   // clear stale
    run_container_observed("...-proxy", "tillandsias-proxy", build_proxy_run_args(...))
}
```

Regression test `forge_launch_proxy_bringup_is_idempotent` asserts each of the
three raw proxy launch sites is preceded by a `container_running("tillandsias-proxy")`
guard.

## Live verification (fixed binary)

With a proxy already running (the failing case), a forge now launches cleanly:
`tillandsias-relverify-forge-maintenance Up`, and inside it
`NODE_USE_ENV_PROXY=1` + `node fetch https://api.openai.com → HTTP 401 (REACHED
REMOTE)`. So the FULL chain now works: --init → forge launches → Node reaches the
model API through the proxy. A Codex session with a valid token would connect.

## Note

Not fixed in v0.3.260704.1 (found by that release's smoke). Warrants v0.3.260704.2.

## Verifiable closure

- `./build.sh --check` + `forge_launch_proxy_bringup_is_idempotent` test green.
- Live: forge launches with a proxy already running; Node reaches remote.
