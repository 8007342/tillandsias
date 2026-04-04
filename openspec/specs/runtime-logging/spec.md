# runtime-logging Specification

## Purpose

Structured logging system with compact formatting, accountability windows for sensitive operations, and spec traceability via `@trace` links.

## Requirements

### Requirement: Terminal log output when launched from CLI
The application SHALL output structured logs to stderr when launched from a terminal, using a custom compact format that separates accountability metadata from regular event fields.

#### Scenario: CLI launch
- **WHEN** tillandsias is launched from a terminal (stderr is a TTY)
- **THEN** log events are printed to stderr using `TillandsiasFormat` with ANSI colors

#### Scenario: Regular event format
- **WHEN** a non-accountability log event is emitted
- **THEN** it SHALL render as a single line: `TIMESTAMP LEVEL target: message {key=val, ...}`
- **AND** the target SHALL be shortened (e.g., `tillandsias_tray::secrets` → `secrets`)

#### Scenario: Accountability event format
- **WHEN** a log event with `accountability = true` is emitted
- **THEN** it SHALL render as a multi-line block with `[category]` prefix on the main line
- **AND** accountability metadata fields (`accountability`, `category`, `safety`, `spec`) SHALL NOT appear in the inline field dump
- **AND** a `-> safety note` indented line SHALL appear if the event has a `safety` field
- **AND** one `@trace spec:name URL` indented line SHALL appear per spec name if the event has a `spec` field

### Requirement: File log output always
The application SHALL always write logs to a file at the platform-appropriate state directory, using the same custom compact format as stderr but without ANSI escape codes.

#### Scenario: Log file location
- **WHEN** the application starts
- **THEN** logs are written to `~/.local/state/tillandsias/tillandsias.log` (Linux)

#### Scenario: File format matches stderr structure
- **WHEN** a log event is written to the file
- **THEN** it SHALL use the same `TillandsiasFormat` as stderr, with ANSI disabled

#### Scenario: Logs are ephemeral
- **WHEN** the user deletes the log file
- **THEN** the application creates a new one on next run with no data loss or errors

### Requirement: Modular log filtering via environment variable
The application SHALL support `TILLANDSIAS_LOG` environment variable for module-level log filtering.

#### Scenario: Default log level
- **WHEN** `TILLANDSIAS_LOG` is not set
- **THEN** the default filter is `tillandsias=info`

#### Scenario: Custom log level
- **WHEN** `TILLANDSIAS_LOG=tillandsias_podman=debug` is set
- **THEN** only the podman crate logs at debug level

### Requirement: Container lifecycle logging
All container lifecycle operations SHALL emit structured log events with relevant context fields.

#### Scenario: Container start logged
- **WHEN** a container is launched via "Attach Here"
- **THEN** an info-level event is emitted with container name, project, genus, port range, and image tag

#### Scenario: Container stop logged
- **WHEN** a container is stopped
- **THEN** an info-level event is emitted with container name and stop duration

#### Scenario: Error logged with context
- **WHEN** a container operation fails
- **THEN** an error-level event is emitted with the operation, container name, and error details

### Requirement: Spec trace links in all accountability events
Accountability events SHALL include GitHub code search URLs linking to the `@trace spec:` annotations in source code.

#### Scenario: Single spec trace link
- **WHEN** an accountability event has `spec = "native-secrets-store"`
- **THEN** the formatted output SHALL include `@trace spec:native-secrets-store https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code`

#### Scenario: Multiple spec trace links
- **WHEN** an accountability event has `spec = "environment-runtime, secret-rotation"`
- **THEN** the formatted output SHALL include one `@trace` line per spec name

### Requirement: Accountability metadata excluded from inline fields
Accountability tagging fields SHALL NOT appear as inline key=value pairs in the log output.

#### Scenario: Fields filtered from output
- **WHEN** an event has fields `accountability = true, category = "secrets", safety = "...", spec = "..."`
- **THEN** none of these four fields SHALL appear in the `{key=val}` suffix of the log line
- **AND** any other fields (e.g., `container`, `error`) SHALL still appear in the suffix

### Requirement: Proxy accountability window
The system SHALL provide a `--log-proxy` accountability flag that enables a curated view of proxy operations. Events SHALL include domain, request size, allow/deny status, and cache hit/miss. No request content, credentials, or context parameters SHALL appear in proxy logs. Each event SHALL include a clickable `@trace spec:proxy-container` link.

@trace spec:runtime-logging, spec:proxy-container

#### Scenario: Proxy log flag enables proxy events
- **WHEN** the application is launched with `--log-proxy`
- **THEN** proxy request events SHALL be visible in the accountability output
- **AND** each event SHALL include `@trace spec:proxy-container`

#### Scenario: Proxy log excludes secrets
- **WHEN** proxy events are logged
- **THEN** no request bodies, headers, cookies, or credentials SHALL appear in the output
- **AND** only domain, size, status (allow/deny), and cache status SHALL be included

### Requirement: Enclave accountability window
The system SHALL provide a `--log-enclave` accountability flag that enables a curated view of enclave lifecycle operations. Events SHALL include network creation/removal, container attachment/detachment, and health check results. Each event SHALL include a clickable `@trace spec:enclave-network` link.

@trace spec:runtime-logging, spec:enclave-network

#### Scenario: Enclave log flag enables lifecycle events
- **WHEN** the application is launched with `--log-enclave`
- **THEN** enclave lifecycle events SHALL be visible in the accountability output
- **AND** each event SHALL include `@trace spec:enclave-network`

#### Scenario: Enclave log shows network creation
- **WHEN** the enclave network is created
- **AND** `--log-enclave` is active
- **THEN** the output SHALL show `[enclave] Network created: tillandsias-enclave`

### Requirement: Git accountability window
The system SHALL provide a `--log-git` accountability flag that enables a curated view of git mirror operations. Events SHALL include mirror creation/update, clone/push from forge, and remote push results. No credentials SHALL appear in logs. Each event SHALL include a clickable `@trace spec:git-mirror-service` link.

@trace spec:runtime-logging, spec:git-mirror-service

#### Scenario: Git log flag enables mirror events
- **WHEN** the application is launched with `--log-git`
- **THEN** git mirror events SHALL be visible in the accountability output

#### Scenario: Remote push failure logged prominently
- **WHEN** a post-receive hook fails to push to remote
- **AND** `--log-git` is active
- **THEN** the output SHALL show the failure at WARN level with the error message

### Requirement: All enclave accountability windows emit real events
The `--log-proxy`, `--log-enclave`, and `--log-git` accountability windows SHALL emit structured events for all enclave operations. Events SHALL use the `accountability = true` field and include `@trace spec:<name>` links.

@trace spec:runtime-logging

#### Scenario: Enclave events emitted during attach
- **WHEN** the user clicks "Attach Here" with `--log-enclave` active
- **THEN** the output SHALL show network creation, proxy start, git service start, inference start, and forge launch events

#### Scenario: Git events emitted during push
- **WHEN** a forge container pushes to the mirror with `--log-git` active
- **THEN** the output SHALL show the push event and remote push result
