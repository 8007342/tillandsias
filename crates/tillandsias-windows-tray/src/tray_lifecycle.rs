//! ORDER 783-eeii. The host tray's own lifecycle record: start, heartbeat,
//! and the exit route it took — so the next death leaves a trace instead of
//! only an absent process.
//!
//! WHY A RECORD AND NOT ONLY A LOG LINE. Two tray deaths on yolanda on
//! 2026-08-16 were found only because a human noticed a missing icon. The
//! Event Log search for the closing event (queries quoted there) split them:
//!
//! - death 2 WAS logged — `tray menu click {menu_id=quit, action=Quit}` at
//!   14:04:46 local, then `VM drained on Quit (wsl --terminate)`, which is
//!   exactly what took the guest and the enclave down. Nobody had looked.
//! - death 1 left NOTHING: the 04:52:19 instance's last event is 04:52:46 and
//!   the next is a manual start at 13:27:33. No panic, no Quit, no error, no
//!   WER report, no power or shutdown event. That is the signature of an
//!   EXTERNAL termination — `TerminateProcess`, or a job object reaping the
//!   process tree that launched it — which no code inside the process can
//!   observe, by construction.
//!
//! So logging every exit route the tray CAN observe is necessary and not
//! sufficient. The unobservable route is detected from the outside: a record
//! that says "started, alive at T" and never says "exited" IS the evidence of
//! an unrecorded death, and the heartbeat bounds when it happened. The next
//! tray start reports it (WARN, relayed to the Event Log), and `--diagnose`
//! and `--forge` read it with no human looking for an icon.
//!
//! Pure and NOT cfg-gated: the parse, the render, and the verdict are what
//! need pinning, and keeping them free of Win32 means every host runs them.
//! The Windows wiring (file IO, the singleton probe, the call sites) lives in
//! notify_icon.rs and main.rs.
//!
//! @trace order:783-eeii, spec:windows-native-tray, spec:windows-event-logging

// The portable half is exercised by tests everywhere; on a non-Windows build
// nothing outside the tests calls it.
#![cfg_attr(not(target_os = "windows"), allow(dead_code))]

/// First line of the record. A file without it is unreadable, never a guess.
pub const HEADER: &str = "tillandsias-tray-lifecycle v1";

/// How often the running tray rewrites `heartbeat_unix`.
pub const HEARTBEAT_INTERVAL_SECS: u64 = 60;

/// A heartbeat older than this on a tray that still holds the singleton means
/// the message loop has stopped turning: alive, but not doing its job.
pub const HEARTBEAT_STALE_SECS: u64 = 3 * HEARTBEAT_INTERVAL_SECS;

/// Every exit route the tray process can observe from the inside. An external
/// kill has no variant on purpose: it is what the ABSENCE of an exit line
/// means.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitReason {
    /// The Quit menu item (which drains the VM: the guest and enclave stop).
    QuitMenu,
    /// `WM_ENDSESSION` — the user logged off or Windows is shutting down.
    SessionEnd,
    /// `GetMessageW` returned -1; the message loop could not continue.
    MessageLoopError,
    /// A panic reached the hook in main.rs.
    Panic,
    /// `run()` returned before the message loop (window or icon creation).
    StartupFailure,
    /// The loop saw `WM_QUIT` with no more specific reason recorded first.
    MessageLoopEnded,
}

impl ExitReason {
    pub const ALL: [ExitReason; 6] = [
        ExitReason::QuitMenu,
        ExitReason::SessionEnd,
        ExitReason::MessageLoopError,
        ExitReason::Panic,
        ExitReason::StartupFailure,
        ExitReason::MessageLoopEnded,
    ];

    pub fn slug(self) -> &'static str {
        match self {
            ExitReason::QuitMenu => "quit-menu",
            ExitReason::SessionEnd => "session-end",
            ExitReason::MessageLoopError => "message-loop-error",
            ExitReason::Panic => "panic",
            ExitReason::StartupFailure => "startup-failure",
            ExitReason::MessageLoopEnded => "message-loop-ended",
        }
    }

    pub fn from_slug(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.slug() == s)
    }

    /// What a reader should conclude, in one clause.
    pub fn meaning(self) -> &'static str {
        match self {
            ExitReason::QuitMenu => {
                "Quit was chosen from the tray menu (the VM was drained with it)"
            }
            ExitReason::SessionEnd => "Windows ended the session (log-off or shutdown)",
            ExitReason::MessageLoopError => "the Win32 message loop failed",
            ExitReason::Panic => "the tray panicked (see tray.log / Event Log)",
            ExitReason::StartupFailure => "the tray failed during startup",
            ExitReason::MessageLoopEnded => "the message loop ended (WM_QUIT)",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub pid: u32,
    pub version: String,
    pub started_unix: u64,
    pub heartbeat_unix: u64,
    pub exit: Option<(ExitReason, u64)>,
}

impl Record {
    pub fn started(pid: u32, version: &str, now_unix: u64) -> Self {
        Self {
            pid,
            version: version.to_string(),
            started_unix: now_unix,
            heartbeat_unix: now_unix,
            exit: None,
        }
    }

    pub fn render(&self) -> String {
        let mut out = format!(
            "{HEADER}\npid {}\nversion {}\nstarted_unix {}\nheartbeat_unix {}\n",
            self.pid,
            self.version.replace(char::is_whitespace, "_"),
            self.started_unix,
            self.heartbeat_unix
        );
        if let Some((reason, at)) = self.exit {
            out.push_str(&format!("exit {} {at}\n", reason.slug()));
        }
        out
    }

    /// Strict: a missing header or field is an error naming it, because a
    /// half-read record would turn "unknown" into a confident verdict.
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut lines = text.lines();
        if lines.next().map(str::trim) != Some(HEADER) {
            return Err(format!("missing header {HEADER:?}"));
        }
        let (mut pid, mut version, mut started, mut heartbeat, mut exit) =
            (None, None, None, None, None);
        for line in lines {
            let mut parts = line.split_whitespace();
            match (parts.next(), parts.next(), parts.next()) {
                (Some("pid"), Some(v), None) => pid = v.parse::<u32>().ok(),
                (Some("version"), Some(v), None) => version = Some(v.to_string()),
                (Some("started_unix"), Some(v), None) => started = v.parse::<u64>().ok(),
                (Some("heartbeat_unix"), Some(v), None) => heartbeat = v.parse::<u64>().ok(),
                (Some("exit"), Some(r), Some(at)) => {
                    let reason = ExitReason::from_slug(r)
                        .ok_or_else(|| format!("unknown exit reason {r:?}"))?;
                    let at = at
                        .parse::<u64>()
                        .map_err(|_| format!("bad exit time {at:?}"))?;
                    exit = Some((reason, at));
                }
                (None, _, _) => {}
                _ => return Err(format!("unrecognised line {line:?}")),
            }
        }
        Ok(Self {
            pid: pid.ok_or("missing or bad pid")?,
            version: version.ok_or("missing version")?,
            started_unix: started.ok_or("missing or bad started_unix")?,
            heartbeat_unix: heartbeat.ok_or("missing or bad heartbeat_unix")?,
            exit,
        })
    }
}

/// The finding a NEW tray start reports about the instance before it, when
/// that instance never wrote an exit line. `None` when it exited on a route
/// it recorded (that is logged at INFO by the caller, not warned about).
pub fn previous_instance_finding(prev: &Record) -> Option<String> {
    if prev.exit.is_some() {
        return None;
    }
    Some(format!(
        "previous tray instance (pid {}, {}, started {}) ended WITHOUT recording an exit; \
         last heartbeat {} — it died between then and {} at the latest. No exit route the \
         tray can observe fired, so it was terminated from outside (TerminateProcess, a \
         job object reaping the process tree that launched it, or power loss) or crashed \
         below the panic hook",
        prev.pid,
        prev.version,
        format_unix_utc(prev.started_unix),
        format_unix_utc(prev.heartbeat_unix),
        format_unix_utc(prev.heartbeat_unix + HEARTBEAT_INTERVAL_SECS),
    ))
}

/// Whether some tray process holds the `tray-windows` singleton right now.
/// Version-independent: a tray built before this record existed holds it too.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Holder {
    Held,
    Free,
    Unknown(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayVerdict {
    /// `Some(false)` only when the singleton is FREE: that, and nothing
    /// weaker, is what a launcher may refuse on.
    pub running: Option<bool>,
    pub line: String,
}

/// The `Tray process:` line. The singleton decides RUNNING; the record only
/// explains, so a missing or foreign record never manufactures a death.
pub fn verdict(holder: &Holder, record: &Result<Option<Record>, String>, now: u64) -> TrayVerdict {
    let ago = |t: u64| format_age(now.saturating_sub(t));
    match holder {
        Holder::Held => {
            let line = match record {
                Ok(Some(r)) if r.exit.is_none() => {
                    let age = now.saturating_sub(r.heartbeat_unix);
                    if age > HEARTBEAT_STALE_SECS {
                        format!(
                            "Tray process: running (pid {}, {}) but its heartbeat is STALE — last \
                             {} ({} ago, expected every {HEARTBEAT_INTERVAL_SECS}s): the message \
                             loop is not turning",
                            r.pid,
                            r.version,
                            format_unix_utc(r.heartbeat_unix),
                            ago(r.heartbeat_unix)
                        )
                    } else {
                        format!(
                            "Tray process: running (pid {}, {}, started {}, heartbeat {} ago)",
                            r.pid,
                            r.version,
                            format_unix_utc(r.started_unix),
                            ago(r.heartbeat_unix)
                        )
                    }
                }
                _ => "Tray process: running (holds the singleton; no current lifecycle record — \
                      a tray built before 783-eeii, or one started with \
                      TILLANDSIAS_NO_SINGLETON)"
                    .to_string(),
            };
            TrayVerdict {
                running: Some(true),
                line,
            }
        }
        Holder::Free => {
            let why = match record {
                Ok(Some(r)) => match r.exit {
                    Some((reason, at)) => format!(
                        "last instance pid {} ({}) exited {} ago at {}: {} [{}]",
                        r.pid,
                        r.version,
                        ago(at),
                        format_unix_utc(at),
                        reason.meaning(),
                        reason.slug()
                    ),
                    None => format!(
                        "last instance pid {} ({}) died WITHOUT recording an exit — last \
                         heartbeat {} ({} ago); terminated from outside or crashed below the \
                         panic hook",
                        r.pid,
                        r.version,
                        format_unix_utc(r.heartbeat_unix),
                        ago(r.heartbeat_unix)
                    ),
                },
                Ok(None) => "no lifecycle record (never started since 783-eeii)".to_string(),
                Err(e) => format!("lifecycle record unreadable: {e}"),
            };
            TrayVerdict {
                running: Some(false),
                line: format!(
                    "Tray process: NOT RUNNING — {why}. Without the tray the guest has no VM pin \
                     and idles out; start tillandsias-tray.exe"
                ),
            }
        }
        Holder::Unknown(e) => TrayVerdict {
            running: None,
            line: format!("Tray process: UNKNOWN — the singleton could not be probed: {e}"),
        },
    }
}

/// `secs` as a coarse human age. Coarse deliberately: the question is "minutes
/// or days", and a precise figure invites reading the number as freshness.
pub fn format_age(secs: u64) -> String {
    match secs {
        s if s < 90 => format!("{s}s"),
        s if s < 5400 => format!("{}m", s / 60),
        s if s < 172_800 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

/// Unix seconds as `YYYY-MM-DDTHH:MM:SSZ` without adding a date dependency.
pub fn format_unix_utc(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let tod = secs % 86_400;
    let (mut y, mut d) = (1970i64, days);
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let len = if leap { 366 } else { 365 };
        if d < len {
            break;
        }
        d -= len;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let ml = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut m = 0usize;
    while m < 12 && d >= ml[m] {
        d -= ml[m];
        m += 1;
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m + 1,
        d + 1,
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-08-16T11:52:19Z — death 1's last start, 04:52:19 local (UTC-7).
    const START: u64 = 1_786_881_139;

    fn rec(exit: Option<(ExitReason, u64)>) -> Record {
        Record {
            pid: 8768,
            version: "56.9.2.1".into(),
            started_unix: START,
            heartbeat_unix: START + 600,
            exit,
        }
    }

    #[test]
    fn record_round_trips_with_and_without_an_exit_line() {
        for r in [rec(None), rec(Some((ExitReason::QuitMenu, START + 700)))] {
            assert_eq!(Record::parse(&r.render()), Ok(r.clone()), "{}", r.render());
        }
        for reason in ExitReason::ALL {
            assert_eq!(ExitReason::from_slug(reason.slug()), Some(reason));
        }
    }

    #[test]
    fn a_damaged_record_is_an_error_not_a_guess() {
        assert!(Record::parse("").is_err());
        assert!(Record::parse("pid 1\n").is_err(), "no header");
        let no_heartbeat = format!("{HEADER}\npid 1\nversion v\nstarted_unix 5\n");
        assert!(
            Record::parse(&no_heartbeat)
                .unwrap_err()
                .contains("heartbeat")
        );
        let bad_reason = format!("{}exit vanished 9\n", rec(None).render());
        assert!(Record::parse(&bad_reason).unwrap_err().contains("vanished"));
    }

    /// The 783-eeii guard: an instance that never wrote an exit line is
    /// REPORTED by its successor, with the heartbeat window that bounds when it
    /// died; one that recorded its route is not warned about.
    #[test]
    fn a_previous_instance_without_an_exit_line_is_reported_with_its_death_window() {
        let finding =
            previous_instance_finding(&rec(None)).expect("unrecorded death must be reported");
        assert!(finding.contains("pid 8768"), "{finding}");
        assert!(finding.contains("WITHOUT recording an exit"), "{finding}");
        assert!(finding.contains(&format_unix_utc(START + 600)), "{finding}");
        assert!(finding.contains(&format_unix_utc(START + 660)), "{finding}");
        assert_eq!(
            previous_instance_finding(&rec(Some((ExitReason::Panic, START + 1)))),
            None
        );
    }

    #[test]
    fn a_free_singleton_reads_not_running_and_names_how_the_last_tray_ended() {
        let now = START + 9 * 3600;
        let quit = verdict(
            &Holder::Free,
            &Ok(Some(rec(Some((ExitReason::QuitMenu, START + 700))))),
            now,
        );
        assert_eq!(quit.running, Some(false));
        assert!(
            quit.line.starts_with("Tray process: NOT RUNNING"),
            "{}",
            quit.line
        );
        assert!(quit.line.contains("[quit-menu]"), "{}", quit.line);

        let silent = verdict(&Holder::Free, &Ok(Some(rec(None))), now);
        assert_eq!(silent.running, Some(false));
        assert!(
            silent.line.contains("died WITHOUT recording an exit"),
            "{}",
            silent.line
        );

        for record in [Ok(None), Err("missing header".to_string())] {
            let v = verdict(&Holder::Free, &record, now);
            assert_eq!(
                v.running,
                Some(false),
                "a free singleton is decisive: {}",
                v.line
            );
        }
    }

    /// NEGATIVE CONTROL for the refusal in `--forge`: only a FREE singleton may
    /// read as not-running. A held one is running whatever the record says —
    /// even a record claiming an exit (a pre-783-eeii tray holds the lock and
    /// writes no record, leaving the last new tray's exit line on disk) — and
    /// an unprobeable one is unknown, never dead.
    #[test]
    fn a_held_singleton_is_running_whatever_the_record_says() {
        let now = START + 700;
        for record in [
            Ok(None),
            Err("garbage".to_string()),
            Ok(Some(rec(Some((ExitReason::QuitMenu, START + 650))))),
            Ok(Some(rec(None))),
        ] {
            let v = verdict(&Holder::Held, &record, now);
            assert_eq!(v.running, Some(true), "{}", v.line);
            assert!(v.line.starts_with("Tray process: running"), "{}", v.line);
        }
        let u = verdict(&Holder::Unknown("io".into()), &Ok(Some(rec(None))), now);
        assert_eq!(u.running, None, "{}", u.line);
    }

    #[test]
    fn a_held_singleton_with_a_stale_heartbeat_says_the_loop_is_not_turning() {
        let fresh = verdict(&Holder::Held, &Ok(Some(rec(None))), START + 600 + 30);
        assert!(!fresh.line.contains("STALE"), "{}", fresh.line);
        let stale = verdict(
            &Holder::Held,
            &Ok(Some(rec(None))),
            START + 600 + HEARTBEAT_STALE_SECS + 1,
        );
        assert_eq!(stale.running, Some(true));
        assert!(stale.line.contains("STALE"), "{}", stale.line);
    }

    #[test]
    fn utc_formatter_matches_known_instants() {
        assert_eq!(format_unix_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_unix_utc(START), "2026-08-16T11:52:19Z");
        assert_eq!(format_age(59), "59s");
        assert_eq!(format_age(9 * 3600), "9h");
    }
}
