<!-- @trace spec:logging-accountability -->
## Status

status: active

## Requirements

### Requirement: Per-module log level control
Users MUST be able to control log verbosity for individual subsystems via a CLI flag.

#### Scenario: Single module at trace level
- **WHEN** the user runs `tillandsias --log=secrets:trace <project>`
- **THEN** log output MUST include trace-level messages from the secrets module
- **AND** all other modules MUST log at the default level (info)
- **AND** trace messages MUST include `@trace spec:` references and GitHub code search URLs

#### Scenario: Multiple modules at different levels
- **WHEN** the user runs `tillandsias --log=secrets:trace;containers:debug;scanner:off <project>`
- **THEN** secrets module MUST log at trace level
- **AND** containers module MUST log at debug level
- **AND** scanner module MUST produce no log output
- **AND** other modules (updates, menu, events) MUST log at the default level

#### Scenario: Invalid module name
- **WHEN** the user runs `tillandsias --log=bogus:debug <project>`
- **THEN** a warning MUST be printed to stderr: "Unknown log module: bogus. Valid modules: secrets, containers, updates, scanner, menu, events"
- **AND** the application MUST start normally with default log levels

#### Scenario: Invalid log level
- **WHEN** the user runs `tillandsias --log=secrets:potato <project>`
- **THEN** an error MUST be printed to stderr: "Invalid log level: potato. Valid levels: off, error, warn, info, debug, trace"
- **AND** the secrets module MUST fall back to info level

#### Scenario: CLI flag overrides environment variable
- **GIVEN** `TILLANDSIAS_LOG=tillandsias=warn` is set in the environment
- **WHEN** the user runs `tillandsias --log=secrets:debug <project>`
- **THEN** the `--log` flag MUST take precedence
- **AND** secrets module MUST log at debug level (not warn)

### Requirement: Accountability windows
Users MUST be able to enable curated views of sensitive subsystem operations.

#### Scenario: Secret management accountability window
- **WHEN** the user runs `tillandsias --log-secrets-management <project>`
- **THEN** each secrets operation MUST produce output in the format:
  ```
  [secrets] v0.1.97.76 | <human-readable summary>
    Spec: <spec-name>
    Cheatsheet: docs/cheatsheets/secrets-management.md
  ```
- **AND** no actual secret values (tokens, keys, passwords) MUST appear in the output
- **AND** operations MUST include: keyring retrieval, token file writes, secret injection into containers, token rotation events

#### Scenario: Accountability window composes with --log
- **WHEN** the user runs `tillandsias --log-secrets-management --log=scanner:debug <project>`
- **THEN** both the accountability window output AND scanner debug output MUST be visible
- **AND** the accountability formatter MUST apply only to secrets operations

#### Scenario: Accountability window in tray mode
- **WHEN** the user runs `tillandsias --log-secrets-management` (no project path, tray mode)
- **THEN** accountability output MUST be written to the log file at `~/.local/state/tillandsias/tillandsias.log`
- **AND** if stderr is a terminal, accountability output MUST also be printed to stderr
- **AND** if stderr is not a terminal (e.g., launched from desktop file), only the log file MUST receive output

### Requirement: Zero-cost disabled modules
Log macros for disabled modules MUST have zero runtime cost.

#### Scenario: Disabled module has no overhead
- **GIVEN** the scanner module is set to `off` via `--log=scanner:off`
- **WHEN** scanner code executes log macros
- **THEN** no string formatting, allocation, or I/O MUST occur for those macros
- **AND** this MUST be verified by the `tracing` crate's callsite filtering mechanism

### Requirement: Spec URLs at trace level
Trace-level log output MUST include clickable GitHub code search URLs for spec traceability.

#### Scenario: Trace output includes spec URL
- **GIVEN** the secrets module is at trace level
- **WHEN** a spec-governed operation executes (e.g., token write)
- **THEN** the trace output MUST include lines:
  ```
  @trace spec:secret-rotation
  https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Asecret-rotation&type=code
  ```
- **AND** the URL MUST be a valid GitHub code search link that finds all files implementing the spec

#### Scenario: Spec URLs not generated at non-trace levels
- **GIVEN** the secrets module is at info level
- **WHEN** a spec-governed operation executes
- **THEN** no spec URL MUST be generated or formatted (zero cost)

### Requirement: No secrets in logs
Log output MUST NOT contain actual secret values, regardless of log level.

#### Scenario: Token values are redacted
- **WHEN** any log message references a token or API key
- **THEN** the log MUST show the operation and target but not the secret value
- **AND** examples: "Token retrieved from native keyring" (not "Token gho_abc123 retrieved"), "ANTHROPIC_API_KEY injected" (not "ANTHROPIC_API_KEY=sk-ant-...")

### Requirement: Logging initialization (updated)
The logging system MUST accept configuration from CLI flags in addition to environment variables.

#### Scenario: logging::init accepts LogConfig
- **WHEN** `logging::init(log_config)` is called
- **THEN** the tracing subscriber MUST be configured according to the `LogConfig`
- **AND** if `LogConfig` has no module overrides, behavior MUST be identical to the current implementation (TILLANDSIAS_LOG / RUST_LOG / default)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- Each log line includes structured fields: timestamp, level, module, message
- Accountability log format includes `account_id`, `timestamp`, `source`, `action`, optional `error`
- All container/forge/proxy operations logged to stdout (captured by tray)
- Sensitive fields (credentials, tokens) never logged
- Log filtering via `TILLANDSIAS_LOG=module1=warn,module2=debug` works end-to-end
- LogConfig struct properly serialized from env vars and passed to logging::init
- Backward compatibility: no env vars = default behavior (identical to current implementation)

## Sources of Truth

- `cheatsheets/runtime/logging-levels.md` — Logging Levels reference and patterns
- `cheatsheets/runtime/external-logs.md` — External Logs reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:logging-accountability" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
