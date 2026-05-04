//! Logging initialization with per-module log levels and accountability windows.
//!
//! The logging system supports three configuration sources, in priority order:
//!
//!   1. `--log=module:level;...` CLI flag (highest priority)
//!   2. `TILLANDSIAS_LOG` environment variable
//!   3. `RUST_LOG` environment variable
//!   4. Default: `tillandsias=info` (lowest priority)
//!
//! Accountability windows (`--log-secrets-management`, etc.) are composable
//! with `--log` and add a curated stderr layer for sensitive operations.
//!
//! @trace spec:logging-accountability, spec:runtime-logging

use std::io::IsTerminal;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

use tillandsias_core::config::log_dir;

use crate::cli::{AccountabilityWindow, LogConfig};

// ---------------------------------------------------------------------------
// Module-to-target mapping
// ---------------------------------------------------------------------------

/// Map a user-facing module name to one or more Rust tracing targets.
///
/// These targets match the crate/module paths used in `tracing` macros.
/// The `tillandsias` crate is referenced as `tillandsias` in tracing
/// targets because of how the binary crate's module path works.
///
/// Used by `build_filter_from_config` and tested from `cli::tests`.
pub fn module_to_targets(module: &str) -> Vec<&'static str> {
    match module {
        "secrets" => vec!["tillandsias::secrets", "tillandsias::launch"],
        "containers" => vec![
            "tillandsias::handlers",
            "tillandsias::launch",
            "tillandsias_podman",
        ],
        "updates" => vec![
            "tillandsias::updater",
            "tillandsias::update_cli",
            "tillandsias::update_log",
        ],
        "scanner" => vec!["tillandsias_scanner"],
        "menu" => vec!["tillandsias::menu", "tillandsias::event_loop"],
        "events" => vec![
            "tillandsias::event_loop",
            "tillandsias_podman::events",
        ],
        // @trace spec:proxy-container
        "proxy" => vec![
            "tillandsias::handlers",
            "tillandsias::proxy",
        ],
        // @trace spec:enclave-network
        "enclave" => vec![
            "tillandsias::handlers",
            "tillandsias::enclave",
        ],
        // @trace spec:git-mirror-service
        "git" => vec![
            "tillandsias::handlers",
            "tillandsias::git",
        ],
        _ => vec![],
    }
}

// ---------------------------------------------------------------------------
// Filter construction
// ---------------------------------------------------------------------------

/// Build an [`EnvFilter`] from `LogConfig`.
///
/// If the config has module overrides, those take precedence over environment
/// variables. Each user-facing module name is expanded to its Rust targets.
/// Modules not mentioned in the config keep the default level (`info`).
///
/// If the config is empty (no `--log` flag), falls back to the env var chain:
/// `TILLANDSIAS_LOG` -> `RUST_LOG` -> `tillandsias=info`.
fn build_filter(config: &LogConfig) -> EnvFilter {
    if config.modules.is_empty() && config.accountability.is_empty() {
        return build_env_filter();
    }

    // Start with a base that allows info-level for the tillandsias crates.
    let mut directives = vec!["tillandsias=info".to_string()];

    // Apply per-module overrides from --log flag.
    for ml in &config.modules {
        for target in module_to_targets(&ml.module) {
            directives.push(format!("{target}={}", ml.level));
        }
    }

    // Accountability windows implicitly enable their modules at info level
    // (or trace if --log already set a higher detail level for that module).
    for window in &config.accountability {
        // @trace spec:proxy-container
        // @trace spec:enclave-network
        // @trace spec:git-mirror-service
        let module_name = match window {
            AccountabilityWindow::SecretManagement => "secrets",
            AccountabilityWindow::ImageManagement => "containers",
            AccountabilityWindow::UpdateCycle => "updates",
            AccountabilityWindow::ProxyManagement => "proxy",
            AccountabilityWindow::EnclaveManagement => "enclave",
            AccountabilityWindow::GitManagement => "git",
        };

        // Only add if not already overridden by --log.
        let already_set = config.modules.iter().any(|ml| ml.module == module_name);
        if !already_set {
            for target in module_to_targets(module_name) {
                directives.push(format!("{target}=info"));
            }
        }
    }

    let filter_str = directives.join(",");
    EnvFilter::try_new(&filter_str).unwrap_or_else(|_| {
        eprintln!("Warning: Failed to parse log filter: {filter_str}");
        EnvFilter::new("tillandsias=info")
    })
}

/// Build an [`EnvFilter`] by checking `TILLANDSIAS_LOG` first, then `RUST_LOG`,
/// falling back to `"tillandsias=info"`.
fn build_env_filter() -> EnvFilter {
    if let Ok(val) = std::env::var("TILLANDSIAS_LOG") {
        EnvFilter::try_new(&val).unwrap_or_else(|_| EnvFilter::new("tillandsias=info"))
    } else {
        EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new("tillandsias=info"))
    }
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

/// Initialize the tracing subscriber with file logging, optional stderr output,
/// and optional accountability layer.
///
/// Accepts a `LogConfig` parsed from CLI arguments. If the config is default
/// (no flags), behavior is identical to the previous `init()`.
///
/// Returns a [`WorkerGuard`] that **must** be held for the lifetime of the
/// application so the non-blocking file writer flushes on shutdown.
pub fn init(config: &LogConfig) -> WorkerGuard {
    let log_path = log_dir();

    // Ensure the log directory exists.
    if let Err(e) = std::fs::create_dir_all(&log_path) {
        eprintln!("Failed to create log directory {}: {e}", log_path.display());
    }

    let file_appender = tracing_appender::rolling::never(&log_path, "tillandsias.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = tracing_subscriber::fmt::layer()
        .event_format(crate::log_format::TillandsiasFormat::new())
        .with_writer(non_blocking)
        .with_ansi(false);

    let filter = build_filter(config);

    // Pretty-print to stderr only when running in a terminal.
    // Wrap the stderr writer so a closed terminal (BrokenPipe/EPIPE) doesn't
    // crash the tray — the file appender keeps receiving every event.
    // @trace spec:tray-cli-coexistence
    let stderr_layer = if std::io::stderr().is_terminal() {
        Some(
            tracing_subscriber::fmt::layer()
                .event_format(crate::log_format::TillandsiasFormat::new())
                .with_writer(BrokenPipeStderr),
        )
    } else {
        None
    };

    tracing_subscriber::registry()
        .with(filter)
        .with(file_layer)
        .with(stderr_layer)
        .init();

    guard
}

// ---------------------------------------------------------------------------
// Broken-pipe-tolerant stderr writer
// ---------------------------------------------------------------------------

/// Writer that swallows `BrokenPipe` errors so a closed terminal doesn't
/// crash the process. Other errors propagate normally.
///
/// @trace spec:tray-cli-coexistence
struct BrokenPipeFilter<W>(W);

impl<W: std::io::Write> std::io::Write for BrokenPipeFilter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self.0.write(buf) {
            Ok(n) => Ok(n),
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => Ok(buf.len()),
            Err(e) => Err(e),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self.0.flush() {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
            Err(e) => Err(e),
        }
    }
}

/// `MakeWriter` that produces a `BrokenPipeFilter<Stderr>` per write.
///
/// @trace spec:tray-cli-coexistence
struct BrokenPipeStderr;

impl<'a> MakeWriter<'a> for BrokenPipeStderr {
    type Writer = BrokenPipeFilter<std::io::Stderr>;
    fn make_writer(&'a self) -> Self::Writer {
        BrokenPipeFilter(std::io::stderr())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn broken_pipe_writer_swallows_errors() {
        use std::io::Write;
        struct AlwaysBrokenPipe;
        impl Write for AlwaysBrokenPipe {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe))
            }
        }
        let mut w = BrokenPipeFilter(AlwaysBrokenPipe);
        assert_eq!(w.write(b"hello").unwrap(), 5);
        assert!(w.flush().is_ok());
    }

    #[test]
    fn broken_pipe_writer_passes_other_errors() {
        use std::io::Write;
        struct OtherError;
        impl Write for OtherError {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut w = BrokenPipeFilter(OtherError);
        assert_eq!(
            w.write(b"x").unwrap_err().kind(),
            std::io::ErrorKind::PermissionDenied
        );
    }
}
