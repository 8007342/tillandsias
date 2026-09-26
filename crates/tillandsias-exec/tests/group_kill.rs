//! Order 1384-aixy: a deadline kills what the child STARTED, not only the child.
//!
//! The child starts a detached grandchild that writes a marker file about two
//! seconds later, then sleeps far past the deadline. With `group(true)` the
//! deadline kills the grandchild with it, so the marker never appears. The
//! control runs the SAME command with `group(false)`: the grandchild survives
//! the child's kill and the marker DOES appear. A test that only ran the
//! grouped arm would pass on a machine where the grandchild simply failed to
//! start.

use std::path::Path;
use std::time::{Duration, Instant};
use tillandsias_exec::{Command, Completion};

#[cfg(unix)]
fn spawner(marker: &Path) -> Command {
    let m = marker.display().to_string();
    Command::new([
        "sh".to_string(),
        "-c".to_string(),
        format!("(sleep 2; touch '{m}') & sleep 30"),
    ])
}

#[cfg(windows)]
fn spawner(marker: &Path) -> Command {
    // The grandchild is a .cmd file beside the marker, so no quoting nests.
    // `start /b` launches it as a separate process that outlives a kill of
    // the outer cmd unless the job takes it too; ping is the portable sleep.
    let dir = marker.parent().expect("marker has a parent");
    let grand = dir.join("grand.cmd");
    std::fs::write(
        &grand,
        format!(
            "@ping -n 3 127.0.0.1 >nul\r\n@echo x> \"{}\"\r\n",
            marker.display()
        ),
    )
    .unwrap();
    Command::new([
        "cmd.exe".to_string(),
        "/c".to_string(),
        format!("start /b {} & ping -n 30 127.0.0.1 >nul", grand.display()),
    ])
}

async fn run_with_deadline(group: bool, marker: &Path) -> (Completion, Duration) {
    let t0 = Instant::now();
    let out = spawner(marker)
        .group(group)
        .timeout(Duration::from_millis(500))
        .run()
        .await
        .expect("spawn");
    (out.completion, t0.elapsed())
}

async fn marker_after(marker: &Path, wait: Duration) -> bool {
    tokio::time::sleep(wait).await;
    marker.exists()
}

#[tokio::test]
async fn a_grouped_deadline_kills_the_grandchild() {
    let dir = tempfile::tempdir().unwrap();
    let marker = dir.path().join("grandchild-survived");
    let (completion, elapsed) = run_with_deadline(true, &marker).await;
    assert!(
        matches!(completion, Completion::TimedOut { .. }),
        "{completion:?}"
    );
    assert!(
        elapsed < Duration::from_secs(2),
        "deadline took {elapsed:?}"
    );
    assert!(
        !marker_after(&marker, Duration::from_secs(5)).await,
        "the grandchild outlived a grouped deadline"
    );
}

#[tokio::test]
async fn control_an_ungrouped_deadline_leaves_the_grandchild_running() {
    let dir = tempfile::tempdir().unwrap();
    let marker = dir.path().join("grandchild-survived");
    let (completion, _) = run_with_deadline(false, &marker).await;
    assert!(
        matches!(completion, Completion::TimedOut { .. }),
        "{completion:?}"
    );
    assert!(
        marker_after(&marker, Duration::from_secs(8)).await,
        "control failed: without a group the grandchild should survive and write the marker; \
         if it does not, the grouped arm above proves nothing on this host"
    );
}
