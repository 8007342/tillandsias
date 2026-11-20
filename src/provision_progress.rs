//! ORDER 1420-83vf, reworked by 1420-x6rz — first-provision progress for the
//! `--provision` renderer.
//!
//! 83vf had to parse vm-layer's prose ("Downloading Fedora Cloud image X/Y MB
//! (P%)") back into numbers and pin those format strings with a drift test.
//! Since 1420-x6rz vm-layer emits typed `ProgressEvent`s (1420-r2sn's types), so
//! this is a straight, total mapping from the wire event to the renderer's
//! `TaskState`: nothing is parsed, and there is no prose left to drift. Pure: no
//! macOS dependency, tests run on every host.

use tillandsias_control_wire::{ProgressEvent, ProgressKind};
use tillandsias_progress_tty::TaskState;

/// (display name, renderer state) for one event. The display name is the
/// event's own `label`, so the bar reads what vm-layer calls the step.
pub fn event_to_task(ev: &ProgressEvent) -> (String, TaskState) {
    let state = match &ev.kind {
        ProgressKind::Determinate {
            done,
            total: Some(total),
            ..
        } if *total > 0 => TaskState::Determinate {
            done: (*done).min(*total),
            total: *total,
        },
        // A size the source does not know is honest activity, not a guess.
        ProgressKind::Determinate { .. } => TaskState::Indeterminate {
            activity: "working".to_string(),
        },
        ProgressKind::Indeterminate { activity } => TaskState::Indeterminate {
            activity: activity.clone(),
        },
        ProgressKind::Done => TaskState::Done,
        ProgressKind::Failed { reason } => TaskState::Failed {
            reason: reason.clone(),
        },
    };
    (ev.label.clone(), state)
}

/// 1420-v3zt: one run of same-coloured text in a menu-bar progress bar.
/// `rgb: None` means "the system's own label colour", so the percent stays
/// legible on both light and dark menu bars.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BarSegment {
    pub text: String,
    pub rgb: Option<(u8, u8, u8)>,
}

/// 1420-v3zt: the tillandsia bar for the menu bar and the status row —
/// `cells` glyphs, filled ones on the leaf ramp (deep green at the base) with
/// the leading cell in the blush tip, unfilled ones in the track colour, then
/// the percent. Pure, so the palette mapping is tested on every host.
pub fn menu_bar_segments(fraction: f64, cells: usize) -> Vec<BarSegment> {
    use tillandsias_progress_tty::palette;
    let fraction = if fraction.is_nan() {
        0.0
    } else {
        fraction.clamp(0.0, 1.0)
    };
    let filled = ((fraction * cells as f64).floor() as usize).min(cells);
    let mut out = Vec::with_capacity(cells + 1);
    for i in 0..filled {
        let colour = if i + 1 == filled && filled < cells {
            palette::TIP_BLUSH
        } else {
            let ramp = &palette::LEAF_RAMP;
            ramp[(i * ramp.len() / cells.max(1)).min(ramp.len() - 1)]
        };
        out.push(BarSegment {
            text: "\u{25B0}".to_string(),
            rgb: Some(colour.rgb),
        });
    }
    if filled < cells {
        out.push(BarSegment {
            text: "\u{25B1}".repeat(cells - filled),
            rgb: Some(palette::TRACK.rgb),
        });
    }
    out.push(BarSegment {
        text: format!(" {}%", tillandsias_progress_tty::percent(fraction)),
        rgb: None,
    });
    out
}

/// 1420-v3zt: vm-layer emits an event per chunk; AppKit needs a repaint only
/// when the shown percent changes. `true` = repaint.
#[derive(Debug, Default)]
pub struct PercentGate {
    last: Option<(String, u32)>,
}

impl PercentGate {
    pub fn changed(&mut self, task: &str, fraction: f64) -> bool {
        let key = (
            task.to_string(),
            tillandsias_progress_tty::percent(fraction),
        );
        if self.last.as_ref() == Some(&key) {
            return false;
        }
        self.last = Some(key);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_control_wire::ProgressUnit;

    fn ev(label: &str, kind: ProgressKind) -> ProgressEvent {
        ProgressEvent {
            task: "t".to_string(),
            parent: None,
            label: label.to_string(),
            kind,
            ts_unix_ms: 0,
        }
    }

    #[test]
    fn typed_events_map_totally_onto_renderer_states() {
        let bytes = ev(
            "Download Fedora Cloud image",
            ProgressKind::Determinate {
                done: 132_000_000,
                total: Some(528_000_000),
                unit: ProgressUnit::Bytes,
            },
        );
        assert_eq!(
            event_to_task(&bytes),
            (
                "Download Fedora Cloud image".to_string(),
                TaskState::Determinate {
                    done: 132_000_000,
                    total: 528_000_000
                }
            )
        );
        let steps = ev(
            "Prepare VM disk",
            ProgressKind::Determinate {
                done: 40,
                total: Some(100),
                unit: ProgressUnit::Steps,
            },
        );
        assert_eq!(
            event_to_task(&steps).1,
            TaskState::Determinate {
                done: 40,
                total: 100
            }
        );
        assert_eq!(
            event_to_task(&ev("x", ProgressKind::Done)).1,
            TaskState::Done
        );
        assert_eq!(
            event_to_task(&ev(
                "x",
                ProgressKind::Failed {
                    reason: "ENOSPC".into()
                }
            ))
            .1,
            TaskState::Failed {
                reason: "ENOSPC".into()
            }
        );
    }

    #[test]
    fn an_unknown_total_is_activity_not_a_fake_fraction() {
        let unknown = ev(
            "x",
            ProgressKind::Determinate {
                done: 5,
                total: None,
                unit: ProgressUnit::Bytes,
            },
        );
        assert!(matches!(
            event_to_task(&unknown).1,
            TaskState::Indeterminate { .. }
        ));
        let zero = ev(
            "x",
            ProgressKind::Determinate {
                done: 0,
                total: Some(0),
                unit: ProgressUnit::Bytes,
            },
        );
        assert!(matches!(
            event_to_task(&zero).1,
            TaskState::Indeterminate { .. }
        ));
    }

    /// 1420-v3zt: leaf-ramp body, blush tip, track remainder, percent.
    #[test]
    fn menu_bar_bar_uses_the_tillandsia_palette() {
        use tillandsias_progress_tty::palette;
        let segs = menu_bar_segments(0.42, 10);
        assert_eq!(segs.len(), 4 + 1 + 1, "{segs:?}");
        assert_eq!(segs[0].rgb, Some(palette::LEAF_DEEPEST.rgb));
        assert_eq!(segs[3].rgb, Some(palette::TIP_BLUSH.rgb));
        assert_eq!(segs[4].text.chars().count(), 6);
        assert_eq!(segs[4].rgb, Some(palette::TRACK.rgb));
        assert_eq!(
            segs[5],
            BarSegment {
                text: " 42%".into(),
                rgb: None
            }
        );
        // Complete: all leaf, no blush tip, no track.
        let full = menu_bar_segments(1.0, 5);
        assert!(
            full[..5]
                .iter()
                .all(|s| s.rgb != Some(palette::TIP_BLUSH.rgb))
        );
        assert_eq!(full.last().unwrap().text, " 100%");
        assert_eq!(menu_bar_segments(f64::NAN, 5).last().unwrap().text, " 0%");
    }

    /// 1420-v3zt closure shape: a byte-granular download repaints once per
    /// percent — at least 10 distinct values, never one per chunk.
    #[test]
    fn percent_gate_repaints_once_per_percent() {
        let mut gate = PercentGate::default();
        let total = 528_000_000u64;
        let repaints = (0..=total)
            .step_by(1_000_000)
            .filter(|done| gate.changed("dl", *done as f64 / total as f64))
            .count();
        assert!((10..=101).contains(&repaints), "{repaints}");
        assert!(gate.changed("expand", 0.0), "a new task repaints");
    }

    /// 1420-x6rz: vm-layer must not fold progress back into prose. The row's
    /// criterion is that no consumer receives a formatted percent string.
    #[test]
    fn vm_layer_no_longer_emits_percent_prose() {
        let vz = include_str!("../../tillandsias-vm-layer/src/vz.rs");
        for prose in [
            "\"Downloading Fedora Cloud image {}/{} MB ({}%)\"",
            "\"Converting Fedora Cloud image ({pct}%)\"",
        ] {
            assert!(
                !vz.contains(prose),
                "vz.rs emits percent prose again: {prose}"
            );
        }
        assert!(vz.contains("PROGRESS_TASK_DOWNLOAD") && vz.contains("ProgressUnit::Bytes"));
    }
}
