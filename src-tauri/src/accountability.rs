//! Accountability window layer for `tracing_subscriber`.
//!
//! Provides a curated view of sensitive subsystem operations. When a
//! `--log-*` flag is active, this layer intercepts events tagged with
//! `accountability = true` and renders them in a human-readable format:
//!
//! ```text
//! [secrets] v0.1.97.76 | GitHub token retrieved from OS keyring (GNOME Keyring)
//!   -> Never written to disk, injected via GIT_ASKPASS
//!   @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code
//! ```
//!
//! The layer is composable — it coexists with the normal file and stderr
//! layers, filtering only on accountability-tagged spans.
//!
//! @trace spec:logging-accountability

use std::collections::HashSet;
use std::fmt;
use std::io::Write;

use tracing::field::{Field, Visit};
use tracing::span;
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

use crate::cli::AccountabilityWindow;

// ---------------------------------------------------------------------------
// Spec URL generation
// ---------------------------------------------------------------------------

/// Generate a GitHub code search URL for a given spec name.
///
/// The URL searches for `@trace spec:<name>` across the repository,
/// linking runtime behavior back to the OpenSpec design documents.
///
/// # Example
///
/// ```text
/// spec_url("native-secrets-store")
/// // -> "https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code"
/// ```
pub fn spec_url(spec_name: &str) -> String {
    format!(
        "https://github.com/8007342/tillandsias/search?q=%40trace+spec%3A{}&type=code",
        spec_name
    )
}

// ---------------------------------------------------------------------------
// Accountability Layer
// ---------------------------------------------------------------------------

/// A `tracing_subscriber::Layer` that formats accountability-tagged events
/// to stderr in a curated, human-readable format.
///
/// Only processes events where the enclosing span or the event itself has
/// `accountability = true`. All other events pass through untouched.
pub struct AccountabilityLayer {
    /// Which accountability windows are active (determines which categories
    /// to display).
    active_categories: HashSet<String>,
}

impl AccountabilityLayer {
    /// Create a new accountability layer from the active window flags.
    pub fn new(windows: &[AccountabilityWindow]) -> Self {
        let mut categories = HashSet::new();
        for window in windows {
            match window {
                AccountabilityWindow::SecretManagement => {
                    categories.insert("secrets".to_string());
                }
                AccountabilityWindow::ImageManagement => {
                    categories.insert("images".to_string());
                }
                AccountabilityWindow::UpdateCycle => {
                    categories.insert("updates".to_string());
                }
            }
        }
        Self {
            active_categories: categories,
        }
    }
}

/// Visitor that extracts accountability-related fields from a tracing event.
struct AccountabilityVisitor {
    /// Whether the event is tagged as accountable.
    is_accountable: bool,
    /// The category (e.g., "secrets", "images").
    category: Option<String>,
    /// The spec name for URL generation.
    spec: Option<String>,
    /// The human-readable safety note (e.g., "Never written to disk").
    safety: Option<String>,
    /// The main message.
    message: String,
}

impl AccountabilityVisitor {
    fn new() -> Self {
        Self {
            is_accountable: false,
            category: None,
            spec: None,
            safety: None,
            message: String::new(),
        }
    }
}

impl Visit for AccountabilityVisitor {
    fn record_bool(&mut self, field: &Field, value: bool) {
        if field.name() == "accountability" {
            self.is_accountable = value;
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "category" => self.category = Some(value.to_string()),
            "spec" => self.spec = Some(value.to_string()),
            "safety" => self.safety = Some(value.to_string()),
            "message" => self.message = value.to_string(),
            _ => {}
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "message" {
            self.message = format!("{value:?}");
        }
    }
}

/// Visitor that checks span fields for accountability tags.
struct SpanFieldVisitor {
    is_accountable: bool,
    category: Option<String>,
}

impl SpanFieldVisitor {
    fn new() -> Self {
        Self {
            is_accountable: false,
            category: None,
        }
    }
}

impl Visit for SpanFieldVisitor {
    fn record_bool(&mut self, field: &Field, value: bool) {
        if field.name() == "accountability" {
            self.is_accountable = value;
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "category" {
            self.category = Some(value.to_string());
        }
    }

    fn record_debug(&mut self, _field: &Field, _value: &dyn fmt::Debug) {}
}

impl<S> Layer<S> for AccountabilityLayer
where
    S: tracing::Subscriber + for<'lookup> tracing_subscriber::registry::LookupSpan<'lookup>,
{
    fn on_event(&self, event: &tracing::Event<'_>, ctx: Context<'_, S>) {
        // Extract fields from the event itself.
        let mut visitor = AccountabilityVisitor::new();
        event.record(&mut visitor);

        // If the event itself is not tagged, check if any enclosing span is.
        if !visitor.is_accountable {
            if let Some(scope) = ctx.event_scope(event) {
                for span_ref in scope {
                    let extensions = span_ref.extensions();
                    if let Some(fields) = extensions.get::<AccountabilityFields>() {
                        visitor.is_accountable = true;
                        if visitor.category.is_none() {
                            visitor.category.clone_from(&fields.category);
                        }
                        break;
                    }
                }
            }
        }

        if !visitor.is_accountable {
            return;
        }

        // Check if this category is in our active set.
        let category = visitor.category.as_deref().unwrap_or("unknown");
        if !self.active_categories.contains(category) {
            return;
        }

        // Format the accountability output.
        let version = crate::cli::version_full();
        let mut stderr = std::io::stderr().lock();

        // ANSI color codes for terminal output.
        const GREEN: &str = "\x1b[32m";
        const DIM: &str = "\x1b[2m";
        const CYAN: &str = "\x1b[36m";
        const RESET: &str = "\x1b[0m";

        // Main line: [category] version | message
        let _ = writeln!(
            stderr,
            "\n{GREEN}[{category}]{RESET} {DIM}v{version}{RESET} | {message}",
            message = visitor.message,
        );

        // Safety note (if present).
        if let Some(ref safety) = visitor.safety {
            let _ = writeln!(stderr, "  {CYAN}->{RESET} {safety}");
        }

        // Spec URL at trace level.
        if let Some(ref spec) = visitor.spec {
            let url = spec_url(spec);
            let _ = writeln!(stderr, "  {DIM}@trace {url}{RESET}");
        }
    }

    fn on_new_span(&self, attrs: &span::Attributes<'_>, id: &span::Id, ctx: Context<'_, S>) {
        let mut visitor = SpanFieldVisitor::new();
        attrs.record(&mut visitor);

        if visitor.is_accountable {
            if let Some(span) = ctx.span(id) {
                span.extensions_mut().insert(AccountabilityFields {
                    category: visitor.category,
                });
            }
        }
    }
}

/// Stored on span extensions to propagate accountability tags to child events.
struct AccountabilityFields {
    category: Option<String>,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_url_basic() {
        let url = spec_url("native-secrets-store");
        assert_eq!(
            url,
            "https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code"
        );
    }

    #[test]
    fn spec_url_with_hyphens() {
        let url = spec_url("secret-rotation-tokens");
        assert!(url.contains("spec%3Asecret-rotation-tokens"));
        assert!(url.starts_with("https://github.com/8007342/tillandsias/search"));
    }

    #[test]
    fn accountability_layer_categories() {
        let layer = AccountabilityLayer::new(&[AccountabilityWindow::SecretManagement]);
        assert!(layer.active_categories.contains("secrets"));
        assert!(!layer.active_categories.contains("images"));
        assert!(!layer.active_categories.contains("updates"));
    }

    #[test]
    fn accountability_layer_multiple_windows() {
        let layer = AccountabilityLayer::new(&[
            AccountabilityWindow::SecretManagement,
            AccountabilityWindow::ImageManagement,
            AccountabilityWindow::UpdateCycle,
        ]);
        assert!(layer.active_categories.contains("secrets"));
        assert!(layer.active_categories.contains("images"));
        assert!(layer.active_categories.contains("updates"));
    }
}
