//! Pure registered-distro exec-probe safety policy.
//!
//! Kept platform-independent so Linux CI can execute every transition even
//! though the WSL process wiring in `wsl_lifecycle.rs` is Windows-only.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DistroExecProbeClass {
    Healthy,
    DistroFailure,
    ServiceFailure,
    Timeout,
    InfrastructureFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DistroExecProbeAttempt {
    Initial,
    AfterShutdownRecovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DistroExecProbeDecision {
    UseRegistered,
    RecoverAndRetry,
    ReprovisionDamaged,
    FailNonDestructively,
}

/// Classify a completed non-zero `wsl.exe` probe.
///
/// A non-zero status is distro-damage evidence only after a separate WSL
/// service probe succeeds and the exec stderr carries no known service-wedge
/// marker. The marker check remains authoritative even if the independent
/// sanity probe races and happens to pass.
pub(crate) fn classify_nonzero_distro_exec(
    stderr: &str,
    wsl_service_sane: bool,
) -> DistroExecProbeClass {
    let normalized = stderr.replace('\0', "").to_ascii_uppercase();
    if !wsl_service_sane
        || normalized.contains("WSL/SERVICE")
        || normalized.contains("E_UNEXPECTED")
    {
        DistroExecProbeClass::ServiceFailure
    } else {
        DistroExecProbeClass::DistroFailure
    }
}

/// Pure safety state machine for the registered-distro integrity probe.
///
/// A timeout or explicit WSL-service failure gets exactly one recovery
/// attempt and one retry. The retry may authorize reprovisioning only after a
/// non-zero distro exec whose independent service check is sane. A second
/// timeout/service failure, or an infrastructure failure on either attempt,
/// fails closed without unregistering anything.
pub(crate) fn distro_exec_probe_decision(
    attempt: DistroExecProbeAttempt,
    result: DistroExecProbeClass,
) -> DistroExecProbeDecision {
    match (attempt, result) {
        (_, DistroExecProbeClass::Healthy) => DistroExecProbeDecision::UseRegistered,
        (_, DistroExecProbeClass::DistroFailure) => DistroExecProbeDecision::ReprovisionDamaged,
        (
            DistroExecProbeAttempt::Initial,
            DistroExecProbeClass::Timeout | DistroExecProbeClass::ServiceFailure,
        ) => DistroExecProbeDecision::RecoverAndRetry,
        (
            DistroExecProbeAttempt::AfterShutdownRecovery,
            DistroExecProbeClass::Timeout | DistroExecProbeClass::ServiceFailure,
        )
        | (_, DistroExecProbeClass::InfrastructureFailure) => {
            DistroExecProbeDecision::FailNonDestructively
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_decision_table_is_bounded_and_non_destructive() {
        use DistroExecProbeAttempt::{AfterShutdownRecovery, Initial};
        use DistroExecProbeClass::{
            DistroFailure, Healthy, InfrastructureFailure, ServiceFailure, Timeout,
        };
        use DistroExecProbeDecision::{
            FailNonDestructively, RecoverAndRetry, ReprovisionDamaged, UseRegistered,
        };

        let cases = [
            (Initial, Healthy, UseRegistered),
            (Initial, DistroFailure, ReprovisionDamaged),
            (Initial, ServiceFailure, RecoverAndRetry),
            (Initial, Timeout, RecoverAndRetry),
            (Initial, InfrastructureFailure, FailNonDestructively),
            (AfterShutdownRecovery, Healthy, UseRegistered),
            (AfterShutdownRecovery, DistroFailure, ReprovisionDamaged),
            (AfterShutdownRecovery, ServiceFailure, FailNonDestructively),
            (AfterShutdownRecovery, Timeout, FailNonDestructively),
            (
                AfterShutdownRecovery,
                InfrastructureFailure,
                FailNonDestructively,
            ),
        ];

        for (attempt, result, expected) in cases {
            assert_eq!(
                distro_exec_probe_decision(attempt, result),
                expected,
                "unexpected decision for {attempt:?} + {result:?}"
            );
        }
    }

    #[test]
    fn service_errors_are_never_distro_damage_evidence() {
        assert_eq!(
            classify_nonzero_distro_exec(
                "Wsl/Service/CreateInstance/CreateVm/HCS/E_UNEXPECTED",
                true,
            ),
            DistroExecProbeClass::ServiceFailure,
            "the motivating E_UNEXPECTED wedge must recover, never unregister"
        );
        assert_eq!(
            classify_nonzero_distro_exec("WSL/Service/0x8000ffff", true),
            DistroExecProbeClass::ServiceFailure
        );
        assert_eq!(
            classify_nonzero_distro_exec("generic non-zero", false),
            DistroExecProbeClass::ServiceFailure,
            "an independently unhealthy service makes the exec result inconclusive"
        );
        assert_eq!(
            classify_nonzero_distro_exec("distro exec failed", true),
            DistroExecProbeClass::DistroFailure,
            "only non-zero + independently sane service may authorize repair"
        );
    }
}
