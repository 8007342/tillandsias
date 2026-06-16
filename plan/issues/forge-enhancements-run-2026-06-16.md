# Forge enhancements diagnostics run - 2026-06-16

Status: triaged (2026-06-16, coord/critical-forge-proposal-triage-20260616)

The destructive Linux smoke launched the forge successfully and processed the
diagnostics backlog. It found no terminal smoke failure, but it filed a backlog
of proposed forge-environment improvements.

## Evidence

- source summary:
  `plan/diagnostics/forge-enhancements-curated-toolchain-backlog-2026-05-29.md`
- diagnostics summary:
  `plan/diagnostics/diagnostics_20260616T072847Z-summary.md`
- forge state:
  `plan/forge-improvements/.diagnose-state`
- proposal directory:
  `plan/forge-improvements/proposals/`

## Triage Frontier

Only these items are immediate enough to surface in `plan/issues/ACTIVE.md`:

- `plan/forge-improvements/proposals/2026-06-16-network-isolation-regression.md`
  - critical security/isolation regression candidate.
- `plan/forge-improvements/proposals/2026-06-16-git-pii-scrub.md` - privacy
  candidate for Git identity exposure inside forge containers.
- `plan/forge-improvements/proposals/2026-06-16-podman-in-forge.md` - build
  enablement candidate that needs rootless feasibility review.

The remaining 2026-06-16 proposals stay in the forge backlog and should not
crowd the immediate active queue unless triage promotes them.

## Triage Outcome — 2026-06-16

- network-isolation-regression → **rejected** (not reproducing; 2026-06-16
  diagnostics 100%/25-of-25 + `ephemeral-guarantee` litmus green; backlog note
  for an enclave-network egress litmus).
- git-pii-scrub → **accepted** → promoted to `plan/index.yaml` order 53
  `privacy/forge-git-identity-anonymization` (now on the ACTIVE frontier).
- podman-in-forge → **deferred** (rootless infeasible under the forge isolation
  envelope; kept in backlog).
