//! Real per-image build progress for `tillandsias --init` (order 1420-6brx).
//!
//! THE DEFECT. `build_image_with_logging` used to jump its bar to 50% on any
//! line containing "Pulling", 75% on "Digest:" and 100% on "Commit", which is
//! a fill no event had earned: a twelve-step build read 50% after its first
//! pull and then sat there for minutes.
//!
//! WHAT IT READS NOW. `podman build` prints `STEP n/m: …` and `COMMIT …` on
//! STDOUT (measured on podman 5 with a three-step Containerfile: all four
//! lines on stdout, nothing on stderr), so step `n` of `m` starting means
//! `n - 1` of `m` are finished. That is a Determinate count with a real
//! denominator. `COMMIT` means every step is done; the process exit decides
//! Done or Failed.
//!
//! THE OUTPUT IS TYPED. Each observation is a
//! `tillandsias_control_wire::ProgressEvent` (1420-r2sn), so the renderer
//! (1420-9vpk) and a future guest relay read fields instead of a sentence.
//!
//! @trace order:1420-6brx

use tillandsias_control_wire::{ProgressEvent, ProgressKind, ProgressUnit};

/// One recognised line of `podman build` stdout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildSignal {
    /// `STEP n/m: <instruction>`: step `n` of `m` is starting.
    Step { n: u64, m: u64 },
    /// `COMMIT <name>`: every step finished; the image is being written.
    Commit,
}

/// Parse one stdout line. Anything unrecognised is `None`, never a guess.
pub fn parse_build_line(line: &str) -> Option<BuildSignal> {
    let line = line.trim_start();
    if let Some(rest) = line.strip_prefix("STEP ") {
        let (frac, _) = rest.split_once(':')?;
        let (n, m) = frac.split_once('/')?;
        let n: u64 = n.trim().parse().ok()?;
        let m: u64 = m.trim().parse().ok()?;
        if n == 0 || m == 0 || n > m {
            return None;
        }
        return Some(BuildSignal::Step { n, m });
    }
    if line == "COMMIT" || line.starts_with("COMMIT ") {
        return Some(BuildSignal::Commit);
    }
    None
}

/// Turns one image's build output into a stream of `ProgressEvent`s.
///
/// `observe` returns an event only when something changed, so a caller can
/// print or log every event it gets without flooding.
pub struct ImageBuildProgress {
    image: String,
    done: u64,
    total: Option<u64>,
    now_ms: fn() -> u64,
}

fn wall_clock_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl ImageBuildProgress {
    pub fn new(image: &str) -> Self {
        Self::with_clock(image, wall_clock_ms)
    }

    /// Test seam: a fixed clock so events compare equal.
    pub fn with_clock(image: &str, now_ms: fn() -> u64) -> Self {
        Self {
            image: image.to_string(),
            done: 0,
            total: None,
            now_ms,
        }
    }

    fn event(&self, kind: ProgressKind) -> ProgressEvent {
        ProgressEvent {
            task: format!("init/build/{}", self.image),
            parent: Some("init/build".to_string()),
            label: self.image.clone(),
            kind,
            ts_unix_ms: (self.now_ms)(),
        }
    }

    fn determinate(&self) -> ProgressEvent {
        self.event(ProgressKind::Determinate {
            done: self.done,
            total: self.total,
            unit: ProgressUnit::Steps,
        })
    }

    /// Feed one stdout line; returns the event it produced, if any.
    pub fn observe(&mut self, line: &str) -> Option<ProgressEvent> {
        let before = (self.done, self.total);
        match parse_build_line(line)? {
            BuildSignal::Step { n, m } => {
                // Grow-only: a total that changes (a multi-stage build restarts
                // its count) never moves `done` backwards.
                self.total = Some(self.total.map_or(m, |t| t.max(m)));
                self.done = self.done.max(n - 1);
            }
            BuildSignal::Commit => {
                let total = self.total.unwrap_or(self.done.max(1));
                self.total = Some(total);
                self.done = total;
            }
        }
        // Silent unless the (done, total) pair actually changed.
        ((self.done, self.total) != before).then(|| self.determinate())
    }

    /// The terminal event, from the process exit.
    pub fn finish(&self, result: &Result<(), String>) -> ProgressEvent {
        match result {
            Ok(()) => self.event(ProgressKind::Done),
            Err(reason) => self.event(ProgressKind::Failed {
                reason: reason.clone(),
            }),
        }
    }

    /// Whole-percent completion for the legacy one-line bar, from real counts.
    pub fn percent(&self) -> usize {
        match self.total {
            Some(t) if t > 0 => ((self.done * 100) / t) as usize,
            _ => 0,
        }
    }
}

/// The legacy stdout line, same format as before, now fed by real counts.
/// Its WORDING is unchanged on purpose: changing user-facing text needs the
/// operator's approval under spec:tray-ux, which this row does not carry.
pub fn legacy_bar_line(image: &str, percent: usize) -> String {
    let filled = (percent.min(100)) / 10;
    format!(
        "Pulling image {} [{}{}] {}%",
        image,
        "█".repeat(filled),
        "░".repeat(10 - filled),
        percent.min(100)
    )
}

/// One line for the build log, marking a typed event so a reader (and the
/// closure check) can find every event a build produced.
pub fn event_log_line(event: &ProgressEvent) -> String {
    format!("[progress-event] {}", event.summary_line())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock() -> u64 {
        7
    }

    /// The exact stdout of a real three-step `podman build`, captured on
    /// lenovinha (podman 5, Fedora Silverblue) while writing this module.
    const REAL_STDOUT: &str = "STEP 1/3: FROM scratch\n\
STEP 2/3: COPY a /a\n\
--> 3fda1a136d91\n\
STEP 3/3: COPY a /b\n\
COMMIT localhost/pbtest:1\n\
--> 0bfeb9243772\n\
Successfully tagged localhost/pbtest:1\n\
0bfeb9243772ca04bb640ed203c5f63996d550f7108853837f59054a407710d1\n";

    #[test]
    fn parses_step_and_commit_and_nothing_else() {
        assert_eq!(
            parse_build_line("STEP 2/12: RUN dnf -y install git"),
            Some(BuildSignal::Step { n: 2, m: 12 })
        );
        assert_eq!(
            parse_build_line("COMMIT localhost/x:1"),
            Some(BuildSignal::Commit)
        );
        for noise in [
            "--> 3fda1a136d91",
            "Successfully tagged localhost/x:1",
            "Pulling fs layer",
            "Digest: sha256:abc",
            "STEP x/3: FROM",
            "STEP 4/3: FROM",
            "STEP 0/3: FROM",
            "",
        ] {
            assert_eq!(parse_build_line(noise), None, "{noise:?}");
        }
    }

    /// The closure property: a real build yields Determinate events with
    /// done < total BEFORE the terminal Done, and never jumps to a made-up
    /// 50/75/100.
    #[test]
    fn a_real_build_yields_determinate_events_before_done() {
        let mut p = ImageBuildProgress::with_clock("forge", clock);
        let events: Vec<ProgressEvent> = REAL_STDOUT.lines().filter_map(|l| p.observe(l)).collect();
        let dets: Vec<(u64, Option<u64>)> = events
            .iter()
            .map(|e| match e.kind {
                ProgressKind::Determinate { done, total, .. } => (done, total),
                ref k => panic!("unexpected kind before finish: {k:?}"),
            })
            .collect();
        assert_eq!(
            dets,
            vec![(0, Some(3)), (1, Some(3)), (2, Some(3)), (3, Some(3))]
        );
        assert!(dets.iter().any(|(d, t)| Some(*d) < *t));
        assert_eq!(p.finish(&Ok(())).kind, ProgressKind::Done);
        assert_eq!(p.percent(), 100);
    }

    #[test]
    fn percent_follows_steps_not_keywords() {
        let mut p = ImageBuildProgress::with_clock("forge", clock);
        p.observe("STEP 1/12: FROM registry.fedoraproject.org/fedora:44");
        p.observe("Pulling fs layer");
        assert_eq!(p.percent(), 0, "a pull line must not fake 50%");
        p.observe("STEP 7/12: RUN something");
        assert_eq!(p.percent(), 50);
    }

    #[test]
    fn done_never_decreases_and_duplicates_are_silent() {
        let mut p = ImageBuildProgress::with_clock("forge", clock);
        assert!(p.observe("STEP 3/5: RUN a").is_some());
        assert!(p.observe("STEP 3/5: RUN a").is_none());
        assert!(
            p.observe("STEP 2/5: RUN b").is_none(),
            "a lower step must not move the bar back"
        );
        assert_eq!(p.percent(), 40);
    }

    #[test]
    fn a_failed_build_ends_failed_with_the_reason() {
        let p = ImageBuildProgress::with_clock("forge", clock);
        assert_eq!(
            p.finish(&Err("Build exited with status 1".into())).kind,
            ProgressKind::Failed {
                reason: "Build exited with status 1".into()
            }
        );
    }

    #[test]
    fn legacy_line_keeps_its_format() {
        assert_eq!(
            legacy_bar_line("forge", 40),
            "Pulling image forge [████░░░░░░] 40%"
        );
        assert_eq!(
            legacy_bar_line("forge", 100),
            "Pulling image forge [██████████] 100%"
        );
    }

    #[test]
    fn event_log_lines_are_marked() {
        let p = ImageBuildProgress::with_clock("forge", clock);
        assert_eq!(
            event_log_line(&p.finish(&Ok(()))),
            "[progress-event] forge: done"
        );
    }
}
