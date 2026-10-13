//! Chrome DevTools Protocol (CDP) client over a browser window's pipe relay.
//!
//! Order 1655-urz9. A window's Chromium runs with `--remote-debugging-pipe`
//! inside its container: DevTools is NUL-framed JSON on the child's fds 3/4,
//! never a TCP port. The container's relay serves that pipe on a Unix socket
//! in a per-window directory only the tray mounts, for exactly one client.
//! This is that client.
//!
//! - Framing: each message is one JSON object followed by a NUL byte, in
//!   both directions. (The old client wrote this pipe framing to an HTTP
//!   DevTools port, which never worked.)
//! - The connection is browser-level. Page commands carry the flattened
//!   `sessionId` from `Target.attachToTarget`/`Target.setAutoAttach`.
//! - One reader thread routes replies to their caller by id and every event
//!   to one event channel (`take_events`), so an event handler may itself
//!   issue commands without deadlocking the reader.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-core, spec:cdp-robustness, gap:BR-005
//! @cheatsheet web/cdp.md

use base64::Engine;
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;
use thiserror::Error;

/// Every command's reply budget.
/// @trace spec:cdp-robustness
pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Error)]
pub enum CdpError {
    #[error("window not running: {0}")]
    WindowNotRunning(String),
    #[error("CDP connection failed: {0}")]
    ConnectionFailed(String),
    #[error("CDP request timeout")]
    Timeout,
    #[error("CDP protocol error: {message} (code: {code})")]
    ProtocolError { code: i32, message: String },
    #[error("screenshot failed: {0}")]
    ScreenshotFailed(String),
    #[error("element not found: selector {selector}")]
    ElementNotFound { selector: String },
    #[error("click failed: {0}")]
    ClickFailed(String),
    #[error("type failed: {0}")]
    TypeFailed(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// This host has no transport to a window's CDP relay yet (the relay is
    /// a Unix socket; a Windows/WSLg path brings its own transport).
    #[error("CDP unsupported on this host: {0}")]
    Unsupported(String),
}

type Pending = Arc<Mutex<HashMap<u64, mpsc::Sender<Result<Value, CdpError>>>>>;

/// One browser-level CDP connection, over any byte transport (the relay's
/// Unix socket on Unix hosts).
pub struct CdpConnection {
    writer: Mutex<Box<dyn Write + Send>>,
    close: Box<dyn Fn() + Send + Sync>,
    pending: Pending,
    next_id: AtomicU64,
    events: Mutex<Option<mpsc::Receiver<Value>>>,
}

impl CdpConnection {
    /// Connect to a relay socket, waiting up to `budget` for the relay to
    /// create it (the container is still starting when this is called).
    #[cfg(unix)]
    pub fn connect(socket: &Path, budget: Duration) -> Result<Self, CdpError> {
        let deadline = Instant::now() + budget;
        loop {
            match UnixStream::connect(socket) {
                Ok(stream) => return Self::from_stream(stream),
                Err(e) if Instant::now() >= deadline => {
                    return Err(CdpError::ConnectionFailed(format!(
                        "{} did not accept within {budget:?}: {e}",
                        socket.display()
                    )));
                }
                Err(_) => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    }

    /// No Unix sockets in std here: a typed refusal, never a silent no-op.
    #[cfg(not(unix))]
    pub fn connect(socket: &Path, _budget: Duration) -> Result<Self, CdpError> {
        Err(CdpError::Unsupported(format!(
            "the window CDP relay ({}) is a Unix socket; this host has no transport for it",
            socket.display()
        )))
    }

    /// Wrap an already connected Unix stream (a relay socket, or a test pair).
    #[cfg(unix)]
    pub fn from_stream(stream: UnixStream) -> Result<Self, CdpError> {
        let reader = stream.try_clone()?;
        let closer = stream.try_clone()?;
        Self::from_io(reader, stream, move || {
            let _ = closer.shutdown(std::net::Shutdown::Both);
        })
    }

    /// Wrap a connected transport: its read half, its write half, and how
    /// to close both (which must end the read half too).
    pub fn from_io(
        reader: impl Read + Send + 'static,
        writer: impl Write + Send + 'static,
        close: impl Fn() + Send + Sync + 'static,
    ) -> Result<Self, CdpError> {
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let (event_tx, event_rx) = mpsc::channel();
        let routes = Arc::clone(&pending);
        std::thread::Builder::new()
            .name("cdp-reader".into())
            .spawn(move || read_loop(reader, routes, event_tx))?;
        Ok(Self {
            writer: Mutex::new(Box::new(writer)),
            close: Box::new(close),
            pending,
            next_id: AtomicU64::new(0),
            events: Mutex::new(Some(event_rx)),
        })
    }

    /// Close the connection: the relay then ends the window's Chromium.
    pub fn shutdown(&self) {
        (self.close)();
    }

    /// The event stream (every message without an `id`). Taken once.
    pub fn take_events(&self) -> Option<mpsc::Receiver<Value>> {
        self.events.lock().take()
    }

    /// Send one command and wait for its reply. `session` is the flattened
    /// target session, or `None` for the browser itself.
    /// @trace spec:cdp-robustness
    pub fn call(
        &self,
        session: Option<&str>,
        method: &str,
        params: Value,
    ) -> Result<Value, CdpError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let mut message = json!({ "id": id, "method": method, "params": params });
        if let Some(session) = session {
            message["sessionId"] = Value::String(session.to_string());
        }
        let mut frame = serde_json::to_vec(&message).map_err(|e| CdpError::ProtocolError {
            code: -32700,
            message: format!("JSON encode error: {e}"),
        })?;
        frame.push(0);
        let (tx, rx) = mpsc::channel();
        self.pending.lock().insert(id, tx);
        let written = {
            let mut writer = self.writer.lock();
            writer.write_all(&frame).and_then(|()| writer.flush())
        };
        if let Err(e) = written {
            self.pending.lock().remove(&id);
            return Err(CdpError::ConnectionFailed(format!("write failed: {e}")));
        }
        match rx.recv_timeout(COMMAND_TIMEOUT) {
            Ok(reply) => reply,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.pending.lock().remove(&id);
                Err(CdpError::Timeout)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(CdpError::ConnectionFailed(
                "the relay closed the connection".into(),
            )),
        }
    }

    /// Capture a screenshot of the page behind `session`.
    pub fn screenshot(&self, session: &str, full_page: bool) -> Result<Vec<u8>, CdpError> {
        let result = self.call(
            Some(session),
            "Page.captureScreenshot",
            json!({ "format": "png", "captureBeyondViewport": full_page }),
        )?;
        let data = result
            .get("data")
            .and_then(Value::as_str)
            .ok_or_else(|| CdpError::ScreenshotFailed("no data in response".to_string()))?;
        base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|e| CdpError::ScreenshotFailed(format!("base64 decode error: {e}")))
    }

    /// Click the element matching a CSS selector.
    pub fn click(&self, session: &str, selector: &str) -> Result<(), CdpError> {
        let expression = format!(
            "(function() {{ const el = document.querySelector({sel}); \
             if (!el) throw new Error('Element not found'); el.click(); return true; }})()",
            sel = js_string(selector)
        );
        self.evaluate_checked(session, &expression, selector, CdpError::ClickFailed)
    }

    /// Type text into the element matching a CSS selector.
    pub fn type_text(&self, session: &str, selector: &str, text: &str) -> Result<(), CdpError> {
        let expression = format!(
            "(function() {{ const el = document.querySelector({sel}); \
             if (!el) throw new Error('Element not found'); el.focus(); el.value = {text}; \
             el.dispatchEvent(new Event('input', {{ bubbles: true }})); \
             el.dispatchEvent(new Event('change', {{ bubbles: true }})); return true; }})()",
            sel = js_string(selector),
            text = js_string(text)
        );
        self.evaluate_checked(session, &expression, selector, CdpError::TypeFailed)
    }

    fn evaluate_checked(
        &self,
        session: &str,
        expression: &str,
        selector: &str,
        failed: fn(String) -> CdpError,
    ) -> Result<(), CdpError> {
        let result = self.call(
            Some(session),
            "Runtime.evaluate",
            json!({ "expression": expression, "returnByValue": true }),
        )?;
        if let Some(details) = result.get("exceptionDetails") {
            let text = details
                .pointer("/exception/description")
                .or_else(|| details.get("text"))
                .and_then(Value::as_str)
                .unwrap_or("unknown error");
            if text.contains("Element not found") {
                return Err(CdpError::ElementNotFound {
                    selector: selector.to_string(),
                });
            }
            return Err(failed(text.to_string()));
        }
        Ok(())
    }
}

/// A JavaScript string literal for `s` (JSON is a subset of JS literals),
/// so a selector or text can never break out of the expression.
fn js_string(s: &str) -> String {
    Value::String(s.to_string()).to_string()
}

fn read_loop(stream: impl Read, pending: Pending, events: mpsc::Sender<Value>) {
    let mut reader = BufReader::new(stream);
    let mut frame = Vec::new();
    loop {
        frame.clear();
        match reader.read_until(0, &mut frame) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if frame.last() == Some(&0) {
            frame.pop();
        }
        let Ok(message) = serde_json::from_slice::<Value>(&frame) else {
            continue;
        };
        match message.get("id").and_then(Value::as_u64) {
            Some(id) => {
                let Some(reply) = pending.lock().remove(&id) else {
                    continue;
                };
                let result = match message.get("error") {
                    Some(error) => Err(CdpError::ProtocolError {
                        code: error.get("code").and_then(Value::as_i64).unwrap_or(-1) as i32,
                        message: error
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown error")
                            .to_string(),
                    }),
                    None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                };
                let _ = reply.send(result);
            }
            None => {
                let _ = events.send(message);
            }
        }
    }
    // The relay is gone: fail every waiting caller now, not at its timeout.
    pending.lock().clear();
}

#[cfg(all(test, not(unix)))]
mod tests_non_unix {
    use super::*;

    #[test]
    fn connect_is_a_typed_refusal_without_unix_sockets() {
        assert!(matches!(
            CdpConnection::connect(Path::new("cdp.sock"), Duration::from_millis(10)),
            Err(CdpError::Unsupported(_))
        ));
    }
}

#[cfg(all(test, unix))]
pub(crate) mod tests {
    use super::*;
    use std::io::Read;

    /// A scripted stand-in for Chromium's end of the pipe: answers each
    /// command with `reply(method, params)`, and records what it was sent.
    pub(crate) struct FakeChromium {
        pub(crate) seen: Arc<Mutex<Vec<Value>>>,
        pub(crate) peer: UnixStream,
    }

    impl FakeChromium {
        pub(crate) fn start(
            reply: impl Fn(&Value) -> Option<Value> + Send + 'static,
        ) -> (CdpConnection, FakeChromium) {
            let (ours, theirs) = UnixStream::pair().unwrap();
            let seen = Arc::new(Mutex::new(Vec::new()));
            let log = Arc::clone(&seen);
            let mut writer = theirs.try_clone().unwrap();
            let peer = theirs.try_clone().unwrap();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(theirs);
                let mut frame = Vec::new();
                loop {
                    frame.clear();
                    match reader.read_until(0, &mut frame) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    frame.pop();
                    let msg: Value = serde_json::from_slice(&frame).unwrap();
                    log.lock().push(msg.clone());
                    let result = reply(&msg).unwrap_or_else(|| json!({}));
                    let mut answer = json!({ "id": msg["id"], "result": result });
                    if let Some(s) = msg.get("sessionId") {
                        answer["sessionId"] = s.clone();
                    }
                    let mut out = serde_json::to_vec(&answer).unwrap();
                    out.push(0);
                    if writer.write_all(&out).is_err() {
                        break;
                    }
                }
            });
            (
                CdpConnection::from_stream(ours).unwrap(),
                FakeChromium { seen, peer },
            )
        }

        /// Push an event at the client, as Chromium would.
        pub(crate) fn emit(&self, event: Value) {
            let mut out = serde_json::to_vec(&event).unwrap();
            out.push(0);
            (&self.peer).write_all(&out).unwrap();
        }

        pub(crate) fn methods(&self) -> Vec<(String, Option<String>)> {
            self.seen
                .lock()
                .iter()
                .map(|m| {
                    (
                        m["method"].as_str().unwrap_or("").to_string(),
                        m.get("sessionId")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    )
                })
                .collect()
        }
    }

    #[test]
    fn commands_are_nul_framed_json_with_increasing_ids_and_the_session() {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let conn = CdpConnection::from_stream(ours).unwrap();
        std::thread::spawn(move || {
            let _ = conn.call(None, "Browser.getVersion", json!({}));
            let _ = conn.call(Some("S1"), "Page.navigate", json!({ "url": "about:blank" }));
        });
        let mut got = Vec::new();
        let mut buf = [0u8; 512];
        theirs
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        while got.iter().filter(|b| **b == 0).count() < 1 {
            let n = theirs.read(&mut buf).unwrap();
            got.extend_from_slice(&buf[..n]);
        }
        let first: Vec<&[u8]> = got.split(|b| *b == 0).collect();
        let msg: Value = serde_json::from_slice(first[0]).unwrap();
        assert_eq!(msg["id"], 1);
        assert_eq!(msg["method"], "Browser.getVersion");
        assert!(msg.get("sessionId").is_none());
    }

    #[test]
    fn replies_route_by_id_and_events_go_to_the_event_channel() {
        let (conn, chromium) = FakeChromium::start(|m| match m["method"].as_str() {
            Some("Browser.getVersion") => Some(json!({ "product": "Chrome/154" })),
            _ => None,
        });
        let events = conn.take_events().unwrap();
        assert!(
            conn.take_events().is_none(),
            "the event stream is taken once"
        );
        chromium.emit(json!({ "method": "Target.targetCreated", "params": {} }));
        let v = conn.call(None, "Browser.getVersion", json!({})).unwrap();
        assert_eq!(v["product"], "Chrome/154");
        let e = events.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(e["method"], "Target.targetCreated");
        let r = conn.call(Some("S9"), "Page.enable", json!({})).unwrap();
        assert_eq!(r, json!({}));
        assert_eq!(
            chromium.methods().last().unwrap(),
            &("Page.enable".to_string(), Some("S9".to_string()))
        );
    }

    #[test]
    fn a_protocol_error_is_an_error() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let conn = CdpConnection::from_stream(ours).unwrap();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(theirs.try_clone().unwrap());
            let mut frame = Vec::new();
            reader.read_until(0, &mut frame).unwrap();
            let mut out =
                br#"{"id":1,"error":{"code":-32601,"message":"'Nope.nope' wasn't found"}}"#
                    .to_vec();
            out.push(0);
            (&theirs).write_all(&out).unwrap();
        });
        match conn.call(None, "Nope.nope", json!({})) {
            Err(CdpError::ProtocolError { code, message }) => {
                assert_eq!(code, -32601);
                assert!(message.contains("wasn't found"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_closed_relay_fails_the_caller_at_once() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let conn = CdpConnection::from_stream(ours).unwrap();
        drop(theirs);
        let started = Instant::now();
        assert!(conn.call(None, "Browser.getVersion", json!({})).is_err());
        assert!(started.elapsed() < COMMAND_TIMEOUT);
    }

    #[test]
    fn connect_gives_up_after_its_budget() {
        let dir = tempfile::tempdir().unwrap();
        let err =
            CdpConnection::connect(&dir.path().join("absent.sock"), Duration::from_millis(250));
        assert!(matches!(err, Err(CdpError::ConnectionFailed(_))));
    }

    #[test]
    fn selectors_and_text_are_quoted_as_js_string_literals() {
        assert_eq!(js_string("a[x='y']"), r#""a[x='y']""#);
        assert_eq!(js_string("\"); alert(1); (\""), r#""\"); alert(1); (\"""#);
    }

    #[test]
    fn click_reports_a_missing_element() {
        let (conn, _chromium) = FakeChromium::start(|_| {
            Some(
                json!({ "exceptionDetails": { "text": "Uncaught", "exception": { "description": "Error: Element not found" } } }),
            )
        });
        assert!(matches!(
            conn.click("S1", "#nope"),
            Err(CdpError::ElementNotFound { .. })
        ));
        assert!(matches!(
            conn.type_text("S1", "#nope", "x"),
            Err(CdpError::ElementNotFound { .. })
        ));
    }

    #[test]
    fn screenshot_decodes_the_png_and_requires_data() {
        let (conn, _c) = FakeChromium::start(|_| Some(json!({ "data": "iVBORw==" })));
        assert_eq!(conn.screenshot("S1", false).unwrap(), b"\x89PNG");
        let (conn, _c) = FakeChromium::start(|_| Some(json!({})));
        assert!(matches!(
            conn.screenshot("S1", true),
            Err(CdpError::ScreenshotFailed(_))
        ));
    }
}
