//! The process-wide destination for typed progress events (order 1420-4grt).
//!
//! Emitters (image builds today) call [`publish`] without knowing whether a
//! control wire exists. The vsock server, when this process runs one, calls
//! [`install`] once at startup so every event reaches its `Progress`
//! subscribers. With nothing installed, [`publish`] is a no-op: a CLI run on a
//! host has no subscribers to reach.
//!
//! This covers emitters in the SAME process as the server. A guest command
//! run as a separate child process (the relayed `--init` / `--github-login`)
//! needs a bridge from its output to [`publish`]; that is the next slice of
//! 1420-4grt.
//!
//! @trace order:1420-4grt

use std::sync::OnceLock;
use tillandsias_control_wire::ProgressEvent;

type Sink = Box<dyn Fn(ProgressEvent) + Send + Sync>;

static SINK: OnceLock<Sink> = OnceLock::new();

/// Install the sink. The first install wins; a second returns `false` rather
/// than silently redirecting events that other code already relies on.
#[cfg_attr(not(feature = "listen-vsock"), allow(dead_code))]
pub fn install(sink: impl Fn(ProgressEvent) + Send + Sync + 'static) -> bool {
    SINK.set(Box::new(sink)).is_ok()
}

/// Deliver one event to the installed sink, if any.
pub fn publish(event: ProgressEvent) {
    if let Some(sink) = SINK.get() {
        sink(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tillandsias_control_wire::ProgressKind;

    static SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());

    /// One test owns the process-wide sink: OnceLock cannot be reset, so the
    /// install-once and delivery properties are asserted together.
    #[test]
    fn install_once_then_publish_delivers() {
        let first = install(|e| SEEN.lock().unwrap().push(e.task));
        assert!(first, "the first install must win");
        assert!(!install(|_| {}), "a second install must be refused");
        publish(ProgressEvent {
            task: "init/build/forge".into(),
            parent: None,
            label: "forge".into(),
            kind: ProgressKind::Done,
            ts_unix_ms: 0,
        });
        assert_eq!(*SEEN.lock().unwrap(), vec!["init/build/forge".to_string()]);
    }
}
