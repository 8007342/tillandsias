# RESEARCH: idiomatic-layer call taxonomy & cost model — classify every call by cost class + coalescibility (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable direction. One near-term slice (a machine-checkable classification manifest + the litmus) is cheap and could land earlier as the guardrail that catches the next self-DDoS.
- **Owner host**: any (spans the macOS/Windows trays' host-side pollers + the shared `tillandsias-headless` guest probe/ensure surface consumed on all hosts)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: "We don't like
  polling, EVER." The idiomatic layer has many expensive "probes" we must RATE
  LIMIT — and it needs intense overhauling; it's starting to bite us. Just like
  the dependency+state graph, CATEGORIZE our idiomatic-layer calls: some must
  NOT be called frequently; some are sporadic-if-ever (`podman prune`, other
  I/O-intensive calls, calls depending on long-running orchestration). HOWEVER,
  concurrent calls to STARTING a shared element should just receive the SAME
  shared element (coalescing / singleflight — no duplicate starts). CRITICAL
  invariant to PRESERVE: on Windows the WSL2 layer adds ~zero overhead — the
  guest idles at near-zero CPU, exactly like the Linux-native path; our
  idiomatic layers must not break that by DDoSing ourselves to poll a tooltip.
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
- **Sibling packets in this anti-DDoS wave (non-overlapping, file together)**:
  - `plan/issues/research-impl-rate-limiting-expensive-probes-2026-07-23.md` (the limiter + typed rate-limited error this taxonomy's Class B feeds)
  - `plan/issues/research-impl-singleflight-shared-element-starts-2026-07-23.md` (the coalescing this taxonomy's Class C feeds)
  - `plan/issues/research-near-zero-overhead-guest-invariant-2026-07-23.md` (the CPU/probe-rate guardrail that enforces the taxonomy's frequency policy)
- **Cross-references the flow-graph wave (commit d89fac3d)**: the event channel
  (`research-flow-state-event-channel-2026-07-23.md`) REPLACES polling by
  emitting transitions; this taxonomy + its siblings are the **guardrail layer
  around it** — the classification says which calls a consumer is even allowed
  to make on a timer, and the limiter/coalescer enforce it until (and after) the
  push channel removes the reason to poll at all.

## Motivation

The macOS login self-DDoS is the taxonomy's charter. A tray "fast confirm" polled
`poll_github_login_once` every ~2 s while the login chip was up
(`crates/tillandsias-macos-tray/src/action_host.rs`, the reverted fast cadence
around the tick loop, `action_host.rs:2618-2662`). That control-wire request looks
cheap — one vsock round-trip. But its **guest-side handler** runs
`probe_github_username` (`crates/tillandsias-headless/src/vsock_server.rs:1000-1007`),
which calls `run_git_image_shell` (`crates/tillandsias-headless/src/remote_projects.rs:295`)
and **spawns a fresh `podman run --rm` container every single tick**
(`remote_projects.rs:355-358`) — cold container create + AppRole lease mint +
proxy self-heal + Vault read + `gh api user`. A 2 s tooltip refresh became a 2 s
container storm inside the guest: literally self-DDoS, and on WSL2 it turns the
"near-zero idle CPU" guest into a busy one.

The root defect the taxonomy targets: **there is no cost model.** The wire probe
being cheap masked the guest handler being expensive; nothing in the codebase
declares that `GithubLoginStatusRequest` is Class-B-behind-no-cache while
`VmStatusRequest` is Class-A-in-memory. So a well-meaning tray change wired a
2 s cadence onto a per-call container spawn and nothing failed a test. The
existing mitigations are real but **piecemeal and undocumented as a system**: a
5-min TTL cache exists on the cloud list but NOT on the login probe
(`remote_projects.rs:77,450-460` vs. the un-cached `probe_github_username`); a
`resource_lock` flock coalesces the proxy ensure but there is no uniform rule
that every "ensure shared X" must; `is_github_key_present` is a cheap
exec-into-running alternative to the container-spawning probe but its own doc is
the only thing that says "use this for high-frequency loops"
(`crates/tillandsias-headless/src/vault_bootstrap.rs:799`, and the pointer at
`remote_projects.rs:411-412`). A machine-checkable taxonomy turns "someone
should have known this poll was expensive" into "the litmus fails because a
sub-min-interval caller reaches a Class B guest handler with no limiter."

## Proposed model

A four-class cost taxonomy over the idiomatic-layer call surface, with each call
tagged by **cost class** and **coalescibility**, plus a per-class policy. The
classification is a checked-in manifest (data), not prose, so a litmus can
enforce it against the source.

### Cost classes

| Class | Definition | Examples (file:line) | Policy |
|---|---|---|---|
| **A — cheap wire/in-guest probe** | one control-wire RTT whose guest handler does only in-memory or cheap-fs work; no container / network egress / Vault | `poll_vm_status_once`→`VmStatusRequest`→in-memory `VmPhase` (`action_host.rs:399`; `vsock_server.rs:908`); `poll_local_projects_once`→`EnumerateLocalProjects`→`~/src` walk (`action_host.rs:557`; `vsock_server.rs:949`) | Frequent-OK at the steady 30 s cadence; still **event-first** — poll suppressed while the push subscription is healthy (`should_poll_fallback`, `action_host.rs:1922`) |
| **B — expensive guest probe** | reaches `run_git_image_shell` → **spawns a container** (+ AppRole lease + proxy self-heal + Vault read + GitHub egress) | `probe_github_username`/`is_github_logged_in` (`remote_projects.rs:384,415`) — **no cache**; `fetch_github_projects`/`discover_github_projects_inner` (`remote_projects.rs:419,450`) — cached 5 min + in-flight latch | **Rate-limit** (sibling: min-interval / token-bucket / cache-last-good; typed rate-limited error). A Class-A *wire* probe that triggers a Class-B *guest* handler (`poll_github_login_once`→`probe_github_username`; `poll_cloud_projects_once`→`fetch_cloud_projects`) is classified by its **true end-to-end** cost = B |
| **C — shared-element ensure/start** | idempotent "bring X up"; concurrent callers must share ONE in-flight start, never duplicate | `ensure_proxy_running` (`main.rs:2441`), `ensure_enclave_network` (`main.rs:1908`), `ensure_egress_network` (`main.rs:2075`), `ensure_router_running` (`main.rs:3605`), `ensure_git_image_available` (`remote_projects.rs:109`), Vault ensure (`vault_bootstrap.rs`), `RemoteVaultLease::acquire`→`mint_approle_secret_lease` (`remote_projects.rs:186`; `vault_bootstrap.rs:1285`) | **Coalesce / singleflight** (sibling: loser waits and receives the winner's result). Existing substrate: `resource_lock` Exclusive/Shared flock (`resource_lock.rs`) |
| **D — rare / destructive** | I/O-intensive or irreversible; sporadic-if-ever; never on a timer | `podman system reset --force` (`main.rs:1849,1863`, one-shot self-heal behind a `Healer` seam); `--replace` recreates of **shared** containers (`main.rs:2399,2832,3284,3452,10945`); `podman image prune` (`crates/tillandsias-podman-cli/src/lib.rs:49`); mirror-volume reset | **Strong-gate**: drain gate (`container_mutations_allowed()`, `main.rs:2444`) + refcount (`foreign_launches_in_flight`, `main.rs:4423`) + ensure-if-absent-and-healthy, NOT `--replace` on a live sibling (`concurrent-forges-unsafe-shared-stack-bounce-and-teardown-race-2026-07-20.md`) |

### The one insight the taxonomy encodes

**Classify by the guest-side work a call triggers, not by the wire cost.** The
incident is exactly a Class A wire probe (`poll_github_login_once`, one RTT)
whose guest handler is Class B (a container spawn). The manifest records the
**resolved** class so a fast cadence onto that call is a litmus failure.

This packet defines the **taxonomy, the manifest schema, and the enforcing
litmus**. It does NOT build the limiter (sibling ii) or the coalescer (sibling
iii) or the CPU guardrail (sibling iv); it is the classification those consume.

## Investigate / prototype

- **Enumerate the full call surface.** From the operator's named entry points,
  walk transitively: host pollers (`action_host.rs` `poll_vm_status_once` /
  `poll_cloud_projects_once` / `poll_github_login_once` / `poll_local_projects_once`);
  guest handlers (`vsock_server.rs` `VmStatusRequest` / `EnumerateLocalProjects`
  / `CloudRefreshRequest` / `GithubLoginStatusRequest`); guest probes
  (`remote_projects.rs` `run_git_image_shell` / `probe_github_username` /
  `fetch_github_projects`); ensures (`main.rs` `ensure_*`); container ops
  (`podman run`/exec/prune/reset). Produce one row per call.
- **Resolve each wire probe to its guest cost.** For every host poller, follow
  the request to its `vsock_server.rs` handler and record the heaviest thing the
  handler does (in-memory / fs-walk / container-spawn / Vault). This is the
  column that reclassifies `poll_github_login_once` from A to B.
- **Manifest schema.** Decide the checked-in form: a Rust `const` table in a new
  `idiomatic_cost` module (compile-time, tests can import it) vs. a data file
  (`plan/` or `openspec/`) parsed by a shell litmus. Prefer the Rust table so
  the Class C entries can share the `Service`/node vocabulary already used by
  `container_deps.rs` (sibling ii of the flow-graph wave).
- **Coalescibility flag.** For each Class C call, record whether a limiter/lock
  already exists and which (`resource_lock::acquire("proxy", …)`,
  `vault_stability_lease`, the launch-in-flight flock). Gaps become the
  singleflight packet's worklist.
- **Existing-limiter inventory.** Tag each Class B call with its current
  mitigation: `fetch_github_projects` = 5-min cache + `cloud_refresh_in_flight`
  latch; `probe_github_username` = **none** (the gap the incident hit);
  `run_git_image_shell` = `GH_INVOCATION_TIMEOUT` bound only (`remote_projects.rs:25`).
- **Where does a caller's cadence live?** Catalog every timer/cadence that
  drives a Class B call: the tick loop (`action_host.rs:2599-2670`), the
  reverted 2 s fast-confirm, the guest periodic login re-check
  (`main.rs:11477,11502`). Each is a candidate litmus subject.
- **False-negative hunt.** Are there Class B calls reached from a UI event with
  no debounce (menu-open → cloud refresh)? An event-driven trigger is not
  automatically safe if the event can fire in a tight loop.

## Exit criteria

- A **checked-in classification manifest** (Rust `const` table or data file):
  one row per idiomatic-layer call with `{name, cost_class ∈ {A,B,C,D},
  coalescible: bool, existing_limiter: Option<…>, guest_cost}`. Reviewers can
  diff it against the source with no gaps.
- A **falsifiable litmus** that fails on an un- or mis-categorized hot call.
  Concretely, at least: (a) any host-side poller whose cadence is below the
  Class B min-interval AND whose resolved guest cost is B while `existing_limiter
  == None` is a FAIL — this reproduces the reverted 2 s login poll as a red test;
  (b) every call reaching `run_git_image_shell` in the source appears in the
  manifest as Class B (a new un-listed container-spawning probe fails the test);
  (c) every `ensure_*`/shared-start reaching a `podman run` for a shared
  container appears as Class C with a coalescer or is flagged. Prefer a
  `scripts/`-runnable litmus + a Rust unit test over prose.
- A decision record: manifest location/format; the A-vs-B reclassification rule
  ("resolved guest cost wins"); the Class B min-interval default; how the
  manifest stays in sync (a test that greps the source for `run_git_image_shell`
  / `podman_cmd_sync().args(["run"…])` call sites and asserts each is classified).
- Explicit statement of which classes are **operator-tunable** (Class B
  intervals, Class D gates) vs. structural (Class A cadence follows the existing
  push-first contract).

## Existing-code references

- `crates/tillandsias-macos-tray/src/action_host.rs:399,557,645,708` — the four host pollers (`poll_vm_status_once` / `poll_local_projects_once` / `poll_cloud_projects_once` / `poll_github_login_once`).
- `crates/tillandsias-macos-tray/src/action_host.rs:2599-2670` — the tick loop cadence (first tick + every 10 ticks; the reverted 2 s fast-confirm lived here).
- `crates/tillandsias-macos-tray/src/action_host.rs:1922` — `should_poll_fallback`: poll suppressed while push healthy (SC-07) — the event-first rule Class A already honors.
- `crates/tillandsias-headless/src/vsock_server.rs:908,949,969,1000` — guest handlers for `VmStatusRequest` (in-memory) / `EnumerateLocalProjects` (fs walk) / `CloudRefreshRequest` (container) / `GithubLoginStatusRequest` (container).
- `crates/tillandsias-headless/src/vsock_server.rs:1000-1007` — the login handler that spawns a container per request via `probe_github_username` (the self-DDoS site).
- `crates/tillandsias-headless/src/remote_projects.rs:295` — `run_git_image_shell`: the Class B base (`podman run --rm` + lease + proxy + Vault).
- `crates/tillandsias-headless/src/remote_projects.rs:384,415` — `probe_github_username` / `is_github_logged_in`: Class B, **no cache**.
- `crates/tillandsias-headless/src/remote_projects.rs:77,450-460` — 5-min TTL cache (`CACHE_TTL_SECS`) on the cloud list — the cache the login probe lacks.
- `crates/tillandsias-headless/src/remote_projects.rs:22` — the host-side `cloud_refresh_in_flight` latch note (in-flight de-dup already exists for one path).
- `crates/tillandsias-headless/src/remote_projects.rs:25,31` — `GH_INVOCATION_TIMEOUT` (25 s) / `CLONE_INVOCATION_TIMEOUT` (600 s): existing bounds.
- `crates/tillandsias-headless/src/vault_bootstrap.rs:799` — `is_github_key_present`: cheap exec-into-running Vault check, the documented alternative to the container-spawning probe.
- `crates/tillandsias-headless/src/main.rs:2441,1908,2075,3605` — `ensure_proxy_running` / `ensure_enclave_network` / `ensure_egress_network` / `ensure_router_running`: Class C shared starts.
- `crates/tillandsias-headless/src/main.rs:2444` — `container_mutations_allowed()` drain gate (Class D/C refuse-before-wait).
- `crates/tillandsias-headless/src/main.rs:4385-4530` — `acquire_launch_in_flight_marker` / `foreign_launches_in_flight` / `cleanup_shared_stack_if_no_running_forge`: the derived-live shared-stack refcount (Class C/D concurrency model).
- `crates/tillandsias-headless/src/main.rs:1849,1863` — `podman system reset --force` one-shot self-heal (Class D) behind the `Healer` seam.
- `crates/tillandsias-headless/src/main.rs:2399,2832,3284,3452,10945` — `--replace` recreate sites for shared containers (Class D hazard per the concurrent-forges packet).
- `crates/tillandsias-headless/src/resource_lock.rs` — flock Exclusive/Shared, bounded wait, loser-waits: the coalescing substrate for Class C.
- `crates/tillandsias-headless/src/vsock_server.rs:51,1121` — `VAULT_BOOTSTRAP_DONE` `compare_exchange(false,true)` once-gate: an existing singleflight-once idiom to generalize.
- `crates/tillandsias-podman-cli/src/lib.rs:49` — `image prune` compatibility lane (Class D archetype the operator named).
- `openspec/specs/vm-idiomatic-layer/spec.md` — the idiomatic-layer contract this taxonomy annotates with cost.
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — motivating incident (the reverted 2 s container-per-tick poll).

## Non-goals / scope

- NOT building the limiter — that is sibling ii (`research-impl-rate-limiting-expensive-probes-2026-07-23.md`); this packet only tags calls Class B.
- NOT building the coalescer — that is sibling iii (`research-impl-singleflight-shared-element-starts-2026-07-23.md`); this packet only tags calls Class C.
- NOT the CPU/probe-rate guardrail litmus — that is sibling iv (`research-near-zero-overhead-guest-invariant-2026-07-23.md`); this packet feeds it the per-class frequency policy.
- NOT removing polling — that is the event channel (`research-flow-state-event-channel-2026-07-23.md`, commit d89fac3d); this is the guardrail that makes any residual polling safe.
- NOT changing the Vault security boundary, the pre-receive relay, or wire-version.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation; out of scope).
- NOT a v0.4 behavior change — the incident's point-fixes already shipped; durable v0.5+ direction (the manifest+litmus slice may land near-term as a pure guardrail).
