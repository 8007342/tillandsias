# RESEARCH: forge-stack bring-up waiting-state — image build / VM boot / git-mirror cold seed / inference warm-up, extending the condensed-status model to the whole stack (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable
  direction. Two of the four surfaces here already emit; the value is standardizing them
  under one contract and closing the two silent gaps (clone backstop, inference warm-up).
- **Owner host**: any (image build + VM boot are host-launcher/tray surfaces on Windows
  and macOS; the git-mirror seed and inference warm-up straddle host launcher + guest)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased — preserve intent)**: if the
  forge / VM / stack does slow work at init/launch, we MUST show the user that this is a
  NORMAL, VALID WAITING STATE — what it is doing, that it is expected, and roughly how
  long. The forge image build ("this may take several minutes"), the VM boot, and the
  git-mirror clone-readiness wait are all long, silent-ish operations; users must never
  wonder if the stack is hung.
- **Motivating incident**: same session — the stack bring-up is the other long-wait
  cluster alongside the harness inits. Some pieces already speak (VM condensed status,
  image-build notice); the classification below shows which still run silently.
- **Parent contract**: `plan/issues/research-valid-waiting-state-contract-2026-07-23.md`
  (this lane supplies the forge-stack half of that contract's known-long-operation
  registry).
- **Sibling lane**: `plan/issues/research-harness-init-waiting-state-2026-07-23.md`
  (the per-harness init long ops inside the forge).
- **Builds directly on**: `openspec/specs/vm-provisioning-lifecycle/spec.md` (the
  condensed-status contract — the canonical waiting surface to generalize) and
  `plan/issues/macos-tray-status-ux-parity-2026-07-23.md` (this session's Connecting-chip
  + labeled-phase work — the seed this lane widens to the whole stack).
- **Cross-references**: `plan/issues/research-flow-state-event-channel-2026-07-23.md`
  (VmPhase-style transitions already ride the wire; stack-waiting states extend that);
  `plan/issues/research-near-zero-overhead-guest-invariant-2026-07-23.md` (the phase
  emitters already avoid busy-polling — keep it that way).

## Motivation

The forge stack must exist before any agent runs, and standing it up is genuinely slow on
first launch: a Fedora rootfs download, a VM boot, a podman enclave, one or more image
builds, a git-mirror cold seed (a full-repo fetch through the proxy — the comment bounds
it as "minutes, not seconds", `crates/tillandsias-headless/src/main.rs:3198-3200`), and an
optional inference container. This is precisely the operator's "the forge image builds
(this may take several minutes), the VM boot, the git-mirror clone-readiness wait" list.

The good news: this lane already has the product's BEST waiting surface —
`vm-provisioning-lifecycle`'s condensed status, a single status line rolling through seven
verbatim phases (`spec.md:76-98`), plus this session's macOS parity work that added the
`Connecting…` chip and labeled the previously-silent boot→ready tail
(`macos-tray-status-ux-parity-2026-07-23.md`). The image build also emits: a host-side
"building missing image …; this may take several minutes" line (`main.rs:1797-1799`) and a
tray `🔨 Building… (several minutes)` chip (`tray/mod.rs:2054-2063`, `:2409`). And the
git-mirror seed emits ONE non-debug notice at attempt 5, explicitly worded "so an operator
… knows the wait … is not a hang" (`main.rs:3222-3228`).

The gaps: (a) the git-mirror notice only fires at attempt 5 (≈10 s in) rather than on
entry, and the FORGE-SIDE clone backstop (`clone_project_from_mirror`,
`lib-common.sh:595-652`) is fully silent (traces debug-gated), fail-loud only on
exhaustion; (b) the inference warm-up is a silent async probe; (c) the several emitting
surfaces use ad-hoc, non-uniform wording rather than one standardized valid-waiting-state
vocabulary. This lane inventories the stack, keeps what emits, and closes the silent
pieces — all under the parent contract's one registry + guardrail.

## Proposed model

Treat the whole stack bring-up as a sequence of **valid waiting states** under the parent
contract, generalizing the `vm-provisioning-lifecycle` condensed-status model beyond the
VM phases to every long stack step. Each step: a stable dotted code, a single
human-readable line/chip emitted ON ENTRY (not after / not at attempt 5), with what /
expected / rough duration, driven by the existing phase-emit paths (no new polling).

### Per-step inventory (classification: SILENT vs EMITS)

| Step | Where | Surface today | Class |
|---|---|---|---|
| Fedora rootfs download | `vm-provisioning-lifecycle` provision | `🔵 Downloading Fedora rootfs…` + byte/% counter | **EMITS** |
| Tillandsias binary download | provision | `🔵 Downloading Tillandsias…` | **EMITS** |
| Rootfs install / import | provision | `🔵 Installing Tillandsias…` | **EMITS** |
| VM boot | provision → tray | `🔵 Starting Fedora Linux…` (parity fix) | **EMITS** |
| vsock handshake | provision → tray | `🔵 Connecting…` (`action_host.rs:790,1695`) | **EMITS** |
| base/forge image build (on-demand) | `main.rs:1797-1799`; `tray/mod.rs:2054-2063,2409` | host eprintln "several minutes" + `🔨 Building…` chip | **EMITS (ad-hoc wording)** |
| git-mirror cold seed (launcher gate) | `main.rs:3210-3235` | ONE non-debug notice at ATTEMPT 5 only; est. only as "Ns max" | **PARTIAL (late, no on-entry)** |
| git-mirror clone (forge-side backstop) | `lib-common.sh:595-652` | debug-only traces; fail-loud on exhaustion only | **SILENT** |
| inference container warm-up | opencode entrypoint `:94-100`; `async-inference-launch` spec | debug-only probe trace; user sees a provider error only if they invoke local LLM | **SILENT (deferred)** |
| enclave services (vault/proxy/router) start | launch ensure path | `WIRE_UNREACHABLE`/health chips post-hoc | **PARTIAL** |

### Standardization + gap-closing

- **Keep the emitters, unify the vocabulary.** Fold the image-build line and the VM
  phases into one `init.stack.*` code set (reuse `stable-state-codes-research-2026-07-05.md`),
  so all stack waits render with the same "what / expected / duration" shape. This is
  wording/registry work, not new UX plumbing.
- **git-mirror seed: emit on entry, not attempt 5.** Move the "waiting for git mirror to
  finish seeding (bounded, Ns max)" notice to fire on ENTRY to the wait (the operator's
  "on entry" requirement), keep the bound, and give the forge-side backstop
  (`clone_project_from_mirror`) a matching non-debug line for the "empty tree, mirror
  still seeding, retrying" case (`lib-common.sh:611-612`) instead of a debug-only trace.
- **inference warm-up: it is legitimately deferred.** The async-inference-launch design
  says inference starts off the critical path and a provider error surfaces only if the
  user invokes local inference. That is a defensible "no wait shown because nothing is
  blocking the user" — but if a local-LLM action IS invoked before warm-up completes, THAT
  is a wait and MUST surface "Starting local inference…". Decide the trigger.
- **Emit-not-poll preserved.** VmPhase transitions already ride change-gated pushes, not
  polls (`control-wire`/`vsock_server` push loops); the stack-waiting codes extend that
  same emit path. The near-zero-overhead litmus (sibling) must stay green.

## Investigate / prototype

- **On-entry vs first-observation.** For the git-mirror seed and image build, confirm the
  waiting line is emitted at the START of the blocking call, not after a delay/attempt
  count. `wait_for_git_mirror_ready` deliberately delayed to attempt 5 to avoid noise on
  fast warm launches — reconcile "emit on entry" with "don't shout on a 200 ms warm
  path": likely gate on a cold-vs-warm predicate (mirror not yet seeded) rather than a
  time delay.
- **Wording unification.** Map the current ad-hoc strings (image build "several minutes",
  VM's seven verbatim phases, the mirror notice) to one `init.stack.*` vocabulary without
  regressing the spec's verbatim-phase invariant (`vm-provisioning-lifecycle.invariant.status-rolls-text-not-items`).
  Decide whether the image build becomes an eighth condensed-status phase on non-Linux
  hosts (it currently prints on the host launcher, separate from the tray phase roll).
- **Forge-side clone backstop surface.** `clone_project_from_mirror` runs inside the forge
  popup terminal (a different surface from the tray). Give it a non-debug "seeding, this
  is normal, retrying (i/N)" line for the empty-tree/not-ready retries
  (`lib-common.sh:611-612,646-647`), matching the harness-init lane's pre-banner style.
- **Inference trigger.** Prototype detecting "user invoked a local-LLM action while
  inference is still warming" and surfacing "Starting local inference… (first use)"; leave
  the silent async warm-up as-is when no one is waiting on it.
- **Enclave-services start.** vault/proxy/router/git bring-up currently surfaces mostly as
  post-hoc health/`WIRE_UNREACHABLE` chips. Decide whether the first cold start of these
  warrants an "Starting workspace services…" waiting state or whether it is fast enough to
  stay under T_visible.
- **Cross-host surface seams.** The VM phases render on the tray; the image build prints on
  the host launcher stdout AND a tray chip; the mirror seed prints on the host launcher;
  the forge clone prints in the popup terminal. Enumerate which surface each stack-waiting
  state lands on per host so the registry rows are unambiguous.

## Exit criteria

- A **complete, verified per-step inventory** (the table above, checked against source with
  file:line) classifying every stack bring-up step as EMITS / PARTIAL / SILENT and naming
  its surface — the forge-stack rows of the parent contract's known-long-operation registry.
- A **standardization plan**: the ad-hoc emitting strings mapped onto one `init.stack.*`
  code vocabulary, WITHOUT regressing the `vm-provisioning-lifecycle` verbatim-phase and
  single-status-item invariants.
- A **gap-closing design** for the two silent/partial steps: git-mirror seed emitted on
  entry (cold-gated, bound preserved) with a matching forge-side backstop line; and the
  inference "Starting local inference…" surface triggered only when a user action actually
  waits on warm-up.
- A **falsification test** slotting into the parent guardrail: the runtime litmus goes RED
  if the git-mirror on-entry notice or the forge-side seeding line is removed / re-gated
  behind `--debug`, driven against a cold mirror seed.
- A decision record: whether image build becomes a condensed-status phase on non-Linux
  hosts; the cold-vs-warm gate for on-entry emission; the enclave-services threshold; and
  the inference trigger.

## Existing-code references

- `openspec/specs/vm-provisioning-lifecycle/spec.md:76-98` — condensed-status requirement
  (seven verbatim phases): the canonical waiting-state model this lane generalizes.
- `openspec/specs/vm-provisioning-lifecycle/spec.md:285-293` — the single-status-item /
  rolls-text-not-items invariants the standardization must not regress.
- `plan/issues/macos-tray-status-ux-parity-2026-07-23.md` — this session's Connecting-chip
  + labeled boot→ready tail (the seed widened here to the whole stack).
- `crates/tillandsias-headless/src/main.rs:1797-1799` — "building missing image …; this
  may take several minutes" (host-side image-build wait — EMITS, ad-hoc wording).
- `crates/tillandsias-headless/src/tray/mod.rs:2054-2063` — `🔨 building forge image …
  (this can take several minutes)…` + `TrayIconState::Building`; `:2409` — `⏳ Building
  images …` chip.
- `crates/tillandsias-headless/src/main.rs:3198-3235` — `wait_for_git_mirror_ready`: bound
  rationale ("minutes, not seconds", `:3198-3200`); the ATTEMPT-5-only non-debug notice
  `:3222-3228` ("…knows the wait … is not a hang") — PARTIAL, to promote to on-entry.
- `images/default/lib-common.sh:585-652` — `clone_project_from_mirror` forge-side backstop:
  12-retry loop, backoff 2–5 s (`:593-596`); empty-tree/not-ready retries traced
  DEBUG-only (`:611-612,646-647`); fail-loud only on exhaustion (`:616,653`) — SILENT.
- `images/default/entrypoint-forge-opencode.sh:94-100` — inference probe: debug-only
  trace; provider error deferred to user action (SILENT warm-up).
- `openspec/specs/async-inference-launch/spec.md` — the off-critical-path inference design
  (why warm-up is legitimately deferred until a user waits on it).
- `crates/tillandsias-macos-tray/src/action_host.rs:783,790,1695` —
  `WIRE_UNREACHABLE_CHIP_TEXT` / `CONNECTING_CHIP_TEXT`: existing stack-state chips.
- `crates/tillandsias-control-wire/src/lib.rs:355` — `VmPhase`: the shared phase
  vocabulary the `init.stack.*` codes extend; `:1177-1206` — slow-but-progressing provision
  is EXPECTED, not a crash (the "valid wait" semantics).
- `scripts/install.sh:249` — "Running tillandsias --init (sets up local runtime — may take
  a minute)…": an existing host-side stack-setup wait notice (EMITS).

## Non-goals / scope

- NOT the universal contract or the guardrail mechanism — parent packet; this lane supplies
  its forge-stack rows.
- NOT the harness-init long ops inside the forge — sibling lane packet.
- NOT changing the VM provisioning download/verify/import logic, the shutdown-drain
  contract, or the image-build mechanics — only the waiting-state surface/wording around
  them.
- NOT regressing the `vm-provisioning-lifecycle` verbatim-phase / single-status-item
  invariants; standardization must preserve them.
- NOT forcing inference to warm up synchronously — it stays off the critical path; the only
  change is surfacing a wait IF a user action blocks on it.
- NOT a v0.4 change; durable v0.5+ direction. Do NOT modify code under this packet.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation; out of scope).
