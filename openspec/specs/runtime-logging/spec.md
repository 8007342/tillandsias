<!-- @trace spec:runtime-logging -->
# runtime-logging Specification

## Status

status: active

## Purpose

Structured logging system with compact formatting, accountability windows for sensitive operations, and spec traceability via `@trace` links.
## Requirements
### Requirement: Terminal log output when launched from CLI
The application MUST output structured logs to stderr when launched from a terminal, using a custom compact format that separates accountability metadata from regular event fields.

#### Scenario: CLI launch
- **WHEN** tillandsias is launched from a terminal (stderr is a TTY)
- **THEN** log events MUST be printed to stderr using `TillandsiasFormat` with ANSI colors

#### Scenario: Regular event format
- **WHEN** a non-accountability log event is emitted
- **THEN** it MUST render as a single line: `TIMESTAMP LEVEL target: message {key=val, ...}`
- **AND** the target MUST be shortened (e.g., `tillandsias_tray::secrets` → `secrets`)

#### Scenario: Accountability event format
- **WHEN** a log event with `accountability = true` is emitted
- **THEN** it MUST render as a multi-line block with `[category]` prefix on the main line
- **AND** accountability metadata fields (`accountability`, `category`, `safety`, `spec`) MUST NOT appear in the inline field dump
- **AND** a `-> safety note` indented line MUST appear if the event has a `safety` field
- **AND** one `@trace spec:name URL` indented line MUST appear per spec name if the event has a `spec` field

### Requirement: File log output always
The application MUST always write logs to a file at the platform-appropriate state directory, using the same custom compact format as stderr but without ANSI escape codes.

#### Scenario: Log file location
- **WHEN** the application starts
- **THEN** logs MUST be written to `~/.local/state/tillandsias/tillandsias.log` (Linux)

#### Scenario: File format matches stderr structure
- **WHEN** a log event is written to the file
- **THEN** it MUST use the same `TillandsiasFormat` as stderr, with ANSI disabled

#### Scenario: Logs are ephemeral
- **WHEN** the user deletes the log file
- **THEN** the application MUST create a new one on next run with no data loss or errors

### Requirement: Modular log filtering via environment variable
The application MUST support `TILLANDSIAS_LOG` environment variable for module-level log filtering.

#### Scenario: Default log level
- **WHEN** `TILLANDSIAS_LOG` is not set
- **THEN** the default filter MUST be `tillandsias=info`

#### Scenario: Custom log level
- **WHEN** `TILLANDSIAS_LOG=tillandsias_podman=debug` is set
- **THEN** only the podman crate MUST log at debug level

### Requirement: Container lifecycle logging
All container lifecycle operations MUST emit structured log events with relevant context fields.

#### Scenario: Container start logged
- **WHEN** a container is launched via "Attach Here"
- **THEN** an info-level event MUST be emitted with container name, project, genus, port range, and image tag

#### Scenario: Container stop logged
- **WHEN** a container is stopped
- **THEN** an info-level event MUST be emitted with container name and stop duration

#### Scenario: Error logged with context
- **WHEN** a container operation fails
- **THEN** an error-level event MUST be emitted with the operation, container name, and error details

### Requirement: Spec trace links in all accountability events
Accountability events MUST include GitHub code search URLs linking to the `@trace spec:` annotations in source code.

#### Scenario: Single spec trace link
- **WHEN** an accountability event has `spec = "native-secrets-store"`
- **THEN** the formatted output MUST include `@trace spec:native-secrets-store https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code`

#### Scenario: Multiple spec trace links
- **WHEN** an accountability event has `spec = "environment-runtime, secret-rotation"`
- **THEN** the formatted output MUST include one `@trace` line per spec name

### Requirement: Accountability metadata excluded from inline fields
Accountability tagging fields MUST NOT appear as inline key=value pairs in the log output.

#### Scenario: Fields filtered from output
- **WHEN** an event has fields `accountability = true, category = "secrets", safety = "...", spec = "..."`
- **THEN** none of these four fields MUST appear in the `{key=val}` suffix of the log line
- **AND** any other fields (e.g., `container`, `error`) SHOULD appear in the suffix

### Requirement: Proxy accountability window
The system MUST provide a `--log-proxy` accountability flag that enables a curated view of proxy operations. Events MUST include domain, request size, allow/deny status, and cache hit/miss. No request content, credentials, or context parameters MUST appear in proxy logs. Each event MUST include a clickable `@trace spec:proxy-container` link.

@trace spec:runtime-logging, spec:proxy-container

#### Scenario: Proxy log flag enables proxy events
- **WHEN** the application is launched with `--log-proxy`
- **THEN** proxy request events MUST be visible in the accountability output
- **AND** each event MUST include `@trace spec:proxy-container`

#### Scenario: Proxy log excludes secrets
- **WHEN** proxy events are logged
- **THEN** no request bodies, headers, cookies, or credentials MUST appear in the output
- **AND** only domain, size, status (allow/deny), and cache status SHOULD be included

### Requirement: Enclave accountability window
The system MUST provide a `--log-enclave` accountability flag that enables a curated view of enclave lifecycle operations. Events MUST include network creation/removal, container attachment/detachment, and health check results. Each event MUST include a clickable `@trace spec:enclave-network` link.

@trace spec:runtime-logging, spec:enclave-network

#### Scenario: Enclave log flag enables lifecycle events
- **WHEN** the application is launched with `--log-enclave`
- **THEN** enclave lifecycle events MUST be visible in the accountability output
- **AND** each event MUST include `@trace spec:enclave-network`

#### Scenario: Enclave log shows network creation
- **WHEN** the enclave network is created
- **AND** `--log-enclave` is active
- **THEN** the output MUST show `[enclave] Network created: tillandsias-enclave`

### Requirement: Git accountability window
The system MUST provide a `--log-git` accountability flag that enables a curated view of git mirror operations. Events MUST include mirror creation/update, clone/push from forge, and remote push results. No credentials MUST appear in logs. Each event MUST include a clickable `@trace spec:git-mirror-service` link.

@trace spec:runtime-logging, spec:git-mirror-service

#### Scenario: Git log flag enables mirror events
- **WHEN** the application is launched with `--log-git`
- **THEN** git mirror events MUST be visible in the accountability output

#### Scenario: Remote push failure logged prominently
- **WHEN** a post-receive hook fails to push to remote
- **AND** `--log-git` is active
- **THEN** the output MUST show the failure at WARN level with the error message

### Requirement: All enclave accountability windows emit real events
The `--log-proxy`, `--log-enclave`, and `--log-git` accountability windows MUST emit structured events for all enclave operations. Events MUST use the `accountability = true` field and include `@trace spec:<name>` links.

@trace spec:runtime-logging

#### Scenario: Enclave events emitted during attach
- **WHEN** the user clicks "Attach Here" with `--log-enclave` active
- **THEN** the output MUST show network creation, proxy start, git service start, inference start, and forge launch events

#### Scenario: Git events emitted during push
- **WHEN** a forge container pushes to the mirror with `--log-git` active
- **THEN** the output MUST show the push event and remote push result

### Requirement: External-tier logging

Tillandsias MUST distinguish two log tiers per container: INTERNAL (existing per-container `ContainerLogs` mount, RW at owner, never visible to siblings) and EXTERNAL (hand-curated files declared in the producer's `external-logs.yaml` manifest, RO-visible to every consumer in the enclave). The two-tier model enforces a contract: what a service publishes externally is its versioned API for cross-container observability.

#### Scenario: INTERNAL vs EXTERNAL distinction
- **WHEN** a container emits log output
- **THEN** its per-container `ContainerLogs` mount MUST be classified as the INTERNAL tier: full debug stream, RW at owner, NOT readable by siblings
- **AND** any file a producer writes to `/var/log/tillandsias/external/` MUST be classified as the EXTERNAL tier: hand-curated, declared in the producer's manifest, RO at consumers

#### Scenario: INTERNAL isolation is an explicit invariant
- **WHEN** a sibling forge or maintenance container is running
- **THEN** it MUST NOT receive a mount of any other container's `ContainerLogs` directory
- **AND** this property is now an explicit, enumerable requirement (previously true by accident of per-container mount naming; now locked by spec)

#### Scenario: External-log retention across container stop
- **WHEN** a producer container stops
- **THEN** its external-log files in `~/.local/state/tillandsias/external-logs/<role>/` MUST persist on the host
- **AND** MUST NOT be deleted or rotated by container lifecycle events

#### Scenario: External-log rotation discipline
- **WHEN** an external-log file exceeds its `rotate_at_mb` cap (default 10 MB)
- **THEN** the tray auditor MUST rotate it in place (truncate to newest 50% of bytes)
- **AND** no `.1`/`.2` rotation files MUST be created (flat layout for `tail -f` consumers)
- **AND** rotation MUST be logged at INFO+accountability level

#### Scenario: Content-type restriction
- **WHEN** a producer declares a file in its manifest
- **THEN** `format` MUST be `text` or `jsonl` only
- **AND** binary formats MUST NOT be permitted
- **AND** agents reading external logs SHOULD be able to `grep` or `jq` them without a deserialiser dep


## Sources of Truth

- `cheatsheets/runtime/logging-levels.md` — Logging Levels reference and patterns
- `cheatsheets/runtime/external-logs.md` — External Logs reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Runtime logs are ephemeral; logs don't persist beyond container lifetime
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:runtime-logging" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
