# Proposal — workload-identity-plane

Umbrella packet: `1684-tx37` (milestone, desired_release v0.6). It builds on
`692-zjzg` and `methodology/philosophy.yaml` → `identity_plane_aspiration`.

## Why

The operator's direction (2026-10-14), after a study of SPIFFE and SPIRE
(Red Hat's topic page, the spiffe.io specs, the SPIRE docs):

- "inference and router and a bunch of services within our enclave are wide
  open, and would benefit from two-way tls in many other places as well";
- name identities in SPIFFE form, "popularize and extend" that naming, and give
  git commits "some non-aggregatable identity of the agent, providing project,
  lane, agent, model";
- for the per-lane sockets, "make sure there's plenty of SELinux enforcements
  on top of that to make it super-duper-extra strong".

Tillandsias already has three mechanisms in SPIFFE's shape:

- the SSH-CA push lane: the workload never holds the key, and certs are
  short-lived and renewed automatically;
- per-lane sockets that attribute a caller from the accepting listener;
- the host-guest channel key derived from the guest binary's digest.

What is missing is one name for a workload, any client authentication inside
the enclave, and SELinux separation between containers.
`--security-opt=label=disable` is today one of the four
`MANDATORY_HARDENING_FLAGS` (`crates/tillandsias-podman/src/policy.rs`).

## What changes

- **Borrow the SPIFFE model; do not run SPIRE.** SPIRE's server, agents,
  datastore and registration workflow are built for clusters. Red Hat's product
  (Zero Trust Workload Identity Manager) is scoped to OpenShift, and floor-tier
  hosts cannot carry two more daemons. Vault stays the only signing authority.
  SPIRE accepts Vault as an UpstreamAuthority, so adopting it later stays
  possible.
- **One workload name.** Every enclave workload is named
  `spiffe://<trust-domain>/project/<mirror-id>/lane/<instance>[/agent/<harness>]`.
  The name appears first in the SSH lane cert, then in every client cert's URI
  SAN and in the commit provenance trailer.
- **Every enclave connection authenticates both ends.** Short-lived lane client
  certs (1 h) come from the existing sidecar pattern and chain to the ephemeral
  enclave CA. Vault, inference, the router and the egress proxy require them. A
  guard inventories every enclave listener, and `client-auth=none` needs a
  named, dated waiver.
- **Every per-lane socket checks its peer twice, independently.** The kernel
  attests the peer (SO_PEERCRED plus the cgroup's container id), and SELinux
  MCS labelling on the socket file stops any other container from connecting.
- **SELinux is on by default.** `container_t` with a per-container MCS pair is
  the default. Confined per-role types follow the `vault_container_t`
  precedent. `label=disable` becomes a named, justified exception.
- **Agent provenance on commits.** Each commit gets a signed trailer that is
  pseudonymous per project, naming the project, lane, harness and model. It is
  added beside 1668-8jmq's authorship, never instead of it.
- **Not adopted:** JWT-SVIDs, because X.509 over local sockets is stronger and
  the JWT-SVID spec lists replay as a weakness. SPIRE's node-attestation plugins
  (join tokens, TPM DevID) are not adopted either, because the host-guest PSK
  keyed to the binary digest already attests the node.

## Impact

- New capabilities: `workload-identity` and `enclave-selinux-confinement`.
- Affected:
  - `git-mirror-service`: the anonymous `git://` receive path is retired
    (1685-kwmr);
  - `tillandsias-vault`: client certs (1689-echb);
  - `reverse-proxy-internal`: router and proxy client auth (1691-96gk);
  - `mcp-tool-socket` and `host-browser-mcp`: peer attestation (1692-37qz);
  - `security-privacy-isolation`: the hardening flag set (1693-9qfb);
  - `forge-git-identity-anonymization`: the provenance trailer (1687-ipmx).
- Cross-platform:
  - every enforcement point lives in the Linux guest on macOS and Windows;
  - WSL2 Fedora usually runs without SELinux, so the SELinux rows must state
    what they measure there.
- Risk: turning SELinux labelling on breaks bind mounts, the Wayland socket and
  named volumes until each is relabelled. 1693-9qfb lands it one container role
  at a time behind an exception allow-list.
