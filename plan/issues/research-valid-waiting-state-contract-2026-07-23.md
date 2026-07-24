# RESEARCH: the VALID WAITING STATE contract — every long init/launch/bootstrap/download/build op MUST surface a clear "waiting, this is expected" status, with a falsifiable guardrail (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable
  direction. The guardrail scan itself is a candidate near-term slice: it is the
  machine-checkable trip-wire that fails the moment a known-long operation can run
  with no waiting-state signal.
- **Owner host**: any (the contract spans the forge popup terminal on all hosts, the
  guest headless launch path, and all three trays)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased — preserve intent)**: if
  ANY harness — or the forge / VM / stack — does slow work at init or launch, we MUST
  show the user a clear message that this is a NORMAL, VALID WAITING STATE, not a hang
  or an unresponsive system. Standing principle, repeated all session: **users must
  NEVER be left wondering whether the system is hung, or whether "now we wait" is the
  correct and valid state.** Being at a valid waiting state should be very clear at all
  times — what it is doing, that it is expected, and ideally a rough duration.
- **Motivating incident**: Codex "always takes some time to start" with no "this is
  normal, please wait" indication → it reads as hung. Root mechanism confirmed below:
  the first-run harness install is a foreground `npm install` whose only status is a
  DEBUG-GATED lifecycle trace, so a normal user sees a frozen terminal.
- **Sibling packets (this waiting-state wave, non-overlapping, file together)**:
  - `plan/issues/research-harness-init-waiting-state-2026-07-23.md` (the harness-init
    lane: the per-harness inventory + the pre-banner "setting up …" surface — the
    concrete instance that closes the Codex-silent-start gap)
  - `plan/issues/research-forge-bringup-waiting-state-2026-07-23.md` (the forge-stack
    lane: image build / VM boot / git-mirror seed / inference warm-up — extending the
    condensed-status model to the whole bring-up)
- **Cross-references the flow-graph + anti-DDoS waves**:
  - `plan/issues/research-auth-flow-state-machines-2026-07-23.md` — a "waiting" is a
    first-class, NAMED FSM state (`prereqs_pending`, `awaiting_operator`), not a gap
    inferred after the fact. This contract makes "waiting" observable; that packet
    supplies the state vocabulary.
  - `plan/issues/research-flow-state-event-channel-2026-07-23.md` — the `FlowStatePush`
    transport that carries a `→ waiting{op, reason, est}` transition over the backbone
    we own, so the surface is EMITTED, not reconstructed.
  - `plan/issues/research-near-zero-overhead-guest-invariant-2026-07-23.md` — surfacing
    a wait MUST NOT mean busy-polling. A waiting-state signal is emitted on entry/exit
    of the wait; it is not a tight poll that DDoSes the guest to animate a spinner.
  - `plan/issues/stable-state-codes-research-2026-07-05.md` — the dotted `StateCode`
    vocabulary the waiting states reuse (e.g. `init.harness.installing`,
    `init.image.building`, `init.gitmirror.seeding`).

## Motivation

Codex starts slowly with no "this is normal, please wait" indication, so it reads as
hung. That is not a Codex-specific bug — it is one instance of a whole CLASS of long,
silent-ish operations at init/launch across the product:

- **Harness first-run installs.** `require_codex` → `_require_harness` runs a FOREGROUND
  `npm install -g @openai/codex@latest` whose stdout/stderr is redirected to a temp file
  (`images/default/lib-common.sh:1528`); the only breadcrumb is
  `trace_lifecycle "harness" "$name missing — install latest"` (`lib-common.sh:1526`),
  and `trace_lifecycle` returns immediately unless `TILLANDSIAS_DEBUG` is set
  (`lib-common.sh:198`). Net effect for a normal (non-debug) user: the forge popup
  terminal sits blank for the duration of a cold Node install through the enclave proxy,
  BEFORE the welcome banner is even printed (`entrypoint-forge-codex.sh:99` runs
  `require_codex`; `show_banner` is only at `:116`). This is exactly "is it hung?".
- **The forge stack bring-up.** Image builds ("building missing image …; this may take
  several minutes", `crates/tillandsias-headless/src/main.rs:1797-1799`), the VM boot,
  the git-mirror cold seed (a full-repo fetch through the proxy — minutes,
  `main.rs:3198-3200`), and the inference warm-up are all long operations.

Some of these ALREADY surface a wait signal; most do not. The failure is that there is
**no contract** saying they all must, and **no guardrail** that fails when one does not.
The single best piece of prior art proves the operator's principle is already recognized
in exactly one spot: `wait_for_git_mirror_ready` emits one non-debug line at attempt 5
specifically **"so an operator watching a first launch knows the wait is the mirror
seed, not a hang"** (`main.rs:3222-3228`). This packet generalizes that one-off instinct
into a system-wide, enforceable contract.

The deeper defect is the recurring whack-a-mole: each new silent long-op (a new harness,
a new download, a new build step) is discovered to "look hung" only when a user hits it
in the field, because nothing enumerates "these operations are long, therefore each MUST
declare a waiting-state signal."

## Proposed model

Define a single **VALID WAITING STATE contract** with two halves: a normative surface
requirement, and a falsifiable guardrail that enforces it against a registry of known
long operations.

### Half 1 — the contract (normative)

> Every operation at init / launch / bootstrap / download / build whose typical duration
> exceeds a threshold **T_visible** (draft: ~2 s, tunable) MUST, on entering the wait,
> surface a human-readable **valid-waiting-state signal** to the user on whatever surface
> that operation runs, carrying:
> 1. **What** it is doing (e.g. "Setting up the Codex toolchain", "Building the forge
>    image", "Seeding the git mirror").
> 2. **That it is expected** — explicit "this is normal" framing (a first-run/one-time
>    note where applicable), so the state reads as valid, not as a hang.
> 3. **A rough duration** where one can be estimated ("first launch, ~30–60 s";
>    "this can take several minutes"), even if coarse.
>
> The signal MUST be emitted on ENTRY to the wait (not after it finishes) and cleared /
> advanced on exit. It MUST NOT require `--debug`. It MUST be emitted (event/print on a
> state transition), NOT produced by a busy-poll (sibling near-zero-overhead packet).

"Waiting" is thereby a first-class, observable state (sibling auth-FSM / event-channel
packets), with a stable dotted code (`init.<op>.<phase>`, reusing
`stable-state-codes-research-2026-07-05.md`) so the same signal can render as a forge
terminal line, a tray chip, and a diagnostics entry from one source.

**Surfaces per operation class** (the contract is surface-agnostic; each op maps to the
right one):

| Operation class | Runs on | Waiting surface |
|---|---|---|
| Harness first-run / every-launch install | forge popup terminal (pre-banner) | a non-debug "Setting up <harness>… (first launch, this is normal; ~Ns)" line + optional tray "Preparing your forge…" chip |
| Image / base-image build | host launcher stdout + tray | existing eprintln + tray `🔨 Building… (several minutes)` (already emits — keep, standardize wording) |
| VM provision / boot | tray | existing condensed status (7 verbatim phases — the model) |
| git-mirror cold seed | host launcher stdout | existing attempt-5 notice — promote to emit-on-entry, not attempt-5 |
| inference warm-up | tray / on-demand | "Starting local inference…" only if/when the user invokes a local-LLM action |

### Half 2 — the falsifiable guardrail (the trip-wire)

A **known-long-operation registry** (a small declarative table — YAML or a Rust
`const` slice) enumerates every operation classified as long, each row carrying: an id,
the stable state-code, the surface it emits on, and the source location that performs the
wait. A **litmus/scan** then asserts, for every registry row, that a waiting-state
emitter exists on its wait path — and FAILS if a known-long operation can run to
completion with no non-debug waiting-state signal.

Two complementary check strengths (belt + suspenders):

- **Static scan (cheap, always-on).** For each registry row, assert the wait site emits
  a non-debug waiting signal reachable before the blocking call. Concretely: a
  `@waiting-state:<code>` annotation (grep-able, like the existing `@trace spec:` /
  `@trace gap:` convention) MUST appear on the same wait path, and MUST NOT be the only
  form debug-gated. The scan fails on a registry row whose wait site has no annotation,
  and on a wait site (matched by a pattern list: `npm install`, `curl_install_*`,
  `git clone`, `build_image`, long `sleep`/retry loops) that is NOT in the registry —
  catching a NEW silent long-op the moment it is added.
- **Runtime litmus (authoritative).** Under the existing litmus framework
  (`scripts/run-litmus-test.sh --phase runtime`), drive a real cold-start of a
  representative long op with `--debug` OFF and assert the user-visible surface carried a
  waiting signal within T_visible of the wait starting (e.g. a forge lane whose harness
  cache is empty must print the "setting up" line before the banner). The
  falsification-of-the-test is an explicit deliverable: the litmus must go RED against a
  build with the waiting line removed / re-gated behind `--debug`.

The registry is the single source of truth the FSM (sibling) emits from AND the guardrail
scans against — the same "one row" ergonomics as the dependency graph and event-channel
packets: adding a new long operation is one registry row, and forgetting the waiting
signal fails the scan.

## Investigate / prototype

- **Pick T_visible and the duration buckets.** ~2 s to first signal is a defensible
  ceiling (it aligns with the near-zero-overhead packet's wait discipline). Decide the
  rough-duration vocabulary: exact-estimate vs bucket ("seconds" / "up to a minute" /
  "several minutes") — coarse is fine; the operator asked for "ideally an est. duration",
  not precision.
- **Registry shape + location.** YAML under `openspec/` (spec-adjacent, reviewable) vs a
  Rust `const` slice in a shared crate (compile-time, testable). Note the precedent:
  `VmPhase` lives in `tillandsias-control-wire` so guest + host share one vocabulary
  (`control-wire/src/lib.rs:355`); the waiting-state codes likely belong there too.
- **Annotation convention.** Reuse the `@trace`/`@waiting-state:` grep-able marker style
  already used throughout the entrypoints (`@trace spec:`, `@trace gap:`,
  `@trace plan/issues/…`). Prototype the scan as a `scripts/check-waiting-states.sh`
  delegating to a `tillandsias-policy` subcommand (mirror `check-no-python-scripts.sh`
  → `target/debug/tillandsias-policy check-no-python-scripts`).
- **Non-debug surfacing without noise.** The forge lane mutes background output because
  npm stdout corrupts a live TUI mid-frame (`lib-common.sh:1356-1360`). The waiting line
  must therefore be a SINGLE deliberate pre-banner print (before any TUI claims the
  terminal), not un-muted subprocess spew. Prototype where the line lands relative to the
  foreground `require_*` call and the `show_banner` call.
- **Emit-not-poll proof.** With the `FlowStatePush` channel (sibling), a waiting state is
  one transition on entry and one on exit — zero steady-state cost. Confirm the surface
  can be driven that way and that the near-zero-overhead litmus stays green (no
  spinner-polling regression).
- **Threshold discovery.** Which operations actually exceed T_visible? Measure cold-start
  durations: first-run npm install, curl_install refresh, prebuilt-tools fetch, git
  cold seed, image build, VM boot. The registry should list only genuinely-long ops (a
  50 ms op needs no signal).
- **Interaction with graceful-failure.** The contract governs the WAIT; the existing
  classified-failure verdicts (`vm-provisioning-lifecycle.launch.graceful-failure`,
  `harness_missing_fatal`) govern the FAILURE. Define the handoff: waiting → (success →
  clear) OR (failure → classified verdict). A wait must always resolve to one or the
  other, never linger.

## Exit criteria

- A **written contract spec** (an OpenSpec `waiting-state-contract` or a requirement
  added to `host-shell-architecture` / `forge-welcome`): the normative rule (any op >
  T_visible surfaces a non-debug waiting signal with what / expected / rough-duration,
  emitted on entry, not busy-polled), with T_visible chosen and justified.
- A **known-long-operation registry** enumerating every current long init/launch op with:
  id, stable state-code, surface, and wait-site source location — reviewers can check the
  table against the source with no gaps. Seeded from the two sibling lane packets'
  inventories.
- A **falsifiable guardrail**: (a) a static scan that fails when a registry row's wait
  site has no non-debug waiting emitter, AND when a wait-site pattern (npm install /
  curl_install / git clone / build_image / long retry loop) exists outside the registry;
  (b) a runtime litmus that drives a real cold long-op with `--debug` off and asserts the
  waiting signal appeared within T_visible — with an explicit falsification test (RED when
  the signal is removed or re-gated behind `--debug`).
- A decision record: T_visible + duration buckets; registry location/shape; annotation
  convention; the emit-not-poll mechanism; and the waiting→success/failure handoff.
- Explicit statement of which waiting states are user-visible (drive a chip / terminal
  line) vs. diagnostics-only, consistent with `stable-state-codes-research-2026-07-05.md`.

## Existing-code references

- `images/default/lib-common.sh:198` — `trace_lifecycle` returns early unless
  `TILLANDSIAS_DEBUG` is set: the entire lifecycle-trace channel is DEBUG-ONLY, so it is
  NOT a valid user-facing waiting surface (the core gap).
- `images/default/lib-common.sh:1526,1528` — `_require_harness`: the debug-only "missing —
  install latest" trace, then the foreground `npm install … >"$errlog" 2>&1` (output to a
  temp file) — the silent Codex first-run wait.
- `images/default/lib-common.sh:1516` / `:1953` — bounded SILENT waits (sibling-updater up
  to 90 s; curl-refresh lock up to 900 s) with no user-visible signal.
- `images/default/entrypoint-forge-codex.sh:99` (`require_codex`, the wait) vs `:116`
  (`show_banner`, the READY signal that only prints AFTER the wait): the banner is a
  ready signal, not a waiting signal.
- `crates/tillandsias-headless/src/main.rs:3222-3228` — `wait_for_git_mirror_ready` emits
  ONE non-debug "…waiting for git mirror … to finish seeding … (bounded, Ns max)…" line
  "so an operator … knows the wait … is not a hang": the prior-art seed of this contract.
- `crates/tillandsias-headless/src/main.rs:1797-1799` — "building missing image …; this
  may take several minutes" (host-side image-build wait signal — already emits).
- `crates/tillandsias-headless/src/tray/mod.rs:2054-2063` — `🔨 building forge image …
  (this can take several minutes)…` + `TrayIconState::Building` (tray build wait — emits).
- `openspec/specs/vm-provisioning-lifecycle/spec.md:76-98` — the condensed-status
  requirement (7 verbatim phases): the canonical EMITS-a-wait model to generalize.
- `crates/tillandsias-control-wire/src/lib.rs:355` — `VmPhase`: shared typed vocabulary
  precedent (where a `WaitingState` code likely belongs).
- `crates/tillandsias-control-wire/src/lib.rs:1177-1206` — `slow_but_progressing_provision_never_trips`:
  a normal slow provision is EXPECTED, not a crash — the semantic backbone of "valid wait".
- `crates/tillandsias-macos-tray/src/action_host.rs:790,1695` — `CONNECTING_CHIP_TEXT`
  ("🔵 Connecting…"): an existing waiting chip this contract standardizes.
- `scripts/run-litmus-test.sh`, `scripts/litmus-stdlib.sh` (`mf_regex`, `mf_absent`,
  `mf_threshold`) — the litmus harness the runtime guardrail slots into.
- `scripts/check-no-python-scripts.sh` — the `check-*.sh → tillandsias-policy <subcmd>`
  guardrail pattern the static scan should mirror.
- `openspec/specs/runtime-diagnostics-stream/spec.md` — the stream is `--debug`-gated;
  confirms the lifecycle log is not a user-facing surface (motivates the non-debug rule).

## Non-goals / scope

- NOT the harness-init inventory or the pre-banner surface details — that is the sibling
  harness-init lane packet.
- NOT the forge-stack (image/VM/mirror/inference) inventory or the condensed-status
  extension — that is the sibling forge-bringup lane packet.
- NOT defining the FSM state vocabulary (sibling auth-FSM packet) or the transport
  (sibling event-channel packet); this contract consumes both.
- NOT a progress-bar / percentage UI — the operator's model is a single condensed status
  line, not a multi-step progress widget (`vm-provisioning-lifecycle.ux.condensed-status`).
- NOT re-touching the credential/Vault boundary, the graceful-FAILURE classifier, or
  wire-version — the contract observes the wait; failure verdicts and security posture are
  unchanged.
- NOT a v0.4 change — this is durable v0.5+ direction; do NOT modify code under this packet.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation; out of scope).
