# Active Plan Frontier

Last updated: 2026-06-16T11:10:00Z

This file is the first stop for agents inspecting `plan/issues/`. Historical
issue reports remain in this directory for evidence and auditability, but only
the items below are immediate work.

## Immediate

### forge-git-identity-anonymization → transparent agentic attribution (REDESIGNED)

- status: ready
- owner_host: linux
- source: `plan/index.yaml` order 53
- next_action: **DECISION MADE (operator, 2026-06-16): do NOT anonymize.**
  Preserve the real GitHub-login username/email as the commit AUTHOR, and add
  machine-parseable agent/model attribution trailers so Claude/ChatGPT/OpenCode/
  Antigravity/local-model commits are distinguishable (`Co-Authored-By` +
  structured `Generated-By: tool=… model=… params=…`; encode size/quant for
  local models). Implement at the container_profile / commit-trailer layer.
- blocker: none (was blocked-on-decision; now resolved)
- convention + sources: `cheatsheets/concurrent-git/commit-attribution.md`
- evidence_required:
  - real GitHub-login author/email preserved on forge commits (attribution intact)
  - each forge commit carries a machine-parseable agent+model trailer
  - different agents/models → distinguishable trailers (local models include params)

### enclave/network-level-egress-deny

- status: ready
- owner_host: linux
- source: `plan/issues/enclave-egress-network-enforcement-gap-2026-06-16.md`
- next_action: Make `tillandsias-enclave` `--internal` so forge containers have
  no NAT egress; route allowlisted egress only through the dual-homed proxy.
- blocker: none
- evidence_required:
  - direct (`--noproxy`) external curl from an enclave container FAILS on a clean init
  - allowlisted proxy egress + forge→proxy/inference/git-service still work
  - new litmus pins direct-egress-denied on the live enclave network
- note: corrects the cycle-1 rejection below — enclave egress is
  proxy-cooperative, not network-enforced (empirically: direct curl reaches the
  internet, HTTP 200). Verify-heavy (rebuild + reinit), so its own cycle.

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
