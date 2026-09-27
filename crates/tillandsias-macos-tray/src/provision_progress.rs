//! ORDER 1420-83vf — `--provision` (and `--reset-state`, which the curl
//! installer runs) draws tillandsia progress bars for a human instead of
//! printing `{"phase":…}` JSON lines at them.
//!
//! vm-layer still reports first-provision progress as prose through
//! `on_phase(&str)` (typed `ProgressEvent`s are 1420-x6rz). Until then this maps
//! vm-layer's OWN format strings — pinned below against vz.rs, so a reworded
//! phase fails a test rather than silently dropping a bar — onto the renderer's
//! `TaskState`. Pure: no macOS dependency, tests run on every host.

use tillandsias_progress_tty::TaskState;

/// The two tasks first provisioning has: the image download and its expansion.
pub const TASK_DOWNLOAD: &str = "Download Fedora Cloud image";
pub const TASK_EXPAND: &str = "Prepare VM disk";

/// Map one vm-layer phase line to (task, state). `None` for a line this
/// mapper does not model (it is dropped from the bars, never misrendered).
pub fn phase_to_task(phase: &str) -> Option<(&'static str, TaskState)> {
    let p = phase.trim();
    if p == "Downloading Fedora Cloud image" {
        return Some((
            TASK_DOWNLOAD,
            TaskState::Indeterminate {
                activity: "connecting".to_string(),
            },
        ));
    }
    // "Downloading Fedora Cloud image {done}/{total} MB ({pct}%)"
    if let Some(rest) = p.strip_prefix("Downloading Fedora Cloud image ") {
        let mb = rest.split(" MB").next()?;
        let (done, total) = mb.split_once('/')?;
        let (done, total) = (
            done.trim().parse::<u64>().ok()?,
            total.trim().parse::<u64>().ok()?,
        );
        if total > 0 {
            return Some((TASK_DOWNLOAD, TaskState::Determinate { done, total }));
        }
        return None;
    }
    if p == "Converting Fedora Cloud image" {
        return Some((
            TASK_EXPAND,
            TaskState::Indeterminate {
                activity: "expanding".to_string(),
            },
        ));
    }
    // "Converting Fedora Cloud image ({pct}%)"
    if let Some(rest) = p.strip_prefix("Converting Fedora Cloud image (") {
        let pct = rest.strip_suffix("%)")?.trim().parse::<u64>().ok()?;
        return Some((
            TASK_EXPAND,
            TaskState::Determinate {
                done: pct.min(100),
                total: 100,
            },
        ));
    }
    if p == "Fedora Cloud image ready" {
        return Some((TASK_EXPAND, TaskState::Done));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn download_and_expand_lines_become_determinate_tasks() {
        assert_eq!(
            phase_to_task("Downloading Fedora Cloud image 132/528 MB (25%)"),
            Some((
                TASK_DOWNLOAD,
                TaskState::Determinate {
                    done: 132,
                    total: 528
                }
            ))
        );
        assert_eq!(
            phase_to_task("Converting Fedora Cloud image (40%)"),
            Some((
                TASK_EXPAND,
                TaskState::Determinate {
                    done: 40,
                    total: 100
                }
            ))
        );
        assert_eq!(
            phase_to_task("Fedora Cloud image ready"),
            Some((TASK_EXPAND, TaskState::Done))
        );
        assert!(matches!(
            phase_to_task("Downloading Fedora Cloud image"),
            Some((TASK_DOWNLOAD, TaskState::Indeterminate { .. }))
        ));
    }

    #[test]
    fn an_unmodelled_or_malformed_line_is_dropped_not_misrendered() {
        assert_eq!(phase_to_task("Starting Fedora Linux"), None);
        assert_eq!(
            phase_to_task("Downloading Fedora Cloud image x/y MB (?%)"),
            None
        );
        assert_eq!(
            phase_to_task("Downloading Fedora Cloud image 0/0 MB (0%)"),
            None
        );
    }

    /// DRIFT GUARD: the literals this mapper parses must be the ones vz.rs
    /// actually emits. A reworded phase in vm-layer turns this red instead of
    /// silently removing a bar from the installer.
    #[test]
    fn the_mapped_phrases_are_the_ones_vz_rs_emits() {
        let vz = include_str!("../../tillandsias-vm-layer/src/vz.rs");
        for phrase in [
            "on_phase(\"Downloading Fedora Cloud image\")",
            "\"Downloading Fedora Cloud image {}/{} MB ({}%)\"",
            "on_phase(\"Converting Fedora Cloud image\")",
            "\"Converting Fedora Cloud image ({pct}%)\"",
            "on_phase(\"Fedora Cloud image ready\")",
        ] {
            assert!(vz.contains(phrase), "vz.rs no longer emits {phrase}");
        }
    }
}
