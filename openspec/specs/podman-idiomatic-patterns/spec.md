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
- **Invariants**: [podman-idiomatic-patterns.invariant.secrets-not-in-env, podman-idiomatic-patterns.invariant.secrets-cleaned-on-exit, podman-idiomatic-patterns.invariant.forge-capability-only]

Credentials passed to containers SHALL use `podman secret create` at startup and `--secret <name>` at launch time. Embedding credentials in image layers (`ENV`, `RUN echo`) or passing them as `-e` environment variables is PROHIBITED.

This spec distinguishes a **credential** (a value that authenticates to a
third party — a provider API key, an OAuth document, a GitHub token) from a
**capability** (a short-lived, least-privilege Vault AppRole client token that
only entitles its holder to read one named Vault path). A credential's BYTES
are what must never reach a container launch; a capability MAY be mounted,
because it carries no third-party authority of its own and expires. The
`--secret` transport is the only permitted channel for a capability, and
`podman-secrets-integration` plus `tillandsias-vault` remain authoritative for
which roles, policies, paths, TTLs, and mount options are allowed.

#### Scenario: Ephemeral podman secrets created at startup
- **WHEN** Tillandsias starts
- **THEN** the Vault unseal key (HKDF-derived from machine-id + installation-uuid)
  and the CA cert/key pair are registered as named ephemeral podman secrets via
  `podman secret create --driver=file`
- **AND** per-container Vault AppRole tokens are created as podman secrets at
  container launch time
- **AND** no credentials are read from the Linux Secret Service / GNOME Keyring
  (all long-lived tokens live in Vault, not the host keyring)

#### Scenario: Container reads secret from file, not env
- **WHEN** a container is launched that requires a credential
- **THEN** the secret is passed via `--secret <name>` and appears at `/run/secrets/<name>` inside the container
- **AND** the secret value MUST NOT appear in `podman ps`, `podman inspect`, or container logs

#### Scenario: Secrets cleaned up on exit
- **WHEN** Tillandsias receives SIGTERM or SIGINT
- **THEN** all `tillandsias-*` podman secrets (ca-cert, ca-key, vault-unseal,
  vault-token-*) are removed via `podman secret rm` before process exit
- **AND** per-container Vault tokens are revoked via
  `revoke_pending_container_tokens()`
- **AND** no credential remains in podman's secret store after shutdown

#### Scenario: Forge containers carry no raw provider credential
- **WHEN** any forge container is launched — OpenCode CLI, OpenCode Web, Codex,
  Claude, Antigravity, or maintenance
- **THEN** the `podman run` argv MUST NOT carry a provider API key, an OAuth
  document, a GitHub token, or any other third-party credential VALUE — not
  positionally, not via `-e`/`--env`, and not as a podman secret
- **AND** no long-lived credential MUST be registered as a podman secret for a
  forge container
- **AND** the forge image MUST NOT bake any credential into an image layer

#### Scenario: A credentialed forge lane mounts one short-lived Vault capability
- **WHEN** a forge lane is launched whose provider material is present in Vault
- **THEN** the ONLY `--secret` that forge container MAY receive is a
  per-launch, per-container Vault AppRole CLIENT TOKEN registered as
  `tillandsias-vault-token-<role>-<container>` and mounted read-only at
  `/run/secrets/vault-token` with `target=vault-token,uid=1000,gid=1000,mode=0400`
- **AND** that AppRole MUST be bound to a policy that names the exact Vault path
  the lane reads (`opencode-forge-policy`, `claude-forge-policy`,
  `codex-forge-policy`, `antigravity-forge-policy`) — never a broad token
- **AND** the token MUST expire (`APPROLE_TOKEN_TTL_SECS`) and MUST be revoked
  with its podman secret removed when the session ends
- **AND** the credential itself MUST be read from Vault INSIDE the container;
  the launcher MUST NOT read it and hand it to Podman
- **NOTE**: this scenario states only that such a mount is PERMITTED and
  bounded. `podman-secrets-integration` (mount shape, secret-name registry) and
  `tillandsias-vault` (`tillandsias-vault.security.forge-offline@v2` — allowed
  roles, policies, paths, TTL) stay authoritative for the details.

#### Scenario: Credential-free forge lanes receive no `--secret` at all
- **WHEN** a maintenance forge is launched, or a lane whose provider material is
  absent from Vault
- **THEN** the `podman run` argv MUST contain zero `--secret` flags
- **AND** that lane MUST remain fully credential-free

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

#### Scenario: IPAM allocation failures abort without retry
- **WHEN** `podman run` fails with an IPAM allocation error, an "already
  allocated" address, or a netavark cleanup error
- **THEN** the runtime MUST classify the failure as permanent
- **AND** the launch output MUST surface an actionable diagnostic instead of
  retrying the same stale network allocation

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

### Requirement: Enclave network with internal DNS and dynamic IPAM
- **ID**: podman-idiomatic-patterns.network.enclave-per-project@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-idiomatic-patterns.invariant.enclave-network-isolated]

Tillandsias user-runtime launches SHALL use the `tillandsias-enclave` Podman
bridge network with container DNS aliases (`proxy`, `git-service`,
`inference`, `router`) instead of static IP assignments. Containers within the
enclave SHALL resolve each other by container name or network alias via
internal DNS. The enclave network MUST be created before any enclave container
launches.

#### Scenario: Containers resolve peers by name
- **WHEN** containers `proxy`, `git`, `forge`, and `inference` are all on the enclave network
- **THEN** `forge` can reach `proxy` at `http://proxy:3128` using the container name as hostname
- **AND** no manual `/etc/hosts` entries are needed

#### Scenario: Launch args do not pin static IPs
- **WHEN** proxy, git, inference, router, browser, or forge container args are
  constructed
- **THEN** the argv MUST NOT contain `--ip`
- **AND** Podman IPAM SHALL allocate addresses dynamically
- **AND** service discovery SHALL depend on names and aliases, not hard-coded
  `10.0.42.x` addresses

#### Scenario: Network isolation from other projects
- **WHEN** two projects have active enclaves simultaneously
- **THEN** containers in `tillandsias-project-a-enclave` CANNOT reach containers in `tillandsias-project-b-enclave`
- **AND** the isolation is enforced at the Podman bridge level, not by application-level filtering

#### Scenario: Network cleanup on enclave shutdown
- **WHEN** the user-runtime stack has no active forge containers
- **THEN** proxy, git, and inference containers created for foreground launch
  SHALL be removed
- **AND** the shared enclave network MAY remain for tray/router reuse

### Requirement: Observed launch helpers produce actionable failures

Container launches that are user-visible SHALL use observed Podman helpers so
debug output reports the launch stage, container name, state transition, and a
short next-step hint before redacted argv details.

#### Scenario: Debug container launch line
- **WHEN** a debug launch starts a stack service
- **THEN** stderr SHALL include
  `event:container_launch stage=<stage> state=starting container=<name>`
- **AND** successful start SHALL include `state=running`
- **AND** attached foreground forge exit SHALL include `state=exited`

#### Scenario: Debug container failure line
- **WHEN** a launch fails
- **THEN** stderr SHALL include `state=failed`
- **AND** the error body SHALL include a one-line cause, a `next:` hint, and
  a redacted `podman run` argv

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

### Invariant: Forge containers receive capabilities, never credentials
- **ID**: podman-idiomatic-patterns.invariant.forge-capability-only
- **Expression**: `forge_container.secrets SUBSET_OF {tillandsias-vault-token-<role>-<container>} AND forge_container_launch_argv DOES_NOT_CONTAIN provider_credential_value`
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
- `litmus:forge-secret-capability-contract` — validates that this spec and
  `podman-secrets-integration` make the SAME claim about forge `--secret`
  flags, that both forge run-arg builders gate their single scoped
  `vault-token` mount, and that the raw-provider-key env deviation below does
  not spread

Gating points:
- Every `podman run` invocation in the codebase carries the four mandatory security flags
- No `podman ps` polling loop exists (only `podman events` subscriptions)
- Secrets are never passed as `-e` environment variables
- All operations succeed without root
- A forge container's `--secret` set is either empty or exactly one scoped
  `tillandsias-vault-token-<role>-<container>` mount

## Open Deviations

Deviations are recorded here — not silently absorbed into the requirement
wording — so the spec keeps stating the intended invariant while remaining
falsifiable against HEAD.

### Deviation: raw provider API keys reach agent-forge argv as `--env`
- **ID**: podman-idiomatic-patterns.deviation.agent-forge-api-key-in-env
- **Violates**: `podman-idiomatic-patterns.secrets.ephemeral-mount@v1`
  (Scenario "Forge containers carry no raw provider credential"),
  `podman-idiomatic-patterns.invariant.secrets-not-in-env`
- **Observed**: 2026-07-28, order 461
- **Site**: `crates/tillandsias-headless/src/main.rs`, inside
  `build_forge_agent_run_args_with_vault()` — the `provider_api` block reads
  the provider API key out of Vault ON THE HOST via
  `vault_bootstrap::read_provider_api_key()` and injects it as
  `spec.env(p.env_var(), &key)` (plus `GOOGLE_GENERATIVE_AI_API_KEY` for
  Gemini). `ContainerSpec::to_run_args()` renders that as
  `--env <PROVIDER>_API_KEY=<raw value>`, so the key is visible to
  `podman inspect` and in `/proc/<pid>/cmdline`.
- **Scope**: Claude, Codex, and Antigravity agent lanes only, and only when
  Vault holds an API key for that provider. The OpenCode CLI/Web lane does NOT
  deviate — order 431 already moved it to the scoped-capability shape
  (`build_opencode_forge_args()`), which is the target shape for the rest.
- **Not covered by**: the log-redaction path. `format_podman_invocation_line()`
  scrubs the LOG line heuristically; it does not remove the value from the
  container environment or from `podman inspect`.
- **Falsification**:
  `cargo test -p tillandsias-headless tests::forge_agent_lanes_carry_no_raw_provider_key -- --exact`
  does not exist yet; until the fix lands, the falsifiable check is
  `litmus:forge-secret-capability-contract` step "raw provider-key env
  injection does not spread", which budgets the deviation at its 2 known lines
  and turns red if another lane or another key is added, if the OpenCode
  builder regains one, or if the credential-free lanes stop opting out.
- **Exit**: convert these lanes to the order-431 shape (mount the scoped
  `<provider>-forge` AppRole token, read the key from Vault inside the
  entrypoint), then delete this deviation and tighten the litmus step to a
  zero-site assertion. Requires a code-scope packet — not closed by order 461,
  whose scope is spec + litmus only.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-idiomatic-patterns" crates/ scripts/ images/ --include="*.rs" --include="*.sh"
```

## Sources of Truth

- `cheatsheets/runtime/podman-idiomatic-patterns.md` — primary source; idiomatic event-driven patterns, security flags, storage isolation, secrets, error handling, rootless operation, and networking
- `cheatsheets/runtime/podman.md` — Podman reference and core CLI patterns
