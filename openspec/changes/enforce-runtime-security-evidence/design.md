# Design

## Context

See proposal.md for motivation. This is a verification supplement to `workload-identity-plane`, not a competing identity architecture. Audit baseline: `linux-next@b476105364b876034b002f15c1605151a6c9f6ea`, 2026-10-18. These observations describe that checkout; a repository finding does not prove a deployed host's mode.

| Confirmed observation | Evidence | Existing owner |
|---|---|---|
| Mandatory `label=disable`; other label options classified as weaker | `crates/tillandsias-podman/src/policy.rs:17-22,214-219`; `container_spec.rs:130-146` | 1252-qyii, 1693-9qfb |
| Vault domain explicitly permissive; launcher can fall back to label disabling | `images/selinux/vault_container.cil:41`; `vault_bootstrap.rs:4386-4407` | 1252-qyii, 1693-9qfb, 1694-j2sk |
| Default seccomp is the documented forge-to-guest AF_VSOCK barrier | `crates/tillandsias-headless/src/main.rs:22661-22735` | 1692-37qz, 309 |
| Control PSK derives from public binary digest and public context | `crates/tillandsias-secure-channel/src/lib.rs:67-119,143-192`; `vsock_server.rs:110` | 142, 1684-tx37 |
| Expert client rejects HTTPS and sends HTTP over TcpStream | `crates/tillandsias-plan/src/pipeline.rs:130,173-218`; `semantic_expert.rs:293` | 1690-iqh5 |
| Mirror fetch deliberately uses anonymous git:// even with SSH push | `crates/tillandsias-headless/src/main.rs:14370`; `images/default/lib-common.sh:768,1179` | 1685-kwmr, 1688-ideu |
| Anonymous receive-pack remains enabled | `images/git/entrypoint.sh:512` | 1685-kwmr, 451 |
| Known-hosts write failure has no explicit refusal arm | `crates/tillandsias-headless/src/main.rs:14386` | 1685-kwmr; test effective fallback before claiming bypass |
| Readiness client accepts invalid certificates and follows redirects | `crates/tillandsias-headless/src/main.rs:16274-16275` | 1688-ideu, 1691-96gk |
| Vault CLI exec uses HTTPS loopback with VAULT_SKIP_VERIFY=true | `vault_bootstrap.rs:2678,2721` | 1688-ideu, 1689-echb; verification bypass, not plaintext |
| Router retains HTTP :8080 as well as TLS :8443 | `images/router/base.Caddyfile:18` | 1691-96gk |
| Chromium uses enclave-key SPKI certificate-error exemption | `browser_open.rs:416`; WebKit CA bundle at :431 | 1688-ideu, 1691-96gk |
| SSH sidecar renews certificates over an existing key | `images/git/ssh-lane-sidecar.sh:155,228` | 1689-echb, 1684-tx37 |

Live evidence is limited to this forge process: `spc_t:s0`, zero capability sets, `NoNewPrivs=1`, `Seccomp=2`; AF_VSOCK socket creation returned EPERM. `/sys/fs/selinux/enforce` was unavailable. These observations do not prove global enforcing mode, the effective full policy, or other hosts' behavior. No production endpoint impersonation, credential reads or privilege changes were performed.

Overlap review found `1684-tx37` pending with eleven unchecked tasks, `1252-qyii` ready, `142` pending, and the implementation children ready. The folded security-tagged in_progress query returned no rows; broader in_progress work includes credential/launch and browser efforts. This is ledger evidence, not proof no agent has unreported private work. No message was sent to external agents. The unrelated six forge-environment build failures are already recorded by 1780-jxc3; reuse it rather than file a duplicate.

## Goals / Non-Goals

Create evidence that can falsify enforcement claims at the actual deployed boundary, and preserve approved development workflows under those controls. Keep Vault as the authority and the existing SPIFFE-inspired naming choice. This does not adopt SPIRE or claim full SPIFFE API/SVID conformance; those require separate compatibility evidence. Operator ruling 2026-10-18: pending/unavailable/reduced SELinux does not block launches and needs no per-launch approval. Log actual state, affected role, missing protection and reason; full-hardening claims still require proof. Accurately described reduced-security releases remain allowed. This is not a waiver of other security boundaries.

## Decisions

### Bind observations to the deployed runtime

The trusted host/guest verifier records release digest, instance identifier, platform/kernel, role and listener population, observation time, collector authority, control result and bounded evidence references. Bind relevant policy/configuration/trust generations and a finite maximum evidence age. Policy reload, enforcement-mode change, trust replacement, credential transition and listener rebinding invalidate affected evidence even within the same launch; revalidation is required before acceptance resumes. Agent-readable projections exclude secrets, host-sensitive paths and unrelated lane identifiers. Forged agent log text cannot become verifier evidence. The checker compares expected launched roles/listeners to the observed inventory; zero rows and missing roles fail rather than pass vacuously.

Do not add a second event transport for these records. Use the existing diagnostic/provenance paths with scoped projection. The coordinator's review of 1779-sq9g already identifies runtime-diagnostics-stream's session-scoped ring buffer as the diagnostic baseline; storage/broker adoption is outside this change.

### Verify the kernel decision, not just configuration

Report separately: host/guest LSM mode, loaded policy modules and hashes, permissive domains, actual process type/MCS, relevant file/socket types/MCS, effective OCI seccomp and capabilities, mount/device seams, and a policy denial with matching subject/object context. A role with `typepermissive` fails its enforcement claim even when global mode is enforcing. Label disabling does not collect the denials that the intended confined domain would produce.

Use bounded per-domain audit collection on representative workloads, then reviewed least-privilege changes. Never globally disable SELinux or blindly turn every AVC into an allow rule. Do not indiscriminately relabel shared Nix stores, compositor sockets, driver mounts or system trees. Each seam needs its owning role and resource policy.

For cross-lane tests, arrange a reachable controlled test file/socket and show that DAC/network permit the attempted operation before attributing a denial to MAC. Independently test the kernel-peer checker with MAC not deciding the result, and MAC denial with application-peer checks not deciding it. The application remains usable under the production composition. Probe AF_VSOCK creation on native Linux, the macOS Linux guest and the WSL guest; fixture argv checks remain useful but insufficient.

### Authenticate identity and then authorize capability

Use the existing identity grammar, but verify server service identity/trust domain as well as chain validity. A client certificate's lane, a token's lane and the requested target must agree or match an explicit grant. Deny valid certificate A plus token B. Proxy-provided identity is accepted only from an authenticated authorized proxy that strips caller-supplied identity fields. Backend ports cannot bypass the front.

SO_PEERCRED and cgroup/container membership need correct namespace handling and process-lifetime binding; a PID-only map is not enough. MCS is a second access-control layer, not sufficient caller attestation. The draft workload-identity alternative allowing MCS alone must be reconciled by the owning change before implementation is accepted.

### Separate version binding from cryptographic authentication

Retain digest/version binding as a compatibility constraint. Provision a real per-install/boot secret or an equivalent authenticated key channel using the existing trusted provisioning boundary; define confidentiality, rotation and peer scope before coding order 142. A party that knows only release bytes must fail the negative handshake control. This remedy still does not imply measured boot or hardware-backed attestation. Debug/public seeds cannot satisfy hardened acceptance.

### Inventory complete paths

For every edge record caller, listener, bind address, network/namespace, effective transport, authenticated client/server identity, allowed actions/resources, credential/trust source, reload/rotation behavior, direct backend reachability and test owner. Include git fetch separately from push; HTTPS egress separately from inbound inference; readiness separately from actual application calls. SSH, kernel-isolated local sockets and Noise are assessed according to their properties; HTTPS is not the sole acceptable transport.

Inference migration includes all expert/embedding clients, not only a frontend. Test valid trust and identity, unknown CA, wrong service, expiry, plaintext and direct backend refusal. A TLS backend on loopback or a private socket can remain plaintext only inside an explicitly reviewed isolation boundary; a shared enclave network alone is not that boundary. Remove broad skip-verification/probe exemptions or inventory them as exceptions that cannot count as verified TLS. CA trust updates must preserve required public roots where appropriate and validate real certificates, not only PEM delimiters.

### Make lifecycle bounds explicit

Each service declares maximum credential lifetime and connection authorization age, renewal deadlines/backoff, private-key rotation policy, bundle overlap, restart behavior and stopped/revoked-lane invalidation. No numeric revocation SLA is invented in this audit: acceptance is blocked until the owner chooses a finite bound and proves it. Token revocation alone does not revoke already signed certificates. Renewal of an existing key is not private-key rotation.

### Keep existing implementation ownership

Append audit evidence/refusal criteria to 1252, 142 and 1684's children; do not reset their statuses or leases. Add one verification-integration packet for this supplemental contract. Individual remedies remain with their existing owners. Specific unresolved paths (the known-hosts failure and peer-table accepting call path) remain hypotheses to reproduce, not declared exploits.

## Risks / Trade-offs

- Confinement can break legitimate browsers/GPU/builds -> pair every denial with allowed workflow coverage and narrow policy review.
- Platform support can be overstated -> require independent native Linux and Linux guest evidence; absent/unavailable is never pass.
- Probes may pass for the wrong reason -> control reachability and independently weaken each layer in isolated fixtures.
- Certificate renewal can leave old sessions authorized -> measure maximum session age and revoke/stop handling as well as new handshakes.
- More claims than executable tests -> remain draft until each requirement has a bound falsifiable test, including mutation controls and runtime evidence.
- Full-hardening claims and launch availability are separate -> reduced SELinux is supported with truthful logs, while identity/authorization/transport/seccomp/capability boundaries remain required.

## Migration Plan

1. Reconcile the active hardening specs with the existing workload-identity change, including permissive Vault policy and domain-specific exceptions. Apply the operator's ruling: pending/reduced/unavailable SELinux must not block normal launches; logs state the limitation and no full-hardening claim is made.
2. Implement inventory and evidence validation with unknown/missing/stale/forged evidence controls. Bind the tests when created; no nonexistent litmus is declared delivered here.
3. Implement existing remedy packets in dependency order, proving current failures before each fix. Migrate clients and services together; do not retire a protected path until replacement positive and negative controls pass.
4. Exercise supported native/guest platforms and representative productive workloads. Attach sanitized runtime evidence to the ledger; a fully hardened designation cannot substitute static tests or a different platform's result. A truthful reduced-security release or launch is not blocked merely by SELinux limitations.
5. If a hardening change breaks an approved workflow, stop promotion and repair the narrow policy/seam. Do not silently roll back to anonymous traffic, label disabling or verification bypass.

## Sources and Limits

Official sources reviewed 2026-10-18: [Podman run](https://docs.podman.io/en/latest/markdown/podman-run.1.html), [SPIRE concepts](https://spiffe.io/docs/latest/spire-about/spire-concepts/), [SPIFFE concepts](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/), [X.509-SVID profile](https://github.com/spiffe/spiffe/blob/main/standards/X509-SVID.md), [Red Hat SELinux](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_selinux/using_selinux). SPIRE uses independently verified node and process properties; a URI-shaped SSH Key ID is not an X.509-SVID and a custom sidecar is not the Workload API.

MCP-first reads used project-info and folded plan queries. Broad plan questions were unsupported and spec RAG reported no index; file discovery was the documented unavailable fallback. No host-level enforcement evidence exists from this forge audit beyond the process observations above. No production changes are implied by a validated planning artifact.
