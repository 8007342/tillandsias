//! ORDER 1420-ev7i (PRETTY INSTALLER 6/10): the provisioning console for
//! `--provision-once` and `--reset-state`.
//!
//! These verbs used to `println!` one raw `[provision] phase: <emoji> ...` line
//! per phase. On a console that is a wall of text; captured through a pipe by
//! the Windows PowerShell 5.1 installer it is MOJIBAKE, because PowerShell
//! decodes the tray's UTF-8 with the console code page. Measured in the
//! v56.9.27.2 Windows smoke: `[reset-state] phase: dY"<?> Starting Fedora
//! Linux<?>`.
//!
//! Now the phases drive the tillandsia-palette renderer (1420-9vpk): a live
//! coloured bar per phase plus an overall bar on a console that can show it,
//! and plain ASCII lines with no escape bytes everywhere else.
//!
//! PORTABLE ON PURPOSE. The tier decision and the phase-to-task mapping are
//! pure and unit-tested on every host; only enabling virtual-terminal
//! processing on the real console is Win32, in [`enable_vt_on_stderr`].
#![cfg_attr(not(target_os = "windows"), allow(dead_code))]

use std::sync::Mutex;

use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_progress_tty::{EnvView, PlainSink, Sink, TaskState, Tier, TtySink};

/// Every phase, in the order provisioning walks them. All are registered as
/// Pending up front, so the overall bar is phases-done out of six from the
/// first line, and a late phase can never pull it backwards.
pub const PHASES: [ProvisionPhase; 6] = [
    ProvisionPhase::SettingUp,
    ProvisionPhase::DownloadingRootfs,
    ProvisionPhase::DownloadingTillandsias,
    ProvisionPhase::InstallingTillandsias,
    ProvisionPhase::StartingVm,
    ProvisionPhase::Connecting,
];

/// Bar width in cells: fits an 80-column console beside a 25-character label.
const BAR_WIDTH: usize = 30;

/// The longest activity line shown beside a live bar before it is cut.
const ACTIVITY_MAX: usize = 60;

/// How much colour the Windows console may carry.
///
/// `Tier::detect` is the POSIX rule and returns Plain whenever `TERM` is unset,
/// which on Windows is always: neither conhost nor Windows Terminal sets it. The
/// Windows question is instead whether virtual-terminal processing could be
/// turned on for the console stderr is attached to. Plain when stderr is not a
/// console (a pipe, a file: the installer's capture), when `NO_COLOR` or `CI`
/// says so, or when VT could not be enabled (a pre-1511 conhost). Truecolor
/// under Windows Terminal or when `COLORTERM` says so, 256 colours otherwise.
pub fn windows_tier(env: &EnvView, vt_enabled: bool, wt_session: bool) -> Tier {
    if !env.is_tty || env.no_color.is_some() || env.ci.is_some() || !vt_enabled {
        return Tier::Plain;
    }
    if wt_session || matches!(env.colorterm.as_deref(), Some("truecolor") | Some("24bit")) {
        Tier::TrueColor
    } else {
        Tier::Ansi256
    }
}

/// A phase's label: the ASCII status text without its trailing ellipsis. The
/// emoji form stays the tray chip's; a console line must survive a pipe.
pub fn phase_label(phase: ProvisionPhase) -> &'static str {
    phase.status_text_ascii().trim_end_matches("...")
}

/// Whether a line may be written to a plain (non-console) sink as-is. Anything
/// else is transliterated, because the installer decodes our pipe with the
/// console code page and every non-ASCII byte becomes mojibake there.
fn ascii_only(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\u{2014}' | '\u{2013}' => out.push('-'),
            '\u{2026}' => out.push_str("..."),
            '\u{2713}' => out.push('+'),
            '\u{2192}' => out.push('>'),
            c if c.is_ascii() => out.push(c),
            _ => out.push('?'),
        }
    }
    out
}

/// This process's tier: the Windows rule, with VT enabled on the stderr
/// console where that is possible.
pub fn process_tier() -> Tier {
    let env = EnvView::from_process();
    let vt = env.is_tty && enable_vt_on_stderr();
    let wt = std::env::var_os("WT_SESSION").is_some();
    windows_tier(&env, vt, wt)
}

/// A one-off `[prefix] text` line outside the bars (start, wipe and result
/// lines): ASCII-only when the output is plain, untouched on a live console.
pub fn render_line(tier: Tier, prefix: &str, text: &str) -> String {
    let text = format!("[{prefix}] {text}");
    match tier {
        Tier::Plain => ascii_only(&text),
        _ => text,
    }
}

/// [`ProvisionProgress`] over a renderer sink.
pub struct PhaseConsole {
    tier: Tier,
    prefix: &'static str,
    state: Mutex<(Box<dyn Sink + Send>, Option<usize>)>,
}

impl PhaseConsole {
    /// The console for this process, in [`process_tier`]. Create it only when
    /// provisioning starts: on a console its bars draw at once, and a line
    /// printed around live bars tears them.
    pub fn for_process(prefix: &'static str) -> Self {
        let tier = process_tier();
        let sink: Box<dyn Sink + Send> = match tier {
            Tier::Plain => Box::new(PlainSink::new(std::io::stderr())),
            tier => Box::new(TtySink::new(tier, BAR_WIDTH)),
        };
        Self::with_sink(prefix, tier, sink)
    }

    /// Over an explicit sink, for tests.
    pub fn with_sink(prefix: &'static str, tier: Tier, mut sink: Box<dyn Sink + Send>) -> Self {
        for phase in PHASES {
            let _ = sink.update(phase_label(phase), TaskState::Pending);
        }
        PhaseConsole {
            tier,
            prefix,
            state: Mutex::new((sink, None)),
        }
    }

    pub fn tier(&self) -> Tier {
        self.tier
    }

    /// A one-off line outside the bars, in this console's tier.
    pub fn line(&self, text: &str) -> String {
        render_line(self.tier, self.prefix, text)
    }

    /// Provisioning reached Ready: every phase is Done, so the overall bar
    /// reads 100% even when a phase was skipped (an already-downloaded rootfs).
    pub fn finish_ok(&self) {
        let Ok(mut st) = self.state.lock() else {
            return;
        };
        for phase in PHASES {
            let _ = st.0.update(phase_label(phase), TaskState::Done);
        }
        let _ = st.0.finish();
    }

    /// Provisioning failed: the phase it was in reads FAILED with the reason.
    pub fn finish_err(&self, reason: &str) {
        let Ok(mut st) = self.state.lock() else {
            return;
        };
        let label =
            st.1.map(|i| phase_label(PHASES[i]))
                .unwrap_or(phase_label(PHASES[0]));
        let _ = st.0.update(
            label,
            TaskState::Failed {
                reason: ascii_only(reason),
            },
        );
        let _ = st.0.finish();
    }
}

impl ProvisionProgress for PhaseConsole {
    fn report_phase(&self, phase: ProvisionPhase) {
        tracing::info!(?phase, "provision phase");
        let Some(idx) = PHASES.iter().position(|p| *p == phase) else {
            return;
        };
        let Ok(mut st) = self.state.lock() else {
            return;
        };
        if let Some(prev) = st.1
            && prev != idx
        {
            let _ = st.0.update(phase_label(PHASES[prev]), TaskState::Done);
        }
        let _ = st.0.update(
            phase_label(phase),
            TaskState::Indeterminate {
                activity: String::new(),
            },
        );
        st.1 = Some(idx);
    }

    fn report_message(&self, message: &str) {
        tracing::info!(message, "provision message");
        let Ok(mut st) = self.state.lock() else {
            return;
        };
        match self.tier {
            // Plain: the message is its own line, as before, so a captured log
            // keeps every detail (the installer's log shows each dnf step).
            Tier::Plain => {
                eprintln!("{}", ascii_only(&format!("[{}] {message}", self.prefix)));
            }
            // Live: the message is the current phase's activity line.
            _ => {
                if let Some(idx) = st.1 {
                    let activity: String = message.chars().take(ACTIVITY_MAX).collect();
                    let _ = st.0.update(
                        phase_label(PHASES[idx]),
                        TaskState::Indeterminate { activity },
                    );
                }
            }
        }
    }
}

/// Turn on virtual-terminal processing for the console stderr is attached to.
/// True when the console now interprets escape sequences.
#[cfg(target_os = "windows")]
pub fn enable_vt_on_stderr() -> bool {
    use windows::Win32::System::Console::{
        CONSOLE_MODE, ENABLE_VIRTUAL_TERMINAL_PROCESSING, GetConsoleMode, GetStdHandle,
        STD_ERROR_HANDLE, SetConsoleMode,
    };
    // SAFETY: plain Win32 calls on this process's own standard handle; a
    // handle that is not a console makes GetConsoleMode fail, which is the
    // "no" answer.
    unsafe {
        let Ok(handle) = GetStdHandle(STD_ERROR_HANDLE) else {
            return false;
        };
        let mut mode = CONSOLE_MODE(0);
        if GetConsoleMode(handle, &mut mode).is_err() {
            return false;
        }
        if mode.0 & ENABLE_VIRTUAL_TERMINAL_PROCESSING.0 != 0 {
            return true;
        }
        SetConsoleMode(
            handle,
            CONSOLE_MODE(mode.0 | ENABLE_VIRTUAL_TERMINAL_PROCESSING.0),
        )
        .is_ok()
    }
}

#[cfg(not(target_os = "windows"))]
pub fn enable_vt_on_stderr() -> bool {
    false
}

// ---------------------------------------------------------------------------
// ORDER 1439-p853: GUEST progress over the control wire.
// ---------------------------------------------------------------------------

/// The topics the tray's push listener subscribes to, given the guest's
/// `HelloAck.server_caps`: the base three, plus `Progress` ONLY when the guest
/// advertises `progress.push@v1`. Built through the wire crate's
/// `subscription_topics`, the one place the opt-in rule lives. The rule is not
/// optional: the tray's reader loop treats any decode error as "stream dropped,
/// resubscribe", and an older guest fails a whole Subscribe that names a topic
/// it does not know, so asking unconditionally would loop forever against it.
pub fn push_subscribe_topics(
    server_caps: &[String],
) -> Vec<tillandsias_control_wire::SubscriptionTopic> {
    tillandsias_control_wire::subscription_topics(&base_push_topics(), server_caps)
}

/// The tray's base push topics, before any capability opt-in. The single
/// source: notify_icon's `vm_status_subscribe_topics` delegates here.
pub fn base_push_topics() -> Vec<tillandsias_control_wire::SubscriptionTopic> {
    use tillandsias_control_wire::SubscriptionTopic;
    vec![
        SubscriptionTopic::VmStatus,
        SubscriptionTopic::LoginState,
        SubscriptionTopic::CloudProjects,
    ]
}

/// A guest `ProgressKind` as the renderer's `TaskState`. A determinate kind
/// with no known total cannot be a fraction, so it shows as activity ("12.0
/// MB"), never as a bar stuck at 0%.
pub fn task_state_of(kind: &tillandsias_control_wire::ProgressKind) -> TaskState {
    use tillandsias_control_wire::{ProgressKind, ProgressUnit};
    match kind {
        ProgressKind::Determinate {
            done,
            total: Some(total),
            ..
        } => TaskState::Determinate {
            done: *done,
            total: *total,
        },
        ProgressKind::Determinate {
            done,
            total: None,
            unit,
        } => TaskState::Indeterminate {
            activity: match unit {
                ProgressUnit::Bytes => format!("{:.1} MB", *done as f64 / 1_048_576.0),
                ProgressUnit::Items => format!("{done} items"),
                ProgressUnit::Steps => format!("{done} steps"),
            },
        },
        ProgressKind::Indeterminate { activity } => TaskState::Indeterminate {
            activity: ascii_only(activity),
        },
        ProgressKind::Done => TaskState::Done,
        ProgressKind::Failed { reason } => TaskState::Failed {
            reason: ascii_only(reason),
        },
    }
}

/// Guest progress into a renderer sink, keyed by the event's label (the human
/// name; the task id is an internal key). The sink decides the output: the GUI
/// tray has no console, so it gets a PlainSink over tray.log — one ASCII line
/// per task STATE CHANGE, which is the renderer's own throttle (a 500-step
/// build writes a handful of lines, not 500).
pub struct GuestProgress {
    sink: Box<dyn Sink + Send>,
}

impl GuestProgress {
    pub fn with_sink(sink: Box<dyn Sink + Send>) -> Self {
        GuestProgress { sink }
    }

    /// For the GUI tray: a plain sink whose lines go to tray.log.
    pub fn to_tray_log() -> Self {
        Self::with_sink(Box::new(PlainSink::new(TracingLines::default())))
    }

    pub fn observe(&mut self, event: &tillandsias_control_wire::ProgressEvent) {
        let _ = self
            .sink
            .update(&ascii_only(&event.label), task_state_of(&event.kind));
    }
}

/// A `Write` that turns each complete line into one `tracing::info!` record,
/// so a PlainSink can render into tray.log.
#[derive(Default)]
struct TracingLines {
    pending: Vec<u8>,
}

impl std::io::Write for TracingLines {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.pending.extend_from_slice(buf);
        while let Some(nl) = self.pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=nl).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1]).into_owned();
            tracing::info!(target: "guest_progress", "guest progress {text}");
        }
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A PlainSink writing into a buffer the test can read after the console
    /// is done with it.
    #[derive(Clone, Default)]
    struct Shared(Arc<Mutex<Vec<u8>>>);
    impl std::io::Write for Shared {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn tty(no_color: bool) -> EnvView {
        EnvView {
            no_color: no_color.then(String::new),
            ci: None,
            term: None,
            colorterm: None,
            is_tty: true,
        }
    }

    /// The Windows rule: TERM is never set there, so TERM must not decide.
    #[test]
    fn windows_tier_follows_the_console_not_term() {
        assert_eq!(windows_tier(&tty(false), true, false), Tier::Ansi256);
        assert_eq!(windows_tier(&tty(false), true, true), Tier::TrueColor);
        assert_eq!(
            windows_tier(&tty(false), false, true),
            Tier::Plain,
            "VT not enabled"
        );
        assert_eq!(
            windows_tier(&tty(true), true, true),
            Tier::Plain,
            "NO_COLOR"
        );
        let mut piped = tty(false);
        piped.is_tty = false;
        assert_eq!(
            windows_tier(&piped, true, true),
            Tier::Plain,
            "a pipe is plain"
        );
        let mut ci = tty(false);
        ci.ci = Some("1".into());
        assert_eq!(windows_tier(&ci, true, true), Tier::Plain, "CI");
        // The POSIX rule would have said Plain for the first case: that is
        // the defect this function exists for.
        assert_eq!(Tier::detect(&tty(false)), Tier::Plain);
    }

    /// Piped, a full provision emits plain ASCII lines, zero escape bytes, one
    /// per state change, ending at 100%.
    #[test]
    fn piped_provisioning_is_plain_ascii_with_no_escape_bytes() {
        let buf = Shared::default();
        let console = PhaseConsole::with_sink(
            "provision",
            Tier::Plain,
            Box::new(PlainSink::new(buf.clone())),
        );
        for phase in PHASES {
            console.report_phase(phase);
        }
        console.finish_ok();
        let out = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
        assert!(
            !out.contains('\x1b'),
            "an escape byte reached a pipe:\n{out}"
        );
        assert!(out.is_ascii(), "a non-ASCII byte reached a pipe:\n{out}");
        assert!(out.contains("Setting up Fedora Linux: working"), "{out}");
        assert!(out.contains("Connecting: done (overall 100%)"), "{out}");
        assert!(
            !out.lines()
                .any(|l| l.contains("(overall 100%)") && !l.starts_with("Connecting")),
            "100% only once every phase is done:\n{out}"
        );
    }

    /// A skipped phase still ends at 100% on success, and a failure names the
    /// phase it happened in.
    #[test]
    fn success_completes_every_phase_and_failure_names_the_current_one() {
        let ok = Shared::default();
        let c = PhaseConsole::with_sink(
            "provision",
            Tier::Plain,
            Box::new(PlainSink::new(ok.clone())),
        );
        c.report_phase(ProvisionPhase::SettingUp);
        c.report_phase(ProvisionPhase::Connecting);
        c.finish_ok();
        let out = String::from_utf8(ok.0.lock().unwrap().clone()).unwrap();
        assert!(
            out.lines().last().unwrap_or("").ends_with("(overall 100%)"),
            "{out}"
        );

        let bad = Shared::default();
        let c = PhaseConsole::with_sink(
            "provision",
            Tier::Plain,
            Box::new(PlainSink::new(bad.clone())),
        );
        c.report_phase(ProvisionPhase::StartingVm);
        c.finish_err("wsl --import exited 1 \u{2014} disk full");
        let out = String::from_utf8(bad.0.lock().unwrap().clone()).unwrap();
        assert!(
            out.contains("Starting Fedora Linux: FAILED: wsl --import exited 1 - disk full"),
            "{out}"
        );
    }

    /// The start/result lines: ASCII when plain, untouched on a live console.
    #[test]
    fn result_lines_are_ascii_only_when_plain() {
        let plain = PhaseConsole::with_sink(
            "reset-state",
            Tier::Plain,
            Box::new(PlainSink::new(Shared::default())),
        );
        assert_eq!(
            plain.line("RESULT: VM Ready \u{2014} control wire up \u{2713}"),
            "[reset-state] RESULT: VM Ready - control wire up +"
        );
        let live = PhaseConsole::with_sink(
            "reset-state",
            Tier::Ansi256,
            Box::new(PlainSink::new(Shared::default())),
        );
        assert_eq!(
            live.line("RESULT: VM Ready \u{2014} control wire up \u{2713}"),
            "[reset-state] RESULT: VM Ready \u{2014} control wire up \u{2713}"
        );
    }

    #[test]
    fn phase_labels_are_ascii_and_have_no_ellipsis() {
        for phase in PHASES {
            let l = phase_label(phase);
            assert!(l.is_ascii() && !l.ends_with('.'), "{l:?}");
        }
    }

    /// 1439-p853: against a guest WITHOUT progress.push@v1 the Subscribe is
    /// byte-identical to the pre-change one; with it, Progress is appended.
    #[test]
    fn progress_topic_is_opt_in_and_the_old_subscribe_is_byte_identical() {
        use tillandsias_control_wire::{
            CAP_PROGRESS_PUSH_V1, ControlEnvelope, ControlMessage, SubscriptionTopic, WIRE_VERSION,
            encode,
        };
        let sub = |topics| {
            encode(&ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 7,
                body: ControlMessage::Subscribe { topics },
            })
            .expect("encode")
        };
        // Spelled out, not base_push_topics(): this is the pre-change list the
        // old-guest Subscribe must still equal byte for byte.
        let before = vec![
            SubscriptionTopic::VmStatus,
            SubscriptionTopic::LoginState,
            SubscriptionTopic::CloudProjects,
        ];
        assert_eq!(base_push_topics(), before);
        let old_guest = push_subscribe_topics(&["exec.argv@v1".to_string()]);
        assert_eq!(
            sub(old_guest),
            sub(before.clone()),
            "an old guest's Subscribe changed"
        );
        let new_guest = push_subscribe_topics(&[CAP_PROGRESS_PUSH_V1.to_string()]);
        assert_eq!(new_guest.last(), Some(&SubscriptionTopic::Progress));
        assert_eq!(&new_guest[..3], &before[..]);
    }

    /// 1439-p853: guest events render through the 9vpk PlainSink as ASCII
    /// lines, one per state change, and an unknown total is activity, not 0%.
    #[test]
    fn guest_progress_renders_plain_ascii_per_state_change() {
        use tillandsias_control_wire::{ProgressEvent, ProgressKind, ProgressUnit};
        let buf = Shared::default();
        let mut gp = GuestProgress::with_sink(Box::new(PlainSink::new(buf.clone())));
        let ev = |kind| ProgressEvent {
            task: "image/forge".into(),
            parent: None,
            label: "Build forge image \u{2014} layers".into(),
            kind,
            ts_unix_ms: 0,
        };
        for done in 0..=100 {
            gp.observe(&ev(ProgressKind::Determinate {
                done,
                total: Some(100),
                unit: ProgressUnit::Steps,
            }));
        }
        gp.observe(&ev(ProgressKind::Done));
        let out = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
        assert!(out.is_ascii() && !out.contains('\x1b'), "{out}");
        assert_eq!(out.lines().count(), 2, "one line per state change:\n{out}");
        assert!(
            out.contains("Build forge image - layers: in progress"),
            "{out}"
        );
        assert!(
            out.contains("Build forge image - layers: done (overall 100%)"),
            "{out}"
        );

        assert_eq!(
            task_state_of(&ProgressKind::Determinate {
                done: 12 * 1_048_576,
                total: None,
                unit: ProgressUnit::Bytes,
            }),
            TaskState::Indeterminate {
                activity: "12.0 MB".into()
            }
        );
    }
}
