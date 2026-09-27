//! Golden tests for 1420-9vpk's verifiable closure. Every property here is in
//! the pure core, so none of them needs a terminal.

use tillandsias_progress_tty::{
    EnvView, PlainSink, Sink, TaskState, Tier, Tracker, palette, render_bar,
};

const ESC: u8 = 0x1b;

fn tty(term: &str, colorterm: Option<&str>) -> EnvView {
    EnvView {
        term: Some(term.to_string()),
        colorterm: colorterm.map(str::to_string),
        is_tty: true,
        ..EnvView::default()
    }
}

/// A representative run: two tasks, one determinate, one indeterminate, both
/// finishing. Returns what a plain sink wrote.
fn plain_run() -> Vec<u8> {
    let mut s = PlainSink::new(Vec::new());
    s.update("pull images", TaskState::Pending).unwrap();
    s.update("pull images", TaskState::Determinate { done: 0, total: 10 })
        .unwrap();
    s.update(
        "start vault",
        TaskState::Indeterminate {
            activity: "unsealing".into(),
        },
    )
    .unwrap();
    for d in 1..=10 {
        s.update("pull images", TaskState::Determinate { done: d, total: 10 })
            .unwrap();
    }
    s.update("pull images", TaskState::Done).unwrap();
    s.update("start vault", TaskState::Done).unwrap();
    s.finish().unwrap();
    s.into_inner()
}

#[test]
fn every_degrade_condition_selects_the_plain_tier() {
    // TERM=dumb, NO_COLOR, CI and a non-TTY sink each force plain, even when
    // everything else asks for truecolor.
    let mut e = tty("dumb", Some("truecolor"));
    assert_eq!(Tier::detect(&e), Tier::Plain, "TERM=dumb");
    e = tty("xterm-256color", Some("truecolor"));
    e.no_color = Some(String::new());
    assert_eq!(Tier::detect(&e), Tier::Plain, "NO_COLOR, even empty");
    e = tty("xterm-256color", Some("truecolor"));
    e.ci = Some("true".into());
    assert_eq!(Tier::detect(&e), Tier::Plain, "CI");
    e = tty("xterm-256color", Some("truecolor"));
    e.is_tty = false;
    assert_eq!(Tier::detect(&e), Tier::Plain, "non-TTY");
    // And the positive cases, so a detector that always says Plain fails.
    assert_eq!(
        Tier::detect(&tty("xterm-256color", Some("truecolor"))),
        Tier::TrueColor
    );
    assert_eq!(Tier::detect(&tty("xterm-256color", None)), Tier::Ansi256);
}

#[test]
fn plain_output_contains_zero_escape_bytes() {
    let out = plain_run();
    assert!(!out.is_empty(), "premise: the plain run wrote something");
    assert!(
        !out.contains(&ESC),
        "plain output must carry no ESC byte: {:?}",
        String::from_utf8_lossy(&out)
    );
    // The plain BAR too, at every fill level.
    for f in [0.0, 0.33, 0.5, 0.999, 1.0] {
        assert!(
            !render_bar(f, 20, Tier::Plain).as_bytes().contains(&ESC),
            "fraction {f}"
        );
    }
}

#[test]
fn a_plain_sink_writes_exactly_one_line_per_state_change() {
    let text = String::from_utf8(plain_run()).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    // pull images: Pending, Determinate, Done = 3 changes (ten `done`
    // increments inside Determinate are NOT changes); start vault:
    // Indeterminate, Done = 2 changes.
    assert_eq!(lines.len(), 5, "one line per state change, got:\n{text}");
    assert!(lines[0].starts_with("pull images: pending"));
    assert!(lines[2].starts_with("start vault: working: unsealing"));
    assert!(
        lines[4].ends_with("(overall 100%)"),
        "last line: {}",
        lines[4]
    );
}

#[test]
fn under_truecolor_the_tip_cell_is_the_blush_and_the_body_walks_the_leaf_ramp() {
    let bar = render_bar(0.5, 20, Tier::TrueColor);
    let sgr = |c: palette::Colour| format!("\x1b[38;2;{};{};{}m", c.rgb.0, c.rgb.1, c.rgb.2);
    let cells: Vec<&str> = bar.split('━').collect();
    // 10 filled cells: the SGR before the last filled cell is the tip blush.
    assert_eq!(cells.len(), 11, "premise: ten filled cells, got {bar:?}");
    assert!(
        cells[9].ends_with(&sgr(palette::TIP_BLUSH)),
        "tip cell must be #E8637A"
    );
    assert!(
        cells[8].ends_with(&sgr(palette::BLUSH_MID)),
        "cell behind the tip is blush-mid"
    );
    assert!(
        cells[0].ends_with(&sgr(palette::LEAF_DEEPEST)),
        "the base is the deepest leaf"
    );
    for c in &cells[..8] {
        assert!(
            palette::LEAF_RAMP.iter().any(|l| c.ends_with(&sgr(*l))),
            "a body cell outside the leaf ramp: {c:?}"
        );
    }
    assert!(
        bar.contains(&sgr(palette::TRACK)),
        "the unfilled track is drawn"
    );
}

#[test]
fn under_256_colour_the_tip_is_xterm_168() {
    let bar = render_bar(0.5, 20, Tier::Ansi256);
    let cells: Vec<&str> = bar.split('━').collect();
    assert!(
        cells[9].ends_with("\x1b[38;5;168m"),
        "tip cell must be xterm-256 168: {bar:?}"
    );
}

#[test]
fn the_aggregate_never_decreases_and_reaches_100_only_when_all_tasks_are_done() {
    let mut t = Tracker::new();
    let mut prev = 0.0;
    let mut check = |t: &Tracker, what: &str| {
        let a = t.aggregate();
        assert!(a >= prev, "{what}: aggregate fell from {prev} to {a}");
        prev = a;
    };
    t.update("a", TaskState::Determinate { done: 5, total: 10 });
    check(&t, "a half");
    // A late task would halve the mean; the aggregate must not fall.
    t.update("b", TaskState::Pending);
    check(&t, "late task");
    // A growing total would also pull it back.
    t.update(
        "a",
        TaskState::Determinate {
            done: 5,
            total: 100,
        },
    );
    check(&t, "grown total");
    // Every task at done == total but none Done: NOT 100%.
    t.update(
        "a",
        TaskState::Determinate {
            done: 100,
            total: 100,
        },
    );
    t.update("b", TaskState::Determinate { done: 1, total: 1 });
    check(&t, "all at total");
    assert!(t.aggregate() < 1.0, "100% before every task is Done");
    t.update("a", TaskState::Done);
    check(&t, "a done");
    assert!(t.aggregate() < 1.0, "100% with b not Done");
    t.update("b", TaskState::Done);
    check(&t, "all done");
    assert_eq!(t.aggregate(), 1.0);
}
