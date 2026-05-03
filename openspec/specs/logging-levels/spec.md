<!-- @trace spec:logging-levels -->

# logging-levels Specification

## Status

status: active
annotation-count: 4
derived-from: code annotations only (no archive)
last-updated: 2026-05-02

## Purpose

Defines the embedded external-logs.yaml configuration files that control logging verbosity for container services (Squid proxy, git service, router, inference, etc.). These YAML files are embedded in the Tillandsias binary at compile time, extracted to tmpfs at runtime, and mounted into container image build contexts to enable structured log routing and severity filtering.

## Requirements

### Requirement: External Logs Configuration Files

The Tillandsias binary MUST embed external-logs.yaml files for each service container that requires logging configuration.

#### Embedded Files

| Service | File | Purpose |
|---------|------|---------|
| Git Service | `images/git/external-logs.yaml` | Squid syslog and git daemon logging |
| Inference | `images/inference/external-logs.yaml` | Ollama and inference service logging |
| Router | `images/router/external-logs.yaml` | Router sidecar (DNS/networking) logging |
| Proxy | `images/proxy/external-logs.yaml` | Squid proxy caching and access logs |

**Embedding mechanism**: `include_str!("../../images/<service>/external-logs.yaml")` in `src-tauri/src/embedded.rs`

#### Scenario: Embedded configuration

- **WHEN** Tillandsias binary is built
- **THEN** each external-logs.yaml file MUST be compiled into the binary as a static string constant
- **AND** available as `GIT_EXTERNAL_LOGS`, `INFERENCE_EXTERNAL_LOGS`, `ROUTER_EXTERNAL_LOGS`, etc.

### Requirement: YAML Configuration Format

Each external-logs.yaml file MUST define logging rules using standard syslog/rsyslog conventions.

#### Configuration Structure

```yaml
# Example: images/git/external-logs.yaml
---
version: 1
facility: local1              # Syslog facility (local1 for git service)
hostname: tillandsias-git
services:
  - name: squid
    level: warn              # Log level: error, warn, info, debug, trace
    format: json             # Output format: json or text
  - name: git-daemon
    level: info
    format: json
```

**Required fields:**
- `version`: Always `1`
- `facility`: Syslog facility code (local0–local7, or user/daemon/etc.)
- `hostname`: Container hostname for syslog identification
- `services`: Array of service logging rules

**Service rule fields:**
- `name`: Service identifier (squid, git-daemon, ollama, router)
- `level`: Log severity — error < warn < info < debug < trace
- `format`: json (structured) or text (plain)

### Requirement: Runtime Extraction and Mounting

At startup, the tray MUST extract each embedded external-logs.yaml to tmpfs and mount it into the container build context.

#### Lifecycle: Binary → Tmpfs → Container

1. **Compile time**: YAML embedded in binary via `include_str!()`
2. **Startup**: Extract to tmpfs: `$XDG_RUNTIME_DIR/tillandsias/external-logs.yaml` or `$TMPDIR/tillandsias-external-logs.yaml`
3. **Build context**: COPY external-logs.yaml into container image build
4. **Container layer**: Bake into image at `/etc/tillandsias/external-logs.yaml`
5. **Runtime**: Mount as read-only volume or baked into image
6. **Cleanup**: Tmpfs file cleaned up on Tillandsias shutdown (handled by `runtime_dir()`)

#### Scenario: Git service logging setup

- **WHEN** tray initializes git service image build
- **THEN** extract `GIT_EXTERNAL_LOGS` constant to `/run/tillandsias/external-logs-git.yaml`
- **AND** add `COPY external-logs-git.yaml /etc/tillandsias/external-logs.yaml` to git Containerfile
- **AND** git startup script MUST mount config for syslog

### Requirement: Service-Specific Logging Levels

Each service container MUST respect the log level defined in its external-logs.yaml.

#### Log Level Semantics

| Level | Use Case | Verbosity |
|-------|----------|-----------|
| **error** | Failures that stop operations (network timeout, auth failure) | Very low |
| **warn** | Potential issues, degraded operation (retry, missing optional config) | Low |
| **info** | General operational events (startup, startup completion, major state change) | Medium |
| **debug** | Detailed diagnostics (request details, cache hits, module loading) | High |
| **trace** | Low-level implementation details (bytecode, loop iterations) | Very high |

#### Service-Specific Recommendations

| Service | Recommended Level | Rationale |
|---------|-------------------|-----------|
| **Squid proxy** | `warn` | Minimize log volume; only failures and retries matter |
| **Git daemon** | `info` | Track push/pull operations for audit |
| **Ollama inference** | `info` | Track model loading and inference requests |
| **Router sidecar** | `warn` | DNS and routing failures only |

### Requirement: Syslog Integration

External log configuration MUST route container logs to the host syslog via syslog protocol (RFC 3164).

- **Facility**: Service-specific (local0–local7)
- **Protocol**: UDP or Unix socket to host syslog
- **Hostname field**: MUST be set to container name for filtering (e.g., `tillandsias-git`)
- **Format**: Structured JSON when possible (for parsing)

#### Scenario: Git service syslog streaming

- **WHEN** git-daemon writes a log line: `INFO: Pushed refs/heads/main`
- **THEN** external-logs.yaml MUST route to syslog facility `local1`, hostname `tillandsias-git`
- **AND** line MUST appear in host syslog with timestamp and container name
- **AND** user CAN retrieve logs via: `journalctl --facility local1 -u tillandsias-git` (if systemd)

### Requirement: Diagnostics Integration

External log configuration MUST enable structured log collection via `--log-<service>` CLI flags.

#### CLI Flags (examples, see logging-levels cheatsheet)

```bash
tillandsias --log-proxy-management    # Stream proxy logs to stderr
tillandsias --log-git-management      # Stream git service logs to stderr
tillandsias --log-enclave-management  # Stream all enclave service logs
```

- **Mechanism**: Tray MUST read externals-logs.yaml config, open syslog stream, and re-emit to stderr
- **Format**: Same JSON format as in container
- **Timestamp**: Host-relative (recomputed on stderr emission)

#### Scenario: Proxy diagnostics

- **WHEN** user runs: `tillandsias --log-proxy-management`
- **THEN** tray MUST read `ROUTER_EXTERNAL_LOGS` config
- **AND** listen to syslog facility from router container
- **AND** stream decoded JSON log lines to stderr in real-time
- **AND** user MUST see proxy cache hits, DNS lookups, connection errors

### Requirement: No Runtime Reconfiguration

External log levels MUST NOT be changed at runtime; they are baked into container images at build time.

- **Immutability**: YAML file is read-only after bind-mount
- **Rebuild required**: To change log levels, image rebuild is required
- **CLI override exception**: `--log=module:level` flags in logging-levels cheatsheet override for tray binary ONLY, not container services

#### Scenario: Change git logging

- **WHEN** user wants to change git service logging from `info` to `debug`
- **THEN** manual process MUST be: edit `images/git/external-logs.yaml`, rebuild image, restart container
- **AND** NO `TILLANDSIAS_LOG` environment variable override SHOULD be used

### Requirement: Manifest and Documentation

Every external-logs.yaml file MUST include a manifest comment block describing its purpose and owner service.

#### Header Format

```yaml
# @trace spec:logging-levels, spec:cli-diagnostics
#
# Service: [Git Mirror / Inference / Router / Proxy]
# Owner: Tillandsias [subsystem name]
# Purpose: [One-line description of what gets logged]
# Format: JSON | Text
# Syslog Facility: local[0-7]
# Mounted at: /etc/tillandsias/external-logs.yaml
#
# Last updated: YYYY-MM-DD
# Provenance: [URL to config spec or tool docs]
---
```

#### Scenario: Git external-logs.yaml header

```yaml
# @trace spec:logging-levels, spec:cli-diagnostics, spec:git-mirror-service
#
# Service: Git Mirror
# Owner: Tillandsias enclave
# Purpose: Squid syslog integration + git-daemon push/pull audit
# Format: JSON
# Syslog Facility: local1
# Mounted at: /etc/tillandsias/external-logs.yaml
#
# Last updated: 2026-05-02
# Provenance: https://tools.ietf.org/html/rfc5424 (Syslog format)
---
```

## Sources of Truth

- `cheatsheets/runtime/logging-levels.md` — CLI flags, log level semantics, and examples
- `cheatsheets/runtime/syslog-configuration.md` — Syslog protocol and facility codes (if exists)
- https://tools.ietf.org/html/rfc5424 — Syslog Message Format standard

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- TRACE level only emitted when RUST_LOG or TILLANDSIAS_LOG explicitly enables it
- DEBUG level shows development details (image pulls, build logs, RPC calls)
- INFO level shows user-facing progress (container startup, authentication, sync)
- WARN level triggers alert UI if applicable (credential expiry, network timeout)
- ERROR level halts that operation and forces user remediation
- FATAL level stops entire tray
- --log-* CLI flags stream corresponding logs to diagnostic window in real-time
- Sensitive fields (tokens, credentials, SSHkeys) never appear in any log level

## Related Specifications

- `cli-diagnostics` — --log-* flags and diagnostic window streaming
- `git-mirror-service` — Git daemon and external log usage
- `proxy-container` — Squid proxy and log routing
- `inference-container` — Ollama service and logging
