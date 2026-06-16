# Active Plan Frontier

Last updated: 2026-06-16T07:47:45Z

This file is the first stop for agents inspecting `plan/issues/`. Historical
issue reports remain in this directory for evidence and auditability, but only
the items below are immediate work.

## Immediate

### coord/critical-forge-proposal-triage-20260616

- status: ready
- owner_host: linux
- source: `plan/index.yaml` order 52
- next_action: Review the critical/high forge proposals filed by the
  2026-06-16 smoke run and promote only approved, actionable fixes into
  concrete plan work packets.
- blocker: none
- evidence_required:
  - network-isolation regression is either escalated as a release blocker or
    rejected with evidence
  - Git PII scrub is either packetized or rejected with evidence
  - podman-in-forge rootless feasibility is either packetized or deferred with
    rationale

## Proposed / Needs Triage

These are visible because they affect security, privacy, or local build
ergonomics, but they are not implementation-ready until the triage packet above
accepts them.

- `plan/forge-improvements/proposals/2026-06-16-network-isolation-regression.md`
- `plan/forge-improvements/proposals/2026-06-16-git-pii-scrub.md`
- `plan/forge-improvements/proposals/2026-06-16-podman-in-forge.md`

## Manual Or Deferred

### m8/appkit-action-smoke-and-stub-polish

- status: blocked
- owner_host: macos
- source: `plan/issues/osx-next-work-queue-2026-05-25.md`
- blocker: user-attended macOS click smoke. Autonomous build/test evidence is
  green; this is not claimable by an unattended implementation agent.

## Recently Closed This Coordination Pass

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
