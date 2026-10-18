# Runtime security evidence

## Purpose

Define the evidence required to claim enforced container confinement, authenticated service access and protected transport across Tillandsias runtime platforms.

## ADDED Requirements

### Requirement: Posture evidence identifies the actual runtime

The runtime SHALL produce a bounded, secret-free security evidence record for each shipped role and reachable listener, bound to the release digest, launch instance and observing platform. Each control SHALL report enforced, failed, unavailable or unverified with evidence references. Configuration and static tests alone MUST NOT establish runtime enforcement.

#### Scenario: A container cannot observe host enforcement
- **WHEN** a forge cannot inspect the host or guest SELinux enforcement state
- **THEN** its record states unavailable for that observation
- **AND** it does not infer host enforcement from a flag or its own process label

#### Scenario: Evidence comes from another release or instance
- **WHEN** a gate receives evidence for a different release, runtime instance or platform
- **THEN** that evidence cannot satisfy the current runtime claim

### Requirement: Security changes invalidate prior evidence

Evidence SHALL bind to the effective policy, security configuration and trust generations and a declared finite maximum age. A relevant policy reload, enforcement-mode change, listener rebinding, trust replacement or credential transition SHALL invalidate affected evidence until revalidated. Unchanged release and launch identifiers MUST NOT preserve a stale acceptance verdict.

#### Scenario: Enforcement changes within the same launch
- **WHEN** a previously verified runtime changes a relevant policy, trust, identity or listener generation without changing its launch identifier
- **THEN** its prior affected evidence cannot satisfy hardened acceptance
- **AND** acceptance resumes only after the new state passes the required controls within the declared evidence age

### Requirement: SELinux claims distinguish independent enforcement states

A SELinux confinement claim SHALL identify global enforcing state, loaded policy, relevant permissive domains, actual process and object labels, and observed policy decisions. A permissive workload domain, disabled label separation or missing observation MUST NOT be reported as enforced confinement. The release acceptance gate SHALL require applicable positive and negative controls.

#### Scenario: Enforcing host contains a permissive Vault domain
- **WHEN** global mode is enforcing but the Vault workload domain is permissive
- **THEN** the Vault confinement evidence fails the enforcement claim
- **AND** a loaded module or chosen domain name does not convert that result to a pass

#### Scenario: Cross-lane denial is proved independently
- **WHEN** an enforcing runtime is evaluated for lane isolation
- **THEN** the owning lane's allowed file and socket operations succeed
- **AND** a foreign lane's equivalent forbidden operations fail with matching policy evidence
- **AND** the fixture makes the target reachable so missing mounts or unrelated network failure cannot masquerade as a policy denial

### Requirement: Workload authentication is independent of public release knowledge

Cryptographic peer authentication SHALL depend on non-public independently provisioned identity material and verified trust, with confidentiality and scope appropriate to the peer. Public release digests, caller-supplied labels and SPIFFE-shaped strings MUST NOT establish node or workload authentication. Version compatibility SHALL be reported separately from authentication.

#### Scenario: A peer knows every public release byte
- **WHEN** a test peer derives all material available from published binaries, versions and wire identifiers without possessing provisioned peer credentials
- **THEN** it cannot authenticate to a protected control listener

#### Scenario: A local peer identifier is stale
- **WHEN** a PID is reused, a cgroup disappears or a container restarts
- **THEN** an old identity association cannot authorize the new peer
- **AND** unresolved kernel identity is refused for privileged operations

### Requirement: Authenticated identities receive explicit scoped authorization

Every protected operation SHALL authorize its authenticated identity for the service, action and target resource. Independent credentials used together SHALL identify a consistent authorized subject. Socket isolation SHALL supplement peer authentication rather than replace it. Caller-controlled headers, labels, paths or tenant IDs MUST NOT widen scope.

#### Scenario: Valid credentials belong to different lanes
- **WHEN** lane A's valid client certificate is combined with lane B's otherwise valid token
- **THEN** the operation is refused before B's data or capability is exposed

#### Scenario: A valid identity requests another lane's resource
- **WHEN** an authenticated lane requests another lane's logs, preview, mirror action or credential issuance without an explicit grant
- **THEN** authorization refuses the operation
- **AND** merely trusting the issuing CA does not grant the request

### Requirement: Transport evidence covers every hop and caller

The transport inventory SHALL cover each caller-to-listener edge, including fetch, push, probes, redirects, proxies and backend ports. Protected network edges SHALL validate expected peer identity and confidentiality without silent plaintext retry or verification bypass. A local socket claim SHALL identify kernel access and peer checks; a TLS frontend SHALL NOT hide an exposed unauthenticated backend.

#### Scenario: Inference frontend becomes TLS-only
- **WHEN** an expert or embedding client calls the protected inference service
- **THEN** it succeeds with valid server trust and authorized client identity
- **AND** unknown CA, wrong service identity, expired certificate and direct engine-port bypass attempts fail
- **AND** no client retries over plaintext

#### Scenario: A readiness endpoint redirects elsewhere
- **WHEN** a probe redirects to an unapproved origin or an invalid certificate
- **THEN** it refuses without forwarding credentials or disabling certificate verification

#### Scenario: SSH trust cannot be written
- **WHEN** the mirror client's required known-hosts material cannot be installed
- **THEN** protected operations fail without anonymous receive or unverified SSH fallback
- **AND** fetch and push protection are tested as separate edges

### Requirement: Identity lifetime has observable refusal boundaries

Each credential-bearing service SHALL declare and test issuance authority, renewal and expiry handling, key rotation policy, trust-bundle rollover, stopped-lane invalidation and a finite maximum authorization lifetime for existing connections. Certificate renewal MUST NOT be reported as private-key rotation. Token revocation MUST NOT be assumed to invalidate previously issued certificates.

#### Scenario: Renewal authority is unavailable through expiry
- **WHEN** renewal fails until the existing identity expires
- **THEN** operations fail closed at the declared boundary
- **AND** no fallback extends the credential lifetime or admits anonymous requests

#### Scenario: A lane stops while a connection remains open
- **WHEN** a lane is stopped or revoked
- **THEN** its existing connection loses authorization within the service's declared finite bound
- **AND** the test measures that bound rather than checking only a fresh TLS handshake

### Requirement: Hardened acceptance cannot pass on missing tests

A hardened runtime or release acceptance verdict SHALL require successful applicable positive and negative controls for every supported platform and role. Skipped, unavailable, failed or stale controls SHALL block that verdict. A named exception SHALL carry an owner, narrow scope, expiry and remediation packet, and SHALL NOT count as enforced protection.

#### Scenario: A platform has no enforcing SELinux test evidence
- **WHEN** applicable SELinux enforcement cannot be tested on a supported platform
- **THEN** hardened acceptance is blocked for that platform
- **AND** another platform's success cannot satisfy it

#### Scenario: A security test is only a source-pattern check
- **WHEN** a static test finds the intended flags or policy text but no runtime denial was exercised
- **THEN** it is configuration evidence only and cannot satisfy the enforcement control

### Requirement: Productive workflows survive confinement without broad exemptions

Security acceptance SHALL pair each denied forbidden operation with allowed representative workflows: agent tools and builds, sibling launch and monitoring, Chromium-framework browsing, local inference and scoped diagnostics. Restoring a workflow MUST NOT silently disable labeling, peer verification, transport protection or the runtime's seccomp/capability baseline.

#### Scenario: A confined workflow encounters an access denial
- **WHEN** an approved build, browser or inference workflow is denied
- **THEN** remediation uses a reviewed narrow policy or runtime seam
- **AND** acceptance repeats both the allowed workflow and the forbidden-operation control
