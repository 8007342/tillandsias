---
title: Fix recurring network isolation regression (external_curl reaches internet)
gap: "isolation_or_privacy_risks: network_isolation.external_curl fails — forge container reaches external internet directly, bypassing proxy block"
category: network
status: proposed
proposed_at: 2026-06-16T08:00:00Z
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
