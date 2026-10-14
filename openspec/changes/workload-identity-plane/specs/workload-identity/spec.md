## ADDED Requirements

### Requirement: Every enclave workload has one SPIFFE-form name

Every workload that authenticates inside the enclave SHALL be named by a SPIFFE ID of the form `spiffe://<trust-domain>/project/<mirror-id>/lane/<instance>`, optionally followed by `/agent/<harness>`. The trust domain SHALL be derived once per host install, SHALL be a valid SPIFFE trust-domain name, and SHALL NOT encode the operator's identity, username or hostname. One parser SHALL be the only reader of these names; it SHALL refuse any other shape, a missing segment, an empty segment, and percent-encoded or dot segments. The name SHALL be carried in the SSH lane certificate's Key ID (not its principal), in the URI SAN of every lane client certificate, and in the commit provenance trailer.

#### Scenario: a lane cert names its lane

- **WHEN** the SSH lane sidecar obtains a signed certificate for a lane of mirror `m1`
- **THEN** the certificate's Key ID parses as a SPIFFE ID whose path begins `/project/m1/lane/`

#### Scenario: a malformed name is refused

- **WHEN** the parser is given `spiffe://td/project//lane/x` or `spiffe://td/project/m1/../m2/lane/x`
- **THEN** it refuses with a named reason and returns no identity

### Requirement: Enclave connections authenticate both ends

Every enclave service listener SHALL authenticate its client by one of: a lane client certificate chained to the enclave CA with a lane SPIFFE ID in its URI SAN; a kernel-attested socket peer; or SELinux MCS confinement of a socket file. Lane client certificates SHALL have a lifetime of at most one hour, `cA=false`, the clientAuth extended key usage and exactly one URI SAN. They SHALL be minted by a sidecar, so the workload never holds the CA key or the signing credential. A bearer token alone SHALL NOT be sufficient where a listener has moved to mutual TLS. A listener whose client authentication is `none` SHALL be listed by the enclave listener inventory with a named, dated waiver naming the packet that removes it.

#### Scenario: a token without a certificate is refused

- **WHEN** a client presents a valid Vault AppRole token over TLS without a lane client certificate, after Vault has moved to mutual TLS
- **THEN** the connection is refused during the TLS handshake

#### Scenario: an unclassified listener fails the inventory

- **WHEN** a launch spec opens a listener whose client-auth mode the inventory cannot classify
- **THEN** the inventory guard fails and names the listener

#### Scenario: an empty inventory is a failure

- **WHEN** the inventory guard finds zero listeners
- **THEN** it fails rather than passing over an empty population

### Requirement: Per-lane sockets attest their peer

A per-lane socket (the ssh-agent socket of the push lane, the lane control or MCP socket) SHALL admit a connection only when the kernel-reported peer (SO_PEERCRED pid and uid, and that pid's cgroup) belongs to the lane's own container. The check SHALL NOT trust anything the peer sends about itself. A refusal SHALL name the peer's container id.

#### Scenario: a sibling container sharing the volume is refused

- **WHEN** a container that is not the lane's own mounts the lane's socket volume and connects
- **THEN** the connection is refused and the refusal names the peer's container id

### Requirement: Agent commits carry a signed, per-project pseudonymous workload trailer

A commit made in a forge lane SHALL carry a `Tillandsias-Workload:` trailer naming the workload's SPIFFE path, with the lane instance replaced by a pseudonym, plus the agent harness and the model in clear. The pseudonym SHALL be an HMAC, under a per-project key held in Vault, over the lane instance, harness and model. The same lane, harness and model SHALL therefore yield different pseudonyms in different projects, and an outside reader SHALL NOT be able to join two projects' commits on it. The model string is self-reported by the harness and SHALL be described as such wherever it is displayed. The commit SHALL be signed with the lane's short-lived SSH certificate (`gpg.format=ssh`) through the sidecar's agent, so the forge never holds the key. The git mirror SHALL refuse at receive a forge commit that is unsigned or signed by a key outside the enclave SSH CA. This trailer is added beside the authorship of `forge-git-identity-anonymization` (the operator's GitHub App identity and Co-Authored-By trailers) and SHALL NOT replace it.

#### Scenario: two projects cannot be joined on the pseudonym

- **WHEN** the same lane instance, harness and model commit in projects A and B
- **THEN** the two trailers' pseudonyms differ, and each verifies only under its own project's key

#### Scenario: an unsigned forge commit is refused

- **WHEN** a forge pushes a commit that carries no SSH signature from the enclave CA
- **THEN** the mirror refuses the push and names the commit

### Requirement: SPIRE and JWT-SVIDs are not adopted

Tillandsias SHALL borrow the SPIFFE identity model without running SPIRE's server or agents, and Vault SHALL remain the only signing authority. JWT-SVIDs SHALL NOT be used for enclave-internal authentication; X.509 certificates over Unix or vsock sockets SHALL be used instead. A change that introduces either SHALL first amend this requirement with the measured reason.

#### Scenario: no bearer JWT inside the enclave

- **WHEN** an enclave service is moved off client-auth `none`
- **THEN** its new client authentication is a lane client certificate, a kernel-attested peer or MCS confinement, never a JWT
