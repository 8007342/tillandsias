//! Compact event formatter with structured accountability rendering and deduplication.
//!
//! Replaces the default `tracing-subscriber` full/pretty formatters with a
//! condensed format that separates accountability metadata from regular fields.
//!
//! **Deduplication**: Identical messages within a 30-second window are suppressed.
//! When a new message arrives, any pending duplicates are flushed as
//! `  ... repeated N times (Xs)`.
//!
//! **Accountability events** (tagged with `accountability = true`):
//! ```text
//! 2026-04-01T18:49:44Z  INFO [secrets] GitHub token retrieved from OS keyring
//!   -> Never written to disk, injected via bind mount
//!   @trace spec:native-secrets-store
//! ```
//!
//! **Regular events:**
//! ```text
//! 2026-04-01T18:49:44Z  INFO secrets: Container stopped {container=tillandsias-myapp-aeranthos}
//! ```
//!
//! @trace spec:logging-accountability, spec:runtime-logging

use std::collections::hash_map::DefaultHasher;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::sync::Mutex;
use std::time::Instant;

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
// Deduplication state
// ---------------------------------------------------------------------------

/// Tracks the last logged message to suppress consecutive duplicates.
///
/// When the same message (by hash of message text + target) appears within
/// `DEDUP_WINDOW`, it's suppressed. When a different message arrives, any
/// accumulated duplicates are flushed as "... repeated N times (Xs)".
///
/// @trace spec:logging-accountability
struct DeduplicationState {
    /// Hash of the last emitted message (message text + target).
    last_hash: u64,
    /// How many times the current message has been suppressed.
    suppressed_count: u64,
    /// When the first instance of the current message was logged.
    first_seen: Instant,
}

impl DeduplicationState {
    fn new() -> Self {
        Self {
            last_hash: 0,
            suppressed_count: 0,
            first_seen: Instant::now(),
        }
    }
}

/// Window within which identical messages are suppressed.
const DEDUP_WINDOW_SECS: u64 = 30;

/// Compute a fingerprint for deduplication.
///
/// Uses message text + target so that the same message from different modules
/// is NOT deduplicated (they're different events).
fn message_fingerprint(message: &str, target: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    message.hash(&mut hasher);
    target.hash(&mut hasher);
    hasher.finish()
}

// ---------------------------------------------------------------------------
// Custom event formatter
// ---------------------------------------------------------------------------

/// Compact event formatter for Tillandsias logs with deduplication.
///
/// Renders accountability-tagged events with structured safety notes and
/// spec trace links. Regular events use a compact single-line format.
/// Consecutive identical messages within 30s are suppressed and counted.
///
/// ANSI coloring is determined at render time via `writer.has_ansi_escapes()`,
/// so a single `TillandsiasFormat` instance works for both file (no ANSI) and
/// stderr (ANSI) layers.
pub struct TillandsiasFormat {
    dedup: Mutex<DeduplicationState>,
}

impl TillandsiasFormat {
    pub fn new() -> Self {
        Self {
            dedup: Mutex::new(DeduplicationState::new()),
        }
    }
}

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

        let target = event.metadata().target();
        let fingerprint = message_fingerprint(&fields.message, target);

        // --- Deduplication check ---
        if let Ok(mut dedup) = self.dedup.lock() {
            let now = Instant::now();
            let within_window =
                now.duration_since(dedup.first_seen).as_secs() < DEDUP_WINDOW_SECS;

            if fingerprint == dedup.last_hash && within_window {
                // Same message within window — suppress it.
                dedup.suppressed_count += 1;
                return Ok(());
            }

            // Different message (or window expired) — flush any pending count.
            if dedup.suppressed_count > 0 {
                let elapsed = now.duration_since(dedup.first_seen).as_secs();
                if ansi {
                    writeln!(
                        writer,
                        "  \x1b[2m  ... repeated {} times ({}s)\x1b[0m",
                        dedup.suppressed_count, elapsed
                    )?;
                } else {
                    writeln!(
                        writer,
                        "    ... repeated {} times ({}s)",
                        dedup.suppressed_count, elapsed
                    )?;
                }
            }

            // Record this message as the new "last".
            dedup.last_hash = fingerprint;
            dedup.suppressed_count = 0;
            dedup.first_seen = now;
        }
        // If lock is poisoned, just render without dedup.

        // --- Render the event ---

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
            //     @trace spec:logging-accountability
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
            let short_target = shorten_target(target);
            write!(writer, " {short_target}: {}", fields.message)?;

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

    #[test]
    fn fingerprint_same_message_same_target() {
        let a = message_fingerprint("token retrieved", "secrets");
        let b = message_fingerprint("token retrieved", "secrets");
        assert_eq!(a, b);
    }

    #[test]
    fn fingerprint_different_message() {
        let a = message_fingerprint("token retrieved", "secrets");
        let b = message_fingerprint("token stored", "secrets");
        assert_ne!(a, b);
    }

    #[test]
    fn fingerprint_same_message_different_target() {
        let a = message_fingerprint("starting", "secrets");
        let b = message_fingerprint("starting", "handlers");
        assert_ne!(a, b);
    }

    #[test]
    fn dedup_state_defaults() {
        let state = DeduplicationState::new();
        assert_eq!(state.last_hash, 0);
        assert_eq!(state.suppressed_count, 0);
    }
}
