# proxy-container Specification (Delta)

## Change: fix-proxy-spec-security-boundary

Corrects the security boundary description. The previous spec claimed "SNI-based HTTPS filtering (no TLS interception)" which is materially wrong. The implementation has full ssl-bump MITM infrastructure with an ephemeral CA chain, currently operating in splice-all (passthrough) mode.

### What changed

1. **Purpose**: Rewritten to describe ssl-bump MITM architecture with ephemeral CA chain
2. **Requirement: Caching HTTP/HTTPS proxy**: Replaced "SNI-based HTTPS filtering (no TLS interception)" with accurate description of ssl-bump infrastructure in splice-all mode
3. **NEW Requirement: Ephemeral CA chain**: Documents the full cert chain lifecycle (root + intermediate, tmpfs, per-launch generation)
4. **NEW Requirement: Dual-port architecture**: Documents ports 3128 (strict) and 3129 (permissive) with their different access policies
5. **NEW Requirement: Image builds bypass proxy**: Documents that build-time containers do not route through the proxy
6. **NEW Requirement: CA chain injection into forge containers**: Documents bind-mount + environment variable trust injection
7. **NEW Requirement: SSL bump policy and future activation**: Documents splice-all default, no-bump domains, bump domains, and conditions for enabling active interception
8. **Updated scenarios**: All scenarios now reflect the actual MITM-aware architecture
