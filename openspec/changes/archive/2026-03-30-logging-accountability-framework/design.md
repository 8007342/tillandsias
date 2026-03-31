## Context

Tillandsias uses the `tracing` crate with `tracing-subscriber` for structured logging. The current setup in `logging.rs` creates a dual-output subscriber: a non-blocking file appender (to `~/.local/state/tillandsias/tillandsias.log`) and an optional pretty-printed stderr layer (only when stderr is a terminal). The filter is built from `TILLANDSIAS_LOG`, then `RUST_LOG`, then defaults to `tillandsias=info`.

This works for basic development but provides no user-facing control. Users cannot target specific subsystems, and there is no structured way to audit what the application did with their secrets, containers, or updates.

## Goals / Non-Goals

**Goals:**
- Users can control log verbosity per-module via a single CLI flag
- Accountability windows provide curated, human-readable summaries of sensitive operations
- Trace-level output links to spec documentation via clickable URLs
- Zero runtime cost for disabled log levels (leveraging `tracing`'s compile-time and runtime filtering)
- The logging framework is composable: accountability windows are just pre-configured filter + formatter combinations

**Non-Goals:**
- Log aggregation, remote logging, or cloud telemetry (privacy-first)
- Changing the log file format (structured JSON, etc.) — keep plain text
- GUI log viewer (this is CLI/terminal only)
- Replacing `tracing` with a different logging framework

## Decisions

### D1: Six named log modules

**Choice:** Define six user-facing module names that map to Rust module paths:

| User module | Rust target(s) | What it covers |
|-------------|----------------|----------------|
| `secrets` | `tillandsias::secrets`, `tillandsias::launch` (secret resolution) | Keyring ops, token file writes, secret injection into containers |
| `containers` | `tillandsias::handlers`, `tillandsias::launch`, `tillandsias_podman` | Container create/start/stop/destroy, podman args, port allocation |
| `updates` | `tillandsias::updater`, `tillandsias::update_cli`, `tillandsias::update_log` | Version checks, download, apply, restart |
| `scanner` | `tillandsias_scanner` | Filesystem watching, project discovery, debounce |
| `menu` | `tillandsias::menu`, `tillandsias::event_loop` | Tray menu rebuilds, menu event dispatch, icon state |
| `events` | `tillandsias::event_loop`, `tillandsias_podman::events` | The main `tokio::select!` loop, podman event stream |

**Why:** Users think in terms of "what the app does" (handles secrets, manages containers), not Rust module paths. Six modules provide enough granularity without overwhelming. The mapping is defined in a single function that produces an `EnvFilter` string from the parsed CLI input.

**Trade-off:** Some Rust modules map to multiple user modules (e.g., `event_loop.rs` spans both `menu` and `events`). This is acceptable because the `tracing` span hierarchy carries enough context to disambiguate. Future refinement can split spans if needed.

### D2: CLI flag syntax `--log=module:level;module:level`

**Choice:** A single `--log` flag with semicolon-separated module:level pairs. Levels are standard `tracing` levels: `off`, `error`, `warn`, `info`, `debug`, `trace`.

Examples:
```
--log=secrets:trace                     # Just secrets at trace
--log=secrets:trace;containers:debug    # Two modules
--log=secrets:trace;scanner:off         # Disable scanner noise
```

**Why:** Semicolons avoid shell quoting issues with commas in some contexts. The syntax mirrors `EnvFilter` conventions. A single flag is simpler than six `--log-secrets=trace` flags.

**Parsing:** The flag value is parsed in `cli.rs` into a `Vec<(String, Level)>`, then converted to an `EnvFilter` directive string in `logging.rs`. Invalid module names produce a warning and are skipped. Invalid levels produce an error and fall back to `info`.

**Interaction with `TILLANDSIAS_LOG`:** The CLI flag takes precedence. If both are set, `--log` wins. `TILLANDSIAS_LOG` remains as a fallback for environments where CLI flags aren't convenient (e.g., systemd units, launchd).

### D3: Accountability windows as curated log presets

**Choice:** Each `--log-*` accountability flag is syntactic sugar for a specific filter configuration plus a custom formatter:

| Flag | Equivalent filter | Custom formatting |
|------|-------------------|-------------------|
| `--log-secret-management` | `secrets:info` + accountability formatter | Prefixed `[secrets]`, includes spec links, version |
| `--log-image-management` | `containers:info` + accountability formatter | Prefixed `[images]`, build lifecycle events |
| `--log-update-cycle` | `updates:info` + accountability formatter | Prefixed `[updates]`, version diff, download progress |

**Why:** Accountability windows are not "special logging modes" — they are pre-configured module filters with a custom `tracing_subscriber::fmt::FormatEvent` implementation that adds:
1. A category prefix (`[secrets]`, `[images]`, `[updates]`)
2. A human-readable summary of what happened and why
3. A link to the relevant cheatsheet document
4. The application version

This design means accountability windows compose with `--log`: you can use `--log-secret-management --log=scanner:debug` and both work simultaneously.

**Formatter:** The accountability formatter is a `tracing_subscriber::Layer` that filters on spans tagged with `accountability = true`. Log callsites in the secrets module emit spans with this tag when performing accountable operations. The layer formats these spans with the accountability prefix and metadata, while non-accountable spans pass through to the normal formatter.

### D4: Zero-cost disabled modules

**Choice:** Rely on `tracing`'s existing callsite filtering. When a module's level is set to `off` or a level higher than the callsite, the `tracing` macro fast-path skips all argument evaluation.

**Why:** The `tracing` crate already provides this. We formalize it as a convention:

```rust
// This is zero-cost when secrets module is at warn or higher:
trace!(
    spec = "secret-rotation",
    "Token written for {container} -> {path} (tmpfs, ro mount)"
);
```

No custom macro wrapper needed. The project convention is simply: "use `trace!` for detailed operational logging, `debug!` for state transitions, `info!` for significant events, `warn!`/`error!` for problems."

### D5: Spec URLs at trace level

**Choice:** At `trace` level, log messages for spec-governed operations include a clickable GitHub code search URL:

```
TRACE secrets: Token written for tillandsias-tetris-aeranthos
  @trace spec:secret-rotation
  https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Asecret-rotation&type=code
```

**Why:** This closes the loop between runtime behavior and design documentation. A developer investigating a trace log can click the URL to find every source file that implements the spec, then navigate to the OpenSpec design document for the "why."

**Implementation:** A helper function `spec_url(spec_name: &str) -> String` generates the URL. It is called in `trace!` macros with a `spec` field. The accountability formatter recognizes this field and renders it as a clickable URL. At levels below trace, the URL is never generated (zero-cost).

### D6: Accountability window output format

**Choice:** Accountability window output follows a consistent format:

```
[secrets] v0.1.97.76 | Token retrieved from native keyring
  Spec: native-secrets-store
  Cheatsheet: docs/cheatsheets/secret-management.md

[secrets] v0.1.97.76 | Token written for tillandsias-tetris-aeranthos -> /run/secrets/... (tmpfs, ro mount)
  Spec: secret-rotation
  Cheatsheet: docs/cheatsheets/token-rotation.md

[secrets] v0.1.97.76 | Token refreshed for tillandsias-tetris-aeranthos (55min rotation)
  Spec: secret-rotation
  Cheatsheet: docs/cheatsheets/token-rotation.md

[secrets] v0.1.97.76 | Token revoked for tillandsias-tetris-aeranthos (container stopped)
  Spec: secret-rotation
  Cheatsheet: docs/cheatsheets/token-rotation.md
```

**Why:** Each line answers three questions:
1. **What was done** — the summary line
2. **Why** — the spec name (which links to the design decision)
3. **How** — the cheatsheet (which explains the mechanism in plain language)

The version is included so that support interactions can immediately identify which build produced the log. No secrets are ever shown — only the fact that an operation occurred, the target, and the mechanism.

## Log Level Guidelines

| Level | When to use | Example |
|-------|-------------|---------|
| `error` | Unrecoverable failure, user action needed | "Failed to write token file: permission denied" |
| `warn` | Degraded operation, automatic fallback | "Keyring unavailable, falling back to hosts.yml" |
| `info` | Significant lifecycle events | "Container started: tillandsias-tetris-aeranthos" |
| `debug` | State transitions, decision points | "Resolved repo name: alice/tetris from git remote" |
| `trace` | Detailed operations with spec links | "Token written for ... @trace spec:secret-rotation" |

## Architecture

```
CLI args: --log=secrets:trace;containers:debug --log-secret-management
    |
    v
cli.rs: parse_log_config() -> LogConfig {
    modules: [(secrets, Trace), (containers, Debug)],
    accountability: [SecretManagement],
}
    |
    v
logging.rs: init(log_config) -> WorkerGuard
    |
    +-- Build EnvFilter from module map
    |     "tillandsias::secrets=trace,tillandsias::handlers=debug,..."
    |
    +-- File layer (always, all levels that pass filter)
    |
    +-- Stderr layer (if terminal, pretty-print)
    |
    +-- Accountability layer (if any --log-* flags)
          Filters on spans with accountability=true
          Custom formatter with [category], spec, cheatsheet
```

## Open Questions

1. **Should accountability output go to a separate file?** Current design: same file + stderr. Alternative: `~/.local/state/tillandsias/accountability.log` as a separate append-only log. Pro: easy to find and share. Con: another file to manage. **Leaning toward: same output, separate file is a future enhancement.**

2. **Should `--log` be available in tray mode (no terminal)?** Yes — the filter still applies to the log file. But the accountability formatter's stderr output is only useful with a terminal. For tray mode, accountability output goes only to the log file. **Decision: support it, stderr output is conditional on `is_terminal()`.**

3. **How do accountability windows interact with the future `fine-grained-pat-rotation` change?** The `secret-rotation-tokens` change (this batch) defines the token lifecycle events that the accountability window will display. The logging framework must be in place first so that token rotation code can emit accountability-tagged spans from day one. **Decision: logging-accountability-framework is a prerequisite for secret-rotation-tokens.**
