# Proposal

## Why

Tillandsias declares strong isolation but currently mandates `label=disable`, ships a permissive Vault SELinux domain, exposes plaintext service paths, and derives control-channel authentication material from public release bytes. Existing work already owns the remedies; this change adds an evidence contract so configured intent cannot be reported as enforced protection.

## What Changes

- Add machine-verifiable posture evidence for every shipped container role, listener, caller and platform, tied to the actual release and runtime instance.
- Require independent positive and negative runtime controls for SELinux, peer identity, authorization, transport confidentiality and CA validation. Static flags, manifests and test skips cannot establish enforcement.
- Distinguish host enforcing state, domain permissiveness, process/file/socket labels, effective policy and observed denial.
- Require authorization of action/resource after authentication, including cross-lane certificate/token mismatch refusal.
- Require cryptographic peer authentication to include non-public independently provisioned material; a public binary digest establishes version compatibility, not workload attestation.
- Inventory plaintext paths and bypasses; prohibit unreviewed downgrade or exposed backend routes. Local Unix sockets are assessed by kernel isolation/peer checks rather than renamed HTTPS.
- Extend the existing implementation owners `1252-qyii`, `142`, and `1684-tx37`/`1685-kwmr` through `1694-j2sk`; do not replace them or introduce SPIRE daemons.
- **BREAKING**: when adopted, unsupported or unverified protection cannot satisfy hardened runtime/release acceptance. This supplemental change does not choose normal-launch compatibility on hosts lacking SELinux; that decision remains with the existing enforcement change and the operator's pending clarification. No reduced-security exception is authorized here.

## Capabilities

### New Capabilities

- `runtime-security-evidence`: trustworthy runtime evidence and acceptance gates for container confinement, authenticated service access and protected transport.

### Modified Capabilities

None in this change. Existing `workload-identity-plane` owns identity/enforcement deltas, including reconciliation of the active `security-privacy-isolation` hardening flags. This supplemental capability governs what evidence can substantiate them.

## Impact

Affected integration points: Podman policy and actual launchers, SELinux CIL loading, lane MCP/SSH sockets, secure-channel key provisioning, Vault PKI clients, inference clients/frontends, router/proxy and mirror paths, release/platform acceptance tests. No runtime implementation, privileged host operation, CA rotation, UX alteration or deployment occurs in this planning pass. Verification is draft until executable bindings and platform runtime evidence exist.

## Non-goals

Do not deploy SPIRE, broadly share logs, grant agents runtime sockets/keys, loosen confinement for compatibility, or equate syntactic SPIFFE IDs with SPIFFE conformance. Curated services remain available through narrowly authorized interfaces; project build tools remain free inside their intended sandbox.
