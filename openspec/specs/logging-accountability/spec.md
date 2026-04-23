## ADDED Requirements

### Requirement: Per-module log level control
Users SHALL be able to control log verbosity for individual subsystems via a CLI flag.

#### Scenario: Single module at trace level
- **WHEN** the user runs `tillandsias --log=secrets:trace <project>`
- **THEN** log output includes trace-level messages from the secrets module
- **AND** all other modules log at the default level (info)
- **AND** trace messages include `@trace spec:` references and GitHub code search URLs

#### Scenario: Multiple modules at different levels
- **WHEN** the user runs `tillandsias --log=secrets:trace;containers:debug;scanner:off <project>`
- **THEN** secrets module logs at trace level
- **AND** containers module logs at debug level
- **AND** scanner module produces no log output
- **AND** other modules (updates, menu, events) log at the default level

#### Scenario: Invalid module name
- **WHEN** the user runs `tillandsias --log=bogus:debug <project>`
- **THEN** a warning is printed to stderr: "Unknown log module: bogus. Valid modules: secrets, containers, updates, scanner, menu, events"
- **AND** the application starts normally with default log levels

#### Scenario: Invalid log level
- **WHEN** the user runs `tillandsias --log=secrets:potato <project>`
- **THEN** an error is printed to stderr: "Invalid log level: potato. Valid levels: off, error, warn, info, debug, trace"
- **AND** the secrets module falls back to info level

#### Scenario: CLI flag overrides environment variable
- **GIVEN** `TILLANDSIAS_LOG=tillandsias=warn` is set in the environment
- **WHEN** the user runs `tillandsias --log=secrets:debug <project>`
- **THEN** the `--log` flag takes precedence
- **AND** secrets module logs at debug level (not warn)

### Requirement: Accountability windows
Users SHALL be able to enable curated views of sensitive subsystem operations.

#### Scenario: Secret management accountability window
- **WHEN** the user runs `tillandsias --log-secrets-management <project>`
- **THEN** each secrets operation produces output in the format:
  ```
  [secrets] v0.1.97.76 | <human-readable summary>
    Spec: <spec-name>
    Cheatsheet: docs/cheatsheets/secrets-management.md
  ```
- **AND** no actual secret values (tokens, keys, passwords) appear in the output
- **AND** operations include: keyring retrieval, token file writes, secret injection into containers, token rotation events

#### Scenario: Accountability window composes with --log
- **WHEN** the user runs `tillandsias --log-secrets-management --log=scanner:debug <project>`
- **THEN** both the accountability window output AND scanner debug output are visible
- **AND** the accountability formatter applies only to secrets operations

#### Scenario: Accountability window in tray mode
- **WHEN** the user runs `tillandsias --log-secrets-management` (no project path, tray mode)
- **THEN** accountability output is written to the log file at `~/.local/state/tillandsias/tillandsias.log`
- **AND** if stderr is a terminal, accountability output is also printed to stderr
- **AND** if stderr is not a terminal (e.g., launched from desktop file), only the log file receives output

### Requirement: Zero-cost disabled modules
Log macros for disabled modules SHALL have zero runtime cost.

#### Scenario: Disabled module has no overhead
- **GIVEN** the scanner module is set to `off` via `--log=scanner:off`
- **WHEN** scanner code executes log macros
- **THEN** no string formatting, allocation, or I/O occurs for those macros
- **AND** this is verified by the `tracing` crate's callsite filtering mechanism

### Requirement: Spec URLs at trace level
Trace-level log output SHALL include clickable GitHub code search URLs for spec traceability.

#### Scenario: Trace output includes spec URL
- **GIVEN** the secrets module is at trace level
- **WHEN** a spec-governed operation executes (e.g., token write)
- **THEN** the trace output includes lines:
  ```
  @trace spec:secret-rotation
  https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Asecret-rotation&type=code
  ```
- **AND** the URL is a valid GitHub code search link that finds all files implementing the spec

#### Scenario: Spec URLs not generated at non-trace levels
- **GIVEN** the secrets module is at info level
- **WHEN** a spec-governed operation executes
- **THEN** no spec URL is generated or formatted (zero cost)

### Requirement: No secrets in logs
Log output SHALL NEVER contain actual secret values, regardless of log level.

#### Scenario: Token values are redacted
- **WHEN** any log message references a token or API key
- **THEN** the log shows the operation and target but not the secret value
- **AND** examples: "Token retrieved from native keyring" (not "Token gho_abc123 retrieved"), "ANTHROPIC_API_KEY injected" (not "ANTHROPIC_API_KEY=sk-ant-...")

## MODIFIED Requirements

### Requirement: Logging initialization (updated)
The logging system SHALL accept configuration from CLI flags in addition to environment variables.

#### Scenario: logging::init accepts LogConfig
- **WHEN** `logging::init(log_config)` is called
- **THEN** the tracing subscriber is configured according to the `LogConfig`
- **AND** if `LogConfig` has no module overrides, behavior is identical to the current implementation (TILLANDSIAS_LOG / RUST_LOG / default)
