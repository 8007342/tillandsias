## MODIFIED Requirements

### Requirement: SLOT-6 — Host-native sidecar slots are reachable only behind the enclave proxy
<!-- req-id: 41088a79 -->

A host-native sidecar is an inference server running as a host process. It
exists because NPUs are structurally unreachable from WSL2, because AMD and
Intel NPU stacks require host firmware and userspace lockstep, and because
Apple-Silicon acceleration in a container caps materially below native Metal.
Its introduction MUST NOT weaken enclave isolation. All of the following are
absolute:

1. The sidecar MUST bind either a loopback-only host address or exactly one
   named Unix-domain socket (or Windows named pipe) in a directory owned by
   the tray. It MUST NOT bind `0.0.0.0`, `::`, or any routable host
   interface. A Unix socket is preferred where the engine supports it,
   because it has no address to mis-bind.
2. The `tillandsias-enclave` network MUST remain `--internal`. Registering a
   sidecar MUST NOT attach any enclave container to the default bridge, MUST
   NOT publish a host port into the enclave, and MUST NOT add
   `--network=host` to any container.
3. Enclave containers MUST reach the sidecar only through the enclave's
   existing mediating terminus — the dual-homed proxy container of
   `spec:proxy-container` / `spec:enclave-network`, or the internal reverse
   proxy of `spec:reverse-proxy-internal`. Which of those two terminates the
   route is an implementation choice left open; that the route terminates at
   one of them, and never at a new hole in the enclave, is not.
4. The route MUST be a single explicitly named upstream: one host address
   and one port, or one named Unix socket or named pipe. It may be carried
   to the VM by a per-VM vsock port that the tray splices to that socket. It
   MUST NOT be expressed as a wildcard or a subnet, and adding it
   MUST NOT widen the proxy's egress allowlist for any other destination.
5. The sidecar MUST authenticate its enclave-side caller with an ephemeral,
   per-run credential. That credential MUST NOT be written to a file readable
   by forge containers, MUST NOT appear in process argv, and MUST NOT appear
   in logs.
6. The sidecar MUST NOT receive host credentials, native keyring handles, or
   project secrets. The only data crossing the boundary is inference request
   and response payloads.
7. The sidecar MUST NOT forward, proxy, or relay any request off-host. It is
   an inference terminus, never an egress path.
8. Registration MUST be leased: an entry MUST expire when the sidecar stops
   heartbeating, and MUST be removed on application exit, leaving no listening
   socket and no persistent registration record.
9. CONFINED HOST HELPER (operator approval, 2026-10-12: "The NPU and Metal
   solutions are acceptable and approved"). A sidecar for an NPU or for
   Metal / the Neural Engine is approved ONLY as a confined host helper. It
   MUST run under the host OS sandbox, and the sandbox must enforce the
   confinement, not just the helper's behaviour:
   - AppContainer on Windows (MXC `processcontainer` or an equivalent
     launcher);
   - Seatbelt on macOS (a deny-default profile).
   The sandbox profile MUST deny all network egress and every listening
   surface except the helper's one socket. It MUST deny reads outside the
   helper's model and engine directories and its run directory.
10. The helper MUST do inference only. It MUST NOT execute agent-supplied
    code, fetch models from the network at serve time, or expose any
    endpoint other than the slot contract (SLOT-2).
11. The helper MUST be spawned with an empty environment plus an explicit
    allowlist, so no host credential can be inherited (clause 6), and its
    argv MUST carry no credential (clause 5).

@trace spec:inference-engine-slots

#### Scenario: Enclave stays internal after a sidecar registers
- **WHEN** a host-native sidecar registers and a forge container is launched
- **THEN** `podman network inspect tillandsias-enclave` MUST still report the
  network as internal
- **AND** no enclave container may have a published host port
- **AND** no enclave container may be attached to the default bridge except
  the already-dual-homed proxy

#### Scenario: Forge reaches the sidecar through the unchanged endpoint
- **WHEN** the active slot is a host-native sidecar
- **THEN** a forge container MUST reach it at the same stable inference
  endpoint
- **AND** the forge container MUST NOT be given the sidecar's host address

#### Scenario: Non-loopback sidecar bind is refused
- **WHEN** a sidecar advertises a bind address that is not loopback
- **THEN** registration MUST be refused with a reason
- **AND** no route may be created for it

#### Scenario: Sidecar route does not widen egress
- **WHEN** the sidecar route is installed at the proxy terminus
- **THEN** the only new reachable destination MUST be the single named
  sidecar host and port
- **AND** the external-domain allowlist MUST be byte-identical to what it was
  before the sidecar registered

#### Scenario: Sidecar unavailable does not block the forge
- **WHEN** the registered sidecar stops responding
- **THEN** the route MUST fail closed with an error
- **AND** forge launch MUST be unaffected, per `spec:async-inference-launch`
- **AND** `spec:inference-policy-router` MUST advance to the next candidate in
  the chain

#### Scenario: Registration is ephemeral
- **WHEN** the Tillandsias application exits
- **THEN** the sidecar registration MUST be removed
- **AND** the sidecar's route MUST no longer exist
- **AND** no registration record may survive to the next run

#### Scenario: The sandbox, not the helper, denies egress
- **WHEN** a confined helper attempts an outbound TCP connect to a public
  address, a loopback TCP bind, or a read of a file outside its allowed
  directories
- **THEN** each attempt MUST fail because the OS sandbox denies it
- **AND** an inference request over the helper's one socket MUST still succeed

#### Scenario: A Unix socket upstream is a single named upstream
- **WHEN** a helper binds exactly one named Unix socket in the tray-owned run
  directory and registers it
- **THEN** registration MUST be accepted as satisfying clauses 1 and 4
- **AND** a registration naming a second socket or any TCP address beside it
  MUST be refused
