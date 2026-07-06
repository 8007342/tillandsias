# First-ever macOS full litmus run surfaces 14 unresolved (spec, test) failures — 2026-07-06

- class: research (needs per-item triage before any single item is "reduced")
- filed: 2026-07-06
- owner: any (mostly linux — see the "14 remaining" list below)
- status: ready
- trace: plan/issues/macos-litmus-runner-bash-version-gap-2026-07-06.md (the fix
  that made this run possible for the first time)

## Finding

`scripts/run-litmus-test.sh` could not execute AT ALL on stock macOS (bash 3.2
lacks `declare -A`; see the trace issue above, now fixed on order 196). That
means **no macOS host had ever seen a full litmus-suite pass/fail verdict**
before this cycle — every failure below could have existed, silently, for as
long as the litmus files themselves.

```
scripts/run-litmus-test.sh --phase pre-build --size instant --compact
```

First run (bare macOS shell PATH, no `cargo` on PATH): **93 PASS, 24 FAIL, 119
SKIP, 100% spec coverage (88/88 specs)**.

## Update 2026-07-06T17:00Z — triage narrowed 24 → 14 real remaining unknowns

Three rounds of triage this cycle collapsed the original 24 failures a lot
faster than expected — most were NOT genuine product drift:

1. **1 fixed immediately** (`litmus:versioning-shape`): a `wc -c` BSD-padding
   string-equality bug in the litmus's OWN check script (`DOTS=$(... | wc -c)`
   compared with `[ "$DOTS" = '3' ]` — BSD `wc -c` right-pads its count with
   spaces, so the string never equalled `'3'`). Fixed with `| tr -d ' '`.

2. **2 fixed same-cycle** (orders 199, 200 — both `macos-native-tray`):
   - `litmus:macos-tray-architectural-invariants` step "gui-items-deferred-
     to-v2" pinned `fn macos_target_disables_observatorium_and_opencode_web_for_v2`
     in `crates/tillandsias-host-shell/src/menu_state.rs` — that function
     never existed there. The real behavior IS correctly implemented and
     tested, just in `crates/tillandsias-macos-tray/src/menu_disabled_v2.rs`
     under different names (`render_marks_observatorium_disabled_with_v2_tooltip_on_macos`
     + `render_marks_opencode_web_disabled_with_v2_tooltip_on_macos`).
     Repointed the litmus at the real tests. **No product code changed.**
   - `litmus:pty-attach-project-threading-symmetric` step 1 matched the exact
     literal `use tillandsias_host_shell::pty::{intent_for_action,
     launch_spec}` in windows-tray's `notify_icon.rs`. The current (correct,
     intentional) import is `{PtyIntent, intent_for_action, launch_spec}` —
     `PtyIntent` was added after the litmus was written. Loosened the check
     to match the two names it cares about within the import block. **No
     windows-tray code changed.**

3. **6 more turned out to be a single root cause, not 6 separate bugs**:
   re-running with `cargo` explicitly on `PATH`
   (`export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"`
   — `rustup`'s shim isn't on the default non-interactive bash PATH on this
   macOS host) turned **6 FAILs into PASSes with zero code changes**:
   `browser-isolation-tray-integration/litmus:podman-idiomatic-launch-routing`,
   `external-logs-layer/litmus:external-logs-layer-shape`,
   `fix-windows-image-routing/litmus:fix-windows-image-routing-shape`, and 3
   more folded into the same category. Each of these litmus checks runs a
   Rust-query subprocess or a `cargo`-dependent check that fails with `bash:
   cargo: command not found` when `cargo` isn't reachable — and the runner
   reports that identically to a real `[FAIL]`, with no distinguishing
   "tool missing, skipping" signal. **This is itself a small, real finding**
   (see "New finding" below) — filing it rather than silently absorbing it.
   Result after fixes 1–3: **93→101 PASS, 24→16 FAIL** (with `cargo` on PATH).

After accounting for orders 199/200 (already landed), **14 (spec, test) pairs
remain unresolved and UNTRIAGED further** — see list below. Two of the 14
were spot-checked and are confirmed non-actionable-here (not code bugs):

- `ci-release` / `litmus:guest-binary-embed-integrity`: fails because
  `target-guest/tillandsias-headless-x86_64-unknown-linux-musl` doesn't exist
  on this dev machine (nobody has cross-compiled it here via
  `scripts/build-guest-binaries.sh`). **Local-build-state gap, not drift** —
  expected on any fresh macOS checkout that hasn't run that build step.
- `meta-orchestration` / `litmus:e2e-eligibility-probe-shape` step 3: fails
  with `bash: flock: command not found` — macOS ships no `flock` (util-linux,
  Linux-only), none installed via Homebrew here either. Either
  `scripts/e2e-preflight.sh`/`scripts/with-smoke-lock.sh` needs a portable
  (e.g. `mkdir`-based) locking fallback for macOS, or this litmus step should
  skip gracefully when `flock` is absent. **macOS/BSD tooling gap in the
  check itself**, same class as the `wc -c` bug — not product drift.

## New finding: litmus runner gives no signal when a check's own tool (cargo, flock, podman, …) is missing

Distinguishing "real FAIL" from "the check's own dependency isn't installed"
currently requires a human reading raw stderr for each failure by hand (as
done in this triage). A `[FAIL]` from a missing `cargo`/`flock`/`podman` looks
identical to a `[FAIL]` from a real regression in the runner's summary.
Consider: (a) documenting `scripts/run-litmus-test.sh`'s PATH prerequisites
(cargo especially) in the bootstrap docs, and/or (b) having individual
litmus `command:` checks that shell out to `cargo`/`flock`/etc. first probe
`command -v <tool>` and emit a distinguishable `skip:tool-missing` verdict
rather than falling through to a bash "command not found" error treated as
FAIL. Not fixed this cycle (would require auditing every litmus file that
shells out to an external tool); filed here for whoever picks up the litmus-
runner-portability thread next.

## 14 remaining (spec, test) pairs — genuinely UNTRIAGED, real work

Spot-checked 3 of these (`podman-secrets-integration`, `tillandsias-vault` x2,
`inference-container` x2) by hand: **all 6 look like genuine, specific
Containerfile/entrypoint/main.rs source drift** — concrete grep-pattern
mismatches against real file content, not tool-missing or environment noise.
Examples: `podman-secrets-integration-shape` step 6 reports "only 5 of >=8"
`secret_name` accountability log fields in `main.rs` (a real count
shortfall); `inference-firstrun-default-models-shape` step 4 can't find
`qwen2.5-coder:1.5b` in the current default-models set. These look real and
actionable but were **not fixed this cycle** — they sit in Linux's write
scope (`crates/tillandsias-headless/`, `images/`, vault entrypoint scripts)
and deserve a careful look by whoever owns that code, not a macOS-side guess.

```
ci-release                            litmus:ci-release-toolchain-shape
default-image                         litmus:default-image-containerfile-shape
forge-environment-discoverability     litmus:forge-environment-discoverability-install-shape
forge-hot-cold-split                  litmus:forge-hot-cold-split-shape
forge-opencode-onboarding             litmus:forge-opencode-onboarding-bootstrap-shape
forge-staleness                       litmus:image-build-convergence-shape
gh-auth-script                        litmus:gh-auth-script-shape
github-credential-health              litmus:github-credential-health-shape
inference-container                   litmus:inference-container-implementation-shape
inference-container                   litmus:inference-firstrun-default-models-shape
simplified-tray-ux                    litmus:simplified-tray-ux-leaf-action-shape
zen-default-with-ollama-analysis-pool litmus:zen-default-with-ollama-shape
podman-secrets-integration            litmus:podman-secrets-integration-shape
tillandsias-vault                     litmus:vault-github-token-capture-shape
tillandsias-vault                     litmus:vault-entrypoint-hardened-shape
```

(`security-privacy-isolation`/`litmus:podman-path-availability` from the
original 24-item list was folded into the "cargo not on PATH" / general
Podman-absence bucket — this macOS host has no running Podman session at all
per `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-user-session`,
so this one plausibly needs re-verification on a host with Podman actually
running before it's counted as real drift either way; not re-checked this
cycle, listed here for completeness but likely folds into the flock/podman
environment bucket rather than being a 15th genuine item.)

## Work (next reduction step)

1. Linux (or whoever owns the relevant crate/image) triages each of the 14
   above individually: confirm genuine drift → promote a `plan/index.yaml`
   ready packet with the specific fix; confirm environment-only → note here
   and close without a packet.
2. Pick up the "litmus runner gives no signal for missing tools" finding
   above as its own small packet if it's worth the audit effort — optional,
   not blocking.
3. Sweep other litmus files for the same `wc -c`/`wc -l` un-trimmed
   string-equality pattern that broke `litmus:versioning-shape` on macOS
   (BSD `wc` right-pads its count with spaces) — there may be more silent
   false-failures of the same shape once each host actually runs the suite.

## Acceptance Evidence

- Each of the 14 has either: a `plan/index.yaml` ready packet (genuine
  drift), a one-line note here marking it confirmed-environmental
  (no packet needed), or a landed fix + green re-run.
