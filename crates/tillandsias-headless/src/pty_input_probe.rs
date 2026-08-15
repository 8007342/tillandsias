//! Is this PTY session's foreground process waiting for input?
//!
//! Order 723-54zj, rung 1 of 3 splitting item (b) of 689-y2my. MEASUREMENT
//! ONLY: no wire change, no host behaviour. Rung 2 puts the answer on the
//! heartbeat (`CAP_PTY_HEARTBEAT_V2`); rung 3 lets the host act on it.
//!
//! # Why this exists
//!
//! A host driving a guest over the control wire cannot tell a deadlock from a
//! slow command BY TIMING ALONE. 689-y2my's original progress deadline was
//! refuted for exactly that reason: a first-run `--github-login` legitimately
//! sits silent for ~1290s loading a 580MB image, so any timing rule tight
//! enough to catch a wedge also kills working work. Order 332's pins encode
//! that invariant and must keep passing.
//!
//! The ambiguity is only removable with information the guest has and the host
//! does not: whether the child is *blocked reading its terminal*. That is a
//! fact, not an inference from elapsed time.
//!
//! # How, and the wrong turn that got here
//!
//! The obvious mechanism is `/proc/<pid>/wchan` — the kernel symbol a task is
//! sleeping in — and the documented answer for a terminal read is `n_tty_read`.
//! This module was written that way first, and the positive test failed
//! immediately: on the kernel this project develops against
//! (6.18.33.2-microsoft-standard-WSL2) a `cat` blocked on a real PTY reports
//! `wchan=wait_woken`, not `n_tty_read`. The symbol came from documentation
//! rather than measurement.
//!
//! `wait_woken` cannot be matched on, either — it is the generic wait helper,
//! shared with socket reads among others, so a process waiting on the network
//! would have been reported as waiting for terminal input. A guess that
//! produces confident false wedge reports is worse than no probe.
//!
//! So the mechanism is `/proc/<pid>/syscall`, which is exact rather than
//! indicative. For a blocked task the kernel reports the syscall number and its
//! arguments; the same `cat` reports:
//!
//! ```text
//! syscall: 0 0x0 0x70d19807c000 0x40000 ...
//! fd0 -> /dev/pts/3
//! ```
//!
//! Syscall 0 is `read` on x86-64 and argument 0 is the file descriptor. Follow
//! that descriptor through `/proc/<pid>/fd/<n>` and ask whether it is a
//! pseudo-terminal. Blocked in `read` ON A PTS is not an inference — it is the
//! thing itself. A sleeper is in `clock_nanosleep`, a socket read is in `read`
//! on a socket fd, and neither is confusable with this.
//!
//! `/proc/<pid>/syscall` is not universally readable: it needs
//! `CONFIG_HAVE_ARCH_TRACEHOOK`, and ptrace-scope policy can deny it. That is
//! why the verdict is three-valued and why [`InputState::Unknown`] is a
//! first-class answer rather than an error: rung 3 must treat "I cannot tell"
//! as "behave exactly as today", and collapsing it into `NotBlocked` would
//! silently convert an unmeasurable host into a confidently-wrong one.

/// What the foreground process of a PTY session is doing, as far as the guest
/// can actually establish.
///
/// Three-valued on purpose. `Unknown` is not a failure — it is the correct
/// answer on a kernel that will not report scheduler wait channels, and the
/// consumer is required to fall back to existing behaviour when it sees one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputState {
    /// The foreground process is sleeping in the terminal's read path. It will
    /// not proceed until someone writes to the PTY.
    BlockedOnInput,
    /// The foreground process is running, or sleeping somewhere that is not a
    /// terminal read. This is the *working* case, including the slow one.
    NotBlocked,
    /// This host cannot establish the answer. Not an error; the consumer must
    /// degrade to its pre-existing behaviour.
    Unknown,
}

/// What `/proc/<pid>/syscall` said, decomposed into the two things that matter.
///
/// Separated from the /proc read so the parsing is testable against the exact
/// strings a kernel emits, without spawning anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyscallStop {
    /// Blocked in a syscall, with its number and first argument.
    Blocked { number: i64, arg0: i64 },
    /// The task is on-CPU; the kernel writes the literal "running".
    Running,
    /// Unparseable, or the kernel declined to say.
    Unavailable,
}

/// Parse the body of `/proc/<pid>/syscall`.
///
/// Format is the syscall number followed by six arguments and the stack/PC, all
/// hex-prefixed except the number itself. A running task is the literal string
/// `running`; a task the kernel will not describe is `-1` or empty.
pub fn parse_syscall_line(raw: &str) -> SyscallStop {
    let line = raw.trim();
    if line.is_empty() {
        return SyscallStop::Unavailable;
    }
    if line.starts_with("running") {
        return SyscallStop::Running;
    }
    let mut fields = line.split_whitespace();
    let Some(number) = fields.next().and_then(|n| n.parse::<i64>().ok()) else {
        return SyscallStop::Unavailable;
    };
    // `-1` is the kernel's "I am not going to tell you" for a task it cannot
    // describe. Treating it as a syscall number would be inventing a fact.
    if number < 0 {
        return SyscallStop::Unavailable;
    }
    let arg0 = fields
        .next()
        .and_then(|a| i64::from_str_radix(a.trim_start_matches("0x"), 16).ok());
    match arg0 {
        Some(arg0) => SyscallStop::Blocked { number, arg0 },
        None => SyscallStop::Unavailable,
    }
}

#[cfg(target_os = "linux")]
pub fn probe_pty_input_state(master_fd: std::os::fd::RawFd) -> InputState {
    // SAFETY: tcgetpgrp only reads terminal state for the given fd. A negative
    // return means the fd is not a terminal or has no foreground group, which
    // is a legitimate "cannot tell", not a fault to propagate.
    let pgrp = unsafe { libc::tcgetpgrp(master_fd) };
    if pgrp <= 0 {
        return InputState::Unknown;
    }
    probe_process_group(pgrp)
}

// `std::os::fd::RawFd` does not exist on Windows, and this crate is compiled on
// every host. Take the underlying `i32` (which is exactly what RawFd is on
// unix) so the stub has no unix-only path in its signature. Caught by
// ./build.sh --check on Windows after the Linux build had been green for two
// cycles -- a reminder that "it compiles in WSL" is not "it compiles".
#[cfg(not(target_os = "linux"))]
pub fn probe_pty_input_state(_master_fd: i32) -> InputState {
    // The crate builds on every host; the guest it describes is always Linux.
    // Returning Unknown rather than #[cfg]-ing the caller keeps one code path.
    InputState::Unknown
}

/// The /proc half, split out so tests can drive it with a known pgid without
/// needing to own a PTY.
///
/// Reads the GROUP LEADER, whose pid equals the process-group id. That is the
/// process a shell puts in the foreground and the one that reads the terminal.
/// A leader that has delegated the terminal to a child is a real limitation and
/// is recorded as such rather than papered over with a /proc scan: enumerating
/// every process every 30s to catch it would cost more than the case is worth,
/// and the wrong answer it can produce is `NotBlocked`, which degrades to
/// today's behaviour rather than to a false wedge report.
#[cfg(target_os = "linux")]
pub fn probe_process_group(pgid: i32) -> InputState {
    let raw = match std::fs::read_to_string(format!("/proc/{pgid}/syscall")) {
        Ok(w) => w,
        // The process exited between the heartbeat and this read, or /proc is
        // not readable here. Either way: not a wedge, and not something to
        // claim.
        Err(_) => return InputState::Unknown,
    };
    match parse_syscall_line(&raw) {
        // On-CPU is a measurement: it is working.
        SyscallStop::Running => InputState::NotBlocked,
        SyscallStop::Unavailable => InputState::Unknown,
        SyscallStop::Blocked { number, arg0 } => {
            // `libc::SYS_read` is resolved per-architecture at compile time —
            // 0 on x86-64 but 63 on aarch64, and this guest runs on both.
            // Hardcoding 0 would have made the probe silently useless on ARM,
            // in the NotBlocked direction where nothing would report it.
            if number != libc::SYS_read {
                return InputState::NotBlocked;
            }
            if arg0 < 0 {
                return InputState::Unknown;
            }
            match std::fs::read_link(format!("/proc/{pgid}/fd/{arg0}")) {
                Ok(target) => {
                    if is_pty_path(&target.to_string_lossy()) {
                        InputState::BlockedOnInput
                    } else {
                        // Blocked reading something that is not a terminal — a
                        // socket, a pipe, a file. Real work, and emphatically
                        // not something the host can unblock by typing.
                        InputState::NotBlocked
                    }
                }
                Err(_) => InputState::Unknown,
            }
        }
    }
}

/// Is this `/proc/<pid>/fd/<n>` link target a pseudo-terminal?
///
/// Pure and public so the path shapes are pinned by test rather than trusted.
pub fn is_pty_path(target: &str) -> bool {
    target.starts_with("/dev/pts/") || target == "/dev/tty" || target == "/dev/console"
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `/proc/<pid>/syscall` parse table. Pure, so it runs on every host
    /// including the Windows one this was written on.
    ///
    /// The first case is the string MEASURED from a real `cat` blocked on a
    /// PTY, not one composed to match the parser.
    #[test]
    fn syscall_line_parsing_covers_the_kernel_shapes() {
        assert_eq!(
            parse_syscall_line(
                "0 0x0 0x70d19807c000 0x40000 0x0 0x0 0x0 0x7ffe6f0a2340 0x70d19812f54e"
            ),
            SyscallStop::Blocked { number: 0, arg0: 0 },
        );
        // A read on a higher descriptor — the fd is what decides the verdict,
        // so it must survive parsing.
        assert_eq!(
            parse_syscall_line("0 0x7 0xdead 0x0 0x0 0x0 0x0 0x0 0x0"),
            SyscallStop::Blocked { number: 0, arg0: 7 },
        );
        // On-CPU. A measurement, not a failure to measure.
        assert_eq!(parse_syscall_line("running"), SyscallStop::Running);
        // The kernel declining to describe the task.
        assert_eq!(parse_syscall_line("-1 0x0 0x0"), SyscallStop::Unavailable);
        assert_eq!(parse_syscall_line(""), SyscallStop::Unavailable);
        assert_eq!(parse_syscall_line("garbage"), SyscallStop::Unavailable);
    }

    /// Which descriptor targets count as a terminal. A pipe or a socket must
    /// NOT: blocked reading those is real work the host cannot unblock by
    /// typing, and calling it a wedge would be a confident false report.
    #[test]
    fn only_terminals_count_as_terminals() {
        assert!(is_pty_path("/dev/pts/3"));
        assert!(is_pty_path("/dev/pts/0"));
        assert!(is_pty_path("/dev/tty"));

        assert!(!is_pty_path("pipe:[12345]"));
        assert!(!is_pty_path("socket:[67890]"));
        assert!(!is_pty_path("/dev/null"));
        assert!(!is_pty_path("/home/user/some-file"));
        assert!(!is_pty_path("anon_inode:[eventpoll]"));
    }

    /// Against REAL processes, because the classification table above is only
    /// as good as its assumption about what the kernel actually writes.
    #[cfg(target_os = "linux")]
    #[test]
    fn real_processes_report_the_expected_states() {
        use std::process::{Command, Stdio};
        use std::time::Duration;

        // A sleeper: alive, silent for far longer than the 30s heartbeat
        // interval, and NOT blocked on input. This is the legitimate
        // slow-command case order 332 protects.
        let mut sleeper = Command::new("sleep")
            .arg("30")
            .stdin(Stdio::null())
            .spawn()
            .expect("spawn sleep");
        std::thread::sleep(Duration::from_millis(300));
        let verdict = probe_process_group(sleeper.id() as i32);
        let _ = sleeper.kill();
        let _ = sleeper.wait();
        assert_ne!(
            verdict,
            InputState::BlockedOnInput,
            "a sleeping process must never be reported as waiting for input"
        );

        // An exited process: /proc entry gone. Unknown, never blocked —
        // reporting a dead process as a wedge would be worse than saying
        // nothing.
        let mut gone = Command::new("true").spawn().expect("spawn true");
        let _ = gone.wait();
        let pid = gone.id() as i32;
        assert_ne!(
            probe_process_group(pid),
            InputState::BlockedOnInput,
            "an exited process must never be reported as waiting for input"
        );
    }

    /// THE POSITIVE CASE, and the one the rung is actually for. Everything
    /// above asserts that something is NOT blocked, which a probe hard-wired to
    /// return `NotBlocked` would satisfy completely while being useless.
    ///
    /// Drives a real process reading a real PTY, which is the exact shape of
    /// the wedge that filed 689-y2my: a guest sitting at a prompt the host will
    /// never answer.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_process_reading_a_real_pty_reports_blocked_on_input() {
        use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};
        use std::process::{Command, Stdio};
        use std::time::{Duration, Instant};

        let pty = nix::pty::openpty(None, None).expect("openpty");
        let master: OwnedFd = pty.master;
        let slave: OwnedFd = pty.slave;

        // `cat` with the PTY slave as stdin blocks in the tty line discipline
        // until something is written to the master. stdout goes to the slave
        // too so nothing leaks into the test output.
        let slave_in = slave.try_clone().expect("dup slave for stdin");
        let slave_out = slave.try_clone().expect("dup slave for stdout");
        let mut child = Command::new("cat")
            .stdin(unsafe { Stdio::from_raw_fd(slave_in.into_raw_fd()) })
            .stdout(unsafe { Stdio::from_raw_fd(slave_out.into_raw_fd()) })
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn cat on a pty");

        // Poll rather than sleep a fixed amount: the child needs to reach its
        // read, and a flat sleep would either be flaky or slow.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut verdict = InputState::Unknown;
        let mut raw = String::new();
        while Instant::now() < deadline {
            raw = std::fs::read_to_string(format!("/proc/{}/syscall", child.id()))
                .unwrap_or_else(|e| format!("<unreadable: {e}>"));
            verdict = probe_process_group(child.id() as i32);
            if verdict == InputState::BlockedOnInput {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        let _ = child.kill();
        let _ = child.wait();
        drop(master);
        drop(slave);

        assert_eq!(
            verdict,
            InputState::BlockedOnInput,
            "a process blocked reading a PTY is the signal this probe exists to \
             produce; without this case the probe could be hard-wired to \
             NotBlocked and every other test would still pass. raw syscall line was: {raw:?}"
        );
    }
}
