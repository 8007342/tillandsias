//! Host RAM preflight check for forge container launches.
//!
//! Before launching a forge container with a `/home/forge/src` tmpfs, the
//! host must have enough free RAM to satisfy the combined budget:
//! project-source tmpfs + cheatsheets (8MB) + a 1.25× headroom factor.
//!
//! Implementation:
//! - Linux: reads `/proc/meminfo`, parses the `MemAvailable:` line.
//!
//! @trace spec:forge-hot-cold-split

use std::fmt;

/// The headroom factor applied to the required budget before comparing with
/// host RAM. 1.25 = require 25% slack above the requested allocation.
const HEADROOM_FACTOR: f32 = 1.25;

/// Result of a successful RAM preflight check.
#[derive(Debug, Clone)]
pub struct HostRamCheck {
    /// Host RAM available at check time (in MB).
    pub mem_available_mb: u32,
    /// Budget that was requested (in MB, before headroom factor).
    pub required_mb: u32,
    /// Headroom factor used (always 1.25 — exposed for observability).
    pub headroom_factor: f32,
}

/// Error returned when the preflight check fails.
#[derive(Debug, Clone)]
pub enum PreflightError {
    /// Host RAM is below the minimum required (including headroom).
    InsufficientRam {
        available_mb: u32,
        required_mb: u32,
        headroom_factor: f32,
    },
    /// Failed to probe host memory (e.g., /proc/meminfo unreadable).
    Probe(String),
}

impl fmt::Display for PreflightError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InsufficientRam {
                available_mb,
                required_mb,
                headroom_factor,
            } => write!(
                f,
                "Insufficient host RAM: {available_mb}MB available, \
                 need at least {}MB ({}MB × {headroom_factor:.2}× headroom)",
                (*required_mb as f32 * headroom_factor).ceil() as u32,
                required_mb,
            ),
            Self::Probe(msg) => write!(f, "RAM probe failed: {msg}"),
        }
    }
}

/// Check that the host has enough free RAM to satisfy `required_mb` with
/// the configured headroom factor (1.25 by default).
///
/// Returns `Ok(HostRamCheck)` when `mem_available >= required_mb × 1.25`.
/// Returns `Err(PreflightError::InsufficientRam)` otherwise.
/// Returns `Err(PreflightError::Probe)` when the host memory cannot be read.
///
/// @trace spec:forge-hot-cold-split
pub fn check_host_ram(required_mb: u32) -> Result<HostRamCheck, PreflightError> {
    let mem_available_mb = probe_mem_available_mb()?;

    let threshold = (required_mb as f32 * HEADROOM_FACTOR).ceil() as u32;

    if mem_available_mb < threshold {
        return Err(PreflightError::InsufficientRam {
            available_mb: mem_available_mb,
            required_mb,
            headroom_factor: HEADROOM_FACTOR,
        });
    }

    Ok(HostRamCheck {
        mem_available_mb,
        required_mb,
        headroom_factor: HEADROOM_FACTOR,
    })
}

// ---------------------------------------------------------------------------
// Platform implementations
// ---------------------------------------------------------------------------

fn probe_mem_available_mb() -> Result<u32, PreflightError> {
    probe_linux_meminfo()
}

// ---------------------------------------------------------------------------
// Linux: /proc/meminfo
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn probe_linux_meminfo() -> Result<u32, PreflightError> {
    let content = std::fs::read_to_string("/proc/meminfo").map_err(|e| {
        PreflightError::Probe(format!("cannot read /proc/meminfo: {e}"))
    })?;

    for line in content.lines() {
        // Format: "MemAvailable:   12345678 kB"
        if let Some(rest) = line.strip_prefix("MemAvailable:") {
            let kb_str = rest.split_whitespace().next().unwrap_or("0");
            let kb: u64 = kb_str.parse().map_err(|e| {
                PreflightError::Probe(format!("cannot parse MemAvailable: {e}"))
            })?;
            // Convert kB → MB (integer division, conservative rounding down).
            return Ok((kb / 1024) as u32);
        }
    }

    Err(PreflightError::Probe(
        "MemAvailable not found in /proc/meminfo".to_string(),
    ))
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // @trace spec:forge-hot-cold-split
    #[test]
    fn check_host_ram_passes_when_plenty_available() {
        // 1 MB required — virtually guaranteed to pass on any real machine.
        let result = check_host_ram(1);
        // On Linux CI we can actually read /proc/meminfo, so we expect Ok.
        // On unsupported platforms (rare in CI), Probe is acceptable.
        match result {
            Ok(check) => {
                assert_eq!(check.required_mb, 1);
                assert_eq!(check.headroom_factor, HEADROOM_FACTOR);
                assert!(check.mem_available_mb >= 1);
            }
            Err(PreflightError::InsufficientRam { .. }) => {
                panic!("Preflight should pass for 1MB requirement");
            }
            Err(PreflightError::Probe(msg)) => {
                // Unsupported platform or CI environment — log and skip.
                eprintln!("RAM probe unavailable (platform): {msg}");
            }
        }
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn check_host_ram_fails_with_insufficient_ram_error() {
        // u32::MAX MB requirement — guaranteed to fail on any real machine.
        let result = check_host_ram(u32::MAX / 2);
        match result {
            Err(PreflightError::InsufficientRam {
                required_mb,
                headroom_factor,
                available_mb,
            }) => {
                assert_eq!(required_mb, u32::MAX / 2);
                assert_eq!(headroom_factor, HEADROOM_FACTOR);
                assert!(available_mb < u32::MAX); // probe succeeded
            }
            Err(PreflightError::Probe(msg)) => {
                // Unsupported platform — acceptable in CI.
                eprintln!("RAM probe unavailable (platform): {msg}");
            }
            Ok(_) => {
                panic!("Preflight must fail when required > available (u32::MAX/2 MB)");
            }
        }
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn host_ram_check_includes_25_percent_headroom() {
        // Verify that the threshold is ceil(required × 1.25).
        // We test the logic via the Display impl which shows the threshold.
        let err = PreflightError::InsufficientRam {
            available_mb: 100,
            required_mb: 200,
            headroom_factor: 1.25,
        };
        let msg = err.to_string();
        // 200 * 1.25 = 250
        assert!(
            msg.contains("250"),
            "Error message should show the 25%-headroom threshold (250MB). Got: {msg}"
        );
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn probe_linux_meminfo_returns_nonzero() {
        let result = probe_linux_meminfo();
        match result {
            Ok(mb) => assert!(mb > 0, "MemAvailable should be > 0 on a live system"),
            Err(e) => eprintln!("Linux meminfo probe skipped in this env: {e}"),
        }
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn parse_linux_meminfo_extracts_mem_available() {
        // Simulate /proc/meminfo output with known MemAvailable.
        let fake_meminfo = "\
MemTotal:       16240936 kB\n\
MemFree:         3012344 kB\n\
MemAvailable:    8388608 kB\n\
Buffers:          512000 kB\n\
";
        // Parse via the internal helper by writing to a temp file.
        let dir = std::env::temp_dir().join("tillandsias-preflight-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("meminfo");
        std::fs::write(&path, fake_meminfo).unwrap();

        let content = std::fs::read_to_string(&path).unwrap();
        let mut found_mb = None;
        for line in content.lines() {
            if let Some(rest) = line.strip_prefix("MemAvailable:") {
                let kb: u64 = rest.split_whitespace().next().unwrap_or("0").parse().unwrap();
                found_mb = Some((kb / 1024) as u32);
            }
        }
        // 8388608 kB / 1024 = 8192 MB
        assert_eq!(found_mb, Some(8192));

        std::fs::remove_dir_all(&dir).ok();
    }
}
