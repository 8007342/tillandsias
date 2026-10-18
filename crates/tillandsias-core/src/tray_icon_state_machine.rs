//! The tray icon's work phase (order 1778-gct2).
//!
//! @trace order:1778-gct2, openspec/changes/tray-icon-state-machine/design.md
//!
//! Operator ruling, 2026-10-17: the icon blushes progressively while
//! containers are being created, like a tillandsia before it has pups; when
//! the work completes it shows pups; the first menu open after that returns
//! it to the plain icon. Pups mean finished work ("Pup = initializing" is
//! retired).
//!
//! One pure reducer, shared by the Linux, macOS and Windows trays: each
//! feeds it [`Event`]s and draws the [`Phase`] from its own icon set. Health
//! states (Dried, Stopping) override the phase and live elsewhere.

/// How many blush levels an icon set draws.
pub const BLUSH_LEVELS: u8 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Phase {
    /// At rest: the plain bud.
    #[default]
    Plain,
    /// Containers are being created; `1..=BLUSH_LEVELS`, deepening.
    Blushing(u8),
    /// The work completed; cleared by the next menu open.
    Pups,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// `done` of `total` containers created so far in the current work.
    Progress {
        done: u32,
        total: u32,
    },
    Completed,
    Failed,
    MenuOpened,
}

/// The blush level for `done` of `total`: at least 1 once work has started.
pub fn level(done: u32, total: u32) -> u8 {
    if total == 0 {
        return 1;
    }
    let levels = u64::from(BLUSH_LEVELS);
    let scaled = (u64::from(done) * levels).div_ceil(u64::from(total));
    scaled.clamp(1, levels) as u8
}

pub fn reduce(phase: Phase, event: Event) -> Phase {
    match (phase, event) {
        // Levels only rise within one run: a total that grows mid-run (one
        // more container) never makes the blush fade.
        (Phase::Blushing(old), Event::Progress { done, total }) => {
            Phase::Blushing(old.max(level(done, total)))
        }
        (Phase::Plain | Phase::Pups, Event::Progress { done, total }) => {
            Phase::Blushing(level(done, total))
        }
        (Phase::Blushing(_), Event::Completed) => Phase::Pups,
        // No work was seen: nothing to celebrate.
        (Phase::Plain, Event::Completed) => Phase::Plain,
        (Phase::Pups, Event::Completed) => Phase::Pups,
        // A failure never shows pups; the status line names it.
        (_, Event::Failed) => Phase::Plain,
        // The first open after the work acknowledges it.
        (Phase::Pups, Event::MenuOpened) => Phase::Plain,
        (p, Event::MenuOpened) => p,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(events: &[Event]) -> Vec<Phase> {
        let mut p = Phase::default();
        events
            .iter()
            .map(|e| {
                p = reduce(p, *e);
                p
            })
            .collect()
    }

    #[test]
    fn levels_cover_the_range() {
        assert_eq!(level(0, 0), 1, "work started, nothing counted yet");
        assert_eq!(level(0, 3), 1);
        assert_eq!(level(1, 4), 1);
        assert_eq!(level(2, 4), 2);
        assert_eq!(level(3, 4), 3);
        assert_eq!(level(4, 4), BLUSH_LEVELS);
        assert_eq!(level(9, 4), BLUSH_LEVELS, "clamped");
        assert_eq!(level(1, 3), 2, "ceil");
    }

    #[test]
    fn a_launch_blushes_deeper_then_shows_pups() {
        use Event::*;
        let phases = run(&[
            Progress { done: 0, total: 3 },
            Progress { done: 1, total: 3 },
            Progress { done: 3, total: 3 },
            Completed,
        ]);
        assert_eq!(
            phases,
            [
                Phase::Blushing(1),
                Phase::Blushing(2),
                Phase::Blushing(4),
                Phase::Pups
            ]
        );
    }

    #[test]
    fn the_blush_never_fades_within_a_run() {
        use Event::*;
        // One more container joins mid-run: 2/2 then 2/5 must not fade.
        let phases = run(&[
            Progress { done: 2, total: 2 },
            Progress { done: 2, total: 5 },
        ]);
        assert_eq!(phases, [Phase::Blushing(4), Phase::Blushing(4)]);
    }

    #[test]
    fn the_first_menu_open_after_the_work_returns_plain() {
        use Event::*;
        let phases = run(&[
            Progress { done: 1, total: 1 },
            Completed,
            MenuOpened,
            MenuOpened,
        ]);
        assert_eq!(&phases[2..], [Phase::Plain, Phase::Plain]);
    }

    #[test]
    fn a_menu_open_while_blushing_changes_nothing() {
        assert_eq!(
            reduce(Phase::Blushing(2), Event::MenuOpened),
            Phase::Blushing(2)
        );
    }

    #[test]
    fn a_failure_never_shows_pups() {
        use Event::*;
        let phases = run(&[Progress { done: 1, total: 3 }, Failed, Completed]);
        assert_eq!(phases, [Phase::Blushing(2), Phase::Plain, Phase::Plain]);
        assert_eq!(reduce(Phase::Pups, Failed), Phase::Plain);
    }

    #[test]
    fn new_work_after_pups_blushes_from_its_own_level() {
        let p = reduce(Phase::Pups, Event::Progress { done: 0, total: 2 });
        assert_eq!(p, Phase::Blushing(1));
    }

    /// NEGATIVE CONTROL: completion with no work seen is not a celebration,
    /// and the plain icon stays plain on a menu open.
    #[test]
    fn nothing_happens_without_work() {
        assert_eq!(reduce(Phase::Plain, Event::Completed), Phase::Plain);
        assert_eq!(reduce(Phase::Plain, Event::MenuOpened), Phase::Plain);
        assert_eq!(reduce(Phase::Pups, Event::Completed), Phase::Pups);
    }
}
