//! ORDER 1945-sthg — a studio launch reports each stage and fails by name
//! within a bound.
//!
//! lenovinha 2026-11-01: `--studio comfyui` printed three lines and then
//! nothing for 50 minutes. Each stage of the sibling studio launch now prints
//! one progress line when it starts and one when it ends, and has a deadline.
//! A stage that overruns its deadline fails with its name and the bound
//! instead of leaving a frozen terminal. A blocking stage that overruns is
//! abandoned on its thread; the launch returns the error and the process
//! exits.
// @trace order:1945-sthg, spec:local-web-preview

use std::time::{Duration, Instant};

/// One stage of a studio launch: its name and how long it may take.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Stage {
    pub(crate) index: usize,
    pub(crate) total: usize,
    pub(crate) name: &'static str,
    pub(crate) bound: Duration,
}

impl Stage {
    fn begin(&self, lane: &str) -> Instant {
        eprintln!(
            "[tillandsias] [{lane}] stage {}/{}: {} (deadline {}s)",
            self.index,
            self.total,
            self.name,
            self.bound.as_secs()
        );
        Instant::now()
    }

    fn end(&self, lane: &str, started: Instant) {
        eprintln!(
            "[tillandsias] [{lane}] stage {}/{}: {} done in {}s",
            self.index,
            self.total,
            self.name,
            started.elapsed().as_secs()
        );
    }

    fn overrun(&self, lane: &str) -> String {
        format!(
            "[{lane}] stage '{}' did not finish within {}s; the launch stops here",
            self.name,
            self.bound.as_secs()
        )
    }
}

/// Run a blocking stage on its own thread and wait at most its bound.
pub(crate) fn run_blocking<T, F>(lane: &str, stage: Stage, f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    let started = stage.begin(lane);
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name(format!("studio-stage-{}", stage.index))
        .spawn(move || {
            let _ = tx.send(f());
        })
        .map_err(|e| format!("[{lane}] stage '{}': {e}", stage.name))?;
    match rx.recv_timeout(stage.bound) {
        Ok(result) => {
            let value = result.map_err(|e| format!("[{lane}] stage '{}': {e}", stage.name))?;
            stage.end(lane, started);
            Ok(value)
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(stage.overrun(lane)),
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(format!(
            "[{lane}] stage '{}' ended without a result",
            stage.name
        )),
    }
}

/// Run an async stage with its bound.
pub(crate) async fn run_async<T, Fut>(lane: &str, stage: Stage, fut: Fut) -> Result<T, String>
where
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let started = stage.begin(lane);
    match tokio::time::timeout(stage.bound, fut).await {
        Ok(result) => {
            let value = result.map_err(|e| format!("[{lane}] stage '{}': {e}", stage.name))?;
            stage.end(lane, started);
            Ok(value)
        }
        Err(_) => Err(stage.overrun(lane)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage(name: &'static str, ms: u64) -> Stage {
        Stage {
            index: 1,
            total: 4,
            name,
            bound: Duration::from_millis(ms),
        }
    }

    /// The 2026-11-01 shape: a stage that never returns. Pre-fix the launch
    /// waited 50 minutes in silence; now it fails by name within the bound.
    #[test]
    fn a_stalled_blocking_stage_fails_by_name_within_its_bound() {
        let started = Instant::now();
        let err = run_blocking("comfyui", stage("images", 100), || {
            std::thread::sleep(Duration::from_secs(30));
            Ok(())
        })
        .unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(5), "bounded");
        assert!(
            err.contains("stage 'images' did not finish within"),
            "{err}"
        );
    }

    #[tokio::test]
    async fn a_stalled_async_stage_fails_by_name_within_its_bound() {
        let started = Instant::now();
        let err = run_async(
            "comfyui",
            stage("router route", 100),
            std::future::pending::<Result<(), String>>(),
        )
        .await
        .unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(5), "bounded");
        assert!(
            err.contains("stage 'router route' did not finish within"),
            "{err}"
        );
    }

    #[test]
    fn a_stage_that_fails_names_itself_and_one_that_succeeds_returns_its_value() {
        let err = run_blocking("comfyui", stage("studio container", 5000), || {
            Err::<(), _>("image missing".to_string())
        })
        .unwrap_err();
        assert!(
            err.contains("stage 'studio container': image missing"),
            "{err}"
        );
        let v = run_blocking("comfyui", stage("images", 5000), || Ok(7)).unwrap();
        assert_eq!(v, 7);
    }
}
