//! Process-global VmPhase mirror consulted before container mutations.
//!
//! Order 234 (R6 of the race-safeguards ratification, order 160): during
//! Draining/Stopping, a self-heal or a late request must not (re)create a
//! container the shutdown path just removed, and cleanup must not race the
//! shutdown's own teardown. The vsock listener owns the authoritative
//! `VmPhase` inside `VmStateHandle`; the ensure/cleanup paths are free
//! functions that also run in CLI mode where no listener (and no phase)
//! exists. This module bridges the two: the listener mirrors every phase
//! transition here, and mutation sites consult [`container_mutations_allowed`]
//! — which defaults to ALLOWED when no listener ever set a phase (CLI mode).
//!
//! @trace plan/issues/race-safeguards-research-2026-07-02.md (R6)

use std::sync::atomic::{AtomicU8, Ordering};

use tillandsias_control_wire::VmPhase;

/// 0 = never set (CLI mode — mutations allowed). Other values are
/// `encode(phase)` below.
static RUNTIME_PHASE: AtomicU8 = AtomicU8::new(0);

// Callers live in the listen-vsock-gated vsock_server (plus tests), so the
// default feature set sees these as dead.
#[cfg_attr(not(feature = "listen-vsock"), allow(dead_code))]
fn encode(phase: VmPhase) -> u8 {
    match phase {
        VmPhase::Provisioning => 6,
        VmPhase::Starting => 1,
        VmPhase::Ready => 2,
        VmPhase::Draining => 3,
        VmPhase::Stopping => 4,
        VmPhase::Failed => 5,
    }
}

/// Mirror a phase transition (called by the vsock listener's
/// `VmStateHandle::set_phase`; CLI mode never calls this).
/// dead_code also under cfg(test): the set_phase mirror write is
/// cfg(not(test)) (test-isolation, see vsock_server), so test targets have
/// no caller.
#[cfg_attr(any(not(feature = "listen-vsock"), test), allow(dead_code))]
pub fn set_runtime_phase(phase: VmPhase) {
    RUNTIME_PHASE.store(encode(phase), Ordering::SeqCst);
}

/// Pure gate logic: false only for the Draining/Stopping codes; 0 (never
/// set — CLI mode) and every other phase allow mutations. Kept separate from
/// the global read so the truth table is unit-testable without touching
/// process-global state (tests run in parallel).
fn code_allows_mutations(code: u8) -> bool {
    !matches!(code, 3 | 4)
}

/// Whether container create/remove side effects are currently permitted.
pub fn container_mutations_allowed() -> bool {
    code_allows_mutations(RUNTIME_PHASE.load(Ordering::SeqCst))
}

/// Standard refusal message for mutation sites, naming the gate so operators
/// can find this module from the log line alone.
pub fn refusal(operation: &str) -> String {
    format!(
        "{operation}: refused — VM is draining/stopping (order 234 phase gate); retry after restart"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Truth table over the PURE gate logic only — the global mirror is
    /// deliberately not asserted here because other tests (vsock_server's
    /// set_phase suite) legitimately write it in parallel; a global
    /// "must-allow" assertion would flake whenever one of them sets
    /// Draining/Stopping concurrently.
    #[test]
    fn phase_gate_truth_table() {
        assert!(code_allows_mutations(0), "unset (CLI mode) must allow");
        for allowed in [
            VmPhase::Provisioning,
            VmPhase::Starting,
            VmPhase::Ready,
            VmPhase::Failed,
        ] {
            assert!(
                code_allows_mutations(encode(allowed)),
                "{allowed:?} must allow (Failed allows — recovery ensures are the way out)"
            );
        }
        for refused in [VmPhase::Draining, VmPhase::Stopping] {
            assert!(
                !code_allows_mutations(encode(refused)),
                "{refused:?} must refuse container mutations"
            );
        }
        let msg = refusal("ensure tillandsias-proxy");
        assert!(msg.contains("order 234") && msg.contains("ensure tillandsias-proxy"));
    }
}
