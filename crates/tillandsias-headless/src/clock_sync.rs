//! Host-driven guest clock correction (order 1503-qrgz).
//!
//! The macOS VM does not run while the Mac sleeps, so the guest clock falls
//! behind by the sleep. Measured 2026-09-29 on tlatoanis-macbook-air: chrony
//! then spends about 3.5 min unsynchronised (every source rejected on jitter
//! and root distance after the pause), and under Fedora's "makestep 1.0 3"
//! it only SLEWS afterwards, at about 77 ms/s: 69 minutes takes about 15 h.
//! The tray sends `HostClockSync` on every did-wake notification, and the
//! guest sets its clock from the host's reading at once.
//!
//! Setting CLOCK_REALTIME needs CAP_SYS_TIME, which the headless service
//! already holds as root in the guest. No new privileged helper is involved.

/// Below this skew the clock is left alone: chrony handles small offsets, and
/// a step inside its own accuracy would only add noise.
pub(crate) const CLOCK_STEP_THRESHOLD_MS: i64 = 1_000;

/// How far the guest must move to match the host, or `None` when the skew is
/// within [`CLOCK_STEP_THRESHOLD_MS`]. Positive means the guest is behind.
pub(crate) fn clock_correction_ms(guest_unix_ms: u64, host_unix_ms: u64) -> Option<i64> {
    let delta = host_unix_ms as i64 - guest_unix_ms as i64;
    (delta.abs() >= CLOCK_STEP_THRESHOLD_MS).then_some(delta)
}

/// The guest's wall clock, in Unix milliseconds.
pub(crate) fn guest_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Set CLOCK_REALTIME to `unix_ms`.
#[cfg(target_os = "linux")]
pub(crate) fn set_wall_clock_ms(unix_ms: u64) -> std::io::Result<()> {
    let ts = libc::timespec {
        tv_sec: (unix_ms / 1_000) as libc::time_t,
        tv_nsec: ((unix_ms % 1_000) * 1_000_000) as libc::c_long,
    };
    // SAFETY: a fully initialised timespec, passed by reference.
    let rc = unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// The guest is Linux; elsewhere (host-side test builds) there is no guest
/// clock to set.
#[cfg(not(target_os = "linux"))]
pub(crate) fn set_wall_clock_ms(_unix_ms: u64) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "guest clock setting is Linux-only",
    ))
}

/// Apply one `HostClockSync`: returns the step taken in ms (0 when within the
/// threshold), or the error that prevented it.
pub(crate) fn apply_host_clock(host_unix_ms: u64) -> std::io::Result<i64> {
    match clock_correction_ms(guest_unix_ms(), host_unix_ms) {
        None => Ok(0),
        Some(delta) => set_wall_clock_ms(host_unix_ms).map(|()| delta),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The measured incident: the guest 69 minutes behind is corrected by
    /// exactly that amount, forward.
    #[test]
    fn a_guest_69_minutes_behind_is_stepped_forward_by_69_minutes() {
        let host = 1_790_706_540_000u64;
        let guest = host - 69 * 60 * 1_000;
        assert_eq!(clock_correction_ms(guest, host), Some(69 * 60 * 1_000));
    }

    /// A guest ahead of the host is stepped back.
    #[test]
    fn a_guest_ahead_is_stepped_back() {
        assert_eq!(clock_correction_ms(10_000, 5_000), Some(-5_000));
    }

    /// NEGATIVE CONTROL: sub-second skew is left to chrony; exactly the
    /// threshold is corrected.
    #[test]
    fn sub_second_skew_is_left_alone_and_the_threshold_is_inclusive() {
        assert_eq!(clock_correction_ms(1_000_000, 1_000_999), None);
        assert_eq!(clock_correction_ms(1_000_999, 1_000_000), None);
        assert_eq!(clock_correction_ms(1_000_000, 1_001_000), Some(1_000));
    }
}
