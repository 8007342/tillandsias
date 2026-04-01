//! Compact event formatter with structured accountability rendering.
//!
//! Replaces the default `tracing-subscriber` full/pretty formatters with a
//! condensed format that separates accountability metadata from regular fields:
//!
//! **Accountability events** (tagged with `accountability = true`):
//! ```text
//! 2026-04-01T18:49:44Z  INFO [secrets] GitHub token retrieved from OS keyring
//!   -> Never written to disk, injected via bind mount
//!   @trace spec:native-secrets-store https://github.com/8007342/tillandsias/search?q=...
//! ```
//!
//! **Regular events:**
//! ```text
//! 2026-04-01T18:49:44Z  INFO secrets: Container stopped {container=tillandsias-myapp-aeranthos}
//! ```
//!
//! @trace spec:logging-accountability

use std::fmt;

use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::fmt::format;
use tracing_subscriber::fmt::time::{FormatTime, SystemTime};
use tracing_subscriber::fmt::{FmtContext, FormatEvent, FormatFields};
use tracing_subscriber::registry::LookupSpan;

// ---------------------------------------------------------------------------
// Field extraction visitor
// ---------------------------------------------------------------------------

/// Extracts and classifies fields from a tracing event.
///
/// Accountability metadata (`accountability`, `category`, `safety`, `spec`)
/// is separated from regular operational fields so the formatter can render
/// them differently.
struct EventFields {
    message: String,
    is_accountable: bool,
    category: Option<String>,
    safety: Option<String>,
    spec: Option<String>,
    /// Non-accountability fields like `container`, `error`, `tag`, etc.
    other: Vec<(String, String)>,
}

impl EventFields {
    fn new() -> Self {
        Self {
            message: String::new(),
            is_accountable: false,
            category: None,
            safety: None,
            spec: None,
            other: Vec::new(),
        }
    }
}

impl Visit for EventFields {
    fn record_bool(&mut self, field: &Field, value: bool) {
        if field.name() == "accountability" {
            self.is_accountable = value;
        } else {
            self.other
                .push((field.name().to_string(), value.to_string()));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "message" => self.message = value.to_string(),
            "category" => self.category = Some(value.to_string()),
            "safety" => self.safety = Some(value.to_string()),
            "spec" => self.spec = Some(value.to_string()),
            _ => self
                .other
                .push((field.name().to_string(), value.to_string())),
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "message" {
            self.message = format!("{value:?}");
        } else {
            self.other
                .push((field.name().to_string(), format!("{value:?}")));
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.other
            .push((field.name().to_string(), value.to_string()));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.other
            .push((field.name().to_string(), value.to_string()));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.other
            .push((field.name().to_string(), format!("{value:.2}")));
    }
}

// ---------------------------------------------------------------------------
// Custom event formatter
// ---------------------------------------------------------------------------

/// Compact event formatter for Tillandsias logs.
///
/// Renders accountability-tagged events with structured safety notes and
/// spec trace links. Regular events use a compact single-line format.
///
/// ANSI coloring is determined at render time via `writer.has_ansi_escapes()`,
/// so a single `TillandsiasFormat` instance works for both file (no ANSI) and
/// stderr (ANSI) layers.
pub struct TillandsiasFormat;

impl<S, N> FormatEvent<S, N> for TillandsiasFormat
where
    S: Subscriber + for<'a> LookupSpan<'a>,
    N: for<'a> FormatFields<'a> + 'static,
{
    fn format_event(
        &self,
        _ctx: &FmtContext<'_, S, N>,
        mut writer: format::Writer<'_>,
        event: &Event<'_>,
    ) -> fmt::Result {
        let ansi = writer.has_ansi_escapes();

        // Extract and classify fields.
        let mut fields = EventFields::new();
        event.record(&mut fields);

        // Timestamp (delegates to tracing-subscriber's SystemTime).
        SystemTime.format_time(&mut writer)?;

        // Level (right-aligned, 5 chars: ERROR, WARN, INFO, DEBUG, TRACE).
        let level = *event.metadata().level();
        if ansi {
            write!(writer, " {}{level:>5}\x1b[0m", level_ansi(level))?;
        } else {
            write!(writer, " {level:>5}")?;
        }

        if fields.is_accountable {
            // Accountability format:
            //   TIMESTAMP LEVEL [category] message {extra fields}
            //     -> safety note
            //     @trace spec:name https://...
            let cat = fields.category.as_deref().unwrap_or("unknown");

            if ansi {
                write!(writer, " \x1b[1;32m[{cat}]\x1b[0m {}", fields.message)?;
            } else {
                write!(writer, " [{cat}] {}", fields.message)?;
            }

            // Append any extra non-accountability fields.
            write_other_fields(&mut writer, &fields.other)?;

            // Safety note.
            if let Some(ref safety) = fields.safety {
                if ansi {
                    write!(writer, "\n  \x1b[36m->\x1b[0m {safety}")?;
                } else {
                    write!(writer, "\n  -> {safety}")?;
                }
            }

            // Spec trace links (one per spec, split on comma).
            if let Some(ref spec_str) = fields.spec {
                for spec_name in spec_str.split(',').map(str::trim) {
                    let url = crate::accountability::spec_url(spec_name);
                    if ansi {
                        write!(
                            writer,
                            "\n  \x1b[2m@trace spec:{spec_name} {url}\x1b[0m"
                        )?;
                    } else {
                        write!(writer, "\n  @trace spec:{spec_name} {url}")?;
                    }
                }
            }
        } else {
            // Compact format:
            //   TIMESTAMP LEVEL target: message {extra fields}
            let target = shorten_target(event.metadata().target());
            write!(writer, " {target}: {}", fields.message)?;

            // Append structured fields.
            write_other_fields(&mut writer, &fields.other)?;
        }

        writeln!(writer)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Write `{key=val, key=val}` for non-empty field lists.
fn write_other_fields(writer: &mut format::Writer<'_>, fields: &[(String, String)]) -> fmt::Result {
    if fields.is_empty() {
        return Ok(());
    }
    write!(writer, " {{")?;
    for (i, (k, v)) in fields.iter().enumerate() {
        if i > 0 {
            write!(writer, ", ")?;
        }
        write!(writer, "{k}={v}")?;
    }
    write!(writer, "}}")
}

/// Shorten tracing targets to human-friendly module names.
///
/// - `tillandsias_tray::secrets` → `secrets`
/// - `tillandsias_podman::events` → `podman::events`
/// - `tillandsias_scanner` → `scanner`
/// - `secrets` → `secrets` (already short, e.g. explicit `target:`)
pub fn shorten_target(target: &str) -> &str {
    target
        .strip_prefix("tillandsias_tray::")
        .or_else(|| target.strip_prefix("tillandsias_"))
        .unwrap_or(target)
}

/// ANSI escape sequence for the given log level.
fn level_ansi(level: tracing::Level) -> &'static str {
    match level {
        tracing::Level::ERROR => "\x1b[1;31m", // bold red
        tracing::Level::WARN => "\x1b[1;33m",  // bold yellow
        tracing::Level::INFO => "\x1b[1;32m",   // bold green
        tracing::Level::DEBUG => "\x1b[1;34m",  // bold blue
        tracing::Level::TRACE => "\x1b[2m",     // dim
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shorten_target_strips_tray_prefix() {
        assert_eq!(shorten_target("tillandsias_tray::secrets"), "secrets");
        assert_eq!(shorten_target("tillandsias_tray::handlers"), "handlers");
        assert_eq!(shorten_target("tillandsias_tray::launch"), "launch");
    }

    #[test]
    fn shorten_target_strips_crate_prefix() {
        assert_eq!(shorten_target("tillandsias_podman"), "podman");
        assert_eq!(shorten_target("tillandsias_scanner"), "scanner");
        assert_eq!(
            shorten_target("tillandsias_podman::events"),
            "podman::events"
        );
    }

    #[test]
    fn shorten_target_preserves_short_targets() {
        assert_eq!(shorten_target("secrets"), "secrets");
        assert_eq!(shorten_target("some_other_crate"), "some_other_crate");
    }

    #[test]
    fn shorten_target_preserves_core_crate() {
        assert_eq!(shorten_target("tillandsias_core"), "core");
        assert_eq!(
            shorten_target("tillandsias_core::config"),
            "core::config"
        );
    }

    #[test]
    fn event_fields_defaults() {
        let fields = EventFields::new();
        assert!(!fields.is_accountable);
        assert!(fields.message.is_empty());
        assert!(fields.category.is_none());
        assert!(fields.safety.is_none());
        assert!(fields.spec.is_none());
        assert!(fields.other.is_empty());
    }
}
