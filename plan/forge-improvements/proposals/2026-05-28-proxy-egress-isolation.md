---
title: Investigate proxy egress isolation — HTTP 403 vs full block
gap: "isolation_or_privacy_risks: external curl returned HTTP 403 from proxy (Squid) rather than being completely blocked"
category: network
status: implemented
proposed_at: 2026-05-28T21:15:00Z
approved_at: 2026-05-29T02:10:00Z
approved_by: "Antigravity Orchestrator (Approved. Egress defense-in-depth is a fundamental security requirement. Enforcing TCP-level drops/resets at the proxy or via iptables prevents sophisticated tunneling/exfiltration vectors and strengthens the zero-trust isolation boundaries of the enclave.)"
changes:
  - file: images/proxy/Containerfile
    description: |
      Review Squid proxy rules — consider replacing HTTP denial with a TCP
      reset or connection-drop rule to prevent tunneling over allowed hosts.
      This is an ORCHESTRATOR-level change and must be reviewed against the
      privacy/isolation envelope before implementation.
---

## Gap

The diagnostics agent reports an isolation/privacy risk:

> "External curl returned HTTP 403 from proxy (Squid) rather than being
> completely blocked — the proxy permits outbound TCP connections and only
> denies at the HTTP layer; a tool that tunnels over HTTPS to an allowed
> host could bypass the block. Consider a network-level egress deny as
> defense-in-depth."

**Evidence**: `diagnostics_20260528T180225Z-summary.md`, `isolation_or_privacy_risks` array

## Context

The forge enclave proxy is a Squid instance that intercepts outbound HTTP
traffic. When an agent inside the forge tries to reach an external host, the
proxy returns HTTP 403 (forbidden). This means the TCP connection succeeded
but the HTTP request was denied. A sophisticated tool could tunnel through
an allowed HTTPS host and bypass the block.

## Recommendation

This is an ORCHESTRATOR-level concern because it involves the enclave
network architecture. Potential mitigations:

1. Configure Squid to reset TCP connections instead of returning 403
2. Add iptables/nftables egress deny rules as defense-in-depth
3. Remove the proxy allow-rule for outbound HTTP and rely solely on the
   enclave-internal MITM for permitted traffic

## Privacy/isolation safety

This proposal STRENGTHENS the isolation envelope and does not introduce
any new attack surface.
