# Proposal: Fix proxy-container spec security boundary

## Problem

The proxy-container spec is materially wrong about a security-critical boundary. The spec claims:

> "SNI-based HTTPS filtering (no TLS interception)"

But the actual implementation has:

1. **Full ssl-bump MITM infrastructure** via squid on both ports (3128, 3129)
2. **Ephemeral CA chain generation** (`src-tauri/src/ca.rs`) producing root + intermediate certs on every launch
3. **Dual-port architecture**: port 3128 (strict, allowlisted domains) and port 3129 (permissive, all domains)
4. **Certificate injection** into forge containers via bind-mount + environment variables (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`)
5. **splice-all mode** currently active (passthrough), but the architecture is one config line away from active interception

The spec's claim of "no TLS interception" gives false assurance. The infrastructure for interception is fully deployed. Only the squid bump policy (`ssl_bump splice all`) prevents active decryption.

## Scope

Spec-only change. No code modifications. Update `openspec/specs/proxy-container/spec.md` to honestly describe:

- The ssl-bump MITM architecture with ephemeral CA chain
- The splice-all default (passthrough, no decryption currently)
- The dual-port architecture and their different access policies
- That image builds intentionally bypass the proxy
- The allowlist filtering mechanism and its categories
- The security implications, trust model, and key material lifecycle
- Under what conditions bumping would be enabled (currently: never)

## Why now

A methodology audit surfaced this divergence. This is the most dangerous category of spec drift: a security boundary described incorrectly in the authoritative document. The spec must be corrected before any further proxy work.
