# Tasks

Planning artifacts are complete; every implementation task below remains unchecked. Existing remedy packets keep ownership. The supplemental capability governs evidence and acceptance, not a new compatibility fallback or a second identity implementation.

## 1. Inventory and evidence integrity

- [ ] 1.1 Under 1688-ideu, enumerate actual launched roles and caller/listener edges, including git fetch/push, inference clients, probes, browser/router/backend and Vault CLI paths; verify zero rows, a missing launched role and an unclassified listener each fail the inventory fixture.
- [ ] 1.2 Implement the bounded evidence schema and trusted producer validation for release/instance/platform/control/result; verify forged agent records, stale instance/release evidence and missing observations fail the checker, and credential canaries never appear in its scoped output.
- [ ] 1.3 Bind executable tests for each runtime-security-evidence requirement in the project's litmus registry when created; verify a removed binding or absent negative control prevents hardened acceptance, and document the exact runtime probe commands beside the verifier.
- [ ] 1.4 Bind evidence to policy/configuration/trust generations and a declared finite age; verify same-instance policy reload, permissive switch, trust replacement, credential transition, listener rebinding and age expiry invalidate affected evidence until revalidation.

## 2. SELinux and runtime boundaries

- [ ] 2.1 Extend 1252-qyii and 1693-9qfb's inventory to global mode, loaded policy hashes, permissive domains, process/object labels, effective seccomp/caps and mount/device seams; verify host-enforcing plus typepermissive Vault fails the confinement claim and unavailable host state cannot pass.
- [ ] 2.2 With 1693-9qfb, reconcile policy.rs and active hardening specs, including the Vault fallback, and record the operator's normal-launch disposition for unsupported SELinux in the owning change; verify each label-disable exception has narrow scope, owner, expiry and removal packet, and never counts as enforced protection.
- [ ] 2.3 Under 1694-j2sk, add controlled reachable file/socket cross-lane fixtures that isolate the MAC decision from DAC/network/application refusal; verify allowed same-lane work and forbidden foreign-lane access with matching AVCs, and show disabling the intended MAC policy makes its denial control fail.
- [ ] 2.4 Add deployed AF_VSOCK syscall refusal probes for each Linux host/guest backend without weakening the production filter; verify an isolated fixture with the intended seccomp restriction removed fails the barrier test, and retain argv-shape regression checks.
- [ ] 2.5 Attach a bounded sanitized AVC corpus to 1252-qyii for builds, agent launch/teardown, previews, sibling launch, Chromium-framework, credential refresh and GPU inference; verify workload duration/population are recorded and each policy adjustment repeats both allowed and forbidden operations.

## 3. Workload authentication and authorization

- [ ] 3.1 Under 142, first demonstrate in an isolated adversarial fixture that release bytes derive the current PSK, then provision non-public scoped identity material through a reviewed trusted path; verify public release bytes alone and another boot/install's credentials cannot authenticate, while the legitimate peer succeeds.
- [ ] 3.2 Under 1689-echb, 1690-iqh5 and 1691-96gk, reconcile the draft identity spec with per-service/action/resource authorization and exact expected server identities; verify certificate A plus token B, wrong-service server certificates, cross-lane requests and caller-forged identity headers refuse.
- [ ] 3.3 Under 1692-37qz, trace the accepting socket path through kernel peer/cgroup lookup and process lifetime binding; verify same UID/foreign container, PID reuse, stale entries, vanished cgroup and restart refuse, and legitimate lane requests succeed without treating MCS as peer attestation.
- [ ] 3.4 Under 1684-tx37's identity work, document finite credential/session lifetime, renewal failure, key rotation, bundle rollover and stopped-lane invalidation policies per service; verify renewal outage through expiry, old/new trust overlap and an already established connection losing authorization within its declared bound.

## 4. Transport and CA refusal controls

- [ ] 4.1 Extend 1690-iqh5 to migrate pipeline.rs, semantic_expert.rs and all embedding/expert clients with the inference frontend; verify actual HTTPS/mTLS calls succeed and unknown CA, wrong service, expired credentials, plaintext retry and direct engine-port access fail.
- [ ] 4.2 Under 1685-kwmr and 1688-ideu, protect and test mirror fetch separately from push, and reproduce the known-hosts-write error branch; verify unwritable trust material and absent SSH lane identity never attempt anonymous receive or unverified SSH, and record the explicit protected-fetch policy.
- [ ] 4.3 Under 1688-ideu/1691-96gk, replace readiness/browser verification bypasses with scoped verified trust or a reviewed exception that cannot satisfy TLS acceptance; verify wrong hostname/service, expiry, unknown key and unapproved redirect refusal on each caller path.
- [ ] 4.4 Under 1689-echb, classify the Vault exec loopback CLI boundary and remove skip-verification or record its exact exception; verify the chosen CA/client identity policy and that no broader network path inherits a loopback exemption.
- [ ] 4.5 Under 1688-ideu, test real CA parsing, trust reload/rotation and public-root preservation in the forge, inference and browser language/runtime clients; verify malformed PEM, stale bundle and unauthorized trust replacement fail without logging private material.

## 5. Integrated acceptance

- [ ] 5.1 Run the bound controls on native Linux and separately in macOS/WSL Linux guests, recording actual kernel/policy support; verify unavailable/skipped controls block that platform's hardened acceptance and cannot borrow another platform's evidence.
- [ ] 5.2 Pair the complete adversarial matrix with approved build tools, sibling launch/monitoring, Chromium-framework, local inference and scoped diagnostics; verify supported workflows remain productive without broad exemption flags or direct runtime sockets.
- [ ] 5.3 Publish the verifier results and remaining exceptions through the existing plan/evidence paths; verify release/instance binding, no secret canaries and no false enforced/healthy projection, then review before any activation or archival claim.

## Workflow follow-up

- Sync/archive only after executable bindings and the required platform runtime evidence exist. Draft syntax validation is not enforcement verification.
- Integrate through linux-next's normal gated landing flow; this planning pass does not authorize runtime rollout, SELinux toggles or new UX.
