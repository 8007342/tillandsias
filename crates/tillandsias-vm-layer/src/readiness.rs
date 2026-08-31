//! Bound-listener readiness assertion, shared by the macOS (VZ) and
//! Linux-host (WSL) provisioning paths.
//!
//! @trace order:735-ewzp, order:757-4hdt, order:798-emje, order:740-3k4s
//!
//! WHAT THIS EXISTS FOR. 735-ewzp found a readiness chain in which every
//! signal was green while nothing was bound: `headless-preflight.sh` reported
//! `vsock_device=present` (it tests for `/dev/vsock`, which `vsock_loopback`
//! alone provides and the image loads deliberately), the process logged
//! `app.started`, and systemd held the unit `active (running)` with
//! `--listen-vsock 42420` on its command line. The host saw a seven-and-a-half
//! minute timeout. A `/dev/vsock` node and an `active` unit are proxies; this
//! asserts the property itself by connecting to the port.
//!
//! WHY IT IS A MODULE AND NOT A COPY. 740-3k4s split off from 735-ewzp
//! precisely so the two remaining units would not get a blind copy of a probe
//! that took three attempts to get right on hardware. The discriminating form
//! below is measured, not reasoned, and the failure modes it distinguishes are
//! ones that silently passed in earlier attempts — so vz.rs and wsl.rs share
//! one definition rather than each carrying a hand-transcribed variant that can
//! drift back into an always-passing check.
//!
//! TRIPLICATION RESOLVED (740-3k4s, 2026-08-30). The Windows path
//! (`tillandsias-windows-tray/src/wsl_lifecycle.rs`) carried its own copy —
//! the ORIGINAL, and the one measured on hardware. It now installs THIS
//! definition. The fold was deliberately not done blind: it landed from the
//! Windows host itself, behind a real `--reset-guest` reprovision, because
//! shipping an unverified probe to a path nobody could start is the exact
//! mistake 740-3k4s was split off from 735-ewzp to avoid.
//!
//! It also closes a gap the copy had: the Windows probe carried three verdicts
//! and no UNVERIFIABLE, so a guest missing `socat` reported NOT-BOUND — a
//! broken check and an unbound port reading identical. Windows gets the fourth
//! verdict by adopting this module, not by a second edit.

/// Guest-local probe that CONNECTS to the control-wire port and reports whether
/// anything accepts.
///
/// EVERY PART OF THE socat INVOCATION IS LOAD-BEARING, measured on the Windows
/// host before this was shared (735-ewzp):
///
///   * `socat -T1 VSOCK-CONNECT:1:$PORT /dev/null` — CONNECT ADDRESS FIRST.
///     Exit 0 on a bound port, exit 1 on an unbound one.
///   * `socat -u /dev/null VSOCK-CONNECT:1:$PORT` HANGS against a live
///     listener — it would block whatever runs it.
///   * putting `/dev/null` FIRST makes socat reach EOF and exit 0 before the
///     connect can fail, so it PASSES against a dead port. A check that always
///     succeeds is worse than the signal it replaces.
///   * CID 1 is `VMADDR_CID_LOCAL`, so the probe stays inside the guest and
///     needs no host involvement.
///   * socat ships in the Fedora guest image built WITH_VSOCK — no new
///     dependency.
///
/// FOUR VERDICTS, NOT TWO. `bound` (0), `NOT-BOUND` (1), `INDETERMINATE` (2,
/// no loopback transport), and `UNVERIFIABLE` (3, the probe tool is missing so
/// nothing was observed). Every one of these is a different fact and folding
/// any of them together produces a lie: the macOS guest's first loaded run
/// reported NOT-BOUND on a port the host was actively exec'ing over, purely
/// because socat was absent.
///
/// THE THIRD STATE IS NOT AN ERROR. Reaching CID 1 requires `vsock_loopback`.
/// Without it the connect fails ENETUNREACH, and reporting that as NOT-BOUND is
/// a false alarm about a working system — 757-4hdt shipped exactly that alarm
/// and it stopped healthy daemons. The host wire does not use loopback at all,
/// so "this probe cannot observe the property from here" is a true and distinct
/// verdict, and it gets its own exit code (2) rather than being folded into
/// either PASS or FAIL.
pub const READY_SCRIPT: &str = r#"#!/usr/bin/env bash
set -uo pipefail
PORT="${1:-42420}"

# Reaching CID 1 (VMADDR_CID_LOCAL) requires the vsock_loopback module. The
# modules-load.d entry plus `After=systemd-modules-load.service` on this unit
# are what make it deterministic; this modprobe is the BACKSTOP for a guest
# whose modules-load.d entry was never written (removing it recreates
# 757-4hdt's false alarm). It is not silent: it reports the module state it
# observed BEFORE acting and after, so a run that worked because the ordering
# held and a run that worked only by winning a race print different words.
vsock_loopback_state() {
  if [ -d /sys/module/vsock_loopback ] || grep -q '^vsock_loopback ' /proc/modules; then
    echo loaded
  else
    echo missing
  fi
}
before="$(vsock_loopback_state)"
if [ "$before" = missing ]; then
  modprobe vsock_loopback 2>/dev/null || true
fi
after="$(vsock_loopback_state)"
echo "[tillandsias-ready] vsock_loopback before=${before} after=${after}"

# socat is this probe's ONLY external dependency, and a missing one is NOT a
# missing listener. MEASURED on the macOS VZ guest, 2026-08-28: socat was
# absent, every connect failed with "No such file or directory", and the probe
# reported NOT-BOUND against port 42420 WHILE THE HOST WAS EXEC'ING OVER IT.
# That is a false alarm about a working system -- the same shape as 757-4hdt,
# reached by a different route -- and it also burned the full retry window
# looping on a condition that can never change.
#
# The inherited claim was "socat ships in the guest image built WITH_VSOCK, so
# no new dependency is needed". True of the Windows image; not of this one. A
# prerequisite that is asserted rather than checked is exactly the kind of
# unverified readiness signal this packet family exists to remove, so it is now
# checked, once, up front, with its own verdict and its own exit code.
if ! command -v socat >/dev/null 2>&1; then
  echo "[tillandsias-ready] vsock_listener=UNVERIFIABLE port=${PORT} -- socat is not installed in this guest, so this probe cannot observe the listener at all. This says NOTHING about whether the control wire works; it says the CHECK is broken. Install socat in the guest image." >&2
  exit 3
fi

# The 900s is NOT a bind-latency budget: the listener is the first await in the
# vsock task and answers in 61-255 ms (measured over four cold boots, 795-jeym).
# What this window covers is the module load racing the probe. Shorten it only
# after that dependency is deterministic everywhere -- otherwise a short
# deadline just converts a slow pass into a fast INDETERMINATE.
DEADLINE=$(( $(date +%s) + ${TILLANDSIAS_READY_TIMEOUT:-900} ))
last=""
while :; do
  # The CONNECT address must come FIRST -- see the module docs. The reversed
  # form was measured returning 0 for both a live and a dead port.
  last="$(timeout 8 socat -T1 "VSOCK-CONNECT:1:${PORT}" /dev/null 2>&1)" && {
    echo "[tillandsias-ready] vsock_listener=bound port=${PORT}"
    exit 0
  }
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    case "$last" in
      *"Network is unreachable"*)
        echo "[tillandsias-ready] vsock_listener=INDETERMINATE port=${PORT} -- no vsock loopback transport in this guest (vsock_loopback absent), so a guest-local probe cannot observe the listener; this says NOTHING about host reachability, which does not use loopback." >&2
        exit 2
        ;;
      *"No such file or directory"*|*"command not found"*)
        # Belt and braces for the up-front check: if socat vanishes mid-window
        # (a dnf transaction, a read-only remount) the verdict must still not
        # be NOT-BOUND. A broken check and an unbound port are different facts.
        echo "[tillandsias-ready] vsock_listener=UNVERIFIABLE port=${PORT} -- the probe tool could not be run, so nothing was observed. Last error: ${last}" >&2
        exit 3
        ;;
      *)
        echo "[tillandsias-ready] vsock_listener=NOT-BOUND port=${PORT} -- the transport works but nothing accepts on the control-wire port; the host cannot reach this guest. Last error: ${last}" >&2
        exit 1
        ;;
    esac
  fi
  sleep 1
done
"#;

/// Absolute path the probe is installed at, on every path that installs it.
pub const READY_SCRIPT_PATH: &str = "/usr/local/lib/tillandsias/headless-ready.sh";

/// Bound the daemon's restart loop (735-ewzp): a daemon that can never start
/// should end in `failed`, loudly and once, not restart every two seconds
/// forever.
///
/// THESE ARE `[Unit]` DIRECTIVES on modern systemd. Under `[Service]`, where
/// they read more naturally and where they are most often written, they are
/// SILENTLY IGNORED — the same looks-configured-does-nothing shape this whole
/// packet exists to remove. `start_limit_is_a_unit_section_directive` pins
/// that, because review is exactly how this gets missed.
pub const START_LIMIT_DIRECTIVES: &str = "StartLimitIntervalSec=120\nStartLimitBurst=3";

/// The readiness ASSERTION as its own oneshot unit — deliberately NOT an
/// `ExecStartPost` on the daemon (order 757-4hdt).
///
/// 740-3k4s was filed saying "reference it from ExecStartPost, matching the
/// Windows path". That was true when it was written and is not true now: the
/// Windows path MOVED the probe off `ExecStartPost` because a control process
/// that fails there STOPS the service it was measuring — it killed clean-room
/// provisioning of v0.4.260815.1, and `Restart=on-failure` then restarted the
/// same minutes-long work forever. A probe that can kill the healthy process it
/// measures is not a check. Mirroring the packet's letter would have reproduced
/// a bug the fleet already paid for, so this mirrors the mechanism as it now
/// stands, which is what "don't invent a third" actually asks for.
///
/// `Wants=`, never `Requires=`, and no `Before=` on anything: this unit must be
/// able to fail without taking the daemon or the boot with it. It still fails
/// LOUDLY — a failed oneshot is listed by `systemctl --failed` and its stderr
/// lands in the journal, so an unbound control wire stays a red signal, which
/// was 735-ewzp's whole point and is preserved rather than traded away.
///
/// `After=systemd-modules-load.service` is the deterministic-ordering fix
/// (798-emje). The edge is already implied on a normal boot, but implied is not
/// declared: an implied edge is invisible to the reader, unassertable by a
/// test, and silently lost the day someone adds `DefaultDependencies=no`.
pub fn ready_unit(port: u32) -> String {
    format!(
        r#"[Unit]
Description=Tillandsias control-wire readiness assertion
After=tillandsias-headless.service
Wants=tillandsias-headless.service
After=systemd-modules-load.service
Wants=systemd-modules-load.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={READY_SCRIPT_PATH} {port}
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
"#
    )
}

/// Make `vsock_loopback` present for the probe, and SAY which way it went.
///
/// It confirms rather than assuming: `modprobe` alone can no-op on a kernel
/// that lacks the module and leave a silent gap for the probe to discover
/// minutes later. It deliberately does NOT fail provisioning when the module is
/// unavailable — that is a legitimate guest configuration, the host wire does
/// not use loopback, and the correct verdict for it is the probe's
/// INDETERMINATE, not a dead provision.
pub fn vsock_loopback_provision_snippet() -> &'static str {
    "echo 'vsock_loopback' > /etc/modules-load.d/tillandsias-vsock.conf; \
     modprobe vsock_loopback 2>/dev/null; \
     if [ -d /sys/module/vsock_loopback ] || grep -q '^vsock_loopback ' /proc/modules; then \
       echo '[tillandsias-provision] vsock_loopback=loaded'; \
     else \
       echo '[tillandsias-provision] vsock_loopback=unavailable -- the guest-local readiness \
probe will report INDETERMINATE; host reachability does not use loopback and is unaffected'; \
     fi"
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The reversed socat form PASSES against a dead port. Two of the three
    /// candidate forms silently passed on Windows, so the surviving one is
    /// pinned by shape here rather than by anyone remembering.
    #[test]
    fn probe_puts_the_connect_address_first() {
        assert!(
            READY_SCRIPT.contains(r#"socat -T1 "VSOCK-CONNECT:1:${PORT}" /dev/null"#),
            "the CONNECT address must come FIRST; `socat -u /dev/null VSOCK-CONNECT:...` \
             exits 0 against a dead port, i.e. a check that always succeeds"
        );
        assert!(
            !READY_SCRIPT.contains("socat -u /dev/null"),
            "the always-passing reversed form must never reappear"
        );
    }

    /// ENETUNREACH and ECONNREFUSED are different facts and must not be
    /// conflated: the first is a false alarm about a working system, the second
    /// is exactly the defect this probe exists to catch.
    #[test]
    fn probe_keeps_indeterminate_distinct_from_not_bound() {
        assert!(READY_SCRIPT.contains("Network is unreachable"));
        assert!(READY_SCRIPT.contains("vsock_listener=INDETERMINATE"));
        assert!(READY_SCRIPT.contains("vsock_listener=NOT-BOUND"));
        assert!(
            READY_SCRIPT.contains("exit 2"),
            "INDETERMINATE needs its own exit code — folding it into 0 or 1 \
             loses a true and distinct verdict"
        );
    }

    /// A missing probe tool is not a missing listener. Measured the hard way:
    /// the macOS guest reported NOT-BOUND on port 42420 while the host was
    /// exec'ing over that very port, because socat was not installed.
    #[test]
    fn a_missing_probe_tool_is_not_reported_as_an_unbound_listener() {
        assert!(
            READY_SCRIPT.contains("command -v socat"),
            "the probe must check its own dependency before drawing conclusions \
             from that dependency failing"
        );
        assert!(
            READY_SCRIPT.contains("vsock_listener=UNVERIFIABLE"),
            "a broken check needs its own verdict, distinct from NOT-BOUND"
        );
        let preflight = READY_SCRIPT.split("while :; do").next().expect(
            "the dependency check must run BEFORE the retry loop — \
                     otherwise a missing tool burns the whole window",
        );
        assert!(preflight.contains("command -v socat"));
    }

    /// The negative control the packet demands: a port with no listener must
    /// FAIL. Proven at the source level by the exit-1 branch existing and being
    /// reachable only from a failed connect; proven at runtime by the host
    /// measurement recorded on 740-3k4s.
    #[test]
    fn probe_has_a_failing_branch_at_all() {
        let after_loop = READY_SCRIPT
            .split("while :; do")
            .nth(1)
            .expect("the probe must retry in a loop");
        assert!(
            after_loop.contains("exit 1"),
            "an unbound port must be able to fail the probe"
        );
        assert!(
            after_loop.contains("exit 0"),
            "a bound port must be able to pass it"
        );
    }

    /// Under `[Service]` these are silently ignored — the exact
    /// looks-configured-does-nothing shape 740-3k4s exists to remove. Pinned by
    /// a test rather than by review, per the packet's fourth exit criterion.
    #[test]
    fn start_limit_is_a_unit_section_directive() {
        // The VZ user-data only compiles on macos; its half of this assertion
        // runs on the darwin lane (740-3k4s measured it on hardware there).
        #[cfg(target_os = "macos")]
        let units = vec![
            crate::wsl::headless_unit_for_test(42420),
            crate::vz::provision_user_data_for_test(),
        ];
        #[cfg(not(target_os = "macos"))]
        let units = vec![crate::wsl::headless_unit_for_test(42420)];
        for unit in units {
            let unit_section = unit
                .split("[Unit]")
                .find(|s| s.contains("StartLimitIntervalSec"))
                .expect("StartLimitIntervalSec must appear after a unit-section header");
            let before_service = unit_section
                .split("[Service]")
                .next()
                .expect("a unit carrying start limits must also have a [Service] section");
            assert!(
                before_service.contains("StartLimitIntervalSec=120")
                    && before_service.contains("StartLimitBurst=3"),
                "start-limit directives must sit in [Unit], not [Service], where \
                 systemd silently ignores them"
            );
        }
    }

    /// The assertion must not be able to stop the thing it asserts about
    /// (757-4hdt). `Requires=` or a `Before=` would restore that.
    #[test]
    fn ready_unit_cannot_take_the_daemon_down_with_it() {
        let unit = ready_unit(42420);
        assert!(unit.contains("Wants=tillandsias-headless.service"));
        assert!(
            !unit.contains("Requires="),
            "Requires= makes a failing probe fail the daemon — the 757-4hdt bug"
        );
        assert!(
            !unit.contains("Before="),
            "a Before= edge lets this unit block what it is measuring"
        );
        assert!(
            unit.contains("After=systemd-modules-load.service"),
            "the module edge must be DECLARED, not merely implied (798-emje)"
        );
    }
}
