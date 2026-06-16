# Active Plan Frontier

Last updated: 2026-06-16T09:42:00Z

This file is the first stop for agents inspecting `plan/issues/`. Historical
issue reports remain in this directory for evidence and auditability, but only
the items below are immediate work.

## Immediate

### privacy/forge-git-identity-anonymization

- status: ready
- owner_host: linux
- source: `plan/index.yaml` order 53
- next_action: Substitute the host user's real git identity with an anonymized
  / configured-forge identity at the `container_profile` / launch layer so
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` never carry real PII into the forge, while
  keeping in-forge commits attributable. Bare unset is WRONG (breaks
  enclave-mirror commit attribution).
- blocker: none
- accepted_from: `plan/forge-improvements/proposals/2026-06-16-git-pii-scrub.md`
- evidence_required:
  - diagnostics shows no real host git identity vars inside the forge
  - an in-forge `git commit` still succeeds with the substituted identity
  - a litmus/unit test pins the substitution against silent re-leak

## Triaged 2026-06-16 (no longer needs triage)

The 2026-06-16 critical/high forge proposals were triaged in
`coord/critical-forge-proposal-triage-20260616` (now done). Dispositions:

- `2026-06-16-git-pii-scrub.md` → **accepted**, promoted to the Immediate
  packet above (order 53).
- `2026-06-16-network-isolation-regression.md` → **rejected** — the 2026-06-14
  external_curl regression does not reproduce on 2026-06-16 (diagnostics
  100%/25-of-25, `ephemeral-guarantee` litmus green). Low-priority backlog
  follow-up noted: add an enclave-network egress litmus (the existing litmus
  uses `--network=none` and would not catch this regression class).
- `2026-06-16-podman-in-forge.md` → **deferred** — rootless podman-in-forge is
  infeasible under `--cap-drop=ALL`/`--userns=keep-id`/`no-new-privileges`
  without weakening isolation; kept in the forge backlog.

## Manual Or Deferred

### m8/appkit-action-smoke-and-stub-polish

- status: blocked
- owner_host: macos
- source: `plan/issues/osx-next-work-queue-2026-05-25.md`
- blocker: user-attended macOS click smoke. Autonomous build/test evidence is
  green; this is not claimable by an unattended implementation agent.

## Recently Closed This Coordination Pass

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
