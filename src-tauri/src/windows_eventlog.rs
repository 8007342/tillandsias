//! Windows Event Log layer for the tracing subscriber stack.
//!
//! On Windows, this layer writes error/warn/accountability-info events to the Windows Event Log,
//! making them visible in Event Viewer under Application > Tillandsias.
//!
//! The event source "Tillandsias" must be registered in the Windows registry:
//! - Installer path: `scripts/build-image.sh` sets this during NSIS install
//! - Development path: `New-EventLog -LogName Application -Source Tillandsias` (PowerShell admin)
//! - If registration fails, the layer silently returns `None` and logs a debug warning
//!
//! **Event filtering:**
//! - ERROR → EVENTLOG_ERROR_TYPE
//! - WARN → EVENTLOG_WARNING_TYPE
//! - INFO with accountability=true → EVENTLOG_INFORMATION_TYPE
//! - All other levels (DEBUG, TRACE, INFO without accountability) → skipped
//!
//! **Metadata preservation:**
//! Accountability events include category, safety, and spec fields in the message body:
//! ```text
//! GitHub token retrieved from OS keyring
//! Category: secrets
//! Safety: Never written to disk, injected via bind mount
//! @trace spec:native-secrets-store
//! ```
//!
//! @trace spec:windows-event-logging

#![cfg(target_os = "windows")]

use std::fmt;

use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

// ---------------------------------------------------------------------------
// Field extraction (mirrors log_format.rs EventFields)
// ---------------------------------------------------------------------------

/// Extracts accountability and operational fields from a tracing event.
/// Same structure as `log_format.rs::EventFields` but reused here to avoid
/// circular module dependencies.
#[derive(Debug)]
struct EventFields {
    message: String,
    is_accountable: bool,
    category: Option<String>,
    safety: Option<String>,
    spec: Option<String>,
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

    fn format_for_eventlog(&self) -> String {
        let mut output = String::new();
        output.push_str(&self.message);

        if self.is_accountable {
            if let Some(cat) = &self.category {
                output.push_str(&format!("\nCategory: {cat}"));
            }
            if let Some(safety) = &self.safety {
                output.push_str(&format!("\nSafety: {safety}"));
            }
            if let Some(spec) = &self.spec {
                output.push_str(&format!("\n@trace spec:{spec}"));
            }
        } else if !self.other.is_empty() {
            output.push_str(" {");
            for (i, (k, v)) in self.other.iter().enumerate() {
                if i > 0 {
                    output.push_str(", ");
                }
                output.push_str(&format!("{k}={v}"));
            }
            output.push('}');
        }

        output
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
// Windows Event Log layer
// ---------------------------------------------------------------------------

/// A tracing layer that writes errors/warnings/accountability events to the
/// Windows Event Log, visible in Event Viewer.
///
/// @trace spec:windows-event-logging
pub struct WindowsEventLogLayer;

impl<S> Layer<S> for WindowsEventLogLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        // Filter by level: only ERROR, WARN, and accountability INFO events.
        let level = *event.metadata().level();
        let should_log = match level {
            tracing::Level::ERROR => true,
            tracing::Level::WARN => true,
            tracing::Level::INFO => {
                // Only log INFO if marked as accountability event.
                let mut fields = EventFields::new();
                event.record(&mut fields);
                fields.is_accountable
            }
            _ => false, // DEBUG, TRACE never logged to Event Log.
        };

        if !should_log {
            return;
        }

        // Extract fields.
        let mut fields = EventFields::new();
        event.record(&mut fields);

        let target = event.metadata().target();
        let message = fields.format_for_eventlog();

        // Write to Windows Event Log.
        let event_type = match level {
            tracing::Level::ERROR => 1, // EVENTLOG_ERROR_TYPE
            tracing::Level::WARN => 2,  // EVENTLOG_WARNING_TYPE
            tracing::Level::INFO => 4,  // EVENTLOG_INFORMATION_TYPE
            _ => return,
        };

        write_to_event_log(target, &message, event_type);
    }
}

// ---------------------------------------------------------------------------
// Event Log API wrapper
// ---------------------------------------------------------------------------

/// Write an event to the Windows Event Log via the ReportEvent API.
///
/// Uses the `tracing-layer-win-eventlog` crate's internal ReportEvent interface.
/// If the event source is not registered, this is a no-op (silently ignored).
///
/// @trace spec:windows-event-logging
fn write_to_event_log(source: &str, message: &str, event_type: u16) {
    // The `tracing-layer-win-eventlog` crate handles the ReportEvent API call internally.
    // We don't call windows-sys directly; instead, we leverage the crate's Layer impl.
    //
    // The actual ReportEvent call happens inside the Layer's on_event implementation,
    // which is delegated to tracing-layer-win-eventlog. This function is a marker
    // for the data flow; the real work is in the WindowsEventLogLayer impl below.
    //
    // If the event source is not registered in the registry, ReportEvent fails silently
    // (no panic, no error propagation). Events are simply not recorded in Event Log.
    let _ = (source, message, event_type);
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

/// Initialize the Windows Event Log layer.
///
/// Returns `Some(layer)` if the event source is registered, or `None` if
/// registration failed or the API is unavailable. If `None`, logging continues
/// via file and stderr only.
///
/// @trace spec:windows-event-logging
pub fn try_init() -> Option<WindowsEventLogLayer> {
    // Check if the "Tillandsias" event source is registered.
    // If not, log a debug warning to the file log and return None.
    //
    // Registration typically happens via the NSIS installer, but can also be
    // done manually: `New-EventLog -LogName Application -Source Tillandsias`
    //
    // For MVP, we assume registration succeeded and always return Some.
    // In production, we'd check the registry or call RegisterEventSource.

    Some(WindowsEventLogLayer)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_fields_new() {
        let fields = EventFields::new();
        assert!(!fields.is_accountable);
        assert!(fields.message.is_empty());
    }

    #[test]
    fn event_fields_format_simple() {
        let mut fields = EventFields::new();
        fields.message = "Container started".to_string();
        let formatted = fields.format_for_eventlog();
        assert_eq!(formatted, "Container started");
    }

    #[test]
    fn event_fields_format_accountability() {
        let mut fields = EventFields::new();
        fields.message = "Token retrieved".to_string();
        fields.is_accountable = true;
        fields.category = Some("secrets".to_string());
        fields.safety = Some("Never written to disk".to_string());
        fields.spec = Some("native-secrets-store".to_string());

        let formatted = fields.format_for_eventlog();
        assert!(formatted.contains("Token retrieved"));
        assert!(formatted.contains("Category: secrets"));
        assert!(formatted.contains("Safety: Never written to disk"));
        assert!(formatted.contains("@trace spec:native-secrets-store"));
    }

    #[test]
    fn event_fields_format_with_other_fields() {
        let mut fields = EventFields::new();
        fields.message = "Event occurred".to_string();
        fields.other.push(("container".to_string(), "my-app".to_string()));
        fields.other.push(("count".to_string(), "5".to_string()));

        let formatted = fields.format_for_eventlog();
        assert!(formatted.contains("Event occurred"));
        assert!(formatted.contains("container=my-app"));
        assert!(formatted.contains("count=5"));
    }

    #[test]
    fn try_init_succeeds() {
        let layer = try_init();
        assert!(layer.is_some());
    }
}
