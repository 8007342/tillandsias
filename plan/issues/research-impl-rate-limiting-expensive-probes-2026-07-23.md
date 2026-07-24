# RESEARCH + IMPLEMENTATION: rate-limiting / backpressure for expensive idiomatic probes — throttle repeated rapid calls, return a typed rate-limited error or cached last-good (2026-07-23)

- **Class**: research + implementation (research MANDATORY before the impl slice, operator standing rule)
- **Status**: proposed
- **Desired release**: research = future (v0.5+); **implementation has a near-term
  slice**: putting a min-interval + cache-last-good in front of
  `probe_github_username` (the exact call the reverted 2 s poll DDoSed) is small,
  self-contained, and could land in the current line as a direct anti-DDoS
  guard, independent of the larger v0.5 taxonomy.
- **Owner host**: any (the limiter lives in the shared `tillandsias-headless`
  guest probe surface + optionally the control-wire dispatcher; consumed by all
  three trays)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: our idiomatic
  layer has many expensive "probes" we must RATE LIMIT — start returning errors
  when a consumer fires them repeatedly, so we must not DDoS ourselves. Some
  calls must NOT be called frequently. We must not break the near-zero-CPU guest
  by DDoSing ourselves to poll a tooltip.
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
- **Sibling packets in this anti-DDoS wave (non-overlapping, file together)**:
  - `plan/issues/research-idiomatic-layer-call-taxonomy-2026-07-23.md` (the taxonomy that tags which calls are Class B and therefore in scope here)
  - `plan/issues/research-impl-singleflight-shared-element-starts-2026-07-23.md` (coalescing — the complementary policy for Class C; a limiter throttles, a coalescer shares)
  - `plan/issues/research-near-zero-overhead-guest-invariant-2026-07-23.md` (the litmus that proves the limiter holds the guest at near-zero idle CPU)
- **Cross-references the flow-graph wave (commit d89fac3d)**: the event channel
  (`research-flow-state-event-channel-2026-07-23.md`) removes the *reason* to
  poll a Class B probe (state is pushed when it changes). This limiter is the
  **guardrail that stays** — a subscriber that missed a push, a diagnostic, or a
  new consumer must still not be able to hammer the guest; the limiter caps the
  blast radius whether or not the push channel exists yet.

## Motivation

`probe_github_username` (`crates/tillandsias-headless/src/remote_projects.rs:384`)
has **no rate limit and no cache**. It reaches `run_git_image_shell`
(`remote_projects.rs:295`) which does `podman run --rm` — cold container create +
`RemoteVaultLease::acquire` (mints an AppRole secret lease) + `ensure_proxy_running`
+ Vault read + `gh auth login` + `gh api user` — bounded only by the 25 s
`GH_INVOCATION_TIMEOUT` (`remote_projects.rs:25`). The macOS tray's reverted "fast
confirm" called it via `GithubLoginStatusRequest`
(`crates/tillandsias-headless/src/vsock_server.rs:1000-1007`) every ~2 s while the
login chip was up. Result: a container storm inside the guest, purely to refresh
a tooltip — self-DDoS, and on WSL2 it converts the near-zero-idle guest into a
busy one, breaking the invariant the operator explicitly named.

The contrast proves the fix is idiomatic here: the *cloud list* path already has
a limiter — a 5-min TTL cache (`CACHE_TTL_SECS`, `remote_projects.rs:77`;
`discover_github_projects_inner`, `remote_projects.rs:450-460`) and a host-side
`cloud_refresh_in_flight` latch (`remote_projects.rs:22`). The login probe simply
never got one. And a cheap alternative already exists for the presence half:
`vault_bootstrap::is_github_key_present` (`vault_bootstrap.rs:799`) checks the key
via `podman exec` into the **already-running** Vault container — no new container
— and its own doc points callers there for "high-frequency poll loops"
(`remote_projects.rs:411-412`). The missing piece is a **uniform limiter** so a
Class B probe cannot be executed faster than its budget regardless of how eagerly
a consumer calls it, and a **typed error** so the caller learns "rate-limited,
retry after N" instead of silently triggering the work.

## Proposed approach

A min-interval + token-bucket limiter with a cache-last-good fallback, wrapping
every Class B probe (per the sibling taxonomy), plus a typed rate-limited error
that propagates over the control wire.

### Where the limiter lives

Two layers, defense in depth:

1. **Guest probe boundary (authoritative).** Wrap the Class B functions in
   `remote_projects.rs` so the limiter sits at the single choke where the
   container is actually spawned (`run_git_image_shell`, `remote_projects.rs:295`,
   or per-probe just above it). This catches *every* caller — the vsock handler,
   the guest periodic re-check (`main.rs:11477,11502`), and any future consumer —
   not just the trays. A generalization of the existing per-path 5-min cache.
2. **Control-wire dispatcher (fast-reject).** Optionally also gate at the
   `GithubLoginStatusRequest` / `CloudRefreshRequest` handlers
   (`vsock_server.rs:1000,969`) so a rapid remote caller is rejected *before* the
   `spawn_blocking`, saving even the task hop and letting the reply carry the
   typed error.

### The limiter

- **Min-interval per probe key** (simplest; covers the incident): a probe with a
  fresh result younger than its interval returns the **cached last-good** result
  instead of executing. Login presence: reuse `is_github_key_present`
  (exec-into-running, no container) as the cheap freshness check; only the full
  container probe is rate-limited. This is the "cached last-good result" branch
  the operator named.
- **Token-bucket for burst tolerance** (N executions per window, refill rate):
  when the bucket is empty, return the typed rate-limited error with a
  `retry_after`. Model the window/rate on the taxonomy's Class B default.
- **Circuit-breaker on repeated failure**: if the probe has failed K times in a
  row (e.g. proxy down, CA unreadable — the incident's actual failure), open the
  breaker and fast-fail with the last error for a cooldown, so a broken enclave
  is not re-probed every tick. Reuse the shape of the existing `CrashLoopDetector`
  / `AutoResetPolicy` FSMs in control-wire (`lib.rs:713,974`).

### The typed error

`ErrorCode` in control-wire (`crates/tillandsias-control-wire/src/lib.rs:407`) is
`#[non_exhaustive]` (`lib.rs:406`) and additive-safe (unknown variants degrade to
`UnknownVariant` on old peers, `lib.rs:400-402,409`). Add:

```
ErrorCode::RateLimited   // + a retry_after_ms carried in the Error{message} or a companion field
```

The `.kind()`/name match (`lib.rs:420-433`) forces a stable human name (the
enum's own guardrail — a new variant is a compile error until named). Guest-side,
a rate-limited probe returns this instead of executing; the tray folds it into
"last known" state (exactly the best-effort policy the pollers already use —
`poll_github_login_once` leaves login state untouched on `Err`,
`action_host.rs:2650-2661`). No wire-version bump (`lib.rs` trailing-additive
convention).

### Impl slices

- **Slice A (near-term, standalone):** min-interval + cache-last-good in front of
  `probe_github_username`, using `is_github_key_present` for the cheap freshness
  check. Litmus below. This alone makes the reverted 2 s poll safe even if
  re-introduced.
- **Slice B (v0.5):** generalize into a `probe_limiter` helper keyed by probe
  name, token-bucket + breaker, applied to every Class B call the taxonomy lists.
- **Slice C (v0.5):** the `ErrorCode::RateLimited` variant + dispatcher-side
  fast-reject + tray rendering.

## Investigate / prototype

- **Interval/bucket parameters.** Measure a real `run_git_image_shell` cost (cold
  vs warm container). Pick a Class B min-interval that is generous for genuine
  state changes (login flips are rare) but caps steady-state to ~0 containers/min
  when nothing changes. Confirm against the CPU budget in sibling iv.
- **Cache-last-good vs error — which per caller?** A tray tooltip wants
  last-good (silent); a `--diagnose` run may want the explicit "rate-limited,
  here's the cached value + age". Decide whether the limiter returns
  `Fresh(v) | Cached(v, age) | RateLimited{retry_after}` and let the caller pick.
- **Key granularity.** Per-probe-name (all `probe_github_username` callers share
  one bucket) vs per-(probe,caller). Per-probe-name matches the "don't DDoS the
  guest" goal — the guest cost is shared regardless of who called.
- **Interaction with the existing 5-min cloud cache.** Fold the cloud list's
  ad-hoc `CacheEntry`/`CACHE_TTL_SECS` (`remote_projects.rs:57-93`) into the same
  limiter so there is one mechanism, not two. Confirm the in-flight
  `cloud_refresh_in_flight` latch composes with (or is subsumed by) the
  singleflight sibling.
- **Breaker cooldown + reset.** How does the breaker close? Time-based cooldown
  vs a successful cheap `is_github_key_present`. Reuse `AutoResetPolicy`
  (`lib.rs:974`) semantics rather than inventing.
- **Dispatcher fast-reject safety.** Confirm rejecting at the handler
  (`vsock_server.rs:1000`) before `spawn_blocking` cannot desync the change-gated
  push (`set_login_state`, `vsock_server.rs:252`) — a rejected probe must leave
  the last pushed state intact, never push a false "logged out".
- **`retry_after` transport.** Decide whether `retry_after_ms` rides in
  `Error{message}` (no wire change beyond the variant) or a new field on a
  reply. Prefer the message to stay minimal/additive.

## Exit criteria

- **Litmus (falsifiable, the core deliverable): N rapid calls → ≤ K executions.**
  A test fires the login probe M times in a tight loop (M ≫ K) within one
  interval and asserts the underlying `run_git_image_shell` / `podman run`
  executes ≤ K times (K = 1 for pure min-interval), the rest returning
  cached-last-good or `RateLimited`. Prefer a Rust unit test injecting a spawn
  counter (mirroring the existing `Healer`/`Satisfier` trait seams) so no real
  container is needed, plus a `scripts/` litmus for the wire path.
- A test proving the **reverted incident is now safe**: simulate a 2 s cadence of
  `GithubLoginStatusRequest` for 60 s and assert container spawns ≤ (60 s /
  interval), not 30.
- `ErrorCode::RateLimited` round-trips through the control-wire postcard
  encode/decode tests with **no `WIRE_VERSION` bump**, and an old peer degrades
  it to `UnknownVariant` (test the old/new matrix).
- A decision record: limiter location (guest boundary ± dispatcher), parameters
  (interval/bucket/breaker), cache-last-good-vs-error policy per caller, key
  granularity, and how the cloud-list cache folds in.
- Slice A shipped and verified: `probe_github_username` cannot execute a container
  more than once per interval; `cargo test -p tillandsias-headless` green.

## Existing-code references

- `crates/tillandsias-headless/src/remote_projects.rs:384,415` — `probe_github_username` / `is_github_logged_in`: the un-limited Class B probe (primary target).
- `crates/tillandsias-headless/src/remote_projects.rs:295,355-358` — `run_git_image_shell`: the single choke where the container is spawned (limiter insertion point).
- `crates/tillandsias-headless/src/remote_projects.rs:25` — `GH_INVOCATION_TIMEOUT`: the only current bound (a timeout, not a rate limit).
- `crates/tillandsias-headless/src/remote_projects.rs:57-93,450-460` — `CacheEntry` / `CACHE_TTL_SECS` (5-min) / `discover_github_projects_inner`: the existing per-path cache to generalize into the limiter.
- `crates/tillandsias-headless/src/remote_projects.rs:22` — `cloud_refresh_in_flight` latch note (existing in-flight de-dup).
- `crates/tillandsias-headless/src/vault_bootstrap.rs:799` — `is_github_key_present`: cheap exec-into-running freshness check (no container) for the min-interval fast path.
- `crates/tillandsias-headless/src/vsock_server.rs:1000-1007` — `GithubLoginStatusRequest` handler (dispatcher fast-reject site).
- `crates/tillandsias-headless/src/vsock_server.rs:969,979-981` — `CloudRefreshRequest` handler (second Class B dispatcher site).
- `crates/tillandsias-headless/src/vsock_server.rs:252-275` — `set_login_state` change-gated push (must not be desynced by a fast-reject).
- `crates/tillandsias-headless/src/main.rs:11477,11502` — the guest periodic login re-check (a second Class B caller the guest-boundary limiter also covers).
- `crates/tillandsias-macos-tray/src/action_host.rs:708,2650-2661` — `poll_github_login_once` + its best-effort "leave last state on Err" policy the `RateLimited` reply folds into.
- `crates/tillandsias-macos-tray/src/action_host.rs:2618-2662` — the tick loop where the reverted 2 s fast-confirm lived.
- `crates/tillandsias-control-wire/src/lib.rs:406-417` — `ErrorCode` `#[non_exhaustive]` enum (add `RateLimited`).
- `crates/tillandsias-control-wire/src/lib.rs:400-402,409` — additive/forward-compat contract (`UnknownVariant` degradation on old peers).
- `crates/tillandsias-control-wire/src/lib.rs:420-433` — the `.kind()` name match that forces a stable name for a new variant.
- `crates/tillandsias-control-wire/src/lib.rs:713,974` — `CrashLoopDetector` / `AutoResetPolicy`: in-tree FSMs to model the circuit-breaker on.
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — motivating incident.
- `plan/issues/stable-state-codes-research-2026-07-05.md` — dotted status/reason vocabulary the `RateLimited` reason can reuse.

## Non-goals / scope

- NOT the classification of which calls are Class B — that is sibling i (`research-idiomatic-layer-call-taxonomy-2026-07-23.md`); this packet limits what it tags.
- NOT coalescing concurrent shared-element starts — that is sibling iii (`research-impl-singleflight-shared-element-starts-2026-07-23.md`). A limiter throttles repeated calls; a coalescer shares one concurrent start. Both are needed; they are different mechanisms.
- NOT removing the polls — the event channel does that (`research-flow-state-event-channel-2026-07-23.md`, d89fac3d). The limiter stays as the guardrail even after pushes land.
- NOT rate-limiting Class A cheap probes (VmStatus / local-projects) — they are frequent-OK; over-limiting them would hurt UX for no cost saving.
- NOT changing the Vault security boundary, the pre-receive relay, or the container network topology.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation).
