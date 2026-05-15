// @trace gap:OBS-011
//! Trace budget enforcement for cost control.
//!
//! Prevents unbounded trace generation by enforcing per-spec and global cost budgets.
//! Warns users when trace generation exceeds configured thresholds.
//!
//! # Architecture
//!
//! - **Per-Spec Budgets**: Each spec (e.g., "spec:runtime-logging") has independent cost limits
//! - **Global Budget**: Aggregate limit across all specs in the window
//! - **Time Windows**: Configurable time window (default: 1 hour) for cost aggregation
//! - **Warning System**: Emit warnings when budget exceeded, track violation count
//! - **Configuration**: Per-spec and global limits, configurable via config or env vars
//!
//! # Example
//!
//! ```rust,ignore
//! let mut enforcer = BudgetEnforcer::new(
//!     10 * 1024 * 1024,  // 10MB global limit per hour
//!     3600,              // 1 hour window
//! );
//!
//! enforcer.set_spec_budget("spec:logging-levels", 2 * 1024 * 1024);
//!
//! let should_warn = enforcer.check_trace_cost(&entry)?;
//! if should_warn {
//!     eprintln!("Warning: trace budget exceeded for this window");
//! }
//! ```

use crate::LogEntry;
use parking_lot::RwLock;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// Default global trace cost limit: 10MB per hour
const DEFAULT_GLOBAL_BUDGET_BYTES: u64 = 10 * 1024 * 1024;

/// Default per-spec trace cost limit: 5MB per hour
const DEFAULT_SPEC_BUDGET_BYTES: u64 = 5 * 1024 * 1024;

/// Default time window duration in seconds (1 hour)
const DEFAULT_WINDOW_DURATION_SECS: u64 = 3600;

/// Cost estimation overhead in bytes (per-trace metadata, timing info, etc.)
const ANALYSIS_OVERHEAD_BYTES: usize = 256;

/// Tracks trace costs for a specific window
#[derive(Debug, Clone)]
struct WindowCosts {
    /// Start time of current window (unix seconds)
    window_start: u64,

    /// Global cumulative cost in current window (bytes)
    global_cost: u64,

    /// Per-spec costs in current window (bytes)
    spec_costs: HashMap<String, u64>,

    /// Number of budget violations (warnings issued) in this window
    violations: u64,

    /// Whether global budget warning has been issued in this window
    global_warning_issued: bool,

    /// Specs for which budget warning has been issued in this window
    spec_warnings_issued: HashMap<String, bool>,
}

impl Default for WindowCosts {
    fn default() -> Self {
        Self {
            window_start: current_unix_time(),
            global_cost: 0,
            spec_costs: HashMap::new(),
            violations: 0,
            global_warning_issued: false,
            spec_warnings_issued: HashMap::new(),
        }
    }
}

/// Trace budget enforcer for cost control
///
/// Tracks cumulative trace costs per time window and enforces per-spec
/// and global budget limits. Issues warnings when budgets are exceeded.
#[derive(Clone)]
pub struct BudgetEnforcer {
    /// Global budget limit in bytes per window
    global_budget: u64,

    /// Per-spec budget limits (defaults to DEFAULT_SPEC_BUDGET_BYTES if not set)
    spec_budgets: Arc<RwLock<HashMap<String, u64>>>,

    /// Time window duration in seconds
    window_duration: u64,

    /// Mutable state (window tracking, cumulative costs)
    state: Arc<RwLock<WindowCosts>>,
}

impl BudgetEnforcer {
    /// Create a new budget enforcer with default limits
    pub fn new(global_budget: u64, window_duration: u64) -> Self {
        Self {
            global_budget,
            spec_budgets: Arc::new(RwLock::new(HashMap::new())),
            window_duration,
            state: Arc::new(RwLock::new(WindowCosts::default())),
        }
    }

    /// Create with default global budget (10MB) and default window (1 hour)
    pub fn default_config() -> Self {
        Self::new(DEFAULT_GLOBAL_BUDGET_BYTES, DEFAULT_WINDOW_DURATION_SECS)
    }

    /// Set a per-spec budget limit in bytes
    ///
    /// # Arguments
    /// * `spec_name` - Spec identifier (e.g., "spec:runtime-logging")
    /// * `budget` - Maximum cost in bytes for this spec per window
    pub fn set_spec_budget(&self, spec_name: impl Into<String>, budget: u64) {
        self.spec_budgets.write().insert(spec_name.into(), budget);
    }

    /// Get the per-spec budget for a spec (or default if not set)
    pub fn get_spec_budget(&self, spec_name: &str) -> u64 {
        self.spec_budgets
            .read()
            .get(spec_name)
            .copied()
            .unwrap_or(DEFAULT_SPEC_BUDGET_BYTES)
    }

    /// Check if a trace cost exceeds budget and return warning status
    ///
    /// Returns true if a warning should be issued (budget exceeded and warning
    /// not yet issued in this window). Updates cumulative costs and checks both
    /// global and per-spec budgets.
    ///
    /// # Arguments
    /// * `entry` - The log entry to evaluate
    ///
    /// # Returns
    /// * `Ok(true)` - Budget exceeded, warning should be issued
    /// * `Ok(false)` - Budget OK, no warning needed
    /// * `Err(_)` - Error estimating cost (treat as non-fatal, return false)
    pub fn check_trace_cost(
        &self,
        entry: &LogEntry,
    ) -> std::result::Result<bool, Box<dyn std::error::Error>> {
        let cost = estimate_trace_cost(entry)?;

        let mut state = self.state.write();
        let now = current_unix_time();

        // Check and possibly reset window
        if now >= state.window_start + self.window_duration {
            // Window expired, reset to new window
            state.window_start = now;
            state.global_cost = 0;
            state.spec_costs.clear();
            state.violations = 0;
            state.global_warning_issued = false;
            state.spec_warnings_issued.clear();
        }

        // Update global cost
        state.global_cost += cost as u64;

        // Update per-spec cost (if spec is set in the entry)
        let mut spec_name: Option<String> = None;
        if let Some(spec_trace) = &entry.spec_trace {
            spec_name = Some(spec_trace.clone());
            let entry = state.spec_costs.entry(spec_trace.clone()).or_insert(0);
            *entry += cost as u64;
        }

        // Check global budget
        let mut should_warn = false;
        if state.global_cost > self.global_budget && !state.global_warning_issued {
            state.global_warning_issued = true;
            state.violations += 1;
            should_warn = true;
        }

        // Check per-spec budget if applicable
        if let Some(spec_name) = &spec_name {
            let spec_budget = self.get_spec_budget(spec_name);
            if let Some(spec_cost) = state.spec_costs.get(spec_name) {
                if *spec_cost > spec_budget
                    && !state
                        .spec_warnings_issued
                        .get(spec_name)
                        .copied()
                        .unwrap_or(false)
                {
                    state.spec_warnings_issued.insert(spec_name.clone(), true);
                    state.violations += 1;
                    should_warn = true;
                }
            }
        }

        Ok(should_warn)
    }

    /// Get current window statistics
    ///
    /// Returns (global_cost, violation_count, global_warning_issued)
    pub fn window_stats(&self) -> (u64, u64, bool) {
        let state = self.state.read();
        (
            state.global_cost,
            state.violations,
            state.global_warning_issued,
        )
    }

    /// Get per-spec costs in current window
    pub fn spec_costs(&self) -> HashMap<String, u64> {
        self.state.read().spec_costs.clone()
    }

    /// Get the global budget limit
    pub fn global_budget(&self) -> u64 {
        self.global_budget
    }

    /// Get the window duration in seconds
    pub fn window_duration(&self) -> u64 {
        self.window_duration
    }

    /// Reset window manually (for testing)
    #[cfg(test)]
    pub fn reset_window(&self) {
        let mut state = self.state.write();
        state.window_start = current_unix_time();
        state.global_cost = 0;
        state.spec_costs.clear();
        state.violations = 0;
        state.global_warning_issued = false;
        state.spec_warnings_issued.clear();
    }
}

/// Estimate the cost of a trace in bytes (serialization size + overhead)
fn estimate_trace_cost(entry: &LogEntry) -> std::result::Result<usize, Box<dyn std::error::Error>> {
    // Serialize entry to JSON to measure actual size
    let json = entry.to_json()?;
    let serialization_size = json.len();

    // Total cost: serialization + per-trace overhead (metadata, indexing, etc.)
    let total_cost = serialization_size + ANALYSIS_OVERHEAD_BYTES;

    Ok(total_cost)
}

/// Get current unix timestamp in seconds
fn current_unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn create_test_entry(message: &str, spec: Option<&str>) -> LogEntry {
        let mut entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "test".to_string(),
            message.to_string(),
        );

        if let Some(spec_trace) = spec {
            entry = entry.with_spec_trace(spec_trace);
        }

        entry
    }

    #[test]
    fn test_global_budget_enforcement() {
        // Create enforcer with a budget that will be exceeded after a few traces
        // Each trace is ~300-400 bytes, so 1500 bytes budget allows ~3-4 traces
        let enforcer = BudgetEnforcer::new(1500, 3600);

        // First few traces should not trigger warning
        for i in 0..3 {
            let entry = create_test_entry(&format!("message {}", i), None);
            let _ = enforcer.check_trace_cost(&entry);
        }

        let (_, violations_before, _) = enforcer.window_stats();
        assert!(violations_before == 0, "Should not have violations yet");

        // Add more traces until we exceed the budget and trigger warning
        for i in 3..20 {
            let entry = create_test_entry(&format!("message {}", i), None);
            let _ = enforcer.check_trace_cost(&entry);
        }

        // Should have triggered warning and recorded violations
        let (global_cost, violations, warning_issued) = enforcer.window_stats();
        assert!(global_cost > 1500, "Global cost should exceed budget");
        assert!(warning_issued);
        assert!(violations > 0);
    }

    #[test]
    fn test_per_spec_budget_enforcement() {
        let enforcer = BudgetEnforcer::new(1_000_000_000, 3600);

        // Set very low budget for one spec
        enforcer.set_spec_budget("spec:logging-levels", 100);

        // Add traces for the spec until budget exceeded
        for i in 0..50 {
            let entry = create_test_entry(&format!("message {}", i), Some("spec:logging-levels"));
            let _ = enforcer.check_trace_cost(&entry);
        }

        // Should have recorded violations for this spec
        let (_, violations, _) = enforcer.window_stats();
        assert!(violations > 0);

        // Verify spec cost tracking
        let spec_costs = enforcer.spec_costs();
        assert!(spec_costs.contains_key("spec:logging-levels"));
        let spec_cost = spec_costs.get("spec:logging-levels").unwrap();
        assert!(*spec_cost > 100, "Spec cost should exceed budget");
    }

    #[test]
    fn test_warning_only_issued_once_per_window() {
        let enforcer = BudgetEnforcer::new(100, 3600);

        // Fill up the budget to trigger warning
        for i in 0..50 {
            let entry = create_test_entry(&format!("message {}", i), None);
            let _ = enforcer.check_trace_cost(&entry);
        }

        // Warning should have been issued once
        let (_, violations_1, _) = enforcer.window_stats();
        assert_eq!(violations_1, 1, "Should have exactly 1 violation");

        // Add more traces - warning should not be issued again
        for i in 50..100 {
            let entry = create_test_entry(&format!("message {}", i), None);
            let _ = enforcer.check_trace_cost(&entry);
        }

        // Violations count should not increase
        let (_, violations_2, _) = enforcer.window_stats();
        assert_eq!(
            violations_2, 1,
            "Should still have exactly 1 violation (warning already issued)"
        );
    }

    #[test]
    fn test_window_reset() {
        let enforcer = BudgetEnforcer::new(100, 3600);

        // Add traces until budget exceeded
        for i in 0..50 {
            let entry = create_test_entry(&format!("message {}", i), None);
            let _ = enforcer.check_trace_cost(&entry);
        }

        let (cost1, violations1, warning1) = enforcer.window_stats();
        assert!(cost1 > 100);
        assert!(violations1 > 0);
        assert!(warning1);

        // Reset window
        enforcer.reset_window();

        let (cost2, violations2, warning2) = enforcer.window_stats();
        assert_eq!(cost2, 0);
        assert_eq!(violations2, 0);
        assert!(!warning2);
    }

    #[test]
    fn test_multiple_specs_independent_budgets() {
        let enforcer = BudgetEnforcer::new(1_000_000_000, 3600);

        // Set different budgets for two specs
        enforcer.set_spec_budget("spec:runtime-logging", 100);
        enforcer.set_spec_budget("spec:logging-levels", 50);

        // Add traces for both specs
        for i in 0..30 {
            let entry1 = create_test_entry(&format!("message {}", i), Some("spec:runtime-logging"));
            let entry2 = create_test_entry(&format!("message {}", i), Some("spec:logging-levels"));

            let _ = enforcer.check_trace_cost(&entry1);
            let _ = enforcer.check_trace_cost(&entry2);
        }

        // Both specs should have costs tracked
        let spec_costs = enforcer.spec_costs();
        assert!(*spec_costs.get("spec:runtime-logging").unwrap_or(&0) > 0);
        assert!(*spec_costs.get("spec:logging-levels").unwrap_or(&0) > 0);

        // Violations should be recorded for both
        let (_, violations, _) = enforcer.window_stats();
        assert!(violations >= 2, "Should have violations from both specs");
    }

    #[test]
    fn test_spec_budget_defaults_to_default_limit() {
        let enforcer = BudgetEnforcer::new(1_000_000_000, 3600);

        // Don't set a budget for this spec
        let budget = enforcer.get_spec_budget("spec:unknown");
        assert_eq!(budget, DEFAULT_SPEC_BUDGET_BYTES);
    }

    #[test]
    fn test_cost_estimation_matches_sampler() {
        // Verify cost estimation is consistent across modules
        let entry = create_test_entry("test", None);
        let cost = estimate_trace_cost(&entry).unwrap();

        let json = entry.to_json().unwrap();
        assert_eq!(cost, json.len() + ANALYSIS_OVERHEAD_BYTES);
    }

    #[test]
    fn test_no_warning_when_below_budget() {
        let enforcer = BudgetEnforcer::new(1_000_000_000, 3600);

        // Add a single small trace
        let entry = create_test_entry("small", None);
        let warn = enforcer.check_trace_cost(&entry).unwrap();

        assert!(!warn, "Should not warn when below budget");

        let (_, violations, warning_issued) = enforcer.window_stats();
        assert_eq!(violations, 0);
        assert!(!warning_issued);
    }
}
