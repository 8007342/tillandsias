//! The guest powers itself off when the host asks it to stop (order 1430-rnpd).
//!
//! Measured on darwin 2026-09-28..30: 10 tray quits, 0 clean stops. The
//! VmShutdownRequest arm set phase=Draining and closed the connection, so the
//! tray waited 10 s for a reply that never came. Nothing then started the OS
//! shutdown whose SIGTERM is what makes headless drain, so VZ's requestStop
//! went unanswered for 65 s and every quit ended in a force-stop.
//!
//! THIS MUST NEVER POWER OFF A HOST. Three independent fences:
//!   1. under cfg(test) the action is a recorder, never a command;
//!   2. the real action is compiled only for Linux (a Mac cannot reach it);
//!   3. at runtime it refuses unless the guest's own unit opted in with
//!      TILLANDSIAS_GUEST_POWEROFF=1 (set only by the VZ guest unit).
//!
//! A refusal leaves today's behaviour in place: the host's requestStop and,
//! failing that, its force-stop.

/// The opt-in the VZ guest's systemd unit sets, and nothing else does.
pub const GUEST_POWEROFF_ENV: &str = "TILLANDSIAS_GUEST_POWEROFF";

/// Fence 3, pure and testable: may this process power the machine off?
pub fn poweroff_allowed(opt_in: Option<&str>, is_linux: bool) -> Result<(), String> {
    if !is_linux {
        return Err(
            "refused:guest-poweroff:not-linux — only the Linux guest may power itself off".into(),
        );
    }
    if opt_in != Some("1") {
        return Err(format!(
            "refused:guest-poweroff:not-the-guest — {GUEST_POWEROFF_ENV}=1 is set only by the VZ guest's \
             tillandsias-headless unit; without it this is not known to be the guest, so the host's \
             requestStop/force-stop path stays in charge"
        ));
    }
    Ok(())
}

/// Ask the OS to shut down cleanly. Returns at once: systemd stops the units
/// (headless gets SIGTERM and drains podman) and powers the VM off.
#[cfg(not(test))]
pub fn request_poweroff() -> Result<(), String> {
    let opt_in = std::env::var(GUEST_POWEROFF_ENV).ok();
    poweroff_allowed(opt_in.as_deref(), cfg!(target_os = "linux"))?;
    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("systemctl")
            .args(["poweroff", "--no-wall"])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("could not start `systemctl poweroff`: {e}"))
    }
    #[cfg(not(target_os = "linux"))]
    {
        unreachable!("poweroff_allowed refuses off Linux")
    }
}

#[cfg(test)]
static FAKE_POWEROFF_CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Fence 1: in tests the action only counts.
#[cfg(test)]
pub fn request_poweroff() -> Result<(), String> {
    FAKE_POWEROFF_CALLS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    Ok(())
}

#[cfg(test)]
pub fn fake_poweroff_calls() -> usize {
    FAKE_POWEROFF_CALLS.load(std::sync::atomic::Ordering::SeqCst)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_linux_guest_that_opted_in_may_power_off() {
        assert_eq!(poweroff_allowed(Some("1"), true), Ok(()));
        let host = poweroff_allowed(Some("1"), false).expect_err("a non-Linux host must refuse");
        assert!(
            host.starts_with("refused:guest-poweroff:not-linux"),
            "{host}"
        );
        for opt_in in [None, Some("0"), Some(""), Some("true")] {
            let err = poweroff_allowed(opt_in, true).expect_err("no opt-in must refuse");
            assert!(
                err.starts_with("refused:guest-poweroff:not-the-guest"),
                "{opt_in:?}: {err}"
            );
        }
    }
}
