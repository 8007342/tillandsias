//! ORDER 1286-4437 — the shared half of `--reset-state`.
//!
//! Operator ruling 2026-09-20: an install resets and reprovisions the local
//! state on every platform, so a `curl|bash` or `irm|iex` install is also the
//! repair for a broken one.
//!
//! WHAT LIVES HERE AND WHY ONLY THIS. The three platforms' reset BODIES are
//! legitimately different — podman on Linux, `wsl --unregister` on Windows,
//! Virtualization.framework on macOS — and unifying them would be a refactor of
//! internals that have nothing in common. What must NOT differ is the contract,
//! and two pieces of it are executable rather than prose:
//!
//!   * [`destructive_reset_allowed`] — THE single opt-out. It is here because
//!     the alternative measured itself into a corner: the original
//!     `destructive_reset_allowed()` is a PRIVATE fn in
//!     `tillandsias-headless`'s `main.rs`, and that crate has NO `[lib]`
//!     target, so nothing could import it. Each tray would have had to COPY
//!     it — a second implementation of the one affordance the same ruling says
//!     must have exactly one. All four binaries already depend on this crate.
//!   * [`announce_reset_plan`] — one wording. Three arms printing their own
//!     destroyed/preserved banner is three wordings by the end of the week.
//!
//! THE BODIES DO NOT LIVE HERE. Each binary keeps its own beside its existing
//! flags, so the platform can actually reach it: macOS ships only
//! `tillandsias-tray` (there is no `tillandsias-headless` in the bundle —
//! measured by macneo on a fresh v56.9.19.2 install), and on Windows the
//! headless binary refuses that lane by design.

/// THE single opt-out, and the only one.
///
/// `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` skips the destruction and leaves the
/// caller to reprovision through its platform's plain init. Anything else —
/// unset, empty, any other value — means the reset proceeds, because the
/// operator's ruling makes the reset the DEFAULT and a fresh install the repair.
///
/// A second variable (`TILLANDSIAS_INSTALL_SKIP_RESET`) was proposed, agreed by
/// three hosts and approved by the coordinator before anyone read the source.
/// This function already existed and the smoke runbook already called it "the
/// only supported opt-out". Do not add another.
///
/// NOT to be confused with `TILLANDSIAS_RESET_KEEP_MODELS=1`, which NARROWS the
/// reset's scope (spare the model cache) rather than skipping it. That is a
/// different question and is not a second escape hatch; it predates this order
/// and must not be removed as one.
pub fn destructive_reset_allowed() -> bool {
    std::env::var("TILLANDSIAS_DESTRUCTIVE_RESET_OK").map_or(true, |v| v != "0")
}

/// The exact line every platform prints when the opt-out above suppressed the
/// reset. A shared constant rather than three string literals so it is
/// greppable across the fleet and cannot drift.
pub const RESET_SKIPPED_LINE: &str =
    "[tillandsias] --reset-state: reset SKIPPED by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 \
     — reprovisioning through the platform's plain init instead.";

/// The exact prefix of the refusal every platform prints when its reprovision
/// path is absent. See [`announce_reset_plan`]'s note on the pre-flight guard.
pub const RESET_NO_REPROVISION_PATH: &str =
    "[tillandsias] --reset-state: REFUSING to destroy anything — the reprovision \
     path is missing or not executable:";

/// Print the reset plan BEFORE anything is touched.
///
/// `preserved` is not decoration and is the reason this takes two lists. Every
/// platform preserves an INSTALLATION ANCHOR — `installation-uuid-v1` on Linux
/// and macOS, `tillandsias-vm-uuid` on Windows — from which the in-guest Vault
/// derives its master key. Clearing it makes the next vault UNDERIVABLE rather
/// than re-initialised (order 803-49re: permanently broken GitHub login). An
/// operator shown only a destroyed-list cannot tell whether their identity is
/// about to go with it, which is why the flag is named `--reset-state` and not
/// `--reset-install`: the name must not claim the thing it is forbidden to touch.
///
/// THE PRE-FLIGHT GUARD IS A REQUIREMENT OF THIS CONTRACT, documented here so it
/// is one rule rather than three habits: **the caller verifies its own
/// reprovision path exists and is executable BEFORE calling this, and refuses
/// with [`RESET_NO_REPROVISION_PATH`] if not.** The check is not vacuous even
/// though the running body usually IS that binary: an install can be
/// interrupted between the swap and the reset, and on 2026-09-20 macneo
/// measured `/Applications/Tillandsias.app` GONE while 1.2 GiB of VM state
/// survived, with no `.bak` and no identified cause (recorded as unknown — not
/// an uninstall, not a reset, not a mid-swap death, since all three would have
/// taken the state). A repair tool that assumes the thing it repairs with is
/// present is not a repair tool, and that broken host is exactly the one this
/// flag exists to fix.
pub fn announce_reset_plan(destroyed: &[&str], preserved: &[&str]) {
    eprintln!("[tillandsias] --reset-state: resetting local state before reprovisioning.");
    eprintln!("[tillandsias]   WILL BE DESTROYED:");
    for d in destroyed {
        eprintln!("[tillandsias]     - {d}");
    }
    eprintln!("[tillandsias]   WILL BE PRESERVED:");
    for k in preserved {
        eprintln!("[tillandsias]     - {k}");
    }
    eprintln!(
        "[tillandsias]   Skip the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0. \
         This is the ONLY opt-out."
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The default is the RESET. The operator's ruling makes an install the
    /// repair, so an absent variable must not be read as caution.
    #[test]
    fn unset_means_reset_proceeds() {
        unsafe { std::env::remove_var("TILLANDSIAS_DESTRUCTIVE_RESET_OK") };
        assert!(destructive_reset_allowed());
    }

    /// Only the literal "0" suppresses it. NEGATIVE CONTROL against a fix that
    /// treats any value as an opt-out, which would make `=1` mean "skip" and
    /// silently spare state on every host that set it to enable the reset.
    #[test]
    fn only_zero_suppresses() {
        unsafe { std::env::set_var("TILLANDSIAS_DESTRUCTIVE_RESET_OK", "0") };
        assert!(!destructive_reset_allowed());
        for v in ["1", "yes", "", "false", "00"] {
            unsafe { std::env::set_var("TILLANDSIAS_DESTRUCTIVE_RESET_OK", v) };
            assert!(
                destructive_reset_allowed(),
                "value {v:?} must NOT be read as an opt-out"
            );
        }
        unsafe { std::env::remove_var("TILLANDSIAS_DESTRUCTIVE_RESET_OK") };
    }

    /// The shared strings are what the other two arms copy; pin them so a
    /// reword here is a visible break rather than a silent divergence.
    #[test]
    fn shared_lines_are_greppable_and_name_the_variable() {
        assert!(RESET_SKIPPED_LINE.contains("TILLANDSIAS_DESTRUCTIVE_RESET_OK=0"));
        assert!(RESET_SKIPPED_LINE.contains("--reset-state"));
        assert!(RESET_NO_REPROVISION_PATH.contains("REFUSING to destroy anything"));
    }
}
