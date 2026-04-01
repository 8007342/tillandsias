## MODIFIED Requirements

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

## ADDED Requirements

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
