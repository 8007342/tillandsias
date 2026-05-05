//! Accountability utilities for spec traceability.
//!
//! Provides `spec_url()` for generating GitHub code search links from spec
//! names. Used by `log_format::TillandsiasFormat` to render `@trace` lines
//! in accountability-tagged log events.
//!
//! @trace spec:logging-accountability, spec:logging-levels, spec:observability-convergence, spec:runtime-logging

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
///
/// @trace spec:logging-accountability
pub fn spec_url(spec_name: &str) -> String {
    format!(
        "https://github.com/8007342/tillandsias/search?q=%40trace+spec%3A{}&type=code",
        spec_name
    )
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
}
