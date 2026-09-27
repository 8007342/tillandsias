//! Typed progress events for install, provision and login surfaces (order 1420-r2sn).
//!
//! Before this module every surface passed prose: `on_phase(&str)`,
//! `ProvisionProgress::report_message(&str)`, `ProvisionPhase::status_text`. No
//! renderer could draw a real bar from a sentence, so each one either printed
//! the sentence or animated a fill that no event had earned.
//!
//! [`ProgressEvent`] is the one shape every layer passes instead. It is data
//! only; rendering lives in the renderer crate (1420-9vpk), which adapts this
//! type to its own input rather than depending on a renderer type here.
//!
//! THE AGGREGATE IS A JOIN, NOT AN AVERAGE. A task's `done` is a grow-only
//! counter, so a stale or reordered event can never move a bar backwards:
//! [`ProgressEvent::merge_done`] keeps the maximum. The aggregate over many
//! tasks reaches 100% only when every task has reached its own `Done`.
//!
//! On the wire it travels as [`crate::ControlMessage::ProgressPush`], which is
//! opt-in: see [`crate::CAP_PROGRESS_PUSH_V1`] for why an old peer must never
//! be sent one unasked.
//!
//! @trace order:1420-r2sn

use serde::{Deserialize, Serialize};

/// One observation about one task's progress.
///
/// `task` identifies the task within a run (e.g. `"provision/download-rootfs"`).
/// `parent` names the enclosing task, so a renderer can nest sub-tasks and
/// aggregate them; `None` means a root task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProgressEvent {
    pub task: String,
    pub parent: Option<String>,
    /// Short human label for the task ("Downloading Fedora rootfs").
    pub label: String,
    pub kind: ProgressKind,
    /// Wall-clock milliseconds since the Unix epoch when the event was observed.
    pub ts_unix_ms: u64,
}

/// What is known about the task at this instant.
///
/// NEW VARIANTS MUST BE TRAILING. postcard encodes this enum by index exactly
/// as it does `ControlMessage`, so a mid-enum insertion renumbers every later
/// kind on the wire; the pinned-index test below fails if that happens.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProgressKind {
    /// A measurable amount of work: `done` of `total` `unit`s. `total` is
    /// `None` when the size is not known yet (a download with no
    /// Content-Length); a renderer then shows the count without a percentage.
    Determinate {
        done: u64,
        total: Option<u64>,
        unit: ProgressUnit,
    },
    /// Work with no measurable amount (cloud-init, a VM boot). `activity` is
    /// the latest thing observed, e.g. the last log line.
    Indeterminate { activity: String },
    /// The task finished successfully.
    Done,
    /// The task failed. `reason` is the full error text, not a summary.
    Failed { reason: String },
}

/// Unit of a determinate count. TRAILING ADDITIONS ONLY, as for [`ProgressKind`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProgressUnit {
    Bytes,
    Items,
    Steps,
}

impl ProgressKind {
    /// Whether this kind ends the task. A terminal task never becomes
    /// non-terminal again.
    pub fn is_terminal(&self) -> bool {
        matches!(self, ProgressKind::Done | ProgressKind::Failed { .. })
    }

    /// Completed fraction in `0.0..=1.0`, when one is defined: `Done` is 1.0;
    /// a determinate kind with a non-zero total is `done / total`, clamped.
    /// Indeterminate, failed and total-less kinds have none.
    pub fn fraction(&self) -> Option<f64> {
        match self {
            ProgressKind::Done => Some(1.0),
            ProgressKind::Determinate {
                done,
                total: Some(total),
                ..
            } if *total > 0 => Some((*done as f64 / *total as f64).min(1.0)),
            _ => None,
        }
    }
}

impl ProgressEvent {
    /// Join `later` into `self` for the same task, keeping state grow-only:
    /// a terminal state is never replaced by a non-terminal one, and a
    /// determinate `done` never decreases. This is what makes the aggregate
    /// monotone under reordered or duplicated delivery.
    pub fn merge_done(&mut self, later: &ProgressEvent) {
        if self.kind.is_terminal() {
            return;
        }
        let merged = match (&self.kind, &later.kind) {
            (
                ProgressKind::Determinate { done: a, .. },
                ProgressKind::Determinate {
                    done: b,
                    total,
                    unit,
                },
            ) => ProgressKind::Determinate {
                done: (*a).max(*b),
                total: *total,
                unit: *unit,
            },
            (_, other) => other.clone(),
        };
        self.kind = merged;
        self.label = later.label.clone();
        self.ts_unix_ms = self.ts_unix_ms.max(later.ts_unix_ms);
    }

    /// One plain line describing this event, with no terminal control
    /// characters. This is the adapter for surfaces that still take prose
    /// (`ProvisionProgress::report_message`); a real renderer should read
    /// the fields instead.
    pub fn summary_line(&self) -> String {
        match &self.kind {
            ProgressKind::Determinate { done, total, unit } => {
                let suffix = match unit {
                    ProgressUnit::Bytes => " bytes",
                    ProgressUnit::Items => " items",
                    ProgressUnit::Steps => " steps",
                };
                match (total, self.kind.fraction()) {
                    (Some(total), Some(f)) => format!(
                        "{}: {}/{}{} ({}%)",
                        self.label,
                        done,
                        total,
                        suffix,
                        (f * 100.0).floor() as u64
                    ),
                    _ => format!("{}: {}{}", self.label, done, suffix),
                }
            }
            ProgressKind::Indeterminate { activity } => format!("{}: {}", self.label, activity),
            ProgressKind::Done => format!("{}: done", self.label),
            ProgressKind::Failed { reason } => format!("{}: FAILED: {}", self.label, reason),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(task: &str, kind: ProgressKind) -> ProgressEvent {
        ProgressEvent {
            task: task.into(),
            parent: Some("provision".into()),
            label: "Downloading Fedora rootfs".into(),
            kind,
            ts_unix_ms: 1_790_000_000_000,
        }
    }

    fn det(done: u64, total: Option<u64>) -> ProgressKind {
        ProgressKind::Determinate {
            done,
            total,
            unit: ProgressUnit::Bytes,
        }
    }

    #[test]
    fn progress_event_roundtrip_every_kind() {
        for kind in [
            det(0, None),
            det(314_572_800, Some(629_145_600)),
            ProgressKind::Indeterminate {
                activity: "cloud-init: dnf install".into(),
            },
            ProgressKind::Done,
            ProgressKind::Failed {
                reason: "sha256 mismatch: expected ab12, got cd34".into(),
            },
        ] {
            let e = ev("provision/download-rootfs", kind);
            let bytes = postcard::to_allocvec(&e).unwrap();
            let back: ProgressEvent = postcard::from_bytes(&bytes).unwrap();
            assert_eq!(back, e);
        }
        let root = ProgressEvent {
            parent: None,
            ..ev("provision", ProgressKind::Done)
        };
        let back: ProgressEvent =
            postcard::from_bytes(&postcard::to_allocvec(&root).unwrap()).unwrap();
        assert_eq!(back, root);
    }

    /// The wire index of every kind and unit, as independent literals, for the
    /// reason `pinned_discriminant` in lib.rs gives: anything computed from
    /// the enum agrees with it by construction. No wildcard arm, so a new
    /// variant fails to compile here until it is given a number.
    #[test]
    fn progress_kind_and_unit_indices_are_pinned() {
        fn kind_index(k: &ProgressKind) -> u8 {
            match k {
                ProgressKind::Determinate { .. } => 0,
                ProgressKind::Indeterminate { .. } => 1,
                ProgressKind::Done => 2,
                ProgressKind::Failed { .. } => 3,
            }
        }
        fn unit_index(u: ProgressUnit) -> u8 {
            match u {
                ProgressUnit::Bytes => 0,
                ProgressUnit::Items => 1,
                ProgressUnit::Steps => 2,
            }
        }
        for k in [
            det(1, Some(2)),
            ProgressKind::Indeterminate {
                activity: String::new(),
            },
            ProgressKind::Done,
            ProgressKind::Failed {
                reason: String::new(),
            },
        ] {
            assert_eq!(postcard::to_allocvec(&k).unwrap()[0], kind_index(&k));
        }
        for u in [
            ProgressUnit::Bytes,
            ProgressUnit::Items,
            ProgressUnit::Steps,
        ] {
            assert_eq!(postcard::to_allocvec(&u).unwrap()[0], unit_index(u));
        }
    }

    #[test]
    fn merge_is_grow_only_under_reordering() {
        let mut state = ev("t", det(500, Some(1000)));
        state.merge_done(&ev("t", det(200, Some(1000))));
        assert_eq!(
            state.kind,
            det(500, Some(1000)),
            "a stale event must not move the bar back"
        );
        state.merge_done(&ev("t", det(900, Some(1000))));
        assert_eq!(state.kind, det(900, Some(1000)));
        state.merge_done(&ev("t", ProgressKind::Done));
        state.merge_done(&ev("t", det(950, Some(1000))));
        assert_eq!(
            state.kind,
            ProgressKind::Done,
            "a terminal state is never undone"
        );
    }

    #[test]
    fn fraction_is_defined_only_where_it_is_honest() {
        assert_eq!(det(1, Some(4)).fraction(), Some(0.25));
        assert_eq!(det(9, Some(4)).fraction(), Some(1.0));
        assert_eq!(det(1, None).fraction(), None);
        assert_eq!(det(1, Some(0)).fraction(), None);
        assert_eq!(ProgressKind::Done.fraction(), Some(1.0));
        assert_eq!(
            ProgressKind::Indeterminate {
                activity: "x".into()
            }
            .fraction(),
            None
        );
    }

    #[test]
    fn summary_line_is_plain_text() {
        let line = ev("t", det(1, Some(4))).summary_line();
        assert_eq!(line, "Downloading Fedora rootfs: 1/4 bytes (25%)");
        let failed = ev(
            "t",
            ProgressKind::Failed {
                reason: "disk full".into(),
            },
        )
        .summary_line();
        assert_eq!(failed, "Downloading Fedora rootfs: FAILED: disk full");
        assert!(!line.contains('\x1b') && !failed.contains('\x1b'));
    }
}
