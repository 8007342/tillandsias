<!-- @trace spec:nix-cache-service -->
# nix-cache-service Specification

## Status

active

## Purpose

Serve the persistent host nix store (order 795-h8er) to the enclave as a nix
binary cache, so an ephemeral forge lands on a warm cache without any host path
being mounted into it.

Storage does not need a container; SERVING does. The 795-h8er store stays
exactly as it is and keeps serving host-side builds directly. What this spec
adds is a way for a container that is not allowed to see host paths to benefit
from that store anyway, using nix's own substituter protocol.

The alternative — bind-mounting the host store into the forge — is rejected on
three grounds recorded in order 801-kqme: it inverts the forge-offline default
that the host-mount guard (order 437) exists to protect; nix validity is not
bytes on disk, so a read-only `/nix/store` without the SQLite db yields paths
nix will not consider valid, and sharing a writable db across concurrent forges
is a corruption surface; and it couples every forge to a host path layout,
which is what makes one image behave differently across platforms.

## Requirements

### Requirement: The cache is a first-class enclave service
<!-- req-id: 24b8db69 -->

The system MUST serve the binary cache from a container attached to the
`tillandsias-enclave` network under the network alias `nix-cache`, reachable by
that DNS name from other enclave containers. It MUST NOT be a host-loopback-only
listener, because the enclave is created `--internal` and a forge cannot reach
a host loopback.

The service MUST mount the persistent store READ-ONLY. It MUST NOT require
write access to the store's SQLite database, so that host builds may continue
writing to the same store concurrently with no shared mutable state.

@trace spec:nix-cache-service

#### Scenario: An enclave container fetches from the cache by DNS name
- **WHEN** a container on `tillandsias-enclave` requests `https://nix-cache:5000/nix-cache-info`
- **THEN** the service MUST respond with `StoreDir: /nix/store`
- **AND** the requesting container MUST NOT have any host path mounted into it

#### Scenario: The store is served without write access
- **WHEN** the service container is started
- **THEN** the store MUST be mounted read-only
- **AND** the service MUST answer narinfo and nar requests successfully

#### Scenario: No host store is mounted into the forge
- **WHEN** a forge container is launched
- **THEN** no host nix store path may be bind-mounted into it as a consequence of this service

### Requirement: The cache hostname bypasses the enclave proxy
<!-- req-id: 4ecd56d1 -->

The system MUST include `nix-cache` in the enclave `no_proxy`/`NO_PROXY` set.
The cache's transport is HTTPS, which consults `https_proxy`; without the name
present, every substituter request is sent to squid as a CONNECT and is reset.
The enclave subnet entry does not cover this case, because `no_proxy` is
matched against the hostname as written rather than the address it resolves to.

@trace spec:nix-cache-service

#### Scenario: Enclave client reaches the cache without traversing squid
- **WHEN** an enclave container with the standard proxy environment requests `https://nix-cache:5000`
- **THEN** the request MUST NOT be routed through the proxy
- **AND** the request MUST succeed

### Requirement: Transport trust and content trust are BOTH enforced
<!-- req-id: a8d47aec -->

The system MUST satisfy two independent trust properties. They are different
properties and neither substitutes for the other.

TRANSPORT: the service MUST present a TLS leaf minted from the stack CA, with
`nix-cache` among its subject alternative names, matching how the vault leaf is
minted. A client that does not trust the stack CA MUST fail to complete the
handshake.

CONTENT: the service MUST sign served paths with an ed25519 binary-cache key,
and clients MUST verify against `trusted-public-keys` with `require-sigs`
enabled. The system MUST NOT instead mark the cache as a trusted substituter to
skip signature verification, because that means "accept whatever this host
sends" and discards the integrity property that makes a shared cache safe under
concurrency.

The signing secret key MUST be generated on the host, MUST live outside the
repository and outside every container image, and MUST NOT be imported from or
exported to any other host without an explicit operator decision (order
790-6n2k).

@trace spec:nix-cache-service

#### Scenario: Client without the stack CA is refused
- **WHEN** a client requests the cache over TLS without the stack CA
- **THEN** the TLS handshake MUST fail

#### Scenario: Path signed by the cache key is accepted
- **WHEN** a client with `require-sigs` true and the cache's public key in `trusted-public-keys` substitutes a path
- **THEN** the path MUST be accepted

#### Scenario: Path not signed by a trusted key is refused
- **WHEN** a client substitutes from the cache with a different key in `trusted-public-keys`
- **THEN** nix MUST refuse the path with "lacks a signature by a trusted key"
- **AND** no store path may be added

#### Scenario: Signing key stays out of images
- **WHEN** any container image is built
- **THEN** the binary-cache secret key MUST NOT be present in it

### Requirement: An unreachable cache degrades to silence, not to failure
<!-- req-id: 35d091e6 -->

When the cache is not answering, the system MUST emit no substituter flags at
all. A dead substituter in a build's flag list is worse than no substituter,
because nix retries it for every path. Absence of the service MUST leave build
behaviour exactly as it was before the service existed.

@trace spec:nix-cache-service

#### Scenario: Substituter flags withheld when the cache is down
- **WHEN** the cache is not reachable
- **THEN** the substituter-args surface MUST emit nothing
- **AND** MUST exit successfully

### Requirement: A running but untrusted cache is a violation, not a skip
<!-- req-id: 287020a3 -->

Verification MUST distinguish "the service is absent" from "the service is
running but its trust properties fail". The former MAY skip; the latter MUST
report a violation. A guard that goes quiet exactly when trust breaks is the
failure class this requirement exists to prevent.

@trace spec:nix-cache-service

#### Scenario: Absent service skips
- **WHEN** the cache container is not running
- **THEN** the fixture MUST skip

#### Scenario: Running service with an untrusted leaf fails loudly
- **WHEN** the cache container is running but presents a leaf not minted by the stack CA
- **THEN** the fixture MUST report a violation rather than skipping
