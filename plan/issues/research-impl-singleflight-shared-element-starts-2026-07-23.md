# RESEARCH + IMPLEMENTATION: singleflight coalescing for shared-element starts — concurrent "ensure/start X" collapse to ONE in-flight op whose result is shared (2026-07-23)

- **Class**: research + implementation (research MANDATORY before the impl slice, operator standing rule)
- **Status**: proposed
- **Desired release**: research = future (v0.5+); **implementation has a near-term
  slice**: a uniform `singleflight_ensure(resource, ||…)` wrapper over the
  existing `resource_lock` flock, applied first to `ensure_proxy_running` /
  `ensure_git_image_available` (the two ensures on the hot login/probe path), is
  small and directly reduces duplicate starts under concurrent probes/launches.
- **Owner host**: any (the ensures live in shared `tillandsias-headless`; the
  coalescer is consumed by every launch/probe path on all hosts)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: concurrent calls
  to STARTING a shared element should just receive the SAME shared element —
  coalescing / singleflight, no duplicate starts. This is the explicit exception
  to "rate-limit everything": you don't throttle a shared start, you *share* it.
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
  (the self-DDoS'd login probe re-ran `ensure_proxy_running` / lease-mint / image
  ensure on every tick — the shared starts behind the probe were themselves being
  hammered) and `plan/issues/concurrent-forges-unsafe-shared-stack-bounce-and-teardown-race-2026-07-20.md`
  (a second forge launch `--replace`d shared containers a live sibling was using).
- **Sibling packets in this anti-DDoS wave (non-overlapping, file together)**:
  - `plan/issues/research-idiomatic-layer-call-taxonomy-2026-07-23.md` (the taxonomy that tags which calls are Class C shared-starts and therefore in scope here)
  - `plan/issues/research-impl-rate-limiting-expensive-probes-2026-07-23.md` (rate-limiting — the complementary policy for Class B; a limiter throttles repeated calls, a coalescer shares one concurrent start)
  - `plan/issues/research-near-zero-overhead-guest-invariant-2026-07-23.md` (the litmus that a coalesced ensure does not spawn N duplicate starts and so stays within the CPU budget)
- **Cross-references the flow-graph wave (commit d89fac3d)**: the unified
  dependency graph (`research-unified-runtime-data-dependency-graph-2026-07-23.md`)
  already models shared elements as `Service` nodes with idempotent satisfiers;
  this packet is the **concurrency guardrail** on those satisfiers — the graph
  says *what* to ensure, singleflight guarantees N concurrent ensures of the same
  node produce ONE start, not N.

## Motivation

Shared elements — proxy, enclave/egress networks, Vault, router, git-mirror,
inference, the git image, AppRole leases — are brought up by idempotent `ensure_*`
functions, but the codebase's coalescing is **piecemeal**: some ensures take a
flock, some don't, and there is no uniform "one starts, the rest wait and observe
the winner" wrapper. The consequences are the two named incidents:

- **The login self-DDoS behind the probe.** Each 2 s login tick ran
  `run_git_image_shell` (`remote_projects.rs:295`), which itself calls
  `RemoteVaultLease::acquire` (mints a fresh AppRole lease, `remote_projects.rs:298`;
  `mint_approle_secret_lease`, `vault_bootstrap.rs:1285`) and `ensure_proxy_running`
  (`main.rs:2441`). So the shared starts were re-driven every tick. The proxy
  ensure survives this *because* it already flock-coalesces
  (`resource_lock::acquire("proxy", 300s)`, `main.rs:2451`) — order 232 R4 fixed
  exactly the "two parallel launches both saw not-running and both ran `podman run
  --name tillandsias-proxy`" race. That fix is the template; it just isn't applied
  uniformly.
- **The concurrent-forge bounce.** Launching a second forge re-ensured the shared
  stack with `--replace` (`main.rs:2399,2832,…`), restarting containers the first
  forge was using — killing it (concurrent-forges packet, root cause 1). The cure
  is idempotent ensure-if-absent-and-healthy + a shared refcount, of which the
  pre-create half already exists as the launch-in-flight flock
  (`acquire_launch_in_flight_marker` / `foreign_launches_in_flight`,
  `main.rs:4407,4423`). Singleflight generalizes the ensure half.

The substrate is already here: `resource_lock` (`resource_lock.rs`) is a
cross-process flock with `Exclusive`/`Shared` modes and a bounded wait where **the
loser waits for the winner** — precisely singleflight's "one runs, the rest
block" — plus `VAULT_BOOTSTRAP_DONE`'s `compare_exchange(false,true)` once-gate
(`vsock_server.rs:51,1121`) as the in-process idiom. What's missing is (a) a
uniform wrapper so every Class C start goes through it and (b) **result sharing**:
today the loser waits then re-runs the running-check to observe the winner's
container; a first-class singleflight would hand the loser the winner's `Result`
directly (or its idempotent observation), so "concurrent starts receive the SAME
shared element" is guaranteed by construction, not by each caller re-deriving it.

## Proposed approach

A `singleflight_ensure` primitive layered on the existing `resource_lock`, with
optional in-process result sharing, applied to every Class C call the sibling
taxonomy lists.

### The primitive

```
// cross-process (the authoritative layer — two tillandsias processes)
singleflight_ensure(resource: &str, timeout, ||-> Result<T>) -> Result<T>
//   1. acquire resource_lock::Exclusive(resource)         [loser waits here]
//   2. fast-path: if already-satisfied observation holds, return it (no act)
//   3. run the closure once (the winner starts X)
//   4. drop the lock → next waiter re-enters at step 2 and observes "satisfied"
```

- **Cross-process:** reuse `resource_lock::acquire` (`resource_lock.rs`) exactly as
  `ensure_proxy_running` does today (`main.rs:2451`). The winner starts; every
  waiter, on acquiring, sees the running-check pass and returns without a second
  `podman run`. This already gives "no duplicate starts."
- **In-process result sharing (the upgrade):** for concurrent tasks in the SAME
  process (the vsock server handles requests concurrently), add an in-memory
  `OnceCell`/`tokio::sync` per-resource in-flight map so N concurrent callers
  await ONE future and all receive its `Result<T>` — the classic singleflight,
  avoiding even the flock round-trip and guaranteeing identical results. Model on
  the `VAULT_BOOTSTRAP_DONE` once-gate but returning the shared value.
- **Fast-path satisfied-check:** the closure's first act is the idempotent
  observation the ensures already do (`container_running("tillandsias-proxy")`,
  `main.rs:2452`), so a coalesced ensure of an already-up element is a cheap
  no-op — which is what keeps the guest at near-zero CPU under repeated probes.

### Applying it

- Route `ensure_proxy_running`, `ensure_enclave_network`, `ensure_egress_network`,
  `ensure_router_running`, `ensure_git_image_available`, and the Vault ensure
  through `singleflight_ensure` with a stable resource key per element. Several
  already hold ad-hoc flocks — consolidate onto the one wrapper.
- **Ensure-if-absent-and-healthy, never `--replace`-a-live-sibling** for shared
  containers: the coalescer's fast-path satisfied-check must treat a *healthy*
  shared container as satisfied and skip the `--replace` recreate
  (`main.rs:2399,2832,3284,3452,10945`), reserving `--replace` for exited/unhealthy
  ones. This is the concurrent-forges fix expressed through the coalescer.
- **Teardown side:** keep the derived-live refcount
  (`cleanup_shared_stack_if_no_running_forge`, `main.rs:4477`) — a coalesced START
  and a refcounted STOP are the two halves of the shared-element lifecycle; this
  packet owns start, the concurrent-forges packet owns stop, and they share the
  `resource_lock` + launch-in-flight-marker substrate.

### Impl slices

- **Slice A (near-term):** `singleflight_ensure` wrapper (cross-process only,
  over `resource_lock`) + apply to `ensure_proxy_running` and
  `ensure_git_image_available` (the two on the hot probe path). Litmus below.
- **Slice B (v0.5):** in-process result-sharing map (concurrent vsock tasks share
  one in-flight future) + apply to the remaining ensures + the Vault/lease path.
- **Slice C (v0.5):** the ensure-if-healthy vs `--replace` discipline for shared
  containers, closing the concurrent-forges bounce through the coalescer.

## Investigate / prototype

- **Cross-process vs in-process — do we need both?** The flock already prevents
  duplicate *starts* across processes. In-process sharing additionally avoids the
  flock round-trip and guarantees identical `Result` for concurrent tasks. Measure
  whether the vsock server actually issues concurrent ensures (it handles requests
  concurrently) to justify slice B.
- **Result type shareability.** `resource_lock` returns a guard, not the ensure's
  value. For in-process sharing the `Result<T>` must be `Clone` (or the shared
  element is a handle/name). Most ensures return `Result<()>` or a mount arg
  (`RemoteVaultLease::mount_arg`, `remote_projects.rs:299`) — cheap to clone.
  Confirm per element.
- **Lease semantics vs singleflight.** `RemoteVaultLease` / `mint_approle_secret_lease`
  mint a *new scoped* lease per acquire — is that a "shared element" (coalesce to
  one) or a "per-caller credential" (each caller genuinely needs its own)? Decide:
  probably the Vault *container* is the coalesced shared element while the lease is
  per-caller but cheap. Grounds the boundary of "shared" vs "per-caller."
- **Interaction with the drain gate.** `container_mutations_allowed()`
  (`main.rs:2444`) makes an ensure refuse-before-wait during drain. Confirm
  `singleflight_ensure` preserves refuse-fast (a drain-time loser must not block on
  the flock behind a mutation that will be refused anyway).
- **Failure sharing.** If the winner's start FAILS, do the waiters get the same
  error or retry themselves? For a transient failure, one-retries-all is a
  thundering herd; prefer the winner's error is shared for a short window (ties to
  the sibling circuit-breaker), then the next entrant retries.
- **Bounded wait tuning.** The proxy ensure uses 300 s (`main.rs:2451`), the
  launch marker 10 s (`main.rs:4414`). Pick per-element bounds so a wedged winner
  cannot hang all waiters past their own deadlines.
- **Reconcile with `VAULT_BOOTSTRAP_DONE`.** That once-gate never *re-runs*
  bootstrap; singleflight *does* re-enter after the winner finishes. Confirm the
  once-vs-coalesce distinction per element (bootstrap = once-ever; proxy ensure =
  coalesce-per-call, re-armable after teardown).

## Exit criteria

- **Litmus (falsifiable, the core deliverable): M concurrent ensures → 1 start.**
  A test drives M concurrent `singleflight_ensure(proxy, …)` (or the git-image
  ensure) with an injected start-counter (reuse the `Healer`/`Satisfier`/
  `PodmanClient` trait seams so no real container is needed) and asserts the
  underlying start closure runs exactly once and all M callers receive an
  equivalent success. This reproduces order 232 R4 as a guarded property.
- A test proving **no bounce**: mark a shared container healthy, run the launch-time
  ensure for a second lane, assert the container is NOT recreated (same id
  before/after) — the concurrent-forges Slice-1 fixture expressed through the
  coalescer (`concurrent-forges-…-2026-07-20.md`, closure fixture 1).
- A test proving the **loser observes the winner's element**: two callers, the
  loser's fast-path satisfied-check passes after the winner completes, so the loser
  returns the SAME element with no second `podman run`.
- A decision record: cross-process-only vs +in-process sharing per element; the
  "shared element vs per-caller credential" boundary for the Vault lease; failure
  sharing policy; per-element bounded-wait values; once-gate vs coalesce per
  element.
- Slice A shipped: `ensure_proxy_running` + `ensure_git_image_available` route
  through `singleflight_ensure`; `cargo test -p tillandsias-headless` green;
  existing proxy-race / `--replace` assertions (`main.rs:14982-14995`) still pass.

## Existing-code references

- `crates/tillandsias-headless/src/resource_lock.rs` — flock `Exclusive`/`Shared`, bounded loser-waits acquire: the singleflight substrate.
- `crates/tillandsias-headless/src/main.rs:2441-2481` — `ensure_proxy_running`: the existing flock-coalesced ensure (order 232 R4) that is the template.
- `crates/tillandsias-headless/src/main.rs:2444` — `container_mutations_allowed()` refuse-before-wait (must be preserved through the wrapper).
- `crates/tillandsias-headless/src/main.rs:2452` — `container_running("tillandsias-proxy")` fast-path satisfied-check.
- `crates/tillandsias-headless/src/main.rs:1908,2075,3605` — `ensure_enclave_network` / `ensure_egress_network` / `ensure_router_running`: further Class C ensures to route through the wrapper.
- `crates/tillandsias-headless/src/main.rs:2399,2832,3284,3452,10945` — `--replace` recreate sites (must become ensure-if-unhealthy, not replace-a-live-sibling).
- `crates/tillandsias-headless/src/main.rs:4407-4428` — `acquire_launch_in_flight_marker` / `foreign_launches_in_flight`: the pre-create flock (the start-side complement already built).
- `crates/tillandsias-headless/src/main.rs:4477-4530` — `cleanup_shared_stack_if_no_running_forge`: the derived-live refcount (the stop half; shares this packet's substrate).
- `crates/tillandsias-headless/src/main.rs:14982-14995` — existing `--replace` assertions the coalescer's discipline must keep green.
- `crates/tillandsias-headless/src/remote_projects.rs:109` — `ensure_git_image_available`: Class C ensure on the hot probe path (slice A target).
- `crates/tillandsias-headless/src/remote_projects.rs:186-216,298-306` — `RemoteVaultLease::acquire` + the proxy ensure it drives (the shared starts behind every probe).
- `crates/tillandsias-headless/src/vault_bootstrap.rs:792-794,1285-1291` — `vault_stability_lease` (Shared) + `mint_approle_secret_lease` (Exclusive-under-the-hood): existing shared/exclusive coordination to consolidate.
- `crates/tillandsias-headless/src/vsock_server.rs:51,1121` — `VAULT_BOOTSTRAP_DONE` `compare_exchange` once-gate: the in-process singleflight-once idiom to generalize (into re-armable coalesce for ensures).
- `plan/issues/concurrent-forges-unsafe-shared-stack-bounce-and-teardown-race-2026-07-20.md` — the bounce/teardown incident + its verifiable-closure fixtures this packet's litmus mirrors.
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — the self-DDoS that re-drove the shared starts every tick.

## Non-goals / scope

- NOT rate-limiting repeated calls — that is sibling ii (`research-impl-rate-limiting-expensive-probes-2026-07-23.md`). Coalescing shares ONE concurrent start; it does not throttle serial repeats (a repeated ensure of an up element is already a cheap no-op, which is the point).
- NOT the classification — sibling i (`research-idiomatic-layer-call-taxonomy-2026-07-23.md`) tags Class C.
- NOT the shared-stack TEARDOWN refcount — that is `concurrent-forges-unsafe-shared-stack-bounce-and-teardown-race-2026-07-20.md` (stop half); this packet owns the start half and shares its substrate.
- NOT the dependency-graph node model — that is the flow-graph wave's `research-unified-runtime-data-dependency-graph-2026-07-23.md` (d89fac3d); this coalesces its satisfiers.
- NOT weakening single-forge teardown or the mirror push-path invariants (orders 413/415/424).
- NOT changing the Vault security boundary or minting shared credentials where each caller needs its own.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation).
