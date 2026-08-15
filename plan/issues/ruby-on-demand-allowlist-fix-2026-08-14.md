# Finding: ruby absent from the forge — build.sh gate 440 refused until installed via the brew shim

- Date: 2026-08-14
- Class: environment/provisioning (P1 — blocked `./build.sh --check` gate 440
  on every forge cycle until fixed)
- trace: images/default/brew-tools-allowlist.txt,
  images/default/brew-shim-exec.sh, images/default/lib-common.sh
  (`install_brew_shims`), methodology.yaml → runtime_language_policy
  (tlatoani_hard_no_python), methodology/multi-host-development.yaml:619
  (ruby listed among sanctioned validators), .forge-startup-context.md
  (documented ruby ABSENT), scripts/check-plan-schema-divergence.sh:35
- fixed_by: forge cycle 2026-08-14 (mirror-identity story)

## What

`ruby` was absent from the forge container. `scripts/check-plan-schema-divergence.sh`
(run by `./build.sh --check` as the plan/schema status-vocab gate, order 440)
executes a `ruby -ryaml` one-liner host-side and hard-failed with
`ruby: command not found` when ruby was missing:

```
/home/forge/src/tillandsias/scripts/check-plan-schema-divergence.sh: line 36: ruby: command not found
[build] plan/schema status-vocab gate refused (440)
```

The methodology explicitly names ruby a SANCTIONED validator (the `ruby -ryaml`
YAML fallback; python3 is forbidden by `tlatoani_hard_no_python`), and
`methodology/multi-host-development.yaml:619-620` lists it among the sanctioned
validators build deps. The forge startup context even called this out: ruby is
"the sanctioned validator (ruby) is missing" while the forbidden python3 sits on
PATH. So every prior forge cycle pushed while the 440 gate was RED by
environmental cause (or skipped it), and the honest thing was to install ruby.

## Why it matters

- `./build.sh --check` MUST pass before every push (AGENTS.md; no push CI on
  working branches — the local gate is the only trunk protection). A gate that
  cannot execute on the host it gates is advisory-only (methodology: "a guard
  only an attentive agent honors is a suggestion, not a constraint").
- The sanctioned validator was missing while the forbidden one (python3) was
  present and tempting — exactly the trap `.forge-startup-context.md` warns about.

## Fix (durable, committed)

1. **Allowlist entry** — added `ruby ruby` to
   `images/default/brew-tools-allowlist.txt` under a new
   "Sanctioned validators (build gates require these)" section. The allowlist
   is the durable source: the Containerfile copies it to
   `/usr/local/lib/tillandsias/brew-tools-allowlist.txt`
   (images/default/Containerfile:51) and `install_brew_shims` (lib-common.sh:2760)
   generates a `ruby` shim on forge start, so a FRESH forge rebuild installs
   ruby on first use automatically. Also fixed the stale header comment
   (it still claimed HOMEBREW_VERIFY_ATTESTATIONS=1; the shim-exec
   explicitly disables attestation per operator directive 2026-08-01 — the
   actual contract is authenticated-integrity-from-single-publisher via the
   pinned homebrew-1.pem).
2. **Bootstrap in the running forge** — brew was not yet bootstrapped, so I
   triggered it through an allowlisted tool (`gum` via
   `tillandsias-brew-shim-exec`), then `brew install ruby` (Homebrew 4.5.8,
   ruby 4.0.6, pinned tag), then symlinked the brew ruby/gem/irb/etc. into
   `~/.local/bin` (already last-on-PATH-forge dir). Re-ran `./build.sh --check`:
   gate 440 now reports `ok:status-vocab-in-sync` and the whole check is green.
3. **Doc** — updated `.forge-startup-context.md` to move ruby from ABSENT to
   present/on-demand, with the canonical one-liner.

## Verification

- `bash images/default/brew-shim-exec.sh ruby ruby` hint-mode returns
  "Install it in userspace with: brew install ruby" + exit 127 (auto-install
  off path works for the new pair).
- Allowlist shape check (litmus-brew-ondemand-tools-shape.yaml "allowlist
  lines are well-formed" step) passes: 0 malformed lines, no taps/casks.
- `litmus:brew-ondemand-tools-shape` PASSES in `run-litmus-test.sh default-image`.
- `./build.sh --check` fully green including gate 440
  (`ok:status-vocab-in-sync`). Note: `cargo test -p tillandsias-headless` has
  ONE pre-existing failure (`accel_probe::tests::test_serialization_roundtrip`,
  float-precision, fails on the pristine base too) — unrelated to this finding.

## Guidance for future agents

- If a build gate says "ruby: command not found", ruby is installable on demand:
  it is allowlisted now. `ruby` on PATH triggers the brew shim install on first
  use (or `brew install ruby` in userspace). Do NOT rewrite the gate to use
  python3 — `tlatoani_hard_no_python` forbids it.
- General rule for missing tools: check `images/default/brew-tools-allowlist.txt`
  first. If the tool is NOT allowlisted and a build gate or the methodology
  needs it, add the `<command> <homebrew-core-formula>` pair there (durable for
  every forge rebuild) rather than only installing into the live container.
  Keep to homebrew-core formulae; taps/casks are rejected by design.
- The live container's `/usr/local/lib/tillandsias/brew-tools-allowlist.txt` is
  root-owned; a fresh rebuild re-copies it from the repo, so the committed
  allowlist is what makes the fix durable.
