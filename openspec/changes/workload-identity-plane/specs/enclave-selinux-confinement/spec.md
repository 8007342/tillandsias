## ADDED Requirements

### Requirement: Enclave containers run SELinux-confined by default

Every enclave container (forge, git mirror, router, egress proxy, inference, browser, web preview, vault) SHALL run under SELinux confinement: `container_t` or a confined per-role type, with a per-container MCS category pair, wherever the host or guest enforces SELinux. `--security-opt=label=disable` SHALL NOT be a mandatory hardening flag. The launch-argv hardening guard SHALL refuse `label=disable` unless the call site names an entry from an exception allow-list. Each entry SHALL carry its reason and the packet that removes it. Where SELinux is not enforcing (for example a WSL2 guest), the launch SHALL record that fact rather than report the container as confined.

#### Scenario: label=disable without an exception is refused

- **WHEN** a launch argv carries `--security-opt=label=disable` and its call site names no allow-listed exception
- **THEN** the hardening guard refuses the launch before any podman process is spawned

#### Scenario: containers sharing a uid cannot read each other's files

- **WHEN** two enclave containers run under the same uid on an enforcing host and one writes a file into a path the other can reach
- **THEN** the other's read is denied by MCS, and an AVC names both categories

### Requirement: Lane sockets are MCS-labelled to their lane

Each per-lane socket file and its directory SHALL carry the owning lane container's MCS category pair, so that the kernel denies `connectto` from any other container regardless of uid or file mode. This SHALL hold independently of the socket's kernel-attested peer check, and either control alone SHALL refuse a foreign lane.

#### Scenario: a foreign lane cannot connect even with mode 0666

- **WHEN** a container in lane A connects to lane B's socket, whose mode is 0666 and whose owner uid matches
- **THEN** the connection is denied by SELinux

### Requirement: Enclave roles get confined types shipped with the binary

The forge, git mirror, router and egress proxy SHALL each run under a confined SELinux type, following the existing `vault_container_t` precedent. Each type SHALL allow only that role's own sockets, ports and paths, and SHALL deny the forge type the mirror's SSH keys, the vault data and every other lane's runtime directory. The policy modules SHALL ship with the binary and be loaded at init. A host where a role's module cannot load SHALL refuse to start that role or record a named exception. It SHALL NOT silently fall back to running unconfined.

#### Scenario: a forge cannot read the mirror's SSH host key

- **WHEN** a process in a forge container tries to read the git mirror's SSH host key path
- **THEN** the read is denied by type enforcement

#### Scenario: an unloadable module is never silent

- **WHEN** a role's policy module fails to load on a host
- **THEN** the launch refuses that role or records a named exception, and never reports it as confined
