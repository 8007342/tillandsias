use std::io::IsTerminal;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

use tillandsias_core::config::log_dir;

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

/// Initialize the tracing subscriber with file logging and optional stderr output.
///
/// Returns a [`WorkerGuard`] that **must** be held for the lifetime of the
/// application so the non-blocking file writer flushes on shutdown.
pub fn init() -> WorkerGuard {
    let log_path = log_dir();

    // Ensure the log directory exists.
    if let Err(e) = std::fs::create_dir_all(&log_path) {
        eprintln!("Failed to create log directory {}: {e}", log_path.display());
    }

    let file_appender = tracing_appender::rolling::never(&log_path, "tillandsias.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false);

    let filter = build_env_filter();

    // Pretty-print to stderr only when running in a terminal.
    let stderr_layer = if std::io::stderr().is_terminal() {
        Some(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .pretty(),
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
