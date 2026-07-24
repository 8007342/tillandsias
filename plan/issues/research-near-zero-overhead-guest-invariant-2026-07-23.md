# RESEARCH: near-zero-overhead guest invariant + guardrail — assert the guest idles at near-zero CPU (WSL2 / Linux-native parity) and fail if the idiomatic layer busy-polls (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work;
  durable direction. The guardrail litmus itself is a candidate near-term slice —
  it is the machine-checkable trip-wire that would have caught the reverted 2 s
  login poll before it shipped.
- **Owner host**: any (the invariant spans the WSL2 guest on Windows, the VZ
  guest on macOS, and the Linux-native path; the guardrail litmus runs per host)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: CRITICAL invariant
  to PRESERVE — on Windows the WSL2 layer adds ~zero overhead; the only cost is
  RAM allocated to the guest, and the guest idles at NEAR-ZERO CPU, exactly like
  the Linux-native path. Our idiomatic layers must not break that by DDoSing
  ourselves just to poll a pretty tooltip.
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
- **Sibling packets in this anti-DDoS wave (non-overlapping, file together)**:
  - `plan/issues/research-idiomatic-layer-call-taxonomy-2026-07-23.md` (supplies the per-class frequency policy this guardrail enforces as a CPU/probe-rate budget)
  - `plan/issues/research-impl-rate-limiting-expensive-probes-2026-07-23.md` (the limiter whose effect this litmus measures — throttled probes ⇒ idle CPU)
  - `plan/issues/research-impl-singleflight-shared-element-starts-2026-07-23.md` (coalesced starts ⇒ no duplicate-start CPU spikes this litmus would flag)
- **Cross-references the flow-graph wave (commit d89fac3d)**: the event channel
  (`research-flow-state-event-channel-2026-07-23.md`) is the mechanism that lets
  us stop polling; THIS packet is the **measurement that proves we actually did**
  — an executable budget that fails if any layer reintroduces busy-polling or a
  steady-state probe rate above the ceiling, whether or not the push channel is
  wired for that signal yet.

## Motivation

The operator's invariant is a real, load-bearing architectural claim: the WSL2
guest (and the VZ guest, and Linux-native) must idle at **near-zero CPU** — the
cost of the guest is the RAM it holds, not CPU cycles. This is already stated as
policy across the codebase but **never asserted as an executable budget on the
guest under a running tray**:

- `openspec/specs/vm-idiomatic-layer/spec.md:140-162` — `wait_ready` "SHALL NOT
  busy-poll"; the timeout scenario even bounds it: "SHALL NOT have consumed >1%
  CPU during the wait" (invariant `vm-idiomatic-layer.invariant.wait-ready-no-busy-loop`).
- `openspec/specs/filesystem-scanner/spec.md:44-45,68` — a zero-CPU-idle
  requirement with a pass/fail scenario ("CPU spikes during idle" = fail).
- `plan/issues/socket-audit-master-2026-06-30.md:135` — an un-checked TODO: "Perf
  test: idle tray CPU < 0.1% over 5 minutes (no polling wakeups)."
- `methodology/event/005-hot-path-blocking-policy.yaml:10` — "near-zero idle
  overhead" as a hot-path policy; `methodology/convergence.yaml:265` warns
  polling "raises idle CPU, hides backpressure."
- `plan/issues/smoke-455-windows-v0.3.260722.1-2026-07-22.md:80` — a real
  measurement baseline (idle-healthy ~5% CPU, ~250 MB combined) — a starting
  number to tighten toward the budget.

The incident is the invariant's live violation: a 2 s tray poll drove a **guest
container spawn every tick** (`vsock_server.rs:1000-1007` → `probe_github_username`
→ `run_git_image_shell`, `remote_projects.rs:295,355-358`). That is not "the guest
idling at near-zero CPU"; it is the idiomatic layer DDoSing the guest to refresh a
tooltip — exactly what the operator forbade. Nothing failed, because no test
measures guest steady-state CPU or probe rate under a live tray. This packet
supplies that missing guardrail: the falsifiable ceiling that turns "we believe
the guest idles cheaply" into "a litmus fails if it doesn't."

## Proposed model

Define the near-zero-overhead invariant as a **measurable budget** with a
per-host litmus, expressed in two independent, cross-checking metrics so a
regression trips at least one even if CPU sampling is noisy:

### The budget (draft; tune from the smoke-455 baseline)

- **Steady-state guest CPU**: over a T-second idle window with a healthy tray +
  provisioned guest and no operator action, aggregate guest CPU (the headless
  process + its podman/conmon children) SHALL stay below a ceiling C (start from
  the spec's "<1% during wait" / socket-audit's "<0.1% over 5 min" and the
  measured ~5% baseline; pick a defensible steady-state number).
- **Steady-state probe rate**: over the same window, the count of Class B
  executions (container spawns via `run_git_image_shell`; `podman run`/exec for a
  probe) SHALL be ≤ R (near zero — with the sibling limiter + event channel,
  ideally 0 when nothing changes). This is the metric the incident would have
  blown instantly (30 spawns/min vs a budget of ~0).

The probe-rate metric is the sharper trip-wire: it is deterministic (count
container-create events) where CPU is statistical. CPU is the belt to the
probe-rate suspenders — a busy-loop that burns CPU without spawning containers
(a tight poll with no work) is caught by CPU; a container storm is caught by
rate.

### How to measure

- **Probe rate**: reuse the event-driven litmus helper's approach —
  `podman events` streaming already used by `scripts/litmus-helper-event-driven.sh`
  (create/start/die counting). Count container `create` events attributable to
  Class B probes over the idle window; assert ≤ R.
- **Guest CPU**: sample the headless + child cgroup/PID CPU over the window
  (`/proc` on Linux/WSL2 guest; the VZ guest exposes the same in-guest `/proc`).
  Assert the aggregate stays under C. On WSL2 specifically, the parity check is:
  the same litmus run on Linux-native and on the WSL2 guest yields comparable
  idle CPU (the operator's "exactly like the Linux-native path").
- **Harness**: fits the existing litmus framework —
  `scripts/run-litmus-test.sh` + `scripts/litmus-stdlib.sh`, the
  `crates/tillandsias-litmus` / `crates/tillandsias-litmus-rust` runners, and
  `openspec/litmus-tests`. Add a `phase runtime` litmus that provisions, idles,
  and measures.

### Parity assertion (the operator's specific claim)

A dedicated check that the WSL2 guest's idle overhead ≈ the Linux-native path's:
run the identical idle-window measurement on both and assert the delta is within
a small tolerance. This directly encodes "the WSL2 layer adds ~zero overhead; the
only cost is RAM."

This packet defines the **invariant, the budget metrics, and the litmus that
enforces them**. It does not build the limiter (sibling ii) or coalescer (sibling
iii) — it is the measurement that proves their effect and the trip-wire that
catches any future layer that busy-polls.

## Investigate / prototype

- **Pick C and R.** Derive from: the spec's "<1% during wait" and socket-audit's
  "<0.1% over 5 min", the measured ~5% smoke-455 baseline, and a fresh
  measurement of a genuinely-idle current guest. Decide a steady-state CPU ceiling
  and a probe-rate ceiling (target R = 0 Class B spawns in a no-change window).
- **Attributable-CPU boundary.** What counts as "the guest's idle overhead"? The
  headless process, its vsock server, the always-on shared containers
  (vault/proxy/router/git-mirror/inference) at idle, and conmon. Exclude a forge
  actively doing work. Define the PID/cgroup set precisely so the number is stable.
- **WSL2 vs VZ vs native measurement seams.** Confirm `/proc`-based sampling works
  identically in the WSL2 guest and the VZ guest. Note WSL2's own idle behavior
  (the vmmem/guest kernel) vs the tillandsias processes — measure the latter, not
  the WSL2 substrate the operator already accepts as RAM-only cost.
- **Window length + noise.** A 5-min window (socket-audit) vs shorter for CI. Trade
  off flakiness vs catch rate. The probe-rate metric tolerates a short window
  (a single stray spawn fails it); CPU needs longer to average out.
- **What the litmus drives.** It must exercise the real steady state: tray
  subscribed, push channel healthy, no operator action — the state where the
  reverted poll would silently spawn containers. Confirm it would go RED against a
  build with the 2 s login poll re-applied (the falsification test of the test).
- **Baseline drift tracking.** Should the measured idle CPU be recorded per
  release (like smoke-455 did) so a slow creep is visible before it crosses C?
  Consider emitting the numbers into the evidence bundle
  (`scripts/test-evidence-bundle-litmus-summary.sh`).
- **Relationship to the event channel.** With `FlowState` pushes (d89fac3d) the
  probe rate should approach 0 because state changes are emitted, not polled.
  Confirm the litmus rewards that (near-0 R) and would fail a regression that
  reverts to polling — making it the guardrail that protects the whole anti-poll
  direction.

## Exit criteria

- A **written invariant spec**: the near-zero-overhead guest invariant stated as
  a budget (CPU ceiling C over window T; Class B probe-rate ceiling R over the
  same window), with the chosen numbers and their derivation from the existing
  baselines, and the WSL2/Linux-native parity tolerance.
- A **falsifiable litmus** (in the existing framework) that: (a) provisions +
  idles the guest with a healthy tray, (b) measures guest CPU and Class B probe
  count over the window, (c) PASSES on a quiet build and (d) demonstrably FAILS
  when the reverted 2 s login poll (or any busy-poll) is present — the
  falsification-of-the-test being an explicit deliverable, not assumed.
- A **parity check** that the WSL2 guest idle overhead is within tolerance of the
  Linux-native path, encoding the operator's "exactly like the Linux-native path"
  claim as a test.
- A decision record: the ceilings C/R and window T; the attributable-PID/cgroup
  set; the measurement seam per host (WSL2 `/proc`, VZ `/proc`, native); and
  whether idle numbers are recorded per release for drift tracking.
- Confirmation the litmus slots into `scripts/run-litmus-test.sh --phase runtime`
  and the evidence-bundle summary, so it runs in the normal gate cadence.

## Existing-code references

- `openspec/specs/vm-idiomatic-layer/spec.md:140-162` — `wait_ready` "SHALL NOT busy-poll" + "SHALL NOT have consumed >1% CPU" + invariant `wait-ready-no-busy-loop`: the closest existing executable-ish statement to generalize.
- `openspec/specs/filesystem-scanner/spec.md:44-45,68` — zero-CPU-idle requirement + pass/fail scenario: precedent for a CPU-idle litmus.
- `plan/issues/socket-audit-master-2026-06-30.md:135` — the un-checked "idle tray CPU < 0.1% over 5 minutes (no polling wakeups)" TODO this packet operationalizes.
- `methodology/event/005-hot-path-blocking-policy.yaml:10` — "near-zero idle overhead" hot-path policy.
- `methodology/convergence.yaml:265` — polling "raises idle CPU, hides backpressure" (the rationale).
- `plan/issues/smoke-455-windows-v0.3.260722.1-2026-07-22.md:80` — measured idle baseline (~5% CPU, ~250 MB) to tune C from.
- `scripts/litmus-helper-event-driven.sh` — `podman events` create/start/die counting: the probe-rate measurement mechanism.
- `scripts/run-litmus-test.sh`, `scripts/litmus-stdlib.sh` — the litmus harness to add the runtime-phase budget litmus to.
- `crates/tillandsias-litmus`, `crates/tillandsias-litmus-rust`, `openspec/litmus-tests` — litmus runners/home.
- `scripts/test-evidence-bundle-litmus-summary.sh` — where per-release idle numbers could be recorded for drift.
- `crates/tillandsias-headless/src/remote_projects.rs:295,355-358` — `run_git_image_shell` `podman run`: the Class B container spawn the probe-rate metric counts.
- `crates/tillandsias-headless/src/vsock_server.rs:1000-1007` — the login handler whose per-tick container spawn violated the invariant.
- `crates/tillandsias-macos-tray/src/action_host.rs:2618-2662` — the tick loop where the reverted 2 s fast-confirm lived (the litmus must go red against this).
- `crates/tillandsias-macos-tray/src/action_host.rs:1922` — `should_poll_fallback`: the event-first suppression that keeps idle probe rate low (the behavior the litmus rewards).
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — motivating incident (the tray was 0% CPU while stuck, but the GUEST was spawning containers — the litmus measures the guest, not the tray).

## Non-goals / scope

- NOT building the limiter or coalescer — siblings ii/iii; this packet measures their effect and guards against regressions.
- NOT the call classification — sibling i supplies the per-class frequency policy this budget enforces.
- NOT removing polling — the event channel does that (`research-flow-state-event-channel-2026-07-23.md`, d89fac3d); this proves it stayed removed.
- NOT measuring the WSL2 substrate (vmmem / guest kernel) itself — the operator already accepts the guest's RAM as its cost; this measures the tillandsias processes' CPU overhead, which must stay near-zero.
- NOT a RAM budget — the invariant is explicitly "the only cost is RAM"; RAM is accepted, CPU is the guarded axis. (A separate RAM budget could be a future packet but is out of scope here.)
- NOT changing tray UX, the Vault boundary, or wire-version.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation).
