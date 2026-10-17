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
    /// The step podman last announced: `n`, `m` and its instruction text
    /// (order 1771-4iw3, so the bar can say which step it is on).
    step: Option<(u64, u64, String)>,
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
            step: None,
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
                let instruction = line
                    .trim_start()
                    .split_once(':')
                    .map_or("", |(_, rest)| rest.trim());
                self.step = Some((n, m, instruction.to_string()));
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

    /// The step podman last announced, as `(n, m, what it does)`.
    pub fn current_step(&self) -> Option<(u64, u64, &'static str)> {
        self.step
            .as_ref()
            .map(|(n, m, instruction)| (*n, *m, step_label(instruction)))
    }

    /// Whole-percent completion for the one-line bar, from real counts.
    pub fn percent(&self) -> usize {
        match self.total {
            Some(t) if t > 0 => ((self.done * 100) / t) as usize,
            _ => 0,
        }
    }
}

/// What a build step does, in words, from podman's instruction text. The
/// first recognised tool in the instruction wins, so a RUN that installs
/// Python tools and then Node tools reads as the Python step it starts with.
pub fn step_label(instruction: &str) -> &'static str {
    let keyword = instruction
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_ascii_uppercase();
    match keyword.as_str() {
        "FROM" => return "fetching the base image",
        "COPY" | "ADD" => return "copying files",
        "ENV" | "ARG" | "LABEL" | "WORKDIR" | "USER" | "EXPOSE" | "ENTRYPOINT" | "CMD"
        | "VOLUME" | "SHELL" | "STOPSIGNAL" | "HEALTHCHECK" => return "configuring the image",
        _ => {}
    }
    const TOOLS: &[(&str, &str)] = &[
        ("pip3 install", "installing Python tools"),
        ("pip install", "installing Python tools"),
        ("npm install", "installing Node tools"),
        ("cargo install", "installing Rust tools"),
        ("rustup", "installing the Rust toolchain"),
        ("microdnf install", "installing system packages"),
        ("dnf install", "installing system packages"),
        ("apk add", "installing system packages"),
        ("apt-get install", "installing system packages"),
        ("curl ", "downloading"),
        ("git clone", "downloading"),
    ];
    TOOLS
        .iter()
        .filter_map(|(needle, label)| instruction.find(needle).map(|at| (at, *label)))
        .min_by_key(|(at, _)| *at)
        .map_or("running a build step", |(_, label)| label)
}

/// The stdout line for one image's build, fed by real counts.
///
/// WORDING APPROVED by the operator, 2026-10-17 (order 1771-4iw3), under
/// spec:tray-ux. It used to read "Pulling image forge-base [████░░░░░░] 40%"
/// for a BUILD, and it held that frozen line through a 10-30 min pip stall
/// without saying which step was running. It now names the step.
pub fn bar_line(image: &str, percent: usize, step: Option<(u64, u64, &str)>) -> String {
    let percent = percent.min(100);
    let filled = percent / 10;
    let bar = format!(
        "[{}{}] {}%",
        "█".repeat(filled),
        "░".repeat(10 - filled),
        percent
    );
    match step {
        Some((n, m, what)) if percent < 100 => {
            format!("Building {image}, step {n}/{m}: {what} {bar}")
        }
        _ => format!("Building {image} {bar}"),
    }
}

/// Where a running on-demand build of `image` is, from its helper log
/// (order 1776-pr0g): `(n, m, what the step does)`.
///
/// The helper log is append-only across runs, so only the lines after this
/// run's `[tillandsias] building image <image> (` announcement count. Both
/// shapes a log can carry are read: podman's own `STEP n/m: <instruction>`
/// (with `--debug`, or in a `--init` log) and the bar line the build prints,
/// `Building <image>, step n/m: <what> [...]`. A finished build (`COMMIT`, or
/// the step-less 100% bar) is `None`: nothing is running.
pub fn progress_in_log(image: &str, log: &str) -> Option<(u64, u64, String)> {
    let announce = format!("[tillandsias] building image {image} (");
    let run = &log[log.rfind(&announce)?..];
    let bar_prefix = format!("Building {image}, step ");
    let done_prefix = format!("Building {image} [");
    for line in run.lines().rev() {
        let line = line.trim_start();
        if line.starts_with(&done_prefix) {
            return None;
        }
        if let Some(rest) = line.strip_prefix(&bar_prefix) {
            let (frac, rest) = rest.split_once(": ")?;
            let (n, m) = frac.split_once('/')?;
            let what = rest.rsplit_once(" [").map_or(rest, |(w, _)| w);
            return Some((n.parse().ok()?, m.parse().ok()?, what.to_string()));
        }
        match parse_build_line(line.rsplit_once("] ").map_or(line, |(_, l)| l)) {
            Some(BuildSignal::Commit) => return None,
            Some(BuildSignal::Step { n, m }) => {
                let instruction = line.split_once(": ").map_or("", |(_, i)| i);
                return Some((n, m, step_label(instruction).to_string()));
            }
            None => {}
        }
    }
    None
}

/// [`progress_in_log`] over `image`'s helper log on this host.
pub(crate) fn image_build_progress(image: &str) -> Option<(u64, u64, String)> {
    let text = std::fs::read_to_string(crate::image_build_helper_log_path(image)).ok()?;
    progress_in_log(image, &text)
}

/// The tray's status while an on-demand build runs, in the step wording the
/// operator approved for the `--init` bar (1771-4iw3), without the bar.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub fn building_status(image: &str, step: Option<(u64, u64, &str)>) -> String {
    match step {
        Some((n, m, what)) => format!("Building {image}, step {n}/{m}: {what}"),
        None => format!("Building {image}"),
    }
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

    /// Order 1771-4iw3 (wording approved by the operator, 2026-10-17): the
    /// bar names the image as BUILT and the step it is on.
    #[test]
    fn bar_line_names_the_step() {
        assert_eq!(
            bar_line("forge-base", 40, Some((5, 12, "installing Python tools"))),
            "Building forge-base, step 5/12: installing Python tools [████░░░░░░] 40%"
        );
        assert_eq!(
            bar_line("forge", 100, Some((12, 12, "copying files"))),
            "Building forge [██████████] 100%"
        );
        assert_eq!(bar_line("forge", 0, None), "Building forge [░░░░░░░░░░] 0%");
    }

    #[test]
    fn step_label_reads_what_the_step_does() {
        let mut p = ImageBuildProgress::with_clock("forge-base", clock);
        p.observe("STEP 5/12: RUN rc=0;     timeout \"${PIP_STALL_BUDGET_S}\" pip3 install --timeout 30 pyright     && npm install -g typescript");
        assert_eq!(p.current_step(), Some((5, 12, "installing Python tools")));
        for (instruction, label) in [
            (
                "FROM registry.fedoraproject.org/fedora-minimal:44",
                "fetching the base image",
            ),
            ("COPY entrypoint.sh /usr/local/bin/", "copying files"),
            ("ENV CARGO_HOME=/usr/local/cargo", "configuring the image"),
            ("RUN microdnf install -y git", "installing system packages"),
            ("RUN npm install -g prettier", "installing Node tools"),
            ("RUN chmod +x /usr/local/bin/x", "running a build step"),
        ] {
            assert_eq!(step_label(instruction), label, "{instruction}");
        }
    }

    #[test]
    fn event_log_lines_are_marked() {
        let p = ImageBuildProgress::with_clock("forge", clock);
        assert_eq!(
            event_log_line(&p.finish(&Ok(()))),
            "[progress-event] forge: done"
        );
    }

    /// 1776-pr0g: any image's helper log yields its step, in both shapes,
    /// and only this run's lines count.
    #[test]
    fn image_build_progress_reads_any_image() {
        let log = "\
[tillandsias] building image chromium-framework (localhost/x:v1, digest_missing); this may take several minutes
STEP 7/7: COPY . .
COMMIT localhost/x
[tillandsias] building image chromium-framework (localhost/x:v1, label_mismatch); this may take several minutes
STEP 2/9: FROM localhost/tillandsias-chromium-core:v1
STEP 3/9: RUN microdnf install -y fonts
";
        assert_eq!(
            progress_in_log("chromium-framework", log),
            Some((3, 9, "installing system packages".to_string()))
        );
        // The bar line the build itself prints round-trips.
        let bar = bar_line("forge-base", 40, Some((5, 12, "installing Python tools")));
        let log =
            format!("[tillandsias] building image forge-base (t, digest_missing); x\n{bar}\n");
        assert_eq!(
            progress_in_log("forge-base", &log),
            Some((5, 12, "installing Python tools".to_string()))
        );
        // NEGATIVE CONTROLS: a finished run, another image, no announcement.
        let done = format!("{log}{}\n", bar_line("forge-base", 100, None));
        assert_eq!(progress_in_log("forge-base", &done), None);
        assert_eq!(progress_in_log("forge", &log), None);
        assert_eq!(progress_in_log("forge-base", "STEP 1/2: FROM x\n"), None);
    }

    #[test]
    fn image_build_progress_status_names_the_step() {
        assert_eq!(
            building_status("forge", Some((2, 4, "copying files"))),
            "Building forge, step 2/4: copying files"
        );
        assert_eq!(building_status("forge", None), "Building forge");
    }
}
