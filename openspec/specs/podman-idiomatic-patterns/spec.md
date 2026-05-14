<!-- @trace spec:podman-idiomatic-patterns -->
# podman-idiomatic-patterns Specification

## Status

active

## Purpose

Canonical idiomatic patterns for Podman usage in Tillandsias: event-driven container observation, security-mandatory flags, per-project storage isolation, ephemeral secret mounting, categorized error handling, and rootless-first execution. These patterns govern every layer that touches Podman — Rust crates, shell scripts, and Containerfiles.

## Requirements

### Requirement: Event-driven container observation, never polling
- **ID**: podman-idiomatic-patterns.events.no-polling@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.no-poll-loop]

All Tillandsias code that monitors container state SHALL subscribe to `podman events` rather than periodically calling `podman ps`. Polling loops that sleep and re-query container state are PROHIBITED.

#### Scenario: Container state change detected via events
- **WHEN** a container starts, stops, or dies
- **THEN** the runtime learns of the transition via the `podman events` stream (filtered by label `tillandsias-enclave=<name>`)
- **AND** no periodic sleep/poll cycle is used

#### Scenario: Event filter reduces noise
- **WHEN** subscribing to the event stream
- **THEN** the subscription MUST filter `type=container` and restrict to `status=start,stop,die` (or the relevant subset)
- **AND** unrelated system events SHALL NOT be processed

#### Scenario: Exponential backoff on stream disconnect
- **WHEN** the `podman events` stream terminates unexpectedly
- **THEN** the runtime MUST reconnect with exponential backoff starting at 100 ms, capped at 30 s
- **AND** the runtime MUST NOT immediately poll container state during the backoff window

### Requirement: Non-negotiable security flags on every container
- **ID**: podman-idiomatic-patterns.security.mandatory-flags@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.security-flags-always-present]

Every container launched by Tillandsias SHALL include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--rm`. These flags are non-negotiable and MUST NOT be removed or weakened by any project-level configuration.

#### Scenario: Default launch with all required flags
- **WHEN** any container is launched
- **THEN** the resulting `podman run` argv MUST contain `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--rm`

#### Scenario: Per-project config cannot weaken flags
- **WHEN** a `.tillandsias/config.toml` attempts to disable cap-drop or no-new-privileges
- **THEN** Tillandsias MUST ignore the weakening directive and enforce the defaults

#### Scenario: Additional hardening is allowed
- **WHEN** a per-project config adds `--read-only` or `network=none`
- **THEN** those additional restrictions are applied on top of the non-negotiable defaults

### Requirement: Per-project storage isolation (enclave model)
- **ID**: podman-idiomatic-patterns.storage.per-project-isolation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.no-cross-project-storage]

Each Tillandsias-managed project SHALL operate with its own isolated Podman graph root, run root, and runtime directory. Containers, images, and networks from one project MUST NOT be visible to another project's Podman context.

#### Scenario: Project-scoped graph root
- **WHEN** containers are launched for project `my-project`
- **THEN** `PODMAN_GRAPHROOT` resolves to a path under `~/.cache/tillandsias/my-project/graphroot/`
- **AND** no container or image from another project is visible in that storage context

#### Scenario: Clean teardown removes all project storage
- **WHEN** a project's enclave is shut down
- **THEN** the network `tillandsias-<project>-enclave` is deleted
- **AND** all storage under `~/.cache/tillandsias/<project>/` MAY be removed without affecting other projects

#### Scenario: Parallel enclaves run without interference
- **WHEN** two projects are active simultaneously
- **THEN** each project's containers, images, and networks are fully isolated from the other
- **AND** a container name collision in separate projects does NOT cause an error

### Requirement: Ephemeral secret mounting, never env vars or image layers
- **ID**: podman-idiomatic-patterns.secrets.ephemeral-mount@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.secrets-not-in-env, podman-idiomatic-patterns.invariant.secrets-cleaned-on-exit]

Credentials passed to containers SHALL use `podman secret create` at startup and `--secret <name>` at launch time. Embedding credentials in image layers (`ENV`, `RUN echo`) or passing them as `-e` environment variables is PROHIBITED.

#### Scenario: Secret created at startup from host keyring
- **WHEN** Tillandsias starts
- **THEN** credentials are read from the Linux Secret Service (GNOME Keyring / pass)
- **AND** each credential is registered as a named ephemeral podman secret via `podman secret create --driver=file`

#### Scenario: Container reads secret from file, not env
- **WHEN** a container is launched that requires a credential
- **THEN** the secret is passed via `--secret <name>` and appears at `/run/secrets/<name>` inside the container
- **AND** the secret value MUST NOT appear in `podman ps`, `podman inspect`, or container logs

#### Scenario: Secrets cleaned up on exit
- **WHEN** Tillandsias receives SIGTERM or SIGINT
- **THEN** all `tillandsias-*` podman secrets are removed via `podman secret rm` before process exit
- **AND** no credential remains in podman's secret store after shutdown

#### Scenario: Forge containers receive no secrets
- **WHEN** a forge container is launched
- **THEN** it MUST NOT receive any `--secret` flags
- **AND** forge containers MUST remain fully credential-free

### Requirement: Categorized error handling with retry discrimination
- **ID**: podman-idiomatic-patterns.errors.retry-discrimination@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.no-retry-on-config-error]

Code that invokes Podman SHALL classify errors as transient (network unreachable, temporary failure, timeout) or permanent (image not found, invalid config, permission denied). Transient errors MUST be retried with exponential backoff; permanent errors MUST NOT be retried.

#### Scenario: Transient network error triggers backoff retry
- **WHEN** a `podman run` call fails with a transient network error
- **THEN** the runtime waits with exponential backoff (starting 100 ms, capped 30 s) and retries up to the configured maximum

#### Scenario: Missing image is not retried
- **WHEN** `podman run` fails because the image does not exist in local storage
- **THEN** the error is immediately propagated without retry
- **AND** an actionable log message indicates the image must be pulled or built first

#### Scenario: Configuration error aborts without retry
- **WHEN** `podman run` fails with exit code 125 (invalid flags) or permission denied
- **THEN** the runtime immediately reports the configuration error and does not retry

### Requirement: Rootless-first execution with keep-id mapping
- **ID**: podman-idiomatic-patterns.rootless.keep-id-first@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.no-root-required]

All Tillandsias container operations SHALL execute in rootless Podman mode. `--userns=keep-id` SHALL be applied so that the invoking user's UID is preserved inside the container. No container operation SHALL require root privileges on the host.

#### Scenario: Rootless verification at startup
- **WHEN** Tillandsias initializes
- **THEN** it verifies `podman info` reports `"Rootless": true`
- **AND** a diagnostic warning is emitted if rootless mode is not detected

#### Scenario: UID mapping preserves host user identity
- **WHEN** a container is launched with `--userns=keep-id`
- **THEN** `id` inside the container shows UID matching the invoking host user
- **AND** host files owned by that user are writable from inside the container without setuid tricks

#### Scenario: Container escape has limited blast radius
- **WHEN** a container escapes its namespace (hypothetically)
- **THEN** the escaped process runs as the invoking user's UID on the host, not as root
- **AND** it has access only to `$HOME` and user-owned resources, not `/etc`, `/root`, or system directories

### Requirement: Enclave network per project with internal DNS
- **ID**: podman-idiomatic-patterns.network.enclave-per-project@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.enclave-network-isolated]

Each project SHALL have exactly one Podman bridge network named `tillandsias-<project>-enclave`. Containers within the enclave SHALL resolve each other by container name via internal DNS. The enclave network MUST be created before any enclave container launches and deleted on enclave shutdown.

#### Scenario: Containers resolve peers by name
- **WHEN** containers `proxy`, `git`, `forge`, and `inference` are all on the enclave network
- **THEN** `forge` can reach `proxy` at `http://proxy:3128` using the container name as hostname
- **AND** no manual `/etc/hosts` entries are needed

#### Scenario: Network isolation from other projects
- **WHEN** two projects have active enclaves simultaneously
- **THEN** containers in `tillandsias-project-a-enclave` CANNOT reach containers in `tillandsias-project-b-enclave`
- **AND** the isolation is enforced at the Podman bridge level, not by application-level filtering

#### Scenario: Network cleanup on enclave shutdown
- **WHEN** the enclave for a project is shut down
- **THEN** `podman network rm tillandsias-<project>-enclave` is called after all containers are stopped
- **AND** the network does not persist after shutdown

## Invariants

### Invariant: No poll loop for container state
- **ID**: podman-idiomatic-patterns.invariant.no-poll-loop
- **Expression**: `container_monitoring USES podman_events_stream AND NOT (sleep + podman_ps) loop`
- **Measurable**: true

### Invariant: Security flags always present in container argv
- **ID**: podman-idiomatic-patterns.invariant.security-flags-always-present
- **Expression**: `every_podman_run_argv CONTAINS [--cap-drop=ALL, --security-opt=no-new-privileges, --userns=keep-id, --rm]`
- **Measurable**: true

### Invariant: No cross-project storage leakage
- **ID**: podman-idiomatic-patterns.invariant.no-cross-project-storage
- **Expression**: `project_A.graphroot != project_B.graphroot AND podman(project_A).images NOT_VISIBLE_IN podman(project_B)`
- **Measurable**: true

### Invariant: Secrets not in environment variables
- **ID**: podman-idiomatic-patterns.invariant.secrets-not-in-env
- **Expression**: `container_launch_argv DOES_NOT_CONTAIN -e.*TOKEN AND secrets_passed_via --secret_only`
- **Measurable**: true

### Invariant: Secrets cleaned up on process exit
- **ID**: podman-idiomatic-patterns.invariant.secrets-cleaned-on-exit
- **Expression**: `on SIGTERM|SIGINT: cleanup_secrets() REMOVES all tillandsias-* secrets BEFORE process_exit`
- **Measurable**: true

### Invariant: No retry on permanent/config errors
- **ID**: podman-idiomatic-patterns.invariant.no-retry-on-config-error
- **Expression**: `error.is_permanent() => retry_count == 0 AND error_propagated_immediately`
- **Measurable**: true

### Invariant: No root required for any operation
- **ID**: podman-idiomatic-patterns.invariant.no-root-required
- **Expression**: `ALL podman_operations EXECUTE_AS invoking_user AND NOT require_sudo`
- **Measurable**: true

### Invariant: Enclave network isolated from other enclaves
- **ID**: podman-idiomatic-patterns.invariant.enclave-network-isolated
- **Expression**: `containers(enclave_A) CANNOT_REACH containers(enclave_B) at_network_layer`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation` — validates enclave network isolation
- `litmus:security-privacy-isolation` — validates mandatory security flags
- `litmus:podman-orchestration` — validates container launch argv

Gating points:
- Every `podman run` invocation in the codebase carries the four mandatory security flags
- No `podman ps` polling loop exists (only `podman events` subscriptions)
- Secrets are never passed as `-e` environment variables
- All operations succeed without root

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-idiomatic-patterns" crates/ scripts/ images/ --include="*.rs" --include="*.sh"
```

## Sources of Truth

- `cheatsheets/runtime/podman-idiomatic-patterns.md` — primary source; idiomatic event-driven patterns, security flags, storage isolation, secrets, error handling, rootless operation, and networking
- `cheatsheets/runtime/podman.md` — Podman reference and core CLI patterns
