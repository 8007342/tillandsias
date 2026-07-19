//! Windows Event Log layer for the tracing subscriber stack.
//!
//! Relays tray tracing events to the Windows Application Event Log so a power
//! user can discover Tillandsias failures (e.g. a provisioning error) in
//! Event Viewer > Windows Logs > Application > Source "Tillandsias" — even
//! when the tray UI is crash-looping and the file log is hard to reach.
//!
//! **Event filtering** (operator directive 2026-07-18: relay ALL INFO, not
//! just accountability INFO — provisioning progress/failure events flow up to
//! the UX at INFO/WARN/ERROR and every one of them must be discoverable):
//! - ERROR → `EVENTLOG_ERROR_TYPE`
//! - WARN  → `EVENTLOG_WARNING_TYPE`
//! - INFO  → `EVENTLOG_INFORMATION_TYPE`
//! - DEBUG, TRACE → skipped (file log only)
//!
//! **Registration**: `RegisterEventSourceW` succeeds even when the source is
//! not registered under `HKLM\...\Services\EventLog\Application\Tillandsias`;
//! events still land in the Application log, rendered with Event Viewer's
//! "description not found" wrapper around the message text. The installer's
//! one-time elevated step runs `New-EventLog -LogName Application -Source
//! Tillandsias` (which points `EventMessageFile` at the .NET pass-through
//! message DLL) so registered machines render clean messages. Either way the
//! layer never fails tray startup: if the source handle cannot be obtained the
//! layer is inert and file logging continues.
//!
//! **Metadata preservation**: accountability events append category, safety,
//! and spec fields to the message body:
//! ```text
//! GitHub token retrieved from OS keyring
//! Category: secrets
//! Safety: Never written to disk, injected via bind mount
//! @trace spec:native-secrets-store
//! ```
//!
//! @trace spec:windows-event-logging

// Whole-module gate: tracing-subscriber/tracing-appender are Windows-only
// dependencies of this crate, so non-Windows workspace builds compile this
// file to nothing (same pattern as the old src-tauri module).
#![cfg(target_os = "windows")]

use std::fmt;

use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

/// Fields extracted from a tracing event for Event Log formatting.
#[derive(Debug, Default)]
struct EventFields {
    message: String,
    is_accountable: bool,
    category: Option<String>,
    safety: Option<String>,
    spec: Option<String>,
    other: Vec<(String, String)>,
}

impl EventFields {
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

/// Windows Event Log event types (winnt.h values; kept as plain constants so
/// the mapping is testable on every platform).
const EVENTLOG_ERROR_TYPE: u16 = 0x0001;
const EVENTLOG_WARNING_TYPE: u16 = 0x0002;
const EVENTLOG_INFORMATION_TYPE: u16 = 0x0004;

/// Map a tracing level to a Windows event type, or `None` when the level must
/// not be relayed (DEBUG/TRACE stay in the file log only).
fn event_type_for_level(level: tracing::Level) -> Option<u16> {
    match level {
        tracing::Level::ERROR => Some(EVENTLOG_ERROR_TYPE),
        tracing::Level::WARN => Some(EVENTLOG_WARNING_TYPE),
        tracing::Level::INFO => Some(EVENTLOG_INFORMATION_TYPE),
        _ => None,
    }
}

/// A tracing layer that relays INFO/WARN/ERROR events to the Windows
/// Application Event Log under source "Tillandsias".
///
/// @trace spec:windows-event-logging
pub struct WindowsEventLogLayer {
    source: win::EventSource,
}

/// Build the layer, or `None` when the event source handle cannot be obtained
/// (layer disabled; file + UX logging continue — degradation is mandatory,
/// a logging relay must never take the tray down).
pub fn try_layer() -> Option<WindowsEventLogLayer> {
    win::EventSource::register().map(|source| WindowsEventLogLayer { source })
}

impl<S> Layer<S> for WindowsEventLogLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let Some(event_type) = event_type_for_level(*event.metadata().level()) else {
            return;
        };
        let mut fields = EventFields::default();
        event.record(&mut fields);
        let message = fields.format_for_eventlog();
        self.source.report(event_type, &message);
    }
}

mod win {
    //! Thin safe wrapper over `RegisterEventSourceW`/`ReportEventW`.

    use windows::core::PCWSTR;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::EventLog::{
        DeregisterEventSource, RegisterEventSourceW, ReportEventW, REPORT_EVENT_TYPE,
    };

    /// Owned event-source handle. `Send + Sync`: the Event Log APIs are
    /// documented thread-safe for a given handle.
    pub struct EventSource {
        handle: HANDLE,
    }

    // SAFETY: ReportEventW is safe to call concurrently on one handle.
    unsafe impl Send for EventSource {}
    unsafe impl Sync for EventSource {}

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    impl EventSource {
        /// Obtain a handle for source "Tillandsias" on the local machine.
        /// Succeeds even when the source is not registered in the registry
        /// (events then render with Event Viewer's generic wrapper).
        pub fn register() -> Option<Self> {
            let name = wide("Tillandsias");
            // SAFETY: `name` is a valid NUL-terminated UTF-16 string that
            // outlives the call; a null server means "local machine". The
            // wrapper maps an invalid handle to Err.
            let handle =
                unsafe { RegisterEventSourceW(PCWSTR::null(), PCWSTR(name.as_ptr())) }.ok()?;
            Some(Self { handle })
        }

        /// Report one event. Best-effort: a failed write is dropped — the
        /// relay must never recurse into tracing or crash the tray.
        pub fn report(&self, event_type: u16, message: &str) {
            let msg = wide(message);
            let strings = [PCWSTR(msg.as_ptr())];
            // SAFETY: handle is valid for the lifetime of `self`; `strings`
            // holds one valid NUL-terminated UTF-16 pointer that outlives the
            // call (the wrapper derives the string count from the slice);
            // event id 1 with one insertion string is the conventional
            // unregistered-source shape (.NET EventLogMessages.dll renders
            // event id ranges as pass-through once the source is registered).
            let _ = unsafe {
                ReportEventW(
                    self.handle,
                    REPORT_EVENT_TYPE(event_type),
                    0,    // category
                    1,    // event id
                    None, // user SID
                    0,    // raw data size
                    Some(&strings),
                    None, // raw data
                )
            };
        }
    }

    impl Drop for EventSource {
        fn drop(&mut self) {
            // SAFETY: handle came from RegisterEventSourceW and is
            // deregistered exactly once.
            let _ = unsafe { DeregisterEventSource(self.handle) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_mapping_relays_info_warn_error_only() {
        assert_eq!(
            event_type_for_level(tracing::Level::ERROR),
            Some(EVENTLOG_ERROR_TYPE)
        );
        assert_eq!(
            event_type_for_level(tracing::Level::WARN),
            Some(EVENTLOG_WARNING_TYPE)
        );
        assert_eq!(
            event_type_for_level(tracing::Level::INFO),
            Some(EVENTLOG_INFORMATION_TYPE)
        );
        assert_eq!(event_type_for_level(tracing::Level::DEBUG), None);
        assert_eq!(event_type_for_level(tracing::Level::TRACE), None);
    }

    #[test]
    fn format_simple_message() {
        let fields = EventFields {
            message: "Container started".to_string(),
            ..Default::default()
        };
        assert_eq!(fields.format_for_eventlog(), "Container started");
    }

    #[test]
    fn format_accountability_metadata() {
        let fields = EventFields {
            message: "Token retrieved".to_string(),
            is_accountable: true,
            category: Some("secrets".to_string()),
            safety: Some("Never written to disk".to_string()),
            spec: Some("native-secrets-store".to_string()),
            ..Default::default()
        };
        let formatted = fields.format_for_eventlog();
        assert!(formatted.contains("Token retrieved"));
        assert!(formatted.contains("Category: secrets"));
        assert!(formatted.contains("Safety: Never written to disk"));
        assert!(formatted.contains("@trace spec:native-secrets-store"));
    }

    #[test]
    fn format_plain_event_keeps_structured_fields() {
        let fields = EventFields {
            message: "Provision failed".to_string(),
            other: vec![
                ("phase".to_string(), "fedora-download".to_string()),
                ("attempt".to_string(), "3".to_string()),
            ],
            ..Default::default()
        };
        let formatted = fields.format_for_eventlog();
        assert!(formatted.contains("Provision failed"));
        assert!(formatted.contains("phase=fedora-download"));
        assert!(formatted.contains("attempt=3"));
    }

    #[test]
    fn try_layer_obtains_source_handle() {
        // RegisterEventSourceW succeeds regardless of registry registration,
        // so on any Windows host the layer must come up enabled.
        assert!(try_layer().is_some());
    }

    /// Full-stack verification: emit through a real subscriber carrying the
    /// layer, then read the event back from the Application log. Ignored by
    /// default because it WRITES to the host's real Event Log — run
    /// explicitly (`cargo test -p tillandsias-windows-tray -- --ignored
    /// eventlog`) on a Windows host to verify the relay end to end.
    #[test]
    #[ignore = "writes to the host Application Event Log; run explicitly"]
    fn eventlog_end_to_end_writes_to_application_log() {
        use tracing_subscriber::layer::SubscriberExt;
        let marker = format!("tillandsias-eventlog-e2e-{}", std::process::id());
        let subscriber = tracing_subscriber::registry().with(try_layer());
        tracing::subscriber::with_default(subscriber, || {
            tracing::error!(marker = marker.as_str(), "event log relay smoke");
        });
        // Windows PowerShell 5.1's Get-EventLog reads unregistered sources;
        // Get-WinEvent's ProviderName filter only matches registered
        // providers, so it would miss the default per-user install.
        let out = std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                "Get-EventLog -LogName Application -Source Tillandsias -Newest 10 | ForEach-Object { $_.Message }",
            ])
            .output()
            .expect("Get-EventLog should run");
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(
            text.contains(&marker),
            "emitted marker {marker} not found in Application log; got: {text}"
        );
    }
}
