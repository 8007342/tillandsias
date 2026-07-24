# Forge image lacks the sanctioned YAML validators (tillandsias-policy, ruby)

- Date: 2026-07-16
- Class: enhancement
- Found on: forge (chaparrita), meta-orchestration cycle 2026-07-16T17:26Z
- Status: open

## Observation

Meta-orchestration finalization step 3 names `tillandsias-policy validate-yaml`
as the approved validator with `ruby -ryaml` as the sanctioned fallback. Inside
the forge container NEITHER exists: no `tillandsias-policy` on PATH or under
`target/`, and `ruby` is absent. Two concrete degradations this cycle:

1. Committed plan-YAML edits could not be validated by a sanctioned tool; the
   cycle fell back to `yq`/`yamllint` (both present in the image, neither
   blessed by methodology).
2. Running the mirror's `pre-receive` hook in-forge (offline fixtures, and any
   future in-forge mirror use) emits
   `[pre-receive] WARNING: no YAML validator found (tillandsias-policy or ruby)`
   and downgrades the YAML gate to advisory. The real `tillandsias-git`
   container bakes ruby (litmus:git-mirror-yaml-gate steps pin it), so only the
   forge lane is degraded.

## Why it matters

Forge cycles routinely edit `plan/*.yaml` and push through the verified-ack
mirror. An unvalidated-YAML push from the forge is exactly the class that broke
the trunk before (orphan conflict marker in plan/index.yaml; see
advance-work-from-plan §6 integration gate). The gate exists; the forge image
just cannot run its sanctioned tools.

## Smallest Next Action

Pick one (podman-capable host or forge-image owner):

- Bake `ruby` into the forge image (mirror container already does — smallest
  diff, aligns fixture and finalization behavior), or
- Ship `tillandsias-policy` into the forge image at build time, or
- Bless `yq`(+`yamllint`) as a sanctioned fallback in methodology.yaml and
  update the pre-receive hook + finalization runbooks to probe for it.

## Verifiable Closure

- In-forge: `scripts/check-yaml-validator.sh` (or an equivalent one-line probe)
  exits 0 naming an available sanctioned validator.
- The pre-receive fixture run in-forge no longer emits the
  no-validator WARNING.

## Independent reproduction / upvote — 2026-07-23

The v0.4 forge orchestration independently reproduced the same PATH gap:
`ruby` and `tillandsias-policy` were absent. The repo-native implementation is
usable through `cargo run -p tillandsias-policy -- validate-yaml ...`, and it
successfully validated the changed plan/litmus YAML, but that requires Cargo
setup/compilation and is not the named ready-to-run finalization command.

Upvote the existing packet; do not file a duplicate. Preferred closure is one
shared repo-native integration-tree validation helper backed by the Rust policy
tool, available uniformly to agents and hooks. Baking Ruby remains a valid
smaller alternative, but adding more per-call fallback logic would perpetuate
the divergence this packet documents.
