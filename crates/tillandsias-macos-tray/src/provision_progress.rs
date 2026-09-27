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
