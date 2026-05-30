//! Pre-flight launch gating — host RAM check and friends.
//!
//! Pure functions over (measured_value, required_value) pairs so the
//! decision logic stays unit-testable across hosts. Platform-specific
//! measurement (Linux `/proc/meminfo`, macOS `vm_stat`, Windows
//! `GlobalMemoryStatusEx`) is the caller's responsibility — the
//! cross-platform [`check_host_ram`] decides go / no-go from the
//! measured value.
//!
//! @trace spec:forge-hot-cold-split (Requirement: Pre-flight RAM check
//!   refuses launch on insufficient host RAM)

/// 1.25× headroom factor between MemAvailable and required RAM.
///
/// Spec § "Pre-flight RAM check refuses launch on insufficient host
/// RAM" Scenario "1.25× headroom factor between MemAvailable and
/// required" mandates this exact multiplier. Centralised here so a
/// regression that silently widens or narrows the headroom (e.g. to
/// 1.0 or 2.0) surfaces in a single literal site.
///
/// Expressed as integer numerator + denominator (125/100) so the
/// threshold computation stays integer-only and overflow-safe.
///
/// @trace spec:forge-hot-cold-split
pub const HOST_RAM_HEADROOM_NUM: u64 = 125;
pub const HOST_RAM_HEADROOM_DEN: u64 = 100;

/// Outcome of a successful pre-flight RAM check. Carries the measured
/// + required + threshold trio so the caller can log the decision
/// without re-querying.
///
/// @trace spec:forge-hot-cold-split
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostRamCheck {
    pub mem_available_mb: u64,
    pub required_mb: u32,
    pub threshold_mb: u64,
}

/// Pre-flight errors. Today only `InsufficientRam`; the variant is
/// `non_exhaustive` so future checks (disk, FD limits) can be added
/// without breaking downstream matches.
///
/// Spec § "Refusal emits friendly tray notification + structured
/// accountability log" mandates the structured log carries
/// `host_mem_available_mb`, `budget_mb`, and `decision="refuse"`.
/// The error variant carries the same trio so the log site does not
/// have to re-query the host.
///
/// @trace spec:forge-hot-cold-split
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum PreflightError {
    InsufficientRam {
        mem_available_mb: u64,
        required_mb: u32,
        threshold_mb: u64,
    },
}

impl std::fmt::Display for PreflightError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PreflightError::InsufficientRam {
                mem_available_mb,
                required_mb,
                threshold_mb,
            } => write!(
                f,
                "insufficient host RAM: {mem_available_mb} MiB available, \
                 {required_mb} MiB required ({threshold_mb} MiB with 1.25× headroom)"
            ),
        }
    }
}

impl std::error::Error for PreflightError {}

/// Check whether the host has enough RAM headroom to launch a forge
/// container needing `required_mb` MB.
///
/// Returns `Ok(HostRamCheck)` when `mem_available_mb >= ceil(required_mb × 1.25)`,
/// otherwise `Err(PreflightError::InsufficientRam)`.
///
/// Pure compute — caller is responsible for measuring `mem_available_mb`
/// via the platform-native API (Linux: [`parse_mem_available_mb`] +
/// `/proc/meminfo`; macOS: `vm_stat`; Windows: `GlobalMemoryStatusEx`).
///
/// Spec scenarios:
/// - `available == threshold` → `Ok` (Scenario uses `>=`)
/// - `available == threshold - 1` → `Err`
/// - `required == 0` → trivially `Ok` (no headroom requirement;
///   launching a 0-MB container makes no sense, but the gate doesn't
///   over-reach into validation).
///
/// Integer-only arithmetic. Threshold computed as
/// `ceil((required_mb as u64 × 125) / 100)` so a value like 100 MB
/// rounds to 125 (not 124 from naive integer division).
///
/// @trace spec:forge-hot-cold-split (Requirement: Pre-flight RAM
///   check refuses launch on insufficient host RAM)
pub fn check_host_ram(
    mem_available_mb: u64,
    required_mb: u32,
) -> Result<HostRamCheck, PreflightError> {
    // ceil((required_mb × 125) / 100) without floating-point.
    // `+ DEN - 1` shifts the integer truncation to a ceiling.
    let scaled = (required_mb as u64).saturating_mul(HOST_RAM_HEADROOM_NUM);
    let threshold_mb = scaled.div_ceil(HOST_RAM_HEADROOM_DEN);

    if mem_available_mb >= threshold_mb {
        Ok(HostRamCheck {
            mem_available_mb,
            required_mb,
            threshold_mb,
        })
    } else {
        Err(PreflightError::InsufficientRam {
            mem_available_mb,
            required_mb,
            threshold_mb,
        })
    }
}

/// Parse `MemAvailable: <N> kB` from `/proc/meminfo` content.
///
/// Linux-side measurement step for `check_host_ram`. The kernel
/// reports kibibytes; we convert to mebibytes (integer division —
/// truncation here is conservative: rounds the available value DOWN,
/// making the check more strict, not less).
///
/// Returns `None` when the field is missing or unparseable so callers
/// can fail-closed (refuse launch on a corrupt /proc/meminfo rather
/// than silently treating "no data" as "infinite available").
///
/// Canonical /proc/meminfo line:
///
/// ```text
/// MemAvailable:   16345920 kB
/// ```
///
/// @trace spec:forge-hot-cold-split (Linux-native API per spec
///   § Pre-flight RAM check)
pub fn parse_mem_available_mb(meminfo_output: &str) -> Option<u64> {
    for line in meminfo_output.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("MemAvailable:") {
            // Format: `   16345920 kB`. Strip whitespace, parse the
            // number, drop the `kB` suffix. Tolerant of varying
            // whitespace and a missing suffix (the kernel always
            // emits `kB`, but third-party /proc clones may not).
            let mut parts = rest.split_whitespace();
            let value = parts.next()?.parse::<u64>().ok()?;
            return Some(value / 1024);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // @trace spec:forge-hot-cold-split (Scenario "if mem_available_mb
    //   >= threshold, the result MUST be Ok(HostRamCheck)")
    #[test]
    fn check_host_ram_returns_ok_when_available_meets_threshold() {
        // required 100 MB × 1.25 = 125 MB threshold.
        // available == threshold → Ok (spec uses `>=`).
        let r = check_host_ram(125, 100).expect("125 == threshold should be Ok");
        assert_eq!(r.mem_available_mb, 125);
        assert_eq!(r.required_mb, 100);
        assert_eq!(r.threshold_mb, 125);

        // available > threshold → Ok.
        let r2 = check_host_ram(200, 100).expect("200 > threshold should be Ok");
        assert_eq!(r2.threshold_mb, 125);
    }

    // @trace spec:forge-hot-cold-split (Scenario "if mem_available_mb
    //   < threshold, the result MUST be Err(InsufficientRam)")
    #[test]
    fn check_host_ram_refuses_when_available_below_threshold() {
        // required 100 MB × 1.25 = 125 MB threshold; available 124 → Err.
        let err = check_host_ram(124, 100).expect_err("124 < threshold should be Err");
        match err {
            PreflightError::InsufficientRam {
                mem_available_mb,
                required_mb,
                threshold_mb,
            } => {
                assert_eq!(mem_available_mb, 124);
                assert_eq!(required_mb, 100);
                assert_eq!(threshold_mb, 125);
            }
        }
    }

    // @trace spec:forge-hot-cold-split (Scenario "1.25× headroom
    //   factor between MemAvailable and required")
    #[test]
    fn check_host_ram_uses_ceil_for_threshold() {
        // required 4 MB × 1.25 = 5.0 → ceil 5 (exact).
        let r = check_host_ram(5, 4).unwrap();
        assert_eq!(r.threshold_mb, 5);

        // required 3 MB × 1.25 = 3.75 → ceil 4.
        let r = check_host_ram(4, 3).unwrap();
        assert_eq!(r.threshold_mb, 4);
        // available 3 < 4 → Err.
        let err = check_host_ram(3, 3).unwrap_err();
        match err {
            PreflightError::InsufficientRam { threshold_mb, .. } => {
                assert_eq!(threshold_mb, 4, "3 MB × 1.25 MUST ceil to 4 MB, not 3");
            }
        }
    }

    // @trace spec:forge-hot-cold-split (degenerate-input branch — a
    //   `required_mb=0` launch is nonsensical but the gate must not
    //   panic on it)
    #[test]
    fn check_host_ram_handles_zero_required() {
        // 0 × 1.25 = 0 threshold; any available value meets it.
        let r = check_host_ram(0, 0).unwrap();
        assert_eq!(r.threshold_mb, 0);
        let r2 = check_host_ram(1, 0).unwrap();
        assert_eq!(r2.threshold_mb, 0);
    }

    // @trace spec:forge-hot-cold-split (saturating-mul branch — the
    //   `required_mb × 125` can't overflow u64; required_mb is u32 so
    //   max input is ~5.3 EiB, well below u64::MAX)
    #[test]
    fn check_host_ram_does_not_panic_on_max_required() {
        // u32::MAX MB × 125 = ~5.3 × 10^11; well within u64.
        let err = check_host_ram(0, u32::MAX).unwrap_err();
        match err {
            PreflightError::InsufficientRam { threshold_mb, .. } => {
                assert!(
                    threshold_mb > 0,
                    "max required MUST yield a positive threshold"
                );
            }
        }
    }

    // @trace spec:forge-hot-cold-split (Linux /proc/meminfo parsing)
    #[test]
    fn parse_mem_available_mb_extracts_value_from_canonical_meminfo() {
        let canonical = "MemTotal:       16345920 kB
MemFree:         5234980 kB
MemAvailable:   12500000 kB
Buffers:           45120 kB
Cached:          4567890 kB
";
        // 12500000 kB / 1024 = 12207 MB (truncated — conservative).
        assert_eq!(parse_mem_available_mb(canonical), Some(12207));
    }

    // @trace spec:forge-hot-cold-split (parser fallback — fail-closed
    //   so a corrupt /proc/meminfo refuses launch rather than silently
    //   treating no data as infinite memory)
    #[test]
    fn parse_mem_available_mb_returns_none_on_missing_or_unparseable() {
        // Missing field entirely.
        assert_eq!(
            parse_mem_available_mb("MemTotal: 16000 kB\nMemFree: 5000 kB\n"),
            None
        );
        // Empty input.
        assert_eq!(parse_mem_available_mb(""), None);
        // Unparseable value (corrupt /proc/meminfo).
        assert_eq!(
            parse_mem_available_mb("MemAvailable: not-a-number kB"),
            None
        );
        // Truncated line (no value at all after the colon).
        assert_eq!(parse_mem_available_mb("MemAvailable:"), None);
    }

    // @trace spec:forge-hot-cold-split (Display impl is the
    //   accountability-log-friendly message body)
    #[test]
    fn preflight_error_display_includes_all_three_values() {
        let err = check_host_ram(100, 200).unwrap_err();
        let msg = format!("{err}");
        assert!(
            msg.contains("100 MiB available"),
            "missing available: {msg}"
        );
        assert!(msg.contains("200 MiB required"), "missing required: {msg}");
        assert!(msg.contains("250 MiB"), "missing threshold: {msg}");
        assert!(msg.contains("1.25×"), "missing headroom factor: {msg}");
    }
}
