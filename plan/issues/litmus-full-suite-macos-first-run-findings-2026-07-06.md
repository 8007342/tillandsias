# First-ever macOS full litmus run surfaces 22 unresolved (spec, test) failures — 2026-07-06

- class: research (needs per-item triage before any single item is "reduced")
- filed: 2026-07-06
- owner: any (mostly linux; 2 items below are macos/windows-tray)
- status: ready
- trace: plan/issues/macos-litmus-runner-bash-version-gap-2026-07-06.md (the fix
  that made this run possible for the first time)

## Finding

`scripts/run-litmus-test.sh` could not execute AT ALL on stock macOS (bash 3.2
lacks `declare -A`; see the trace issue above, now fixed on order 196). That
means **no macOS host has ever been able to see a full litmus-suite pass/fail
verdict** — every failure below could have existed, silently, for as long as
the litmus files themselves.

After the bash-3.2 portability fix (`declare -A` → parallel dedup+count
helpers) plus a second latent bash-4-ism found while verifying it
(`${var,,}` lowercase expansion in `behavior_matches_output`, replaced with
`tr '[:upper:]' '[:lower:]'`), the full suite now actually runs:

```
scripts/run-litmus-test.sh --phase pre-build --size instant --compact
```

Result: **93 PASS, 24 FAIL, 119 SKIP, 100% spec coverage (88/88 specs)**. One
of the 24 (`litmus:versioning-shape`, a `wc -c` BSD-padding string-equality
bug in the litmus's OWN check script) was fixed alongside this discovery —
see the sibling commit in this same push. **23 failures remain unresolved.**

## Failing (spec, test) pairs (23 remaining, alphabetical by spec)

```
browser-isolation-tray-integration   litmus:podman-idiomatic-launch-routing
ci-release                           litmus:ci-release-toolchain-shape
ci-release                           litmus:guest-binary-embed-integrity
default-image                        litmus:default-image-containerfile-shape
external-logs-layer                  litmus:external-logs-layer-shape
fix-windows-image-routing            litmus:fix-windows-image-routing-shape
forge-environment-discoverability    litmus:forge-environment-discoverability-install-shape
forge-hot-cold-split                 litmus:forge-hot-cold-split-shape
forge-opencode-onboarding            litmus:forge-opencode-onboarding-bootstrap-shape
forge-staleness                      litmus:image-build-convergence-shape
gh-auth-script                       litmus:gh-auth-script-shape
github-credential-health             litmus:github-credential-health-shape
inference-container                  litmus:inference-container-implementation-shape
inference-container                  litmus:inference-firstrun-default-models-shape
macos-native-tray                    litmus:macos-tray-architectural-invariants
macos-native-tray                    litmus:pty-attach-project-threading-symmetric
meta-orchestration                   litmus:e2e-eligibility-probe-shape
security-privacy-isolation           litmus:podman-path-availability
simplified-tray-ux                   litmus:simplified-tray-ux-leaf-action-shape
zen-default-with-ollama-analysis-pool litmus:zen-default-with-ollama-shape
podman-secrets-integration           litmus:podman-secrets-integration-shape
tillandsias-vault                    litmus:vault-github-token-capture-shape
tillandsias-vault                    litmus:vault-entrypoint-hardened-shape
```

## Spot-check root causes (4 of 23 confirmed by hand; the rest are UNTRIAGED)

Do not assume these 23 are all genuine product bugs — a preliminary spot-check
of 4 shows at least 3 distinct failure classes mixed together:

1. **Genuine spec/code drift (macOS-owned, confirmed, needs real fix):**
   - `macos-native-tray` / `litmus:macos-tray-architectural-invariants` step
     "gui-items-deferred-to-v2": pins
     `fn macos_target_disables_observatorium_and_opencode_web_for_v2` in
     `crates/tillandsias-host-shell/src/menu_state.rs` — that function does
     not exist anywhere in the file (confirmed via direct `grep`, no rename
     candidate found either). Either the test was deleted/renamed without
     updating the litmus, or it was never actually written. Needs: write/
     restore the pin test, or correct the litmus to match current reality.
   - `macos-native-tray` / `litmus:pty-attach-project-threading-symmetric`
     step 1: pins the exact substring
     `use tillandsias_host_shell::pty::{intent_for_action, launch_spec}` in
     `crates/tillandsias-windows-tray/src/notify_icon.rs`. The actual current
     import is `use tillandsias_host_shell::pty::{PtyIntent, intent_for_action, launch_spec};`
     (confirmed via direct `grep` — `PtyIntent` was added, litmus wasn't
     updated). This is windows-tray-owned source; the fix is trivial (update
     the litmus's fixed string) but should be coordinated with windows since
     it's windows' import shape being pinned.

2. **Local-machine artifact gap, NOT a code bug:**
   - `ci-release` / `litmus:guest-binary-embed-integrity`: fails because
     `target-guest/tillandsias-headless-x86_64-unknown-linux-musl` doesn't
     exist on THIS dev machine (nobody has run
     `scripts/build-guest-binaries.sh` here to cross-compile the x86_64 guest
     binary). Re-running after a real cross-compile would likely pass. Not
     itself evidence of drift; a clean-checkout macOS host would see the same
     "failure" and it would be correct behavior for an unbuilt tree.

3. **macOS/BSD-vs-Linux tooling gap inside the litmus check itself:**
   - `meta-orchestration` / `litmus:e2e-eligibility-probe-shape` step 3
     ("a held build-install smoke lock yields a deterministic lock skip
     verdict"): fails with `bash: flock: command not found`. macOS ships no
     `flock` (util-linux, Linux-only) and none is installed via Homebrew on
     this host either. Either `scripts/e2e-preflight.sh` /
     `scripts/with-smoke-lock.sh` needs a portable (e.g. `mkdir`-based)
     locking fallback for macOS, or this litmus step needs to be marked
     Linux-only / skip gracefully when `flock` is absent — same class of
     "macOS lacks a Linux coreutils tool" bug as the `wc -c` padding fix in
     this same push.

The remaining ~19 (podman-path-availability, podman-secrets-integration,
vault-*, forge-*, inference-container x2, default-image,
external-logs-layer, gh-auth-script, github-credential-health,
fix-windows-image-routing, simplified-tray-ux, zen-default-with-ollama,
browser-isolation-tray-integration, ci-release-toolchain-shape) were **not**
individually root-caused this cycle — most likely include a mix of genuine
Linux-owned-crate drift and "this macOS dev host lacks Podman/Linux tooling
these checks assume is present" false positives (e.g.
`podman-path-availability` by name alone suggests a Linux-path assumption).
**Do not action any of these 19 without first confirming, per item, whether
the failure is real drift or a macOS-host environment artifact** — treating
an environment artifact as a code bug would be a wasted/wrong fix.

## Work (next reduction step)

1. Triage each of the 23 (ideally on the owning host — Linux for most, since
   these mostly exercise Linux-target specs/scripts) into: genuine drift
   (promote a `plan/index.yaml` ready packet), local-state gap (no action —
   note it as expected-on-clean-tree), or macOS-tooling gap in the check
   itself (fix the litmus/script to be portable, same spirit as this push).
2. The 2 macos-native-tray items above already have a confirmed root cause
   and could be picked up directly as `ready` packets without further
   triage — the macos-tray-architectural-invariants one needs a macOS/
   host-shell owner to actually decide whether to restore the pin test or
   correct the litmus; the pty-attach one needs windows-tray coordination
   before the litmus's fixed string is corrected.
3. Sweep other litmus files for the same `wc -c`/`wc -l` un-trimmed
   string-equality pattern that broke `litmus:versioning-shape` on macOS
   (BSD `wc` right-pads its count with spaces) — there may be more silent
   false-failures of the same shape once each host actually runs the suite.

## Acceptance Evidence

- Each of the 23 has either: a `plan/index.yaml` ready packet (genuine
  drift), a one-line note here marking it confirmed-environmental
  (no packet needed), or a landed fix + green re-run.
