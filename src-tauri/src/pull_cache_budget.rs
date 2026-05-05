//! Tiered RAMDISK soft-cap detection for the pull-on-demand cheatsheet cache.
//!
//! At tray startup we read host `MemTotal` once, classify the host into one
//! of three tiers (Modest / Normal / Plentiful), and resolve the cap (in MB)
//! that every forge container receives via `TILLANDSIAS_PULL_CACHE_RAM_MB`.
//!
//! User-configurable override: `~/.config/tillandsias/config.toml`'s
//! `[forge] pull_cache_ram_mb = N` wins over auto-detection.
//!
//! The resolved cap is cached for the tray-process lifetime via `OnceLock` —
//! `MemTotal` cannot change at runtime, and re-reading the config on every
//! forge launch would be wasted I/O.
//!
//! @trace spec:cheatsheets-license-tiered, spec:forge-hot-cold-split

use std::sync::OnceLock;

use tillandsias_core::config::GlobalConfig;

/// Modest tier: hosts with < 8 GiB of total RAM. 64 MB cap is the floor —
/// any smaller and a single Oracle JDK doc page can't fit in tmpfs.
const MODEST_CAP_MB: u32 = 64;

/// Normal tier: 8 GiB ≤ MemTotal < 32 GiB. 128 MB is enough for a typical
/// per-project working set of 2–3 large doc archives.
const NORMAL_CAP_MB: u32 = 128;

/// Plentiful tier: MemTotal ≥ 32 GiB. 1024 MB lets a workstation absorb
/// every JDK / Rust / Python doc tree the host's projects might pull
/// without any disk spillover at all.
const PLENTIFUL_CAP_MB: u32 = 1024;

/// 8 GiB in MiB — boundary between Modest and Normal tiers.
const MODEST_NORMAL_BOUNDARY_MIB: u64 = 8 * 1024;

/// 32 GiB in MiB — boundary between Normal and Plentiful tiers.
const NORMAL_PLENTIFUL_BOUNDARY_MIB: u64 = 32 * 1024;

/// Cached resolved cap. Computed exactly once per tray-process lifetime.
static RESOLVED_CAP: OnceLock<u32> = OnceLock::new();

/// Resolve the pull-cache RAM soft-cap for this host (MB).
///
/// Resolution order:
///   1. `forge.pull_cache_ram_mb` override from `~/.config/tillandsias/config.toml`
///      if present (and non-zero).
///   2. Host `MemTotal` tier (auto-detected via `/proc/meminfo` on Linux,
///      platform-equivalent on macOS / Windows).
///   3. NORMAL_CAP_MB fallback if probing `MemTotal` fails.
///
/// Cached for the tray-process lifetime — `MemTotal` cannot change at
/// runtime, and per-launch config re-reads would waste I/O.
///
/// @trace spec:cheatsheets-license-tiered
pub fn resolved_cap_mb() -> u32 {
    *RESOLVED_CAP.get_or_init(|| {
        let cfg = tillandsias_core::config::load_global_config();
        resolve_cap_mb(&cfg)
    })
}

/// Pure resolution function — testable without touching the real config or
/// the OnceLock cache.
///
/// @trace spec:cheatsheets-license-tiered
pub fn resolve_cap_mb(cfg: &GlobalConfig) -> u32 {
    if let Some(override_mb) = cfg.forge.pull_cache_ram_mb {
        if override_mb > 0 {
            tracing::info!(
                accountability = true,
                category = "forge-launch",
                spec = "cheatsheets-license-tiered",
                cap_mb = override_mb,
                source = "config-override",
                "Pull-cache RAM cap resolved from forge.pull_cache_ram_mb override"
            );
            return override_mb;
        }
    }

    let cap = match probe_mem_total_mib() {
        Ok(mib) => classify_mem_total(mib),
        Err(e) => {
            tracing::warn!(
                spec = "cheatsheets-license-tiered",
                error = %e,
                fallback_cap_mb = NORMAL_CAP_MB,
                "MemTotal probe failed — using Normal tier cap"
            );
            NORMAL_CAP_MB
        }
    };

    tracing::info!(
        accountability = true,
        category = "forge-launch",
        spec = "cheatsheets-license-tiered",
        cap_mb = cap,
        source = "auto-detected",
        "Pull-cache RAM cap resolved from host MemTotal tier"
    );
    cap
}

/// Classify a `MemTotal` (in MiB) into one of the three tier caps.
///
/// @trace spec:cheatsheets-license-tiered
pub fn classify_mem_total(mem_total_mib: u64) -> u32 {
    if mem_total_mib < MODEST_NORMAL_BOUNDARY_MIB {
        MODEST_CAP_MB
    } else if mem_total_mib < NORMAL_PLENTIFUL_BOUNDARY_MIB {
        NORMAL_CAP_MB
    } else {
        PLENTIFUL_CAP_MB
    }
}

// ---------------------------------------------------------------------------
// Platform implementations — read MemTotal (NOT MemAvailable, unlike preflight)
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn probe_mem_total_mib() -> Result<u64, String> {
    let content = std::fs::read_to_string("/proc/meminfo")
        .map_err(|e| format!("cannot read /proc/meminfo: {e}"))?;
    for line in content.lines() {
        // Format: "MemTotal:       16240936 kB" — same shape as MemAvailable.
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            let kb_str = rest.split_whitespace().next().unwrap_or("0");
            let kb: u64 = kb_str
                .parse()
                .map_err(|e| format!("cannot parse MemTotal: {e}"))?;
            // Convert kB → MiB. /proc/meminfo's kB is actually KiB (1024
            // bytes), per kernel convention — confirmed in
            // Documentation/filesystems/proc.rst.
            return Ok(kb / 1024);
        }
    }
    Err("MemTotal not found in /proc/meminfo".to_string())
}

#[cfg(target_os = "macos")]
fn probe_mem_total_mib() -> Result<u64, String> {
    // sysctlbyname("hw.memsize") returns total physical RAM in BYTES.
    // Wrap the libc call directly — same pattern as preflight.rs's macOS arm.
    let mut size: u64 = 0;
    let mut len: usize = std::mem::size_of::<u64>();
    let name = std::ffi::CString::new("hw.memsize").unwrap();
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut size as *mut u64 as *mut libc::c_void,
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return Err(format!(
            "sysctlbyname(hw.memsize) failed (errno={})",
            std::io::Error::last_os_error()
        ));
    }
    Ok(size / (1024 * 1024))
}

#[cfg(target_os = "windows")]
fn probe_mem_total_mib() -> Result<u64, String> {
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    let mut mem_status = MEMORYSTATUSEX {
        dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
        dwMemoryLoad: 0,
        ullTotalPhys: 0,
        ullAvailPhys: 0,
        ullTotalPageFile: 0,
        ullAvailPageFile: 0,
        ullTotalVirtual: 0,
        ullAvailVirtual: 0,
        ullAvailExtendedVirtual: 0,
    };
    let ok = unsafe { GlobalMemoryStatusEx(&mut mem_status) };
    if ok == 0 {
        return Err("GlobalMemoryStatusEx returned FALSE".to_string());
    }
    Ok(mem_status.ullTotalPhys / (1024 * 1024))
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
fn probe_mem_total_mib() -> Result<u64, String> {
    Err("MemTotal probe not implemented for this platform".to_string())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // @trace spec:cheatsheets-license-tiered
    #[test]
    fn classify_modest_under_8_gib() {
        // 4 GiB → Modest → 64 MB
        assert_eq!(classify_mem_total(4 * 1024), MODEST_CAP_MB);
        // 6 GiB → still Modest
        assert_eq!(classify_mem_total(6 * 1024), MODEST_CAP_MB);
        // Just below 8 GiB
        assert_eq!(classify_mem_total(MODEST_NORMAL_BOUNDARY_MIB - 1), MODEST_CAP_MB);
    }

    // @trace spec:cheatsheets-license-tiered
    #[test]
    fn classify_normal_8_to_32_gib() {
        // Exactly 8 GiB → Normal → 128 MB
        assert_eq!(classify_mem_total(MODEST_NORMAL_BOUNDARY_MIB), NORMAL_CAP_MB);
        // 16 GiB → Normal
        assert_eq!(classify_mem_total(16 * 1024), NORMAL_CAP_MB);
        // Just below 32 GiB
        assert_eq!(classify_mem_total(NORMAL_PLENTIFUL_BOUNDARY_MIB - 1), NORMAL_CAP_MB);
    }

    // @trace spec:cheatsheets-license-tiered
    #[test]
    fn classify_plentiful_at_or_above_32_gib() {
        // Exactly 32 GiB → Plentiful → 1024 MB
        assert_eq!(classify_mem_total(NORMAL_PLENTIFUL_BOUNDARY_MIB), PLENTIFUL_CAP_MB);
        // 64 GiB → Plentiful
        assert_eq!(classify_mem_total(64 * 1024), PLENTIFUL_CAP_MB);
    }

    // @trace spec:cheatsheets-license-tiered
    #[test]
    fn override_wins_over_autodetection() {
        let mut cfg = GlobalConfig::default();
        cfg.forge.pull_cache_ram_mb = Some(256);
        // Even on a 4 GiB host (Modest tier auto-detects 64 MB), the
        // override wins.
        let resolved = resolve_cap_mb(&cfg);
        assert_eq!(resolved, 256);
    }

    // @trace spec:cheatsheets-license-tiered
    #[test]
    fn override_zero_falls_back_to_autodetection() {
        // A user setting 0 is nonsensical — treat as "no override" and
        // fall back to auto-detection rather than disabling the cache.
        let mut cfg = GlobalConfig::default();
        cfg.forge.pull_cache_ram_mb = Some(0);
        let resolved = resolve_cap_mb(&cfg);
        // Resolved cap must be one of the three tier values (or NORMAL
        // fallback if probing failed in CI).
        assert!(
            resolved == MODEST_CAP_MB
                || resolved == NORMAL_CAP_MB
                || resolved == PLENTIFUL_CAP_MB,
            "resolved cap should be a tier value, got {resolved}"
        );
    }

    // @trace spec:cheatsheets-license-tiered
    #[test]
    fn auto_detection_returns_a_tier_value() {
        let cfg = GlobalConfig::default();
        let resolved = resolve_cap_mb(&cfg);
        assert!(
            resolved == MODEST_CAP_MB
                || resolved == NORMAL_CAP_MB
                || resolved == PLENTIFUL_CAP_MB,
            "auto-detected cap should match one of the three tiers, got {resolved}"
        );
    }

    // @trace spec:cheatsheets-license-tiered
    #[cfg(target_os = "linux")]
    #[test]
    fn linux_meminfo_reports_nonzero_mem_total() {
        match probe_mem_total_mib() {
            Ok(mib) => assert!(mib > 0, "MemTotal must be > 0 on a live Linux system"),
            Err(e) => eprintln!("Linux MemTotal probe skipped in this env: {e}"),
        }
    }
}
