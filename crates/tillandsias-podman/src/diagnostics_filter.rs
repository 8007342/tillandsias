// @trace spec:runtime-diagnostics-stream (Requirement: Event filtering and control)
//! Diagnostics-stream filter: decide which `event:<kind>` lines reach the
//! terminal when `--debug` / `--diagnostics` is on.
//!
//! The filter is configured via three independent env vars; each is `None`
//! by default, which means "no filter, emit everything":
//!
//! - `TILLANDSIAS_DEBUG_FILTER` — comma-separated event-type allowlist,
//!   e.g. `event:container_exit,event:container_signal`. Items may be
//!   given with or without the `event:` prefix.
//! - `TILLANDSIAS_DEBUG_CONTAINER` — container-name glob, e.g.
//!   `tillandsias-myproject-*`. Supports `*` wildcards anywhere; an
//!   absent glob matches everything.
//! - `TILLANDSIAS_DEBUG_LEVEL` — `normal` (default; container events) or
//!   `verbose` (additionally permits internal events: network, mounts,
//!   cgroup, ...). Unknown values fall back to `normal`.
//!
//! The filter type is `Sync` + cheap to construct, so a single instance
//! lives behind a `OnceLock` and is consulted by `emit_launch_event` /
//! `emit_diagnostic_event` from `client.rs`. Pure-data; no I/O.

use std::collections::HashSet;
use std::sync::OnceLock;

/// Granularity knob — `normal` is container-lifecycle events only;
/// `verbose` opens internal-runtime events (network, mounts, cgroups, ...)
/// that the runtime layer may emit additionally.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebugLevel {
    Normal,
    Verbose,
}

impl DebugLevel {
    fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "verbose" => Self::Verbose,
            // Anything else, including the empty string, falls back to
            // Normal — being lenient here keeps misspelled env vars from
            // silently disabling the (default) container stream.
            _ => Self::Normal,
        }
    }

    /// Internal events (network/mounts/cgroups) require `verbose`. Their
    /// canonical type prefix is `event:internal_*` by convention.
    pub fn allows_internal(self) -> bool {
        matches!(self, Self::Verbose)
    }
}

/// Decision record: which event kinds + containers may be streamed.
#[derive(Debug, Clone)]
pub struct DiagnosticsFilter {
    /// `None` → all event types pass. `Some` → allowlist of fully
    /// qualified event names (`event:container_exit`).
    event_types: Option<HashSet<String>>,
    /// `None` → all containers pass. `Some(glob)` → match `*` wildcards.
    container_glob: Option<String>,
    level: DebugLevel,
}

impl DiagnosticsFilter {
    /// Empty filter — passes every event from every container. Used by
    /// callers that just want a default and never plan to set env vars.
    pub fn pass_through() -> Self {
        Self {
            event_types: None,
            container_glob: None,
            level: DebugLevel::Normal,
        }
    }

    /// Construct a filter directly from configuration values, mostly for
    /// unit tests. Production callers should use [`Self::from_env`].
    pub fn new(
        event_types: Option<&[&str]>,
        container_glob: Option<&str>,
        level: DebugLevel,
    ) -> Self {
        let event_types = event_types.map(|items| {
            items
                .iter()
                .map(|raw| normalize_event_name(raw))
                .filter(|s| !s.is_empty())
                .collect::<HashSet<_>>()
        });
        let container_glob = container_glob
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        Self {
            event_types,
            container_glob,
            level,
        }
    }

    /// Construct a filter by reading the three env vars described in the
    /// module docs. Missing/empty vars → no filter.
    pub fn from_env() -> Self {
        let event_types = std::env::var("TILLANDSIAS_DEBUG_FILTER")
            .ok()
            .and_then(|raw| {
                let set: HashSet<String> = raw
                    .split(',')
                    .map(normalize_event_name)
                    .filter(|s| !s.is_empty())
                    .collect();
                if set.is_empty() { None } else { Some(set) }
            });
        let container_glob = std::env::var("TILLANDSIAS_DEBUG_CONTAINER")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let level = std::env::var("TILLANDSIAS_DEBUG_LEVEL")
            .ok()
            .map(|s| DebugLevel::parse(&s))
            .unwrap_or(DebugLevel::Normal);
        Self {
            event_types,
            container_glob,
            level,
        }
    }

    /// Process-wide cached default. Built lazily on first call from env;
    /// subsequent calls are a single atomic load. The cache is intentional
    /// — env vars are read at process start in line with how `--debug` and
    /// the binary-version banner already work; reload requires a restart.
    pub fn global() -> &'static DiagnosticsFilter {
        static FILTER: OnceLock<DiagnosticsFilter> = OnceLock::new();
        FILTER.get_or_init(Self::from_env)
    }

    /// Does this filter permit `event_type` from `container` to reach the
    /// terminal?
    ///
    /// - `event_type` is the full event name as it appears on the wire,
    ///   e.g. `event:container_exit`. It may also be given without the
    ///   `event:` prefix — both are normalised before matching.
    /// - `container` is the literal container name as emitted, e.g.
    ///   `tillandsias-myproject-forge`.
    pub fn allows(&self, event_type: &str, container: &str) -> bool {
        let event = normalize_event_name(event_type);
        if let Some(allowlist) = &self.event_types
            && !allowlist.contains(&event)
        {
            return false;
        }
        if event.starts_with("event:internal_") && !self.level.allows_internal() {
            return false;
        }
        if let Some(glob) = &self.container_glob
            && !glob_matches(glob, container)
        {
            return false;
        }
        true
    }

    pub fn level(&self) -> DebugLevel {
        self.level
    }
}

impl Default for DiagnosticsFilter {
    fn default() -> Self {
        Self::pass_through()
    }
}

/// Lowercase + ensure `event:` prefix. `container_exit` → `event:container_exit`.
fn normalize_event_name(raw: impl AsRef<str>) -> String {
    let s = raw.as_ref().trim().to_ascii_lowercase();
    if s.is_empty() {
        return String::new();
    }
    if s.starts_with("event:") {
        s
    } else {
        format!("event:{s}")
    }
}

/// Match a literal container name against a glob with `*` wildcards.
/// Supports patterns like `tillandsias-foo-*`, `*-router`, and
/// `tillandsias-*-forge`. No character classes or `?` — keep it small;
/// real users only need prefix/suffix/contains over container names.
///
/// The algorithm splits the glob on `*` and walks the parts in order,
/// requiring the first part to be a prefix and the last part to be a
/// suffix (unless the glob starts/ends with `*`). Empty parts (from
/// consecutive `**`) collapse to a single wildcard. O(n·m) worst case;
/// inputs are short container names.
fn glob_matches(glob: &str, candidate: &str) -> bool {
    // Exact match shortcut and the only-`*` shortcut.
    if !glob.contains('*') {
        return glob == candidate;
    }
    if glob == "*" {
        return true;
    }

    let parts: Vec<&str> = glob.split('*').collect();
    // First part must be a prefix (unless glob starts with `*`, in which
    // case parts[0] is empty and the test is vacuous).
    let mut cursor = 0usize;
    if !parts[0].is_empty() {
        if !candidate.starts_with(parts[0]) {
            return false;
        }
        cursor = parts[0].len();
    }
    // Middle parts: each must occur in order, after cursor.
    let last_idx = parts.len() - 1;
    for part in &parts[1..last_idx] {
        if part.is_empty() {
            continue;
        }
        match candidate[cursor..].find(*part) {
            Some(offset) => cursor += offset + part.len(),
            None => return false,
        }
    }
    // Last part must be a suffix (unless glob ends with `*`, in which
    // case parts[last_idx] is empty).
    let last = parts[last_idx];
    if last.is_empty() {
        return true;
    }
    candidate[cursor..].ends_with(last) && candidate.len() >= cursor + last.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pass-through filter (no env vars set) emits every event from every
    /// container — same behaviour as before the filter existed.
    #[test]
    fn pass_through_allows_everything() {
        let f = DiagnosticsFilter::pass_through();
        assert!(f.allows("event:container_launch", "tillandsias-x-forge"));
        assert!(f.allows("event:container_exit", "tillandsias-y-router"));
        assert!(f.allows("event:container_signal", "anything"));
    }

    /// Scenario "Filter by event type" — the allowlist gates the stream.
    /// Items may be given with or without the `event:` prefix; matching is
    /// case-insensitive.
    #[test]
    fn event_type_allowlist_gates_emission() {
        let f = DiagnosticsFilter::new(
            Some(&["event:container_exit", "container_signal"]),
            None,
            DebugLevel::Normal,
        );
        assert!(f.allows("event:container_exit", "c1"));
        assert!(f.allows("event:container_signal", "c1"));
        assert!(f.allows("Event:Container_Exit", "c1"));
        assert!(!f.allows("event:container_launch", "c1"));
        assert!(!f.allows("event:container_stderr", "c1"));
    }

    /// Empty/whitespace items in the comma list are ignored, not treated
    /// as an empty allowlist that blocks everything.
    #[test]
    fn event_type_blank_items_skipped() {
        let f = DiagnosticsFilter::new(
            Some(&[" ", "event:container_exit", ""]),
            None,
            DebugLevel::Normal,
        );
        assert!(f.allows("event:container_exit", "c"));
        assert!(!f.allows("event:container_launch", "c"));
    }

    /// Scenario "Filter by container name" — glob matches with `*` at
    /// start, middle, end, both ends. Exact match (no `*`) also works.
    #[test]
    fn container_glob_matches() {
        // Prefix glob from the spec verbatim.
        let f = DiagnosticsFilter::new(None, Some("tillandsias-myproject-*"), DebugLevel::Normal);
        assert!(f.allows("event:container_exit", "tillandsias-myproject-forge"));
        assert!(f.allows("event:container_exit", "tillandsias-myproject-router"));
        assert!(!f.allows("event:container_exit", "tillandsias-other-forge"));

        // Suffix glob.
        let f = DiagnosticsFilter::new(None, Some("*-router"), DebugLevel::Normal);
        assert!(f.allows("event:container_exit", "tillandsias-x-router"));
        assert!(!f.allows("event:container_exit", "tillandsias-x-forge"));

        // Middle glob.
        let f = DiagnosticsFilter::new(None, Some("tillandsias-*-forge"), DebugLevel::Normal);
        assert!(f.allows("event:container_exit", "tillandsias-acme-forge"));
        assert!(!f.allows("event:container_exit", "tillandsias-acme-router"));

        // Exact match.
        let f = DiagnosticsFilter::new(None, Some("tillandsias-x"), DebugLevel::Normal);
        assert!(f.allows("event:container_exit", "tillandsias-x"));
        assert!(!f.allows("event:container_exit", "tillandsias-x-forge"));

        // Bare `*` matches everything.
        let f = DiagnosticsFilter::new(None, Some("*"), DebugLevel::Normal);
        assert!(f.allows("event:container_exit", "literally-anything"));
    }

    /// Scenario "Debug level control" — internal events (`event:internal_*`)
    /// are gated on `TILLANDSIAS_DEBUG_LEVEL=verbose`. `normal` (the
    /// default) hides them.
    #[test]
    fn internal_events_require_verbose() {
        let normal = DiagnosticsFilter::new(None, None, DebugLevel::Normal);
        assert!(!normal.allows("event:internal_network_attach", "c"));
        assert!(!normal.allows("event:internal_cgroup_apply", "c"));
        // Container events are unaffected.
        assert!(normal.allows("event:container_exit", "c"));

        let verbose = DiagnosticsFilter::new(None, None, DebugLevel::Verbose);
        assert!(verbose.allows("event:internal_network_attach", "c"));
        assert!(verbose.allows("event:container_exit", "c"));
    }

    /// All three knobs compose: an event must satisfy event-type AND
    /// container-glob AND level. None of the three short-circuits the
    /// others.
    #[test]
    fn filters_compose_with_and_semantics() {
        let f = DiagnosticsFilter::new(
            Some(&["event:container_exit", "event:internal_network_attach"]),
            Some("tillandsias-myproject-*"),
            DebugLevel::Verbose,
        );
        // All three checks pass.
        assert!(f.allows("event:container_exit", "tillandsias-myproject-forge"));
        assert!(f.allows(
            "event:internal_network_attach",
            "tillandsias-myproject-router"
        ));
        // Event-type fails.
        assert!(!f.allows("event:container_launch", "tillandsias-myproject-forge"));
        // Glob fails.
        assert!(!f.allows("event:container_exit", "tillandsias-other-forge"));
        // Both pass but a normal-level instance would still gate
        // internal_* — verified separately above.
    }

    /// `DebugLevel::parse` is case-insensitive and lenient: unknown values
    /// fall back to Normal rather than disabling the stream entirely.
    #[test]
    fn debug_level_parse_is_lenient() {
        assert_eq!(DebugLevel::parse("verbose"), DebugLevel::Verbose);
        assert_eq!(DebugLevel::parse("VERBOSE"), DebugLevel::Verbose);
        assert_eq!(DebugLevel::parse(" Verbose "), DebugLevel::Verbose);
        assert_eq!(DebugLevel::parse("normal"), DebugLevel::Normal);
        assert_eq!(DebugLevel::parse(""), DebugLevel::Normal);
        assert_eq!(DebugLevel::parse("nonsense"), DebugLevel::Normal);
    }

    /// Glob primitives in isolation: prefix, suffix, middle, exact, all-`*`.
    #[test]
    fn glob_matches_primitives() {
        assert!(glob_matches("tillandsias-x-*", "tillandsias-x-forge"));
        assert!(!glob_matches("tillandsias-x-*", "tillandsias-y-forge"));
        assert!(glob_matches("*-forge", "tillandsias-x-forge"));
        assert!(!glob_matches("*-forge", "tillandsias-x-router"));
        assert!(glob_matches("a-*-b", "a-mid-b"));
        assert!(!glob_matches("a-*-b", "a-mid-c"));
        assert!(glob_matches("exact", "exact"));
        assert!(!glob_matches("exact", "exactly"));
        assert!(glob_matches("*", "anything"));
    }
}
