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
/// required, and threshold trio so the caller can log the decision
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

/// Parse `MemTotal: <N> kB` from `/proc/meminfo` content.
///
/// Companion to [`parse_mem_available_mb`] for the tmpfs-overlay
/// auto-detection tier table in [`resolve_pull_cache_ram_mb`]. Same
/// kB → MiB integer-division semantics (truncates DOWN; conservative
/// because rounding down a 7.99 GiB host to 8191 MiB lands it in the
/// MODEST tier — the safer side of the spec's boundaries).
///
/// Returns `None` when the field is missing or unparseable so callers
/// can fail-closed (refuse to set the env var rather than silently
/// applying the wrong tier).
///
/// @trace spec:forge-hot-cold-split (Linux-native API for spec §
///   Tmpfs-overlay lane auto-detection at tray startup)
pub fn parse_mem_total_mb(meminfo_output: &str) -> Option<u64> {
    for line in meminfo_output.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("MemTotal:") {
            let mut parts = rest.split_whitespace();
            let value = parts.next()?.parse::<u64>().ok()?;
            return Some(value / 1024);
        }
    }
    None
}

/// Tier-table caps (MB) for the tmpfs-overlay lane. Spec § "Tmpfs-
/// overlay lane for per-project ephemeral cache":
///
/// | `MemTotal`                  | Tmpfs cap |
/// |---|---|
/// | `< 8 GiB`                   | 64 MB     |
/// | `8 GiB ≤ MemTotal < 32 GiB` | 128 MB    |
/// | `≥ 32 GiB`                  | 1024 MB   |
///
/// Boundaries pulled out as constants so a regression that silently
/// shifts the tier thresholds surfaces in a single literal site.
///
/// @trace spec:forge-hot-cold-split (Requirement: Tmpfs-overlay lane
///   for per-project ephemeral cache)
pub const PULL_CACHE_RAM_MB_MODEST: u32 = 64;
pub const PULL_CACHE_RAM_MB_NORMAL: u32 = 128;
pub const PULL_CACHE_RAM_MB_PLENTIFUL: u32 = 1024;

/// 8 GiB = 8 × 1024 MiB. The lower boundary between MODEST and
/// NORMAL tiers.
pub const PULL_CACHE_RAM_TIER_NORMAL_MB: u64 = 8 * 1024;

/// 32 GiB = 32 × 1024 MiB. The lower boundary between NORMAL and
/// PLENTIFUL tiers.
pub const PULL_CACHE_RAM_TIER_PLENTIFUL_MB: u64 = 32 * 1024;

/// Resolve the `TILLANDSIAS_PULL_CACHE_RAM_MB` env var value for a
/// host with `mem_total_mb` total RAM, optionally overridden by the
/// user's `forge.pull_cache_ram_mb` config setting.
///
/// Spec § "Tmpfs-overlay cap auto-detected at tray startup" Scenario:
///
/// > if the user's config sets `forge.pull_cache_ram_mb = 256`, the
/// > override MUST win and the env var MUST be `256`
///
/// So `Some(override_mb)` short-circuits the tier lookup. The `u32`
/// override type matches `ForgeConfig::pull_cache_ram_mb: Option<u32>`
/// in config.rs.
///
/// Boundary semantics from the spec's tier table: the `<` versus `≤`
/// distinction matters at the 8 GiB and 32 GiB marks. A host with
/// exactly 8192 MiB is `>= 8 GiB`, so it lands in NORMAL, not MODEST.
/// A host with exactly 32768 MiB lands in PLENTIFUL.
///
/// @trace spec:forge-hot-cold-split (Requirement: Tmpfs-overlay lane
///   — Scenario "Tmpfs-overlay cap auto-detected at tray startup")
pub fn resolve_pull_cache_ram_mb(mem_total_mb: u64, override_mb: Option<u32>) -> u32 {
    if let Some(value) = override_mb {
        return value;
    }
    if mem_total_mb >= PULL_CACHE_RAM_TIER_PLENTIFUL_MB {
        PULL_CACHE_RAM_MB_PLENTIFUL
    } else if mem_total_mb >= PULL_CACHE_RAM_TIER_NORMAL_MB {
        PULL_CACHE_RAM_MB_NORMAL
    } else {
        PULL_CACHE_RAM_MB_MODEST
    }
}

/// Working-set baseline (MB) added on top of the tmpfs sum to compute
/// the `--memory` ceiling for a forge container.
///
/// Spec § "--memory ceiling pairs with tmpfs caps" mandates
/// `--memory = sum(tmpfs caps) + 256 MB` and `--memory-swap` MUST
/// equal `--memory` exactly (zero net swap). The 256 MB baseline is
/// the spec's working-set headroom — enough for the agent process,
/// language servers, and the in-VM helpers without overcommitting.
///
/// @trace spec:forge-hot-cold-split
pub const FORGE_WORKING_SET_BASELINE_MB: u32 = 256;

/// Parse the `size=<N>m` field from a tmpfs spec string.
///
/// Forge tmpfs strings have the form `/path:size=Nm,mode=NNNN`. The
/// size token is `size=<value>m` (lowercase `m` suffix, MiB unit).
/// Returns the parsed value in MiB or `None` when the field is
/// missing/malformed.
///
/// Tolerant of comma-separated extra tokens (mode, …) and of token
/// order — `size=` may appear anywhere after the first colon.
///
/// @trace spec:forge-hot-cold-split (parser for [`compute_memory_
///   ceiling_mb`])
pub fn parse_tmpfs_size_mb(tmpfs_spec: &str) -> Option<u32> {
    // Everything after the first colon is the option list.
    let (_path, opts) = tmpfs_spec.split_once(':')?;
    for token in opts.split(',') {
        let trimmed = token.trim();
        if let Some(rest) = trimmed.strip_prefix("size=") {
            // Strip a trailing unit suffix (`m`/`M`). The forge profiles
            // exclusively use `m`; we accept both cases defensively.
            let value_str = rest
                .strip_suffix('m')
                .or_else(|| rest.strip_suffix('M'))
                .unwrap_or(rest);
            return value_str.parse::<u32>().ok();
        }
    }
    None
}

/// Compute the `--memory` ceiling (MB) for a forge container, given
/// its tmpfs mount sizes.
///
/// Spec § "--memory ceiling pairs with tmpfs caps":
///
/// > The ceiling is: `sum(all tmpfs size_mb) + 256` (256 MB
/// > working-set baseline).
///
/// `--memory-swap` MUST equal `--memory` exactly (zero net swap) —
/// the caller is responsible for emitting both args from the
/// returned value.
///
/// Saturating add so a malicious profile with billions of MB of
/// tmpfs can't overflow. The 256 baseline always wins for empty
/// profiles (returns 256) — useful when the helper is called
/// preemptively on a profile that hasn't yet been sized.
///
/// @trace spec:forge-hot-cold-split (Requirement: --memory ceiling
///   pairs with tmpfs caps)
pub fn compute_memory_ceiling_mb(tmpfs_sizes_mb: impl IntoIterator<Item = u32>) -> u32 {
    let sum: u32 = tmpfs_sizes_mb
        .into_iter()
        .fold(0_u32, |acc, n| acc.saturating_add(n));
    sum.saturating_add(FORGE_WORKING_SET_BASELINE_MB)
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

    // @trace spec:forge-hot-cold-split (Scenario "--memory = sum(tmpfs
    //   caps) + 256 MB working-set baseline")
    #[test]
    fn compute_memory_ceiling_returns_sum_plus_256_baseline() {
        // Spec example: 4 tmpfs mounts totaling 8 + 800 + 256 + 64 = 1128 MB.
        // Ceiling = 1128 + 256 baseline = 1384 MB.
        let sizes = [8, 800, 256, 64];
        assert_eq!(
            compute_memory_ceiling_mb(sizes),
            1384,
            "spec example: {sizes:?} → 1128 + 256 baseline = 1384"
        );

        // Single 256 MB mount → 256 + 256 = 512.
        assert_eq!(compute_memory_ceiling_mb([256]), 512);
    }

    // @trace spec:forge-hot-cold-split (degenerate: empty tmpfs list
    //   — spec mandates ceiling ALWAYS includes the 256 MB baseline,
    //   so even a profile with zero tmpfs mounts gets 256)
    #[test]
    fn compute_memory_ceiling_returns_baseline_for_empty_profile() {
        let empty: [u32; 0] = [];
        assert_eq!(
            compute_memory_ceiling_mb(empty),
            FORGE_WORKING_SET_BASELINE_MB
        );
    }

    // @trace spec:forge-hot-cold-split (saturating-add branch — a
    //   malicious profile listing billions of MB of tmpfs cannot
    //   overflow u32)
    #[test]
    fn compute_memory_ceiling_saturates_on_overflow() {
        // Two near-u32::MAX entries saturate; baseline can't push it
        // further.
        let huge = [u32::MAX - 100, 200];
        assert_eq!(compute_memory_ceiling_mb(huge), u32::MAX);
    }

    // @trace spec:forge-hot-cold-split (parser for tmpfs spec strings
    //   in container_profile.rs — canonical forge format)
    #[test]
    fn parse_tmpfs_size_mb_extracts_from_canonical_forge_format() {
        // Canonical forge tmpfs strings (from container_profile.rs).
        assert_eq!(parse_tmpfs_size_mb("/tmp:size=256m,mode=1777"), Some(256));
        assert_eq!(
            parse_tmpfs_size_mb("/run/user/1000:size=64m,mode=0700"),
            Some(64)
        );
        assert_eq!(
            parse_tmpfs_size_mb("/opt/cheatsheets:size=8m,mode=0755"),
            Some(8)
        );

        // Size without mode (older format).
        assert_eq!(parse_tmpfs_size_mb("/tmp:size=256m"), Some(256));

        // Token order reversed — `mode=` first, then `size=`.
        assert_eq!(parse_tmpfs_size_mb("/tmp:mode=1777,size=512m"), Some(512));

        // Defensive: uppercase `M` suffix.
        assert_eq!(parse_tmpfs_size_mb("/tmp:size=128M"), Some(128));
    }

    // @trace spec:forge-hot-cold-split (parser fallback — malformed
    //   or missing size token returns None so the caller can decide
    //   how to handle the unknown size)
    #[test]
    fn parse_tmpfs_size_mb_returns_none_on_missing_or_malformed() {
        // No colon at all (not a valid tmpfs spec).
        assert_eq!(parse_tmpfs_size_mb("/tmp"), None);
        // Colon but no size token.
        assert_eq!(parse_tmpfs_size_mb("/tmp:mode=1777"), None);
        // Empty input.
        assert_eq!(parse_tmpfs_size_mb(""), None);
        // size= with no value.
        assert_eq!(parse_tmpfs_size_mb("/tmp:size=m"), None);
        // Unparseable size value.
        assert_eq!(parse_tmpfs_size_mb("/tmp:size=hugem"), None);
    }

    // @trace spec:forge-hot-cold-split (Scenario "Tmpfs-overlay cap
    //   auto-detected at tray startup" tier-table boundaries)
    #[test]
    fn resolve_pull_cache_ram_mb_picks_tier_from_mem_total() {
        // MODEST tier: 4 GiB host → 64 MB.
        assert_eq!(
            resolve_pull_cache_ram_mb(4 * 1024, None),
            PULL_CACHE_RAM_MB_MODEST
        );
        // Just below the 8 GiB boundary stays MODEST.
        assert_eq!(
            resolve_pull_cache_ram_mb(8 * 1024 - 1, None),
            PULL_CACHE_RAM_MB_MODEST
        );

        // NORMAL tier: spec example "MemTotal = 16 GiB" → 128 MB.
        assert_eq!(
            resolve_pull_cache_ram_mb(16 * 1024, None),
            PULL_CACHE_RAM_MB_NORMAL
        );
        // Exactly 8 GiB lands in NORMAL (>= boundary).
        assert_eq!(
            resolve_pull_cache_ram_mb(8 * 1024, None),
            PULL_CACHE_RAM_MB_NORMAL
        );
        // Just below the 32 GiB boundary stays NORMAL.
        assert_eq!(
            resolve_pull_cache_ram_mb(32 * 1024 - 1, None),
            PULL_CACHE_RAM_MB_NORMAL
        );

        // PLENTIFUL tier: exactly 32 GiB and above → 1024 MB.
        assert_eq!(
            resolve_pull_cache_ram_mb(32 * 1024, None),
            PULL_CACHE_RAM_MB_PLENTIFUL
        );
        assert_eq!(
            resolve_pull_cache_ram_mb(128 * 1024, None),
            PULL_CACHE_RAM_MB_PLENTIFUL
        );
    }

    // @trace spec:forge-hot-cold-split (Scenario "if the user's config
    //   sets forge.pull_cache_ram_mb = 256, the override MUST win")
    #[test]
    fn resolve_pull_cache_ram_mb_user_override_wins_at_any_tier() {
        // Override wins over MODEST tier auto-detection.
        assert_eq!(resolve_pull_cache_ram_mb(4 * 1024, Some(256)), 256);
        // Override wins over NORMAL tier auto-detection (spec example).
        assert_eq!(resolve_pull_cache_ram_mb(16 * 1024, Some(256)), 256);
        // Override wins over PLENTIFUL tier auto-detection.
        assert_eq!(resolve_pull_cache_ram_mb(128 * 1024, Some(256)), 256);
        // User can override DOWN to a tiny value (e.g. 0) — the spec
        // doesn't validate, so we don't either.
        assert_eq!(resolve_pull_cache_ram_mb(16 * 1024, Some(0)), 0);
    }

    // @trace spec:forge-hot-cold-split (Linux /proc/meminfo parser
    //   for MemTotal — companion to parse_mem_available_mb)
    #[test]
    fn parse_mem_total_mb_extracts_value_from_canonical_meminfo() {
        let canonical = "MemTotal:       16345920 kB
MemFree:         5234980 kB
MemAvailable:   12500000 kB
";
        // 16345920 kB / 1024 = 15962 MiB (truncated).
        assert_eq!(parse_mem_total_mb(canonical), Some(15962));
    }

    // @trace spec:forge-hot-cold-split (parser fail-closed — corrupt
    //   meminfo refuses to set the env var rather than silently
    //   applying the wrong tier)
    #[test]
    fn parse_mem_total_mb_returns_none_on_missing_or_unparseable() {
        // Missing field (e.g. unprivileged /proc clone).
        assert_eq!(parse_mem_total_mb("MemAvailable: 1000 kB\n"), None);
        // Empty input.
        assert_eq!(parse_mem_total_mb(""), None);
        // Unparseable.
        assert_eq!(parse_mem_total_mb("MemTotal: garbage kB"), None);
    }
}
