//! Tillandsia-palette terminal progress (order 1420-9vpk, PRETTY INSTALLER 2/10).
//!
//! Bars are drawn as a tillandsia leaf: a dark-green body that lightens toward
//! the leading edge, and a red/pink blush at the tip, so the tip appears to
//! grow. Colour is chosen by POSITION along the bar, never animated without an
//! event: a bar moves only when its task reports progress.
//!
//! Three output tiers, chosen once from the environment ([`Tier::detect`]):
//! truecolor (24-bit SGR), xterm-256, and PLAIN. Plain is what a pipe, a CI
//! log, `TERM=dumb` or `NO_COLOR` gets, and it is one clean line per task
//! STATE CHANGE with no escape bytes at all — so a log reader never sees a
//! redraw storm, and the property is testable without a terminal.
//!
//! The renderer takes its OWN small input model ([`TaskState`]) rather than the
//! wire type: the typed `ProgressEvent` is 1420-r2sn's, and a renderer that
//! depended on the wire would couple two layers that should meet in a thin
//! adapter.

use std::io::{self, Write};

pub mod palette {
    //! The tillandsia palette, truecolor with its xterm-256 fallback.
    //! Values are the ones the row pins (1420-9vpk context).

    /// A colour in both tiers.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Colour {
        pub rgb: (u8, u8, u8),
        pub xterm256: u8,
    }

    pub const TIP_BLUSH: Colour = Colour {
        rgb: (0xE8, 0x63, 0x7A),
        xterm256: 168,
    };
    pub const BLUSH_MID: Colour = Colour {
        rgb: (0xC4, 0x4D, 0x63),
        xterm256: 131,
    };
    pub const LEAF_LIGHT: Colour = Colour {
        rgb: (0x9D, 0xBB, 0xA5),
        xterm256: 108,
    };
    pub const LEAF: Colour = Colour {
        rgb: (0x4F, 0x8A, 0x5B),
        xterm256: 65,
    };
    pub const LEAF_DARK: Colour = Colour {
        rgb: (0x2F, 0x6B, 0x45),
        xterm256: 29,
    };
    pub const LEAF_DEEPEST: Colour = Colour {
        rgb: (0x1E, 0x4A, 0x32),
        xterm256: 22,
    };
    pub const TRACK: Colour = Colour {
        rgb: (0x3A, 0x3F, 0x3A),
        xterm256: 237,
    };
    pub const TEXT: Colour = Colour {
        rgb: (0xC9, 0xD3, 0xCB),
        xterm256: 251,
    };

    /// The body ramp from the base of the leaf to just behind the blush.
    pub const LEAF_RAMP: [Colour; 4] = [LEAF_DEEPEST, LEAF_DARK, LEAF, LEAF_LIGHT];
}

use palette::Colour;

/// How much colour the output may carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    TrueColor,
    Ansi256,
    /// No escape bytes at all; one line per state change.
    Plain,
}

/// The environment [`Tier::detect`] reads, injected so tests need no process
/// environment and no terminal.
#[derive(Debug, Clone, Default)]
pub struct EnvView {
    pub no_color: Option<String>,
    pub ci: Option<String>,
    pub term: Option<String>,
    pub colorterm: Option<String>,
    pub is_tty: bool,
}

impl EnvView {
    /// The real process environment and whether stderr is a terminal (stderr is
    /// where progress goes, so stdout stays clean for machine output).
    pub fn from_process() -> Self {
        use std::io::IsTerminal;
        let var = |k: &str| std::env::var(k).ok();
        EnvView {
            no_color: var("NO_COLOR"),
            ci: var("CI"),
            term: var("TERM"),
            colorterm: var("COLORTERM"),
            is_tty: io::stderr().is_terminal(),
        }
    }
}

impl Tier {
    /// Plain whenever anything says colour is unwanted or cannot be shown:
    /// a non-TTY sink, `NO_COLOR` (any value, per no-color.org), `CI`, or
    /// `TERM=dumb`. Otherwise truecolor when `COLORTERM` says so, else 256.
    pub fn detect(env: &EnvView) -> Tier {
        if !env.is_tty || env.no_color.is_some() || env.ci.is_some() {
            return Tier::Plain;
        }
        match env.term.as_deref() {
            None | Some("") | Some("dumb") => return Tier::Plain,
            _ => {}
        }
        match env.colorterm.as_deref() {
            Some("truecolor") | Some("24bit") => Tier::TrueColor,
            _ => Tier::Ansi256,
        }
    }
}

/// One task's state, as the renderer sees it.
#[derive(Debug, Clone, PartialEq)]
pub enum TaskState {
    Pending,
    /// Known size: `done` of `total` units (bytes, layers, steps).
    Determinate {
        done: u64,
        total: u64,
    },
    /// Unknown size: the last activity line, shown beside a blush pulse.
    Indeterminate {
        activity: String,
    },
    Done,
    Failed {
        reason: String,
    },
}

impl TaskState {
    /// The variant, ignoring payload: a change of KIND is a state change;
    /// `done` advancing inside Determinate is not.
    fn kind(&self) -> u8 {
        match self {
            TaskState::Pending => 0,
            TaskState::Determinate { .. } => 1,
            TaskState::Indeterminate { .. } => 2,
            TaskState::Done => 3,
            TaskState::Failed { .. } => 4,
        }
    }

    /// This task's contribution to the aggregate, in [0, 1].
    fn fraction(&self) -> f64 {
        match self {
            TaskState::Done => 1.0,
            TaskState::Determinate { done, total } if *total > 0 => {
                (*done as f64 / *total as f64).clamp(0.0, 1.0)
            }
            _ => 0.0,
        }
    }

    fn plain_word(&self) -> String {
        match self {
            TaskState::Pending => "pending".to_string(),
            TaskState::Determinate { .. } => "in progress".to_string(),
            TaskState::Indeterminate { activity } if activity.is_empty() => "working".to_string(),
            TaskState::Indeterminate { activity } => format!("working: {activity}"),
            TaskState::Done => "done".to_string(),
            TaskState::Failed { reason } => format!("FAILED: {reason}"),
        }
    }
}

/// Every task, in the order first seen, plus the aggregate.
///
/// THE AGGREGATE NEVER DECREASES AND REACHES 100% ONLY WHEN EVERY TASK IS DONE.
/// A task that appears late, or a total that grows, would otherwise pull the
/// bar backwards, and a set of determinate tasks all at `done == total` but not
/// yet Done would otherwise read as finished.
#[derive(Debug, Default)]
pub struct Tracker {
    tasks: Vec<(String, TaskState)>,
    high_water: f64,
}

/// Just below 100%: what the aggregate is capped at until every task is Done.
const NOT_YET_DONE_CAP: f64 = 0.999;

impl Tracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply an update. Returns true when it changed the task's KIND (a state
    /// change), which is what the plain sink prints on.
    pub fn update(&mut self, task: &str, state: TaskState) -> bool {
        let changed = match self.tasks.iter_mut().find(|(n, _)| n == task) {
            Some((_, s)) => {
                let kind_changed = s.kind() != state.kind();
                *s = state;
                kind_changed
            }
            None => {
                self.tasks.push((task.to_string(), state));
                true
            }
        };
        let computed = self.computed_fraction();
        self.high_water = self.high_water.max(computed);
        changed
    }

    fn all_done(&self) -> bool {
        !self.tasks.is_empty() && self.tasks.iter().all(|(_, s)| *s == TaskState::Done)
    }

    fn computed_fraction(&self) -> f64 {
        if self.tasks.is_empty() {
            return 0.0;
        }
        if self.all_done() {
            return 1.0;
        }
        let sum: f64 = self.tasks.iter().map(|(_, s)| s.fraction()).sum();
        (sum / self.tasks.len() as f64).min(NOT_YET_DONE_CAP)
    }

    /// The aggregate fraction in [0, 1]: monotone, and 1.0 only when all Done.
    pub fn aggregate(&self) -> f64 {
        if self.all_done() {
            1.0
        } else {
            self.high_water.min(NOT_YET_DONE_CAP)
        }
    }

    pub fn tasks(&self) -> &[(String, TaskState)] {
        &self.tasks
    }
}

fn sgr_fg(tier: Tier, c: Colour) -> String {
    match tier {
        Tier::TrueColor => format!("\x1b[38;2;{};{};{}m", c.rgb.0, c.rgb.1, c.rgb.2),
        Tier::Ansi256 => format!("\x1b[38;5;{}m", c.xterm256),
        Tier::Plain => String::new(),
    }
}

const RESET: &str = "\x1b[0m";

/// The colour of FILLED cell `i` of `filled` cells: the tip (last filled cell)
/// blushes, the one behind it is blush-mid, and the rest walk the leaf ramp
/// from deepest at the base to light just behind the blush.
fn filled_cell_colour(i: usize, filled: usize) -> Colour {
    if i + 1 == filled {
        return palette::TIP_BLUSH;
    }
    if i + 2 == filled {
        return palette::BLUSH_MID;
    }
    let body = filled.saturating_sub(2).max(1);
    let ramp = &palette::LEAF_RAMP;
    ramp[(i * ramp.len() / body).min(ramp.len() - 1)]
}

/// Render one bar of `width` cells for `fraction` in [0, 1].
///
/// Plain: `[#####-----]` — ASCII only, no escape bytes. Coloured tiers: `━`
/// cells coloured by position, the unfilled remainder in the track colour.
pub fn render_bar(fraction: f64, width: usize, tier: Tier) -> String {
    let fraction = if fraction.is_nan() {
        0.0
    } else {
        fraction.clamp(0.0, 1.0)
    };
    let filled = ((fraction * width as f64).floor() as usize).min(width);
    match tier {
        Tier::Plain => format!("[{}{}]", "#".repeat(filled), "-".repeat(width - filled)),
        _ => {
            let mut s = String::new();
            for i in 0..filled {
                s.push_str(&sgr_fg(tier, filled_cell_colour(i, filled)));
                s.push('━');
            }
            if filled < width {
                s.push_str(&sgr_fg(tier, palette::TRACK));
                s.push_str(&"─".repeat(width - filled));
            }
            s.push_str(RESET);
            s
        }
    }
}

/// Percent as shown to humans: floor, so 100% is never displayed early.
pub fn percent(fraction: f64) -> u32 {
    (fraction.clamp(0.0, 1.0) * 100.0).floor() as u32
}

/// Where rendered progress goes.
pub trait Sink {
    fn update(&mut self, task: &str, state: TaskState) -> io::Result<()>;
    fn finish(&mut self) -> io::Result<()>;
}

/// PLAIN output: one line per task STATE CHANGE, no escape bytes, nothing on a
/// mere `done` increment. The sink a pipe, a CI log, `TERM=dumb` and
/// `NO_COLOR` get.
pub struct PlainSink<W: Write> {
    out: W,
    tracker: Tracker,
}

impl<W: Write> PlainSink<W> {
    pub fn new(out: W) -> Self {
        PlainSink {
            out,
            tracker: Tracker::new(),
        }
    }

    pub fn into_inner(self) -> W {
        self.out
    }

    pub fn tracker(&self) -> &Tracker {
        &self.tracker
    }
}

impl<W: Write> Sink for PlainSink<W> {
    fn update(&mut self, task: &str, state: TaskState) -> io::Result<()> {
        let word = state.plain_word();
        if self.tracker.update(task, state) {
            writeln!(
                self.out,
                "{task}: {word} (overall {}%)",
                percent(self.tracker.aggregate())
            )?;
        }
        Ok(())
    }

    fn finish(&mut self) -> io::Result<()> {
        self.out.flush()
    }
}

/// The LIVE coloured sink: one indicatif bar per task plus an overall bar,
/// each drawn with [`render_bar`] so the palette lives in one place.
pub struct TtySink {
    tier: Tier,
    width: usize,
    multi: indicatif::MultiProgress,
    overall: indicatif::ProgressBar,
    bars: Vec<(String, indicatif::ProgressBar)>,
    tracker: Tracker,
}

impl TtySink {
    pub fn new(tier: Tier, width: usize) -> Self {
        let multi = indicatif::MultiProgress::new();
        let overall = multi.add(indicatif::ProgressBar::new_spinner());
        overall
            .set_style(indicatif::ProgressStyle::with_template("{msg}").expect("static template"));
        TtySink {
            tier,
            width,
            multi,
            overall,
            bars: Vec::new(),
            tracker: Tracker::new(),
        }
    }

    fn line(&self, label: &str, fraction: f64, tail: &str) -> String {
        format!(
            "{}{label:<20}{RESET} {} {:>3}% {tail}",
            sgr_fg(self.tier, palette::TEXT),
            render_bar(fraction, self.width, self.tier),
            percent(fraction)
        )
    }
}

impl Sink for TtySink {
    fn update(&mut self, task: &str, state: TaskState) -> io::Result<()> {
        let (fraction, tail) = match &state {
            TaskState::Indeterminate { activity } => (0.0, activity.clone()),
            TaskState::Failed { reason } => (state.fraction(), format!("FAILED: {reason}")),
            s => (s.fraction(), String::new()),
        };
        self.tracker.update(task, state);
        let msg = self.line(task, fraction, &tail);
        match self.bars.iter().find(|(n, _)| n == task) {
            Some((_, bar)) => bar.set_message(msg),
            None => {
                let bar = self.multi.add(indicatif::ProgressBar::new_spinner());
                bar.set_style(
                    indicatif::ProgressStyle::with_template("{msg}").expect("static template"),
                );
                bar.set_message(msg);
                self.bars.push((task.to_string(), bar));
            }
        }
        let overall = self.line("overall", self.tracker.aggregate(), "");
        self.overall.set_message(overall);
        Ok(())
    }

    fn finish(&mut self) -> io::Result<()> {
        for (_, bar) in &self.bars {
            bar.finish();
        }
        self.overall.finish();
        Ok(())
    }
}

/// The sink the environment calls for: plain unless the tier allows colour.
pub fn sink_for(env: &EnvView, width: usize) -> Box<dyn Sink> {
    match Tier::detect(env) {
        Tier::Plain => Box::new(PlainSink::new(io::stderr())),
        tier => Box::new(TtySink::new(tier, width)),
    }
}
