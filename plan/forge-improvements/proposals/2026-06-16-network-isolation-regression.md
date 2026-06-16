---
title: Fix recurring network isolation regression (external_curl reaches internet)
gap: "isolation_or_privacy_risks: network_isolation.external_curl fails — forge container reaches external internet directly, bypassing proxy block"
category: network
status: reopened
proposed_at: 2026-06-16T08:00:00Z
triaged_at: 2026-06-16T09:40:00Z
retriaged_at: 2026-06-16T11:10:00Z
retriage_decision: >
  SUPERSEDES the rejection below. The rejection relied on the diagnostics
  external_curl probe + litmus-ephemeral-guarantee, both of which only test the
  PROXY-COOPERATIVE path (proxy-aware curl / --network=none). Direct egress on
  the live enclave network was never tested. On re-test it SUCCEEDS (HTTP 200):
  enclave egress is proxy-cooperative, not network-enforced. Reframed and
  reshaped as plan/issues/enclave-egress-network-enforcement-gap-2026-06-16.md
  (packet enclave/network-level-egress-deny). Not a flapping regression — a
  standing architectural gap.
triage_decision: >
  REJECTED as a release blocker — the 2026-06-14 external_curl regression does
  not reproduce on 2026-06-16. Both 2026-06-16 diagnostics runs report
  network_isolation passing at 100% (25/25, no isolation/privacy risks). One
  follow-up backlog item filed (enclave-network egress litmus). See triage note.
changes:
  - file: images/proxy/Containerfile
    description: |
      Diagnose and fix the recurring external_curl regression observed in
      diagnostics runs from 2026-06-14. The proxy egress isolation (previously
      addressed in proposal 2026-05-28-proxy-egress-isolation) is not holding
      — external curl is reaching example.com directly rather than being blocked
      at network level.
  - file: images/default/Containerfile
    description: |
      Verify iptables/nftables egress deny rules are applied at container start.
      Consider adding runtime verification in entrypoint.
---

## Gap

Two diagnostic runs on 2026-06-14 (`diagnostics_20260614T150524Z-summary.md` and
`diagnostics_20260614T230648Z-summary.md`) report that `network_isolation.external_curl`
is **failing**: the forge container can reach external internet directly.

The earlier proposal `2026-05-28-proxy-egress-isolation` (status: implemented)
was supposed to address this via TCP-reset/connection-drop rules, but either:
- The fix was not applied to the running forge instance, or
- The fix regressed in a later image rebuild, or
- The fix only covers the proxy layer and not a direct egress path

## Evidence

- `diagnostics_20260614T150524Z-summary.md`: completeness dropped to 96%,
  `network_isolation.external_curl` failing
- `diagnostics_20260614T230648Z-summary.md`: completeness 96%,
  `network_isolation.external_curl` failing again
- Affected forge version: 0.3.260614.x

## Privacy/Isolation Assessment

This is a **critical isolation regression**. The forge container should not be
able to reach external internet directly. Any tool or agent running inside the
forge could exfiltrate data or download unauthorized content. This must be
fixed before any other proposals are implemented.

## Recommended Approach

1. Investigate whether the iptables/nftables rules from the previous fix are
   present in the current image.
2. Verify the rules are applied at container start (entrypoint vs image build).
3. Add a runtime check in the forge entrypoint that verifies egress isolation
   and fails fast if it's missing.
4. Consider a dual-layer approach: proxy-level deny AND iptables egress drop.

## Triage decision — 2026-06-16 (linux, coord/critical-forge-proposal-triage-20260616)

**REJECTED as a release blocker. Not currently reproducing.**

Evidence the regression is resolved on the current head (`591d4dde`,
v0.3.260616.2):

- `plan/diagnostics/diagnostics_20260616T072847Z-summary.md` — completeness
  100% (25/25), no `isolation_or_privacy_risks`.
- `plan/diagnostics/diagnostics_20260616T081755Z-summary.md` — completeness
  100% (25/25), no `isolation_or_privacy_risks`. `external_curl` reports BLOCKED.
- `target/build-install-smoke-e2e/20260616T081336Z/01-build-install.log` —
  `litmus:ephemeral-guarantee` ("attempt external network connection from
  forge") and `litmus:forge-as-only-runtime` both PASS in the runtime residual
  litmus phase.

**Caveat (filed as a low-priority backlog follow-up, NOT a blocker):**
`openspec/litmus-tests/litmus-ephemeral-guarantee.yaml:19` exercises egress with
`--network=none`, which trivially blocks all traffic and does **not** exercise
the *enclave-network* egress-deny path that the 2026-06-14 regression actually
lived on. The diagnostics' `external_curl` check (run on the real enclave
network) is currently the only signal that catches that regression class.
Recommend adding an enclave-network egress litmus so a re-regression is caught
at build time rather than only by the in-forge diagnostics pass. Tracked in the
forge backlog as `litmus/enclave-network-egress-deny` (low priority — the
behavior is currently correct; this is detection hardening only).

