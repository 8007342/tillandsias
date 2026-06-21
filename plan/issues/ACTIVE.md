# Active Plan Frontier

Last updated: 2026-06-21T00:10Z

## This Cycle (2026-06-21T00:04Z, linux_mutable — Claude Opus 4.8 Cowork meta-orch)

- **Startup**: `linux-next`, fast-forwarded `90e43066..1973d414` to `origin/linux-next`. Found one untracked file at startup — `scripts/check-credential-channel.sh` — classified as a *ready-but-uncommitted deliverable* (the implementation of Order 61), not disposable artifact; adopted it rather than discarding.
- **Credential Channel Guard**: passed via `.git/.gh-credentials` non-empty (`ok:gh-credentials-store`).
- **Worker drain (Order 61, `credential-channel-check`)**: Made the script executable, verified all three branches live (cred-store present → `ok:gh-credentials-store`/exit 0; scrubbed env → `missing:no-credential-channel`/exit 1; seeded `GH_TOKEN` → `ok:gh-token-env`/exit 0). Wired the meta-orchestration Credential Channel Guard to invoke `scripts/check-credential-channel.sh` instead of re-deriving the check in prose. Outcome satisfied script-only, mirroring Order-60 `e2e-preflight.sh`.
- **Verification**: Added `litmus:credential-channel-check-shape` (`openspec/litmus-tests/litmus-credential-channel-check-shape.yaml`), registered under the `meta-orchestration` spec in `litmus-bindings.yaml`. All 5 critical-path steps pass. YAML validated with `ruby -ryaml`.
- **Capture**: Filed `plan/issues/optimization-credential-channel-policy-parity-2026-06-21.md` — deferred optional `tillandsias-policy credential-channel` Rust parity (not a correctness gap; low ROI until other guards co-migrate).
- **Coordinator**: `origin/windows-next@a3c8b23d` and `origin/osx-next@d829808d` both ancestors of `linux-next` HEAD — no sibling merge. No release (loop-tooling + ledger delta only, no runtime change). E2E local-build gate: `linux_mutable` but Cowork sandbox has no `/run/user/<uid>` → `skip:no-podman-user-session` (per Order-60 probe), so no e2e this cycle.
- **Next**: Order 70 (Containerfile.base pip timeout — unblocks immutable curl-install e2e), Order 64/65 (release nix-cache + build monitoring, build/CI-capable host).

## This Cycle (2026-06-20T20:34Z, linux_immutable — Claude Sonnet 4.6 curl-install e2e)

- **Host**: linux_immutable (Fedora 44 Workstation), `linux-next @ a08eb971`, no eligible worker packets.
- **Curl-install e2e**: Tested release `v0.3.260620.8` (published 20:09Z today).
  - Install: **PASS** — `v0.3.260620.8` downloaded (17 MB/s), SHA256 verified.
  - Substrate reset: **PASS** — `podman system reset --force` clean.
  - `--init`: **FAIL** — `forge-base` pip3 install of `pyright==1.1.410` (6.1 MB) timed out (0 bytes received) in `podman build` network context on both first attempt and retry. Root cause: pasta build-network TCP stream issue vs runtime network. Core images (proxy, git, inference, router, chromium, web) built successfully. No containers started.
  - Forge opencode run: **SKIPPED** (forge not built).
- **New findings** (orders 70–71):
  - Order 70 `smoke-finding/forge-base-pip-build-network-timeout`: pip3 large-payload download fails in `podman build` but not `podman run` — pasta MTU/network difference. Quick fix: `PIP_DEFAULT_TIMEOUT=120` in Containerfile.base.
  - Order 71 `smoke-finding/init-all-or-nothing-forge-blocks-core`: init exits 1 and starts zero containers when any image fails, even forge-independent ones. Fix: make forge/forge-base/nanoclawv2 optional in init dependency graph.
- **Next**: Order 70 (quick fix: Containerfile.base pip timeout) should unblock curl-install e2e on immutable Linux. Assign to linux_mutable host with forge build capability.

## This Cycle (2026-06-20T20:12Z, linux_mutable — Claude Opus 4.8 Cowork meta-orch)

- **Startup**: Clean worktree on `linux-next`, fast-forwarded `d3974cdf..cfc475db` to `origin/linux-next`. Credential Channel Guard passed (`.git/.gh-credentials` non-empty + `credential.helper=store` over HTTPS; `gh auth status` keyring-empty, which the guard correctly tolerates).
- **Worker drain**: Claimed and completed `e2e-eligibility-probe/implement` (Order 60). Added `e2e_eligibility_verdict()` + an `eligibility` standalone mode to `scripts/e2e-preflight.sh` emitting one line `^(eligible|skip:[a-z0-9-]+)$` (reasons: `no-podman-binary`, `no-podman-user-session`, `podman-not-functional`); recorded once per run to `LOG_DIR/00-e2e-eligibility.txt`. Wired the skill's E2E Gates to consult it. The recurring prose re-derivation of the podman-session skip is retired.
- **Verification**: Bound `litmus:e2e-eligibility-probe-shape` and registered the `meta-orchestration` spec in `openspec/litmus-bindings.yaml`. `run-litmus-test.sh meta-orchestration --phase pre-build --size instant` → **4/4 OK, PASS**. Live sandbox verdict `skip:no-podman-user-session` (no `/run/user/1000`); `podman-not-functional` + well-formed-grammar branches also exercised live. YAML validated with `ruby -ryaml`.
- **Coordinator**: `origin/windows-next@a3c8b23d` and `origin/osx-next@d829808d` both ancestors of `linux-next` HEAD — no sibling merge, no release (loop-tooling + ledger delta only, no runtime change).
- **Next**: Order 61 `credential-channel-check` (executable guard, needs Rust path), Order 64 `release-nix-cache-ref-scoping` + Order 65 `release-build-monitoring` (build/CI-capable host).

## This Cycle (2026-06-20T20:00Z, linux_mutable — Gemini-Antigravity worker)

- **Meta-orchestration sync**: Started clean on `linux-next`. Fast-forwarded to `origin/linux-next@9411b549`. Dogfooded startup credential check (which passed successfully via `gh auth status` keyring).
- **Worker drain**: Claimed and completed `cowork-nonpython-ledger-validation/decide-and-document` (Order 63). Documented the approved fallback YAML validator `ruby -ryaml -e "YAML.load_file('<file>')"` in the Finalization section of `skills/meta-orchestration/SKILL.md` for environments where `tillandsias-policy` is not pre-built, eliminating the discouraged Python fallback. Updated `plan/index.yaml` and `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` to reflect task closure.
- **Verification**: Validated `plan/index.yaml` with both `tillandsias-policy validate-yaml` and the fallback Ruby one-liner.
- **Next**: (1) Fix release Nix store cache ref-scoping (Order 64) and implement release build monitoring (Order 65).

## This Cycle (2026-06-20T19:56Z, linux_mutable — interactive Claude Code CLI, release + cache diagnosis)


- **Release**: Cut v0.3.260620.8 — merged PR #37 (linux-next→main, 26 commits),
  bumped VERSION on main (`31b01c32`), tagged, triggered workflow_dispatch run
  27881936382 (in progress; ~45 min build).
- **Root-caused the slow release (operator-flagged silent issue)**: every release
  rebuilds the full Nix closure + re-uploads a 2.2 GB store cache (~10 min) because
  the GHA cache is **ref-scoped** and releases dispatch on fresh tags — the Nix
  store cache is saved once per tag ref with an identical key and never on `main`,
  so no release can ever restore another's cache. Repo cache also over the 10 GB
  limit (LRU eviction). The workflow uses `cache-nix-action`, **not** Magic Nix
  Cache as assumed. Web-verified correct fix: FlakeHub Cache (binary cache, not
  ref-scoped) or warm the cache on the `main` default branch.
- **Filed two ordered packets**: order 64 `release-nix-cache-ref-scoping` (the fix,
  with options + verification) and order 65 `release-build-monitoring` (perf gate
  so the next silent slowdown fails loud). Both `ready`.
- **Next**: pick fix approach (FlakeHub vs warm-on-main) on a build/CI-capable
  host; surface v0.3.260620.8 artifact when the build completes.

## This Cycle (2026-06-20T19:40Z, linux_mutable — Cowork meta-orch, Tlatoāni-directed)

- **Governance decision (Tlatoāni)**: The reduction engine's scan bar is fixed
  and the convergence point is "zero residual findings at the current approved
  bar." Raising the bar is **not** autonomous — the loop may only *propose*
  bar-raise candidates (research/exploration issues); enabling any bar-raise is a
  one-off scope expansion The Tlatoāni must approve every time. Recorded as the
  authoritative `bar_raise_governance` section in `methodology/convergence.yaml`;
  rewrote the skill's "Raising the bar" subsection to match (propose-not-escalate,
  stop at the current bar). Future automatable approvals possible but not yet
  policy; absence of policy is not implicit approval.
- This resolves the open design question from the prior cycle (an ever-rising bar
  has no fixed point) by making each bar-raise an operator-owned discontinuity.

## This Cycle (2026-06-20T19:24Z, linux_mutable — interactive Claude Code CLI meta-orch)

- **Startup**: Pulled `origin/linux-next` (23 commits, `8f8887b2..66e1029f`),
  worktree clean, in sync. Credential Channel Guard passed (`gh auth status`
  green, repo+workflow scopes).
- **Worker drain — file-feedback**: Submitted the Anthropic feedback packet
  `cowork-headless-credential-isolation` to the canonical Claude Code feedback
  channel as **https://github.com/anthropics/claude-code/issues/69776** (state
  OPEN, author 8007342), payload verbatim with the tillandsias reference link and
  reporter reference included. The `/bug` in-CLI path is interactive-only (not a
  callable tool); the GitHub issue is the verifiable channel named in the task.
  Node `cowork-headless-credential-isolation` is now **fully resolved** —
  `file-feedback` + `runtime-guard` both completed.
- **Coordinator check**: `origin/windows-next@a3c8b23d` and
  `origin/osx-next@d829808d` both ancestors of `linux-next` HEAD — no sibling
  merge, no release (no code delta this cycle; docs/ledger only).
- **E2E gates**: Skipped — no runtime/code delta; this cycle only filed feedback
  and updated the ledger.
- **Next**: (1) aarch64 macOS VM pasta/published-port probe for Vault
  reachability. (2) Local-build e2e on a host with a podman user session.

## This Cycle (2026-06-20T19:15Z, linux — Cowork meta-orch)

- **Startup recovery**: Entered with a dirty worktree (unpushed `9c8f3f9a` + a
  staged concurrency note). A concurrent sibling agent had already committed
  `b5484c59` and pushed; fetch synced HEAD clean to `origin/linux-next@b5484c59`,
  not ahead. No data loss.
- **Worker drain**: Drained the `runtime-guard` subtask of node
  `cowork-headless-credential-isolation` (order 59). Added a **Credential Channel
  Guard** to `skills/meta-orchestration/SKILL.md`: after `git fetch` and before
  any committable work, require one of `.git/.gh-credentials`,
  `GH_TOKEN`/`GITHUB_TOKEN`, or a reachable keyring; otherwise file a
  `no-credential-channel` blocker and exit loud. Closes the silent-push-failure
  velocity-killer that stranded 17 commits earlier today. Dogfooded — guard
  passed this cycle. Node stays `ready`: `file-feedback` is a write-to-Anthropic
  action reserved for a Claude CLI `/bug` worker, not taken by this loop.
- **Coordinator check**: `origin/windows-next` and `origin/osx-next` both
  ancestors of `linux-next` HEAD — no sibling merge, no release (no code delta).
- **E2E gates**: Skipped — no podman user session in Cowork sandbox (no
  `/run/user`). No runtime delta since v0.3.260620.7.
- **Reduction engine**: Encoded the capture → reduce → promote lifecycle in
  `skills/meta-orchestration/SKILL.md` (new **Reduction Engine** section + a
  Finalization capture-check + a rising-bar scan policy), per the user's
  "Monotonic Reduction of Uncertainty Under Verifiable Constraints" framing.
  Filed `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` with four
  observed opportunities and reduced each to a `ready` packet:
  order 60 `e2e-eligibility-probe` (opt), 61 `credential-channel-check` (enh —
  makes the 19:15Z prose guard verifiable), 62 `ledger-edit-claim-lease` (opt),
  63 `cowork-nonpython-ledger-validation` (research). None implemented here:
  1/2/4 need a build-capable host; shaping them into verifiable packets is the
  reduction step for this sandbox. YAML validated with `ruby` (non-Python,
  dogfooding order 63).
- **Next**: (1) `file-feedback` submission via a Claude CLI `/bug`-capable worker.
  (2) aarch64 macOS VM pasta/published-port probe for Vault reachability (critical
  cross-host blocker, needs VM access). (3) Local-build e2e on a host with a
  podman user session.

## This Cycle (2026-06-20T19:05Z, linux — Cowork meta-orch)

- **Meta-orchestration sync**: Startup on mutable Linux (Cowork) on `linux-next`.
  `git fetch origin --prune` over HTTPS succeeded; the stale "ahead 18" tracking
  resolved to in-sync with `origin/linux-next@4f5fd488` (the earlier SSH/HTTPS
  push blocker is cleared — prior cycles' commits are on origin). Worktree clean.
- **Coordinator check**: `origin/windows-next@a3c8b23d` and `origin/osx-next@d829808d`
  are both ancestors of `linux-next` HEAD — no sibling merge needed.
- **Worker drain**: No runnable plan work for this host. `plan.yaml` future_intentions
  is `[]`. The only non-terminal index nodes were a stale ledger artifact:
  step-58 `future-intentions-drain` showed `in_progress` with its item-7 (Win/macOS
  parity) drain subtask `ready`, despite the step-58 file being closed `done`
  (2026-06-20T11:04Z) and the item recorded under `drained_items`. Closed both to
  match source of truth; the parity IMPLEMENTATION stays tracked under
  `macos-in-vm-enclave-provisioning` + blocker `enclave/macos-vault-unreachable-via-publish-aarch64`.
- **Ledger bug fixed**: `tillandsias-policy validate-yaml` flagged a duplicate `note:`
  key in step-65's github-login-egress completed event (YAML last-wins was silently
  dropping the fix note). Moved the misplaced discovery note onto the `discovered`
  event; validator now returns `ok: plan/index.yaml`.
- **E2E gates**: Skipped — podman user session unavailable in Cowork sandbox
  (no `/run/user`). No runtime/release delta since v0.3.260620.7.
- **Next**: (1) aarch64 macOS VM pasta/published-port probe for Vault reachability
  (critical cross-host blocker, needs VM access). (2) Local-build e2e on a host
  with a podman user session.

## This Cycle (2026-06-20T18:35Z, linux — Cowork meta-orch)

- **Meta-orchestration sync**: Startup on mutable Linux (Cowork). Branch `linux-next`,
  16 commits ahead of `origin/linux-next`. Git fetch FAILED — SSH still unavailable.
  Concurrent agent merged `origin/linux-next@8f8887b2` (commit 4beb811a) and switched
  remote to HTTPS; push still blocked (HTTPS auth requires credentials not present in sandbox).
- **Worker drain**: No ready plan nodes. All steps completed/done/deferred.
  Sibling branches (local cache): windows=a3c8b23d, osx=d829808d, both ancestors of
  linux-next HEAD.
- **Verification**: Litmus 107/107 PASS.
- **E2E gates**: Skipped — podman user session unavailable in Cowork sandbox (no /run/user).
  No runtime delta since v0.3.260620.7 (the 17:55Z cycle completed full local-build E2E).
- **Push state**: BLOCKED — HTTPS auth credentials absent; SSH also unavailable.
  linux-next 16 commits ahead of origin. Operator must: `git push origin linux-next`
  (remote is now HTTPS; SSH key or HTTPS token required).
- **Next**: (1) Operator push. (2) Local-build e2e (nanoclawv2 live container launch).
  (3) aarch64 VM pasta probe for vault port-forwarding.

## This Cycle (2026-06-20T17:45Z, linux — Cowork merge)

- **Fix**: Switched git remote from SSH to HTTPS (`https://github.com/8007342/tillandsias.git`). SSH was unavailable in the Cowork sandbox; HTTPS auth works via host credential store. All prior cycles today were blocked by this; unblocked now.
- **Merge**: Merged `origin/linux-next@8f8887b2` into local `linux-next` (was 15 ahead / 28 behind). Resolved conflicts in `plan/index.yaml`, `plan/issues/ACTIVE.md`, `plan/issues/nanoclawv2-orchestration.md`, `plan/loop_status.md`, `plan/metrics-dashboard.md` — all resolved by taking `origin/linux-next` (authoritative; stale SSH-blocked cycle records in HEAD were superseded).
- **Worker drain**: None — upstream already fully drained by the 17:55Z cycle (E2E all green, forge improvements complete, v0.3.260620.7).
- **Next**: Push merge commit to origin/linux-next.


## This Cycle (2026-06-20T17:55Z, linux)

- **Meta-orchestration sync**: Started clean on mutable-Linux `linux-next`, fetched origin, fast-forwarded to `origin/linux-next@267ddcf5`, then pushed plan claim commit `68b9ed99`.
- **Worker drain**: Completed the remaining `agent-concurrency-collisions-2026-06-20` slice. Linux build/install and init E2E steps now run through a process-cleanup wrapper that terminates only newly leaked host-side `tillandsias` launcher PIDs and fails a successful smoke command that leaked a process.
- **Stale-binary guardrail**: Gate 1 now verifies `command -v tillandsias` resolves to `$HOME/.local/bin/tillandsias` and `tillandsias --version` matches the post-build `VERSION` file after the local autoincremental build-number bump.
- **In-cycle E2E hardening**: Fixed fake-Podman image-build telemetry extraction, preserved successful litmus runner exits by cleaning only descendants, and forced non-interactive E2E/diagnostics smoke paths to run headless with `TILLANDSIAS_NO_TRAY=1`.
- **Verification**: shell syntax checks, no-leak wrapper smoke, deliberate leaked fake `tillandsias` termination with expected exit 70, fake-Podman image-build convergence litmus, `scripts/run-litmus-test.sh init-incremental-builds --size instant`, `git diff --check`, and `./build.sh --check` passed.
- **E2E gates**: Final local-build E2E passed all gates at `target/build-install-smoke-e2e/20260620T173320Z`: build/install, destructive Podman reset, pristine init, and prompted in-forge `/forge-continuous-enhancement` all exited 0 on `Tillandsias v0.3.260620.7`.
- **Ledger hygiene**: `local-smoke/onboarding-cold-start-discovery-cheatsheet-signal`, `local-smoke/image-build-convergence-fake-progress-telemetry`, and `local-smoke/noninteractive-smoke-tray-leak` are now reflected as done in the 2026-06-20 smoke findings; the macOS aarch64 Vault published-port blocker remains the primary immediate item.

## This Cycle (2026-06-20T13:56Z, linux)

- **Meta-orchestration sync**: Started clean on mutable-Linux `linux-next`, fetched origin, fast-forwarded to `origin/linux-next`, pushed claim commit `824cbc67`, then pushed implementation commit `bb4196df`.
- **Worker drain**: Completed the first `agent-concurrency-collisions-2026-06-20` slice by adding a shared smoke lock and routing Linux build-install E2E gate scripts through it.
- **Coordination**: Post-push audit found `origin/windows-next@a3c8b23d` and `origin/osx-next@d829808d` are both ancestors of `origin/linux-next@bb4196df`; sibling-ahead drift is 0.
- **E2E gates**: Ran local-build E2E under the new lock. Gate 1 failed before destructive reset because post-build `litmus:onboarding-cold-start-discovery` could not find the welcome banner `INDEX.md` cheatsheet signal (`build_install_exit=1`; log dir `target/build-install-smoke-e2e/20260620T134849Z`).
- **New finding**: Filed `local-smoke/onboarding-cold-start-discovery-cheatsheet-signal` in `plan/issues/build-install-smoke-e2e-findings-2026-06-20.md`.
- **Next**: Restore the welcome banner cheatsheet `INDEX.md` signal, rerun local-build E2E from gate 1, then continue the remaining concurrency cleanup/stale-binary/autoincremental guardrail work. macOS vault aarch64 remains the critical cross-host blocker.

## This Cycle (2026-06-20T09:00Z, linux)

- **Meta-orchestration sync**: Started clean on mutable-Linux `linux-next`, fetched origin, confirmed local branch was aligned with `origin/linux-next`.
- **E2E gates**: Ran local-build E2E via `/build-install-and-smoke-test-e2e`. The build/install and destructive reset gates succeeded, but the init gate failed with `No match for argument: wasmtime`.
- **New finding**: Filed `local-smoke/wasmtime-dnf-migration-failure` in `plan/issues/build-install-smoke-e2e-findings-2026-06-20.md` to track the failure.
- **Coordination**: Sibling heads are ancestors of `linux-next`.
- **Next**: Revert wasmtime migration to DNF or fix package availability, resolve macOS vault aarch64 blocker.

## This Cycle (2026-06-20T07:49Z, linux)

- **Meta-orchestration sync**: Started clean on mutable-Linux `linux-next`,
  fetched origin, confirmed local branch was aligned with `origin/linux-next`,
  pushed claim commit `22e5987a`, then pushed implementation commit `8fe56fb9`.
- **Worker drain**: Completed `policy/no-python-litmus-drift`. Added
  `tillandsias-policy` helpers for JSON string extraction, menu parity
  assertions, disabled-with-v2 menu assertions, and Vault unsealed timestamp
  parsing; extended `check-no-python-scripts` to scan litmus YAML; replaced the
  remaining active litmus Python snippets with Rust-backed helpers or
  POSIX shell/openssl equivalents.
- **Verification**: `cargo test -p tillandsias-policy`,
  `tillandsias-policy validate-yaml` on all five touched litmus files,
  `tillandsias-policy check-no-python-scripts`,
  `scripts/check-no-python-scripts.sh`, helper smoke checks,
  `cargo fmt --all -- --check`, `git diff --check`, active litmus Python scan
  with no matches, and `./build.sh --check` all passed. The non-fatal
  `Failed to start dev proxy container` warning remains the known unrelated
  local dev-cache warning.
- **Coordination**: post-push mutable-Linux audit confirmed
  `origin/windows-next` and `origin/osx-next` are both ancestors of
  `origin/linux-next@8fe56fb9`; sibling-ahead drift is 0 for both branches
  (linux is 21 commits ahead of Windows and 20 ahead of macOS). No sibling
  merge, runtime-litmus marker, release action, or destructive e2e gate was
  required.
- **Release/e2e freshness**: latest published GitHub release remains
  `v0.3.260618.2` at `6dfafdf1`, published 2026-06-18T18:07:14Z, with existing
  curl-install smoke evidence current. This slice was policy/litmus-only, so no
  shipped runtime or release artifact delta warranted local-build or
  curl-install e2e.
- **Next**: macOS vault aarch64 layer-5 remains the critical cross-host blocker;
  NanoClawV2 remains actively leased until 2026-06-20T09:56Z.

## This Cycle (2026-06-20T07:38Z, linux)

- **Meta-orchestration sync**: Started clean on mutable-Linux `linux-next`,
  fetched origin, fast-forwarded to `origin/linux-next`, and pushed claim commit
  `4c15fc72` before implementation.
- **Worker drain**: Claimed and completed a narrow
  `forge-diagnostics/e2e-piggyback-orchestration` no-Python litmus drift slice.
  Added `tillandsias-policy validate-forge-diagnostics-json`, replaced the
  diagnostics E2E litmus's inline `python3 -c` validator, and fixed its stdout
  log selector so `.stderr.log` companions are not validated as JSON.
- **Verification**: `cargo test -p tillandsias-policy`,
  `tillandsias-policy validate-yaml` on the edited litmus,
  `tillandsias-policy validate-forge-diagnostics-json` on
  `target/forge-diagnostics/diagnostics_20260619T234257Z.log`,
  `scripts/check-no-python-scripts.sh`, `cargo fmt --all -- --check`,
  `git diff --check`, and `./build.sh --check` all passed.
- **Coordination**: post-push audit confirms `origin/windows-next` and
  `origin/osx-next` are both ancestors of `origin/linux-next@30e014dc`; no
  sibling merge or runtime-litmus marker is active. Latest published release is
  still `v0.3.260618.2` (2026-06-18T18:07:14Z), with existing curl-install
  smoke evidence current.
- **New finding**: filed `policy/no-python-litmus-drift` in
  `plan/issues/no-python-litmus-drift-2026-06-20.md` for remaining Python use in
  other litmus YAML command fields.
- **Next**: macOS vault aarch64 layer-5 remains the critical cross-host blocker;
  NanoClawV2 remains actively leased until 2026-06-20T09:56Z.

## This Cycle (2026-06-20T07:20Z, linux)

- **Meta-orchestration sync**: Fetched origin, in sync with linux-next.
- **Worker drain**: Claimed and completed `policy/no-python-runtime-scripts` final slice. Ported the final two Python-backed scripts (`fetch-cheatsheet-source.sh` and `regenerate-cheatsheet-index.sh`) to Rust subcommands and reduced shell scripts to thin wrappers. `scripts/check-no-python-scripts.sh` passes successfully with exit code 0.
- **Verification**: `cargo test` and `build.sh --check` all passed successfully.
- **Next**: macOS vault aarch64 layer-5 (blocked on VM access), or nanoclawv2-orchestration slice 3 (host orchestration surface).

## This Cycle (2026-06-20T06:00Z, linux)

- **Meta-orchestration sync**: Began clean on `linux-next` at `f871f8b2`, fetched
  origin (clean, no new commits), confirmed worktree clean.
- **Worker drain**: Claimed `nanoclawv2-orchestration` (reclaimable, lease expired
  2026-06-20T01:34Z). Slice 2: registered nanoclawv2 in Rust image builder
  (`image_specs`, `image_build_inputs` with forge-base dependency, `run_init`
  image array). Updated init image order and image_specs path tests. All tests
  pass, clippy clean. Committed `58996d8f`.
- **Sibling audit**: `origin/windows-next` and `origin/osx-next` heads checked —
  both remain ancestors of `linux-next`; zero drift.
- **E2E gates**: Skipped — implementation change is Rust-only, no runtime crate
  delta (nanoclawv2 was already buildable via build-image.sh; --init inclusion is
  additive). Latest release remains `v0.3.260618.2`.
- **Next**: macOS vault aarch64 layer-5 (blocked on VM access), or nanoclawv2-orchestration slice 3 (host orchestration surface).

## This Cycle (2026-06-20T04:51Z, macos)

- **Meta-orchestration sync**: Fast-forwarded `osx-next` to current
  `origin/linux-next` (`a3c8b23d`) — includes the latest linux+windows work
  (drain commits, cold-provision headless fix, Windows SAC e2e evidence).
- **Startup hygiene finding**: Untracked user artifacts remain unmodified —
  `build-osx-tray.sh`, `plan/issues/macos-windows-tray-ux-parity-audit-2026-06-13.md`,
  `research/`, `src-tauri/`. Left untouched per policy.
- **Worker drain**: No eligible autonomous macOS work. `enclave/macos-vault-unreachable-via-publish-aarch64`
  still `ready` (owner=linux); `macos-tray/github-login-route-to-orchestrated-flow`
  remains claimed+blocked on vault fix; step 49d user-attended.
- **E2E gates**: Skipped — no macOS runtime delta since prior cycle.
- **Next**: Re-check after the Linux vault fix lands; user work unchanged.


This file is the first stop for agents inspecting `plan/issues/`. Historical
issue reports remain in this directory for evidence and auditability, but only
the items below are immediate work.

## Immediate

### local-smoke/onboarding-cold-start-discovery-cheatsheet-signal

- status: done
- owner_host: linux
- source: `plan/issues/build-install-smoke-e2e-findings-2026-06-20.md`
- severity: high - blocks the local-build E2E gate before destructive reset.
- discovered_by: `/build-install-and-smoke-test-e2e` on tested commit `bb4196df90e60953dbf9c510b20d19d25d115b2f` / installed version `0.3.260620.3`.
- problem: >
    The post-build smoke set fails `litmus:onboarding-cold-start-discovery`
    step 3. `images/default/forge-welcome.sh` still includes `Cheatsheets`
    and `TILLANDSIAS_CHEATSHEETS`, but no longer includes the required
    `INDEX.md` discovery signal.
- evidence:
  - `target/build-install-smoke-e2e/20260620T134849Z/01-build-install-exit.txt`: `build_install_exit=1`
  - `target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2215`: `Executing litmus:onboarding-cold-start-discovery`
  - `target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2218`: `verify welcome banner surfaces cheatsheet path [FAIL]`
  - `target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2219`: `expected=cheatsheet discovery signal present`
  - `target/build-install-smoke-e2e/20260620T134849Z/00-smoke-lock.log`: lock acquired at `2026-06-20T13:49:31Z`, released at `2026-06-20T13:56:24Z` with `exit=1`.
- next_action: >
    None. The smoke findings ledger records a 2026-06-20T16:53Z completion
    event restoring the welcome banner `Cheatsheets`/`TILLANDSIAS_CHEATSHEETS`/
    `INDEX.md` signal and reporting all local-build E2E gates passing.
- blocker: none

### enclave/macos-vault-unreachable-via-publish-aarch64

- status: ready (items 1–2 confirmed in code; remaining: aarch64 VM testing)
- priority: CRITICAL — blocks the macOS m8 release-acceptance gate (step 49d /
  F4 GitHub Login) and, downstream, all macOS project/attach features (F5).
- owner_host: linux (enclave recipe + headless vault bootstrap; aarch64 in-VM)
- source: `plan/issues/macos-github-login-deep-dive-2026-06-18.md` (layer 5)
- discovered_by: macOS operator-attended m8 deep-dive 2026-06-18 (in-guest, by
  SSH into the aarch64 Fedora VM and running `tillandsias-headless
  --github-login --debug` directly).
- problem: >
    The orchestrated in-VM `--github-login` builds + launches `tillandsias-vault`
    successfully, and Vault is healthy INSIDE the container (logs: "vault is
    unsealed", "fully configured … approle+kv2+audit enabled"). But the
    host-side health probe to the published `127.0.0.1:8201` (-> container 8200)
    TIMES OUT, so `--github-login` aborts with "vault did not become healthy
    within 60s". From the VM host: plain TCP to `:8201` is OPEN, but
    `curl -k https://127.0.0.1:8201/v1/sys/health` times out (8s) and
    `openssl s_client -connect 127.0.0.1:8201` gets no response — i.e. the port
    publish accepts the SYN but no bytes reach Vault's API backend. Classic
    podman publish-vs-backend mismatch on aarch64.
- confirmed findings (2026-06-20T05:51Z):
    - Item (1) is already correct: `images/vault/vault.hcl:17` binds
      `address = "0.0.0.0:8200"` — confirmed by code inspection.
    - Item (2) is already correct: `vault_bootstrap.rs:322-328` reads CA from
      `certs_dir.join("intermediate.crt")` which resolves to
      `/tmp/tillandsias-ca/intermediate.crt` via `ensure_ca_bundle`.
    - The root cause is NOT listener binding or CA path. It is an aarch64
      podman port-publish/netns forwarding issue where SYN is accepted but
      no bytes reach Vault's API backend.
- next_action: >
    (3) Investigate the aarch64 podman port-publish forwarding issue in the
    aarch64 Fedora VM. Check: podman version, rootlessport on aarch64,
    `podman inspect tillandsias-vault` for network settings, and whether
    `curl --cacert /tmp/tillandsias-ca/intermediate.crt
    https://127.0.0.1:8201/v1/sys/health?standbyok=true` returns 200.
    Ships to the VM via a release (in-VM headless is fetched from
    releases/latest).
- evidence_required:
  - aarch64 VM host: vault health endpoint returns 200 through the published port
  - `tillandsias-headless --github-login` advances past the Vault-healthy gate
- blocks: `macos-tray/github-login-route-to-orchestrated-flow`, macOS m8 (F4/F5)
- note_to_linux_worker: >
    Distinct from `github-login/enclave-egress-regression` + `bug/github-login-failure`
    (those are the Linux-host egress-network fix, already addressed). THIS is the
    macOS/aarch64 IN-VM Vault-reachability layer surfaced only by the in-guest
    deep-dive. Please prioritize: it is the sole remaining macOS m8 blocker.

### macos-tray/github-login-route-to-orchestrated-flow

- status: blocked (depends on enclave/macos-vault-unreachable-via-publish-aarch64)
- owner_host: macos (+ shared host-shell; mirror Windows per parity)
- source: `plan/issues/macos-github-login-deep-dive-2026-06-18.md` (layers 2-3)
- depends_on: [enclave/macos-vault-unreachable-via-publish-aarch64]
- claimed: lease `ghlogin-route-orchestrated-20260620T0134Z`
  (macos-Tlatoanis-MacBook-Air-vz), claimed 2026-06-20T01:34Z — held pending the
  layer-5 dependency; do NOT ship the code alone (login still dies at Vault and a
  60s hang is worse UX than the current instant-gray).
- problem: >
    The macOS tray's `launch_spec(GithubLogin)` (host-shell/src/pty/mod.rs:142,161)
    runs bare `gh auth login` on the bare VM, where `gh` is not installed (only
    podman is). The correct path is the orchestrated `tillandsias-headless
    --github-login` (already supported in the deployed v0.3.260618.2 headless).
- planned_change: >
    (layer 2) Change `launch_spec(GithubLogin)` argv to
    `["tillandsias-headless","--github-login"]`. (layer 3) Add `XDG_RUNTIME_DIR`
    (+ keep `TERM`) to the PtyOpenOpts.env so the in-VM `require_desktop_user_session`
    guard passes, AND add `loginctl enable-linger root` to the cloud-init
    (`vm-layer/src/vz.rs`) so `/run/user/0` persists for the service-spawned PTY
    child (verified: guard fails without XDG_RUNTIME_DIR, passes with
    `XDG_RUNTIME_DIR=/run/user/0`). Mirror on the Windows tray (shared host-shell
    parity). Re-run m8 GitHub Login after layer 5 + this land together.
- evidence_required:
  - macОS GitHub Login opens a working interactive shell (gh device-code), not gray
  - cargo test -p tillandsias-host-shell / -p tillandsias-macos-tray green
  - m8 login → projects (F5) → attach works end-to-end on a fresh provision

### local-smoke/wasmtime-dnf-migration-failure

- status: done
- lease_id: "wasmtime-revert-20260620T101400Z"
- agent_id: "linux-tlatoani-gemini-20260620T101400Z"
- expires_at: "2026-06-20T14:14:00Z"
- owner_host: linux
- source: `plan/issues/build-install-smoke-e2e-findings-2026-06-20.md`
- severity: high — blocks local-build E2E and therefore release confidence for integrated `linux-next`
- next_action: none — fix landed and E2E verified.
- blocker: none
- completed_evidence: >
    Reverted the wasmtime DNF installation migration to restoration of direct archive fetch with SHA256 checksum verification.
    Updated the default-image litmus test (litmus-default-image-containerfile-shape.yaml) to expect 5 checksum-verification sites.
    Ran `./build.sh --ci-full --install`, which successfully completed all pre-build litmus tests, built, installed, and passed all runtime E2E residual checks.
    Evidence bundle: target/convergence/evidence-bundle-20260620-102600.tar.gz.
- evidence_required:
  - `tillandsias --init --debug` completes successfully on a pristine store.
  - `podman run --rm localhost/tillandsias-forge-base:latest wasmtime --version` returns a valid version.
  - E2E gate 3 passes.

### local-smoke/linux-musl-tray-binary-name-collision

- status: done
- owner_host: linux
- source: `plan/issues/build-install-smoke-e2e-findings-2026-06-19.md`
- severity: high — blocks local-build E2E and therefore release confidence for
  integrated `linux-next`
- next_action: No worker action; the packet is closed after the full local-build
  E2E gate passed on Linux.
- blocker: none
- lease: `lease-linux-musl-tray-collision-20260619T2325Z` (expires
  2026-06-20T03:25:53Z)
- completed_evidence: >
    Fixed in `307ef0eb` by narrowing the Linux install musl build to
    `tillandsias-headless --bin tillandsias --features tray`. Local-build E2E
    then passed on tested commit `307ef0eb3d47d3229ad58cdd821e909bd7eeefbc`:
    `./build.sh --ci-full --install`, destructive `podman system reset
    --force`, fresh `tillandsias --init --debug`, and Linux `--opencode
    --prompt "Use the /forge-continuous-enhancement skill"` all exited 0.
    Installed version: `Tillandsias v0.3.260619.5`. Evidence:
    `target/build-install-smoke-e2e/20260619T233855Z`.
- evidence_required:
  - `./build.sh --ci-full --install` exits 0 on Linux
  - no Cargo `output filename collision` warning for `tillandsias-tray`
  - destructive Podman reset, fresh `tillandsias --init --debug`, and Linux
    forge lane are reached or produce their own later finding

### local-smoke/opencode-forge-continuous-enhancement-prompt-noop

- status: done (commit 89eebe49)
- owner_host: linux
- source: `plan/issues/opencode-forge-continuous-enhancement-prompt-noop-2026-06-19.md`
- severity: high — the prompted Linux forge lane can exit 0 without actually
  running `/forge-continuous-enhancement`, making smoke/release evidence
  semantically weak
- next_action: None — fix landed. Created missing symlink
  `.opencode/skills/forge-continuous-enhancement` → `../../skills/forge-continuous-enhancement`.
- blocker: none
- discovered_evidence: >
    Local-build E2E log `target/build-install-smoke-e2e/20260619T233855Z`
    recorded `forge_exit=0`, but `04-forge-continuous-enhancement.log:16-19`
    shows `Skill "diagnose-forge"`, `That's not a skill in my available list`,
    and `What would you like me to do?` instead of
    `/forge-continuous-enhancement` execution.
- evidence_required:
  - prompted OpenCode forge lane exits 0 only after intended skill start and
    completion, or explicit no-work-needed completion
  - E2E transcript distinguishes command success from semantic no-op
  - regression coverage pins accepted transcript marker(s)

### release/version-tag-sequence-mismatch

- status: done
- owner_host: linux
- source: `plan/issues/release-version-tag-sequence-mismatch-2026-06-17.md`
- next_action: No worker action; the packet is closed. `/merge-to-main-and-release`
  can now preserve the current `VERSION` when it is already ahead of the
  tag-derived sequence for the UTC day.
- blocker: cleared by `764e8745` (`fix(release): preserve VERSION if ahead of
  tag sequence`).
- evidence_required:
  - release PR/tag/workflow uses a version that matches the accepted smoke
    evidence, or fresh smoke evidence is captured for the lower version
  - no `main` VERSION downgrade occurs during release

### nanoclawv2-orchestration

- status: stalled (lease expired 2026-06-18T02:07Z; reclaimable)
- owner_host: linux
- source: `plan/issues/nanoclawv2-orchestration.md`
- next_action: Draft the NanoClawV2 implementation task graph from the new
  spec, then wire the launcher leaf, broker surface, and smoke hooks.
- lease: `nanoclawv2-orchestration-202606172207` (EXPIRED at 2026-06-18T02:07Z)
- blocker: none
- evidence_required:
  - NanoClawV2 launch leaf exists and is branch-aware
  - only approved orchestration actions are reachable
  - smoke coverage proves launch and one approved action

### github-login/enclave-egress-regression

- status: ADDRESSED 2026-06-18 — root cause fixed under `bug/github-login-failure` (runtime validation pending)
- reopened_reason: >
    The Tlatoani reports `--github-login` still fails from both CLI and tray
    across the last several builds. The `d3f4e2f3` fix only renamed the network
    constant and was never live-validated (release smoke never ran
    `--github-login`). Investigation found a likely deeper root cause:
    `run_github_login` launches the helper on the enclave+egress networks but
    never calls `ensure_enclave_network`/`ensure_egress_network`, so the
    `podman run --network …` fails on a clean store. Tracked in the new packet
    `bug/github-login-failure` (see below).
- owner_host: linux
- source: `plan/issues/github-login-enclave-egress-regression-2026-06-17.md`
- prior_fix_commit: `d3f4e2f3` on `linux-next` (insufficient)
- fix_summary: >
    Changed the GitHub login helper container from single-homed `ENCLAVE_NET`
    to dual-homed `ENCLAVE_EGRESS_NETS` (tillandsias-enclave,tillandsias-egress).
    The gh helper now reaches api.github.com through the managed egress network,
    consistent with the proxy and git-service pattern. Added source-level
    regression test `github_login_helper_dual_homes_onto_managed_egress_network`.
- blocker: none
- evidence_required:
  - `tillandsias --debug --github-login` completes after a valid token on a
    clean post-init install (e2e gate, next release)
  - token is persisted into Vault for the forge/git-mirror path
  - direct external curl from an ordinary enclave-only container still fails
  - forge/proxy egress smoke remains green
- latest_evidence_note: >
    Local build/install smoke for `v0.3.260618.1` passed on 2026-06-18:
    `./build.sh --ci-full --install`, destructive Podman reset, clean
    `tillandsias --init --debug`, direct enclave-only HTTPS denial to
    `api.github.com`, and `tillandsias --status-check --debug` all passed.
    The actual `tillandsias --debug --github-login` token paste remains open:
    a noninteractive timed PTY attempt was aborted because it can echo the host
    `gh` token before the hidden container prompt. Next run must be
    operator-attended with a fresh/rotated token.

### bug/github-login-failure

- status: fix-landed (runtime validation pending) — 2026-06-18,
  commit `62e73c70` on `linux-next` (linux-tlatoani-opus-worker2-20260618T043347Z)
- owner_host: linux
- source: `plan/issues/github-login-failure-regression-2026-06-18.md`
- severity: high — blocks GitHub auth from both CLI and tray across recent builds
- fix_summary: >
    Added `ensure_enclave_network(debug)?;` at the top of run_github_login
    (after ensure_image_exists, before the helper podman run). This idempotently
    ensures BOTH tillandsias-enclave and tillandsias-egress exist before the
    dual-homed helper launch, matching every sibling enclave-bootstrap flow.
    Root cause confirmed: the helper launched on ENCLAVE_EGRESS_NETS but the
    networks were never ensured, so on a clean store `podman run --network
    tillandsias-enclave,tillandsias-egress …` failed. Added regression test
    `github_login_ensures_networks_before_helper_launch`. Build/clippy/fmt/
    ./build.sh --check all clean.
- runtime_validation_pending: >
    Operator/e2e gate still required — `tillandsias --debug --github-login` on a
    clean post-init store (no Error:/exit 1), token persisted to Vault, and the
    tray GitHub Login click. Not demonstrated in the worker context (no runtime
    podman login available). Keep acceptance_evidence open.
- next_action: Live-validate `tillandsias --debug --github-login` on a clean
  post-init install; confirm token persists to Vault and the tray path surfaces
  inner errors. If login still fails after the networks exist, audit rootless
  dual-home egress NAT (checklist items 4/6/7 in the source packet).
- supersedes: `github-login/enclave-egress-regression`
- blocker: none
- evidence_required:
  - `tillandsias --debug --github-login` completes on a clean store
  - tray GitHub-login flow succeeds (or surfaces the real error)

### bug/clone-tray-ux-not-refreshed

- status: fix-landed (runtime validation pending) — commit `8e9fa2d9` on
  linux-next
- owner_host: linux
- source: `plan/issues/clone-tray-ux-not-refreshed-2026-06-18.md`
- severity: medium — clone succeeds on disk but tray stayed on "Cloning…" and
  `~/src` never refreshed
- fix: `tray/mod.rs` `handle_launch_cloud_project` now, on clone success, sets a
  "✓ Cloned <name>" status, calls the new `TrayService::refresh_local_projects()`
  (re-scans `~/src` into `state.projects` + bumps revision — the missing
  post-startup writer), then `rebuild_after_state_change()`. Regression test
  `refresh_local_projects_picks_up_new_checkout` added.
- blocker: none
- evidence_required:
  - [open] runtime: actually clone a not-yet-on-disk repo from `☁️ Cloud >` on a
    live tray and observe the status clears AND `🏠 ~/src` lists the new checkout
    without a restart (needs an operator with a logged-in GitHub session)

### enclave/network-level-egress-deny

- status: done
- owner_host: linux
- source: `plan/issues/enclave-egress-network-enforcement-gap-2026-06-16.md`
- completed_evidence:
  - Implementation landed in `e11ff704` (adds `--internal` to enclave network,
    dual-homes git-service) and `4c6d11d8` (replaces nonexistent `bridge` egress
    leg with managed `tillandsias-egress`).
  - Litmus updated in `8d50c134`; existing `litmus:enclave-network-source-shape`
    pins the `--internal` const and dual-homed ENCLAVE_EGRESS_NETS.
  - Live verification on 2026-06-17: `podman network inspect tillandsias-enclave`
    confirms `Internal=true`; direct (`--noproxy`) curl returns HTTP=000 (FAILED).
  - Local-build e2e gate passed (build/install/reset/init/forge lane).

### policy/no-python-runtime-scripts

- status: done
- owner_host: linux
- source: `plan/issues/no-python-runtime-policy-2026-06-16.md`
- progress: >
    All Python-backed scripts are successfully rewritten or retired.
    `check-cheatsheet-tiers.sh` is Rust-backed via `tillandsias-policy check-cheatsheet-tiers`.
    `bind-provenance-local-paths.sh`, `regenerate-source-index.sh`, `refresh-cheatsheet-sources.sh`
    are tombstone-only. `check-convergence-velocity` retired. `sources` and `audit` validators
    are re-homed into `tillandsias-policy` as `check-cheatsheet-sources` and
    `audit-cheatsheet-sources` subcommands. `distill-forge-diagnostics.sh` ported to a
    `tillandsias-policy distill-forge-diagnostics` subcommand. Finally, on 2026-06-20,
    `fetch-cheatsheet-source.sh` (6 python3 sites) and `regenerate-cheatsheet-index.sh`
    (1 python3 site) were ported to Rust subcommands and reduced to thin wrappers.
    `scripts/check-no-python-scripts.sh` now exits 0 with no violations.
- next_action: none — issue is fully resolved
- blocker: none
- evidence_required:
  - `scripts/check-no-python-scripts.sh` exits 0
  - no `*.py` executable scripts remain under `scripts/`
  - no harness, skill, litmus, or repeat path shells out to `python`/`python3`
- follow_up: >
    2026-06-20 diagnostics slice removed the Python validator from
    `litmus-forge-diagnostics-e2e.yaml`; follow-up
    `plan/issues/no-python-litmus-drift-2026-06-20.md` is now complete and
    `scripts/check-no-python-scripts.sh` covers litmus YAML command fields.

### local-smoke/forge-pty-stopped-before-container-start

- status: done
- owner_host: linux
- source: `plan/issues/build-install-smoke-e2e-findings-2026-06-14.md`
- fix_commit: `d761b418` on `linux-next`
- fix_summary: >
    In `build_opencode_forge_args`, skip `--interactive --tty` when a
    prompt is provided via `--prompt`, because the entrypoint execs
    `opencode run --dangerously-skip-permissions` which is non-interactive.
    Podman no longer attempts to claim the terminal, avoiding the
    SIGTTIN/SIGTTOU / stopped T state in harness PTYs.
- blocker: cleared by `d761b418`.
- evidence_required:
  - final local-smoke forge lane exits 0 or emits actionable runtime logs
  - expected forge container is visible while the lane is active
  - no stopped `T` process state in the harness

## Triaged 2026-06-16 (no longer needs triage)

The 2026-06-16 critical/high forge proposals were triaged in
`coord/critical-forge-proposal-triage-20260616` (now done). Dispositions:

- `2026-06-16-git-pii-scrub.md` → **accepted**, promoted to the Immediate
  packet above (order 53).
- `2026-06-16-network-isolation-regression.md` → **REOPENED / reframed**
  (supersedes the original "rejected"). The rejection was based on the
  proxy-cooperative `external_curl` probe + `--network=none` litmus, neither of
  which tests direct egress. On re-test, a direct connection from an enclave
  container reaches the internet (HTTP 200): enclave egress is proxy-cooperative,
  not network-enforced. Reshaped as the `enclave/network-level-egress-deny`
  packet above (`enclave-egress-network-enforcement-gap-2026-06-16.md`).
- `2026-06-16-podman-in-forge.md` → **deferred** — rootless podman-in-forge is
  infeasible under `--cap-drop=ALL`/`--userns=keep-id`/`no-new-privileges`
  without weakening isolation; kept in the forge backlog.

## Manual Or Deferred

### m8/appkit-action-smoke-and-stub-polish

- status: unblocked (was blocked on step 49)
- owner_host: macos
- source: `plan/issues/osx-next-work-queue-2026-05-25.md`
- next_action: user-attended macOS interactive smoke — enclave now reaches Ready
- blocker: user-attended click smoke; not claimable by unattended agent

### macOS in-VM enclave (step 49)

- status: in_progress (49d remaining — user-attended)
- owner_host: macos
- source: `plan/steps/49-macos-in-vm-enclave.md`, `plan/index.yaml` order 55
- next_action: 49d — user-attended m8 interactive smoke (projects populate, github-login, attach shell)
- completed: 49a (design), 49b (cloud-init podman install, b7321f50), 49c (headless reached Ready ~32s), 49e (automated assertion script, diagnose-macos-enclave.sh)
- blocker: user-attention required — 49d cannot be validated unattended
- lease: `step49-macos-vm-enclave-20260616T231619Z` (expires 2026-06-17T03:16Z)
- evidence_required:
  - [x] cargo test passes
  - [x] build-osx-tray produces a valid bundle (E2E gate PASS)
  - [x] VM reaches Ready phase after provisioning (49c verified)
  - [ ] m8 interactive smoke passes (49d) — user-attended

## This Cycle (2026-06-18T20:50Z, linux)

- **Release-smoke priority**: fetched origin, fast-forwarded `linux-next`, and
  found GitHub latest release `v0.3.260618.2` newer than recorded curl-install
  smoke evidence.
- **Curl-install e2e**: installed the published Linux artifact, verified
  `Tillandsias v0.3.260618.2`, ran destructive `podman system reset --force`,
  confirmed empty container/volume/image inventories, and completed fresh
  `tillandsias --debug --init` with Vault healthy/unsealed.
- **Forge lane**: prompted `tillandsias . --opencode --prompt "Use the
  /forge-continuous-enhancement skill"` exited 0.
- **New ready findings**: filed
  `smoke-finding/forge-ripgrep-missing`,
  `smoke-finding/forge-marksman-missing`, and
  `smoke-finding/forge-nix-store-missing` in
  `plan/issues/smoke-e2e-findings-v0.3.260618.2-2026-06-18.md`.
  Detailed forge proposals were committed in `62964f02` and pushed to GitHub.
- **Sibling audit**: `origin/windows-next` (`e332afb6`) and `origin/osx-next`
  (`c7d32fb9`) remain ancestors of `linux-next`; no branch drift, deadlock,
  thrash, or wrong-direction progress detected.
- **Next useful Linux actions**: operator-attended
  `tillandsias --debug --github-login`, claim one new forge tool packet, or
  continue the expired no-Python cleanup lease.

## This Cycle (2026-06-18T16:00Z, linux)

- **Meta-orchestration audit**: fetched origin on a clean mutable-Linux
  `linux-next` checkout and confirmed local HEAD is up to date at `87d2201f`.
- **Sibling audit**: `origin/windows-next` (`e332afb6`) and `origin/osx-next`
  (`c7d32fb9`) are both ancestors of `origin/linux-next`; each has 0 commits
  ahead of linux-next, with no branch drift, deadlock, thrash, or wrong-direction
  progress detected.
- **Worker drain**: no implementation packet was claimed. `policy/no-python-runtime-scripts`
  remains actively leased until 2026-06-18T18:17Z; `nanoclawv2-orchestration`
  remains reclaimable (~4h) and `local-smoke/evidence-bundle-litmus-count-regression`
  is ready (~3h) but both exceed the meta-orchestration cycle budget.
- **Release/e2e freshness**: `gh release view` reports latest release
  `v0.3.260618.1`, published 2026-06-18T01:34:43Z from `b0dba63e`; existing
  release-smoke evidence for the same version passed at 2026-06-18T03:31:55Z.
- **E2E gates**: skipped. This cycle changed only plan ledger text and found no
  runtime, image, installer, or release artifact delta since the current smoke.
- **Next useful Linux actions**: operator-attended
  `tillandsias --debug --github-login`, continue no-Python cleanup after the
  active lease checkpoints/expires, or reclaim NanoClawV2 in a longer worker
  cycle.

## This Cycle (2026-06-18T14:19Z, linux)

- **Worker drain**: reclaimed expired
  `policy/no-python-runtime-scripts` lease as
  `no-python-slice-3-202606181417` and completed a narrow tombstone cleanup.
- **No-Python slice 3**: replaced
  `scripts/bind-provenance-local-paths.sh` with a compact tombstone-only
  wrapper. The wrapper still exits 0 with the replacement notice, and the
  unreachable Python legacy body no longer appears in
  `./scripts/check-no-python-scripts.sh`.
- **Verification**: `scripts/bind-provenance-local-paths.sh` PASS, `bash -n`
  PASS, `cargo test -p tillandsias-policy` PASS, `git diff --check` PASS.
  The no-Python checker still fails on the remaining active
  cheatsheet/provenance/diagnostics/source-index scripts.
- **E2E gates**: skipped. This cycle changed an already-retired maintenance
  wrapper and plan ledgers only; no runtime, image, installer, or release
  artifact behavior changed.

## This Cycle (2026-06-18T13:26Z, linux)

- **Merged osx-next plan-only cycle**: integrated `origin/osx-next` commit
  `c7d32fb9` into `linux-next`. It recorded a macOS no-eligible-work
  meta-orchestration cycle and touched only `plan/issues/osx-next-work-queue-2026-05-25.md`
  plus `plan/loop_status.md`.
- **Worker drain**: no small unclaimed Linux implementation packet was claimed.
  `policy/no-python-runtime-scripts` remains leased until 2026-06-18T14:01Z;
  `nanoclawv2-orchestration` remains reclaimable, but the next implementation
  slice is estimated at 4h and should be picked up by a dedicated worker cycle.
- **E2E gates**: skipped. No implementation/runtime/image/installer files
  changed, and release `v0.3.260618.1` already has current curl-install smoke
  evidence.
- **Next useful Linux evidence**: operator-attended
  `tillandsias --debug --github-login` on a clean post-init install with a
  fresh/rotated token.

## This Cycle (2026-06-18T13:31Z, linux)

- **Meta-orchestration audit**: `/meta-orchestration` was requested, but the
  local available skill is `coordinate-multihost-work`; used that workflow and
  recorded the mismatch in `plan/loop_status.md`.
- **Sibling audit**: `origin/windows-next` (`e332afb6`) and `origin/osx-next`
  (`c7d32fb9`) are both ancestors of `origin/linux-next` (`41a3fab1`), 0 drift.
  No deadlock, thrash, wrong-direction progress, or pending runtime-litmus
  marker was found.
- **No implementation work claimed**: `policy/no-python-runtime-scripts` remains
  leased until 2026-06-18T14:01Z; `nanoclawv2-orchestration` remains reclaimable
  for a longer worker cycle.
- **Next useful evidence unchanged**: operator-attended
  `tillandsias --debug --github-login`; Windows Smart App Control decision;
  macOS step 49d / m8 interactive smoke.

## This Cycle (2026-06-20T01:01Z, windows)

- **SAC blocker RESOLVED**: operator turned Smart App Control off
  (`VerifiedAndReputablePolicyState=0`). Confirmed native builds work via the
  exact failing site: `cargo check -p tillandsias-policy` ran serde's
  build-script clean (6.46s), no os error 4551.
  `plan/issues/windows-smart-app-control-build-block-2026-06-18.md` → RESOLVED.
- **Synced**: fast-forwarded `windows-next` from `41a3fab1` to shared frontier
  `origin/linux-next` `1dfd2bea` (all 5 prior local plan commits were already in
  linux-next; clean ff, no merge conflicts).
- **E2E gate (local-build, windows)**: PASS. build → install (freshness SHA ==
  HEAD) → `wsl --unregister tillandsias` → cold `--provision-once` → VM Ready.
  Forge lane N/A (Linux-only). Report:
  `plan/issues/build-install-smoke-e2e-windows-2026-06-19.md`.
- **Worker fix landed (windows)**: the e2e gate surfaced a cold-provision hang —
  headless units `enable`d but never started. Fixed `enable` → `enable --now` in
  `wsl_lifecycle.rs::inject_bootstrap_logic`; re-verified end-to-end (auto VM
  Ready, no manual start). `windows/cold-provision-headless-units-not-started`
  → done. Packet:
  `plan/issues/windows-cold-provision-headless-units-not-started-2026-06-19.md`.

## Achieved This Cycle (2026-06-18T10:15Z, macos)

- **meta-orchestration sync**: Fast-forwarded `osx-next` to current shared
  `linux-next` state (`2e7a53b6`) so macOS has the latest plan/code frontier.
- **startup hygiene finding**: Tracked worktree was clean, but untracked
  artifacts remain: `build-osx-tray.sh`,
  `plan/issues/macos-windows-tray-ux-parity-audit-2026-06-13.md`,
  `research/`, and `src-tauri/`. They are not ignored and appear meaningful, so
  this cycle left them untouched and skipped new autonomous implementation work.
- **advance-work-from-plan drain**: No eligible autonomous macOS work was
  claimed. The active macOS item remains step 49d / m8 interactive smoke, which
  is user-attended and not suitable for unattended validation.
- **E2E gates**: Skipped; this checkpoint changed only plan ledger text and
  branch sync state.

## Previous macOS Cycle (2026-06-17T22:57Z, macos)

- **repeat**: Added macOS-compatible timeout fallback (`run_with_timeout`) so the
  repeat loop works on stock macOS without GNU coreutils. Commit `807f95f9`.
- **advance-work-from-plan drain**: No eligible autonomous macOS work found.
  All plan items are completed or blocked-on-user (step 49d = user-attended m8
  smoke). Ready macOS bugfix packets in m8 failures file remain but require
  a running VM or interactive session to verify.

## Previous Cycle (2026-06-16T23:16–23:35Z, macos)

- **Step 49a**: Design decision (Option 1 — cloud-init installs podman).
- **Step 49b**: Implemented — `dnf install -y podman` + `podman.socket` in vz.rs cloud-init (b7321f50). E2E gate PASS (build+install+provision+diagnose).
- **Step 49c**: Verified — headless reaches `phase=Ready podman_ready=true` ~32s post-boot (was ~84s `Failed`). Enclave provisioning resolved.
- **Step 49e**: Automated assertion — `scripts/diagnose-macos-enclave.sh`, polls tray log for Ready within 120s. Validated.
- **Step 49d**: Remaining — user-attended m8 interactive smoke.

## This Cycle (2026-06-18T04:19Z, linux)

- **Merged osx-next plan-ledger commit** `c8a6fef9` into `linux-next`:
  macOS meta-orchestration cycle entry (no eligible autonomous macOS work).
  Resolved conflict in `plan/loop_status.md` — kept linux-next's current 04:10Z
  content and updated for this cycle.
- **Reclaimable packets unchanged**: `nanoclawv2-orchestration` and
  `policy/no-python-runtime-scripts` remain available for Linux claim.
- **No e2e gate run**: no runtime crate/image delta since released v0.3.260618.1.

## This Cycle (2026-06-18T10:23Z, windows)

- **Recovered 13 stranded commits**: a prior Windows cycle committed the
  07:25Z meta-orchestration record, the forge PTY fix (`d761b418`), and the
  `v0.3.260618.1` plan/TRACES batch but never pushed. Pushed
  `7674f823..8ab39e97` to `origin/windows-next` (ff-safe).
- **Synced `linux-next`**: merged `origin/linux-next` (`2e7a53b6`, incl.
  `fix(policy): port cheatsheet tier check to Rust`) into `windows-next`;
  resolved `plan/loop_status.md` by taking the newer Linux coordinator content.
- **Added `repeat.ps1`**: committed the Windows launcher that locates bash and
  delegates to `./repeat` (parse-validated). Previously untracked local-only.
- **Worker drain**: No Windows-owned ready work in `plan/index.yaml`; all
  Windows-owned packets are `done`/`completed`. Yielded.
- **E2E gates**: BLOCKED. Smart App Control is enforcing on this host
  (`VerifiedAndReputablePolicyState=1`) and blocks execution of unsigned cargo
  build-script binaries (`os error 4551`), so the native local-build e2e cannot
  run. Curl-install e2e skipped (latest release `v0.3.260618.1` == latest
  tested). Production WSL2 substrate verified healthy via non-destructive probe
  (`wsl -l -v`: `tillandsias` registered, VERSION 2).
  Finding: `plan/issues/windows-smart-app-control-build-block-2026-06-18.md`.

## This Cycle (2026-06-18T07:25Z, windows)

- **Worker drain**: No Windows-owned ready work found in `plan/index.yaml`;
  yielded.
- **E2E gates**: Windows build/install, destructive WSL unregister, and cold
  re-provision PASS.
  Evidence: `plan/issues/build-install-smoke-e2e-findings-2026-06-18.md`.

## This Cycle (2026-06-18T05:38Z, linux)

- **Fixed stale no-Python litmus drift**:
  `litmus:observability-convergence-script-shape` no longer requires the
  retired `scripts/check-convergence-velocity.py`; it now pins the 5 active
  shell surfaces and the explicit Python-retired/no-op wrapper warning.
- **Local build smoke evidence**: `./scripts/run-litmus-test.sh --spec
  observability-convergence --phase pre-build` PASS (2/2), then
  `./build.sh --ci-full --install` PASS (pre-build 129/129, post-build 6/6,
  runtime residual 5/5), installing `Tillandsias v0.3.260618.1`.
- **Clean runtime evidence**: destructive `podman system reset --force` PASS,
  pristine `tillandsias --init --debug` PASS, direct enclave-only HTTPS to
  `api.github.com` denied, and `tillandsias --status-check --debug` PASS.
- **Blocked probes**: `tillandsias --debug --github-login` remains
  operator-attended because timed PTY token injection is unsafe; the forge
  continuous-enhancement lane entered stopped `T` state before container
  startup in this harness (`forge_exit=blocked-stopped-pty`).

## This Cycle (2026-06-18T09:08Z, linux)

- **Merged osx-next plan-ledger commit** `965fc1ae` into `linux-next`:
  macOS meta-orchestration cycle entry (no eligible autonomous macOS work,
  step 49d remains user-attended).
- **Resolved plan cache conflict** in `plan/loop_status.md` by keeping the
  latest Linux smoke/forge PTY evidence and adding the macOS no-work cycle as
  integrated sibling state.
- **Reclaimable packets unchanged**: `nanoclawv2-orchestration` and
  `policy/no-python-runtime-scripts` remain available for Linux claim.
- **No e2e gate run**: this was a plan-only coordination merge with no crate,
  script, image, or release artifact delta.

## This Cycle (2026-06-18T02:28Z, linux)

- **Completed `github-login/enclave-egress-regression`**: code fix in
  `d3f4e2f3` — changed `ENCLAVE_NET` → `ENCLAVE_EGRESS_NETS` for the
  GitHub login helper container. The gh helper now dual-homes onto the
  managed egress network (tillandsias-enclave,tillandsias-egress) so
  `gh auth login` can reach `api.github.com`. Added regression test
  `github_login_helper_dual_homes_onto_managed_egress_network`.
- **Expired leases**: `nanoclawv2-orchestration` (02:07Z) and
  `policy/no-python-runtime-scripts` (02:15Z) are now reclaimable.
- **No e2e gate run**: code fix targets the next release; published
  `v0.3.260618.1` still has the regression (as expected).

## Recently Closed This Coordination Pass

- **Completed `release/version-tag-sequence-mismatch`**: commit `764e8745`
  updated `/merge-to-main-and-release` so a current-day `VERSION` that is ahead
  of the tag-derived sequence is preserved instead of being downgraded.
  The packet header is now `done`; there are no remote `v0.3.260617.*` tags,
  no open `linux-next -> main` PR, and no in-flight `release.yml` run.
- **Completed `enclave/network-level-egress-deny`**: implementation was already
  landed in commits `e11ff704` and `4c6d11d8`. Verified live on 2026-06-17:
  `tillandsias-enclave` is `Internal=true`; direct egress from enclave
  container FAILS (HTTP=000). Litmus `litmus:enclave-network-source-shape`
  pins the implementation surfaces. Marked `done` in ACTIVE.md and issue file.
- Completed `smoke-finding/rootless-bridge-network-missing`: local
  `/build-install-and-smoke-test-e2e` on 2026-06-17 tested commit `6a44f4c6`
  with installed `Tillandsias v0.3.260617.2`; build/install, destructive Podman
  reset, clean init, and prompted OpenCode forge lane all exited 0. Evidence:
  `target/build-install-smoke-e2e/20260617T201922Z`; init log shows
  `podman network create --driver bridge tillandsias-egress` followed by
  internal `tillandsias-enclave`, and forge diagnostics summary
  `plan/diagnostics/diagnostics_20260617T202340Z-summary.md` reports 25/25
  checks passed.
- Completed `cheatsheet/reconcile-committed-tier` (release-pipeline blocker) on
  2026-06-17T20:30Z via Option A: retiered order-53
  `cheatsheets/concurrent-git/commit-attribution.md` from invalid `tier:
  committed` to `bundled` (`bundled_into_image: true`), synced it into
  `images/default/cheatsheets/concurrent-git/`, and regenerated/synced both
  INDEX.md trees byte-identical (commit `0eef1443`). Acceptance:
  `check-cheatsheet-tiers.sh` exits 0 (210 validated); host-image-sync litmus
  critical_path passes; `./build.sh --ci-full` → ALL CHECKS PASSED (14/14).
  Unblocks the local-build e2e gate and `/merge-to-main-and-release` for all
  hosts.
- Completed `privacy/forge-git-identity-anonymization` / order 53: implementation
  commit `e31792e8` preserves real Git author identity and appends machine-parseable
  agent/model trailers. Acceptance fixture verified Codex and OpenCode trailers
  differ, including local-model params; shell syntax and `./build.sh --check`
  passed on 2026-06-16T23:29Z.
- Completed `coord/critical-forge-proposal-triage-20260616`: triaged all three
  2026-06-16 critical/high forge proposals (1 accepted → order 53, 1 rejected
  with evidence, 1 deferred with rootless-feasibility rationale). Decisions
  recorded in each proposal file and `plan/index.yaml`.
- Integrated `origin/osx-next` commits `21f62c3a` and `534e1aeb` into
  `linux-next`: macOS provision progress throttling plus clean smoke evidence.
- Closed stale `multihost-smoke-followups-20260615` rows in `plan/index.yaml`;
  macOS cold-boot suppression, local UX-parity reconciliation, substrate
  spec-amendment, and Windows sync/verify are all completed.
- Archived completed step deliverables from `plan/steps/` to
  `plan/archive/2026-06-16/steps/`.
- Completed `local-smoke/full-build-install-reset-init-forge`: local
  build/install, destructive Podman reset, pristine init, and prompted forge
  run all passed on 2026-06-16. Evidence:
  `target/build-install-smoke-e2e/20260616T072454Z`.
