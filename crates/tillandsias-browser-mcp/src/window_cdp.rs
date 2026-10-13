//! One browser window's CDP broker and its device emulation (order 1655-urz9).
//!
//! The tray holds ONE CDP session per window, for the window's lifetime,
//! over the window container's pipe relay (see `cdp_client`). Through it:
//!
//! - every page target, the first one and every popup, is auto-attached
//!   (`Target.setAutoAttach`, flattened, waiting for the debugger) and gets
//!   the window's device emulation BEFORE it runs;
//! - `set_device` re-applies a new device to every attached page live, and
//!   resizes the window to the device's CSS viewport;
//! - dropping the broker closes the session: the relay then ends Chromium,
//!   so no override outlives the session that set it.
//!
//! The emulation comes from the 1643-q3at resolver's catalogue entry:
//! `Emulation.setDeviceMetricsOverride` (CSS viewport, dpr, mobile, screen),
//! `setUserAgentOverride` (UA, `navigator.platform`, and client-hint metadata
//! for Chromium UAs), `setTouchEmulationEnabled` (maxTouchPoints) and
//! `setEmitTouchEventsForMouse`.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-core
//! @cheatsheet web/cdp.md

use parking_lot::{Condvar, Mutex};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use tillandsias_core::devices::Resolution;

use crate::cdp_client::{CdpConnection, CdpError};

/// `commands()` starts with this many touch commands.
const TOUCH_COMMANDS: usize = 2;

/// How long `attach` waits for the window's first page to be attached.
const FIRST_PAGE_BUDGET: Duration = Duration::from_secs(10);

/// What a window emulates: one resolved catalogue device.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceEmulation {
    pub id: String,
    pub model: String,
    pub approximated: bool,
    pub alternatives: Vec<String>,
    pub width: u32,
    pub height: u32,
    pub screen_width: u32,
    pub screen_height: u32,
    pub landscape: bool,
    pub dpr: f64,
    pub mobile: bool,
    pub touch: bool,
    pub max_touch_points: u32,
    pub ua: String,
    pub platform: &'static str,
    pub ua_metadata: Option<Value>,
}

impl DeviceEmulation {
    pub fn from_resolution(r: &Resolution) -> Self {
        let d = &r.device;
        let max_touch_points = if d.touch {
            d.max_touch_points.max(1)
        } else {
            0
        };
        let ua_metadata = d.ua_metadata.clone().or_else(|| {
            derived_ua_metadata(
                &r.ua,
                &d.engine,
                &d.os.name,
                &d.os.version,
                &d.model,
                d.mobile,
            )
        });
        Self {
            id: r.id.clone(),
            model: r.model.clone(),
            approximated: r.approximated,
            alternatives: r.alternatives.clone(),
            width: r.viewport.w,
            height: r.viewport.h,
            screen_width: r.screen.w,
            screen_height: r.screen.h,
            landscape: r.orientation == "landscape",
            dpr: r.dpr,
            mobile: d.mobile,
            touch: d.touch,
            max_touch_points,
            ua: r.ua.clone(),
            platform: navigator_platform(&d.os.name, &d.model),
            ua_metadata,
        }
    }

    /// The window's size at launch: the device's CSS viewport, in the
    /// host's own DIPs (never multiplied by the device's dpr).
    pub fn window_size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// The CDP commands that make a page this device, in order.
    pub fn commands(&self) -> Vec<(&'static str, Value)> {
        let orientation = if self.landscape {
            json!({ "type": "landscapePrimary", "angle": 90 })
        } else {
            json!({ "type": "portraitPrimary", "angle": 0 })
        };
        let mut ua = json!({ "userAgent": self.ua, "platform": self.platform });
        if let Some(meta) = &self.ua_metadata {
            ua["userAgentMetadata"] = meta.clone();
        }
        // Touch BEFORE metrics (measured live, 1655-urz9): Blink's mobile
        // emulation saves maxTouchPoints when it is enabled and restores that
        // value whenever Chromium re-sends the metrics (the compositor sizing
        // the window does). Set after the metrics, touch fell back to 0 on the
        // window's first page.
        vec![
            (
                "Emulation.setTouchEmulationEnabled",
                if self.touch {
                    json!({ "enabled": true, "maxTouchPoints": self.max_touch_points })
                } else {
                    json!({ "enabled": false })
                },
            ),
            (
                "Emulation.setEmitTouchEventsForMouse",
                json!({
                    "enabled": self.touch,
                    "configuration": if self.mobile { "mobile" } else { "desktop" },
                }),
            ),
            (
                "Emulation.setDeviceMetricsOverride",
                json!({
                    "width": self.width,
                    "height": self.height,
                    "deviceScaleFactor": self.dpr,
                    "mobile": self.mobile,
                    "screenWidth": self.screen_width,
                    "screenHeight": self.screen_height,
                    "screenOrientation": orientation,
                }),
            ),
            ("Emulation.setUserAgentOverride", ua),
        ]
    }

    /// The `browser.open` / `browser.set_device` answer's device block.
    pub fn summary(&self) -> Value {
        json!({
            "id": self.id,
            "model": self.model,
            "approximated": self.approximated,
            "alternatives": self.alternatives,
            "viewport": { "w": self.width, "h": self.height },
            "dpr": self.dpr,
            "mobile": self.mobile,
            "max_touch_points": self.max_touch_points,
        })
    }
}

fn navigator_platform(os: &str, model: &str) -> &'static str {
    match os {
        "ios" => "iPhone",
        "ipados" if model.contains("iPad") => "iPad",
        "ipados" => "MacIntel",
        "android" => "Linux armv81",
        "windows" => "Win32",
        "macos" => "MacIntel",
        _ => "Linux x86_64",
    }
}

/// Client-hint metadata for a Chromium UA the catalogue gives none for.
/// A Safari or Firefox UA sends no client hints, so it gets none.
fn derived_ua_metadata(
    ua: &str,
    engine: &str,
    os: &str,
    os_version: &str,
    model: &str,
    mobile: bool,
) -> Option<Value> {
    if engine != "blink" {
        return None;
    }
    let full = ua
        .split_whitespace()
        .find_map(|t| t.strip_prefix("Chrome/"))?
        .to_string();
    let major = full.split('.').next().unwrap_or(&full).to_string();
    let platform = match os {
        "android" => "Android",
        "windows" => "Windows",
        "macos" => "macOS",
        "chromeos" => "Chrome OS",
        _ => "Linux",
    };
    let brands = |v: &str| {
        json!([
            { "brand": "Chromium", "version": v },
            { "brand": "Google Chrome", "version": v },
            { "brand": "Not)A;Brand", "version": "99" },
        ])
    };
    Some(json!({
        "brands": brands(&major),
        "fullVersionList": brands(&full),
        "fullVersion": full,
        "platform": platform,
        "platformVersion": os_version,
        "architecture": if mobile { "" } else { "x86" },
        "model": if mobile { model } else { "" },
        "mobile": mobile,
    }))
}

#[derive(Debug)]
struct State {
    device: DeviceEmulation,
    /// Attached page sessions, the window's first page first.
    pages: Vec<String>,
}

/// One window's CDP session.
pub struct WindowCdp {
    conn: Arc<CdpConnection>,
    state: Arc<(Mutex<State>, Condvar)>,
}

impl std::fmt::Debug for WindowCdp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WindowCdp")
            .field("state", &self.state.0.lock())
            .finish_non_exhaustive()
    }
}

fn apply(conn: &CdpConnection, session: &str, device: &DeviceEmulation) -> Result<(), CdpError> {
    for (method, params) in device.commands() {
        conn.call(Some(session), method, params)
            .map_err(|e| match e {
                CdpError::ProtocolError { code, message } => CdpError::ProtocolError {
                    code,
                    message: format!("{method}: {message}"),
                },
                other => other,
            })?;
    }
    Ok(())
}

impl WindowCdp {
    /// Connect to a window's relay socket and take over its pages.
    pub fn attach(
        socket: &Path,
        device: DeviceEmulation,
        budget: Duration,
    ) -> Result<Self, CdpError> {
        let conn = Arc::new(CdpConnection::connect(socket, budget)?);
        Self::start(conn, device)
    }

    /// Take over a connected window: auto-attach every page, emulate the
    /// device on each before it runs, and wait for the first page.
    pub fn start(conn: Arc<CdpConnection>, device: DeviceEmulation) -> Result<Self, CdpError> {
        let events = conn.take_events().ok_or_else(|| {
            CdpError::ConnectionFailed("the event stream is already taken".into())
        })?;
        let state = Arc::new((
            Mutex::new(State {
                device,
                pages: Vec::new(),
            }),
            Condvar::new(),
        ));
        let worker_conn = Arc::clone(&conn);
        let worker_state = Arc::clone(&state);
        std::thread::Builder::new()
            .name("cdp-window".into())
            .spawn(move || handle_events(events, &worker_conn, &worker_state))?;
        conn.call(
            None,
            "Target.setAutoAttach",
            json!({ "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true }),
        )?;
        let window = Self { conn, state };
        window.await_first_page(FIRST_PAGE_BUDGET)?;
        // The event worker emulated the page as it attached, but only logs a
        // failure there; re-applying here (idempotent) makes one fatal.
        let (page, device) = {
            let state = window.state.0.lock();
            (state.pages[0].clone(), state.device.clone())
        };
        apply(&window.conn, &page, &device)?;
        Ok(window)
    }

    fn await_first_page(&self, budget: Duration) -> Result<(), CdpError> {
        let deadline = Instant::now() + budget;
        let (lock, ready) = &*self.state;
        let mut state = lock.lock();
        while state.pages.is_empty() {
            if ready.wait_until(&mut state, deadline).timed_out() {
                return Err(CdpError::WindowNotRunning(
                    "the window's page never attached".into(),
                ));
            }
        }
        Ok(())
    }

    /// The window's first page session.
    pub fn main_session(&self) -> Option<String> {
        self.state.0.lock().pages.first().cloned()
    }

    pub fn device(&self) -> DeviceEmulation {
        self.state.0.lock().device.clone()
    }

    pub fn connection(&self) -> &CdpConnection {
        &self.conn
    }

    /// Load `url` in the window's page (it starts on about:blank, so the
    /// first request already carries the device's UA).
    pub fn navigate(&self, url: &str) -> Result<(), CdpError> {
        let session = self
            .main_session()
            .ok_or_else(|| CdpError::WindowNotRunning("no page".into()))?;
        let result = self
            .conn
            .call(Some(&session), "Page.navigate", json!({ "url": url }))?;
        match result.get("errorText").and_then(Value::as_str) {
            Some(err) if !err.is_empty() => Err(CdpError::ProtocolError {
                code: -1,
                message: format!("navigation to {url} failed: {err}"),
            }),
            _ => Ok(()),
        }
    }

    /// Switch the live window to another device: every attached page, and
    /// the window's size (best effort: a compositor may refuse a resize).
    pub fn set_device(&self, device: DeviceEmulation) -> Result<(), CdpError> {
        let pages = {
            let mut state = self.state.0.lock();
            state.device = device.clone();
            state.pages.clone()
        };
        for page in &pages {
            apply(&self.conn, page, &device)?;
        }
        if let Some(page) = pages.first()
            && let Ok(window) = self
                .conn
                .call(Some(page), "Browser.getWindowForTarget", json!({}))
            && let Some(window_id) = window.get("windowId")
        {
            let (w, h) = device.window_size();
            let _ = self.conn.call(
                None,
                "Browser.setWindowBounds",
                json!({ "windowId": window_id, "bounds": { "width": w, "height": h, "windowState": "normal" } }),
            );
        }
        Ok(())
    }
}

impl Drop for WindowCdp {
    fn drop(&mut self) {
        self.conn.shutdown();
    }
}

/// Re-assert the touch half of the emulation on one page.
///
/// Measured live (1655-urz9): after the window's first cross-process commit
/// (about:blank → the project's site) the page's `navigator.maxTouchPoints`
/// fell back to 0 a moment after its first script had read 5, while the
/// viewport, dpr and UA held; same-site navigations kept it. So the broker
/// re-applies touch on every main-frame commit and load.
fn reassert_touch(conn: &CdpConnection, session: &str, state: &(Mutex<State>, Condvar)) {
    let device = state.0.lock().device.clone();
    for (method, params) in device.commands().into_iter().take(TOUCH_COMMANDS) {
        if let Err(err) = conn.call(Some(session), method, params) {
            tracing::warn!(%err, session, method, "browser window: touch re-assert failed");
        }
    }
}

fn handle_events(
    events: mpsc::Receiver<Value>,
    conn: &CdpConnection,
    state: &(Mutex<State>, Condvar),
) {
    for event in events {
        let params = &event["params"];
        let event_session = event["sessionId"].as_str();
        match event["method"].as_str() {
            Some("Page.frameNavigated") if params["frame"].get("parentId").is_none() => {
                if let Some(session) = event_session {
                    reassert_touch(conn, session, state);
                }
            }
            Some("Page.loadEventFired") => {
                if let Some(session) = event_session {
                    reassert_touch(conn, session, state);
                }
            }
            Some("Target.attachedToTarget") => {
                let Some(session) = params["sessionId"].as_str() else {
                    continue;
                };
                if params["targetInfo"]["type"] == "page" {
                    let device = state.0.lock().device.clone();
                    if let Err(err) = apply(conn, session, &device)
                        .and_then(|()| conn.call(Some(session), "Page.enable", json!({})).map(drop))
                    {
                        tracing::warn!(%err, session, "browser window: device emulation failed");
                    }
                    let (lock, ready) = state;
                    lock.lock().pages.push(session.to_string());
                    ready.notify_all();
                }
                if params["waitingForDebugger"] == true {
                    let _ = conn.call(Some(session), "Runtime.runIfWaitingForDebugger", json!({}));
                }
            }
            Some("Target.detachedFromTarget") => {
                if let Some(session) = params["sessionId"].as_str() {
                    state.0.lock().pages.retain(|p| p != session);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cdp_client::tests::FakeChromium;
    use tillandsias_core::devices::resolve;

    fn device(q: &str) -> DeviceEmulation {
        DeviceEmulation::from_resolution(&resolve(q).expect(q))
    }

    #[test]
    fn iphone_12_pro_max_emulates_428_at_3x_with_touch_and_no_client_hints() {
        let d = device("iphone 12 pro max");
        assert_eq!((d.width, d.height, d.dpr), (428, 926, 3.0));
        assert!(d.mobile && d.touch && d.max_touch_points > 0);
        assert_eq!(d.window_size(), (428, 926), "CSS px, not device px");
        assert!(d.ua.contains("iPhone"));
        assert_eq!(d.platform, "iPhone");
        assert!(d.ua_metadata.is_none(), "Safari sends no client hints");
        let cmds = d.commands();
        let names: Vec<&str> = cmds.iter().map(|(m, _)| *m).collect();
        assert_eq!(
            names,
            [
                "Emulation.setTouchEmulationEnabled",
                "Emulation.setEmitTouchEventsForMouse",
                "Emulation.setDeviceMetricsOverride",
                "Emulation.setUserAgentOverride",
            ],
            "touch first: a metrics re-send restores the touch points saved before it"
        );
        assert_eq!(cmds[2].1["width"], 428);
        assert_eq!(cmds[2].1["deviceScaleFactor"], 3.0);
        assert_eq!(cmds[2].1["mobile"], true);
        assert_eq!(cmds[0].1["maxTouchPoints"], d.max_touch_points);
    }

    #[test]
    fn an_android_chrome_ua_gets_client_hint_metadata() {
        let d = device("galaxy s24");
        assert!(d.ua.contains("Android"));
        let meta = d.ua_metadata.clone().expect("Chromium UA: client hints");
        assert_eq!(meta["platform"], "Android");
        assert_eq!(meta["mobile"], true);
        assert!(meta["brands"].as_array().is_some_and(|b| !b.is_empty()));
        let ua_cmd = &d.commands()[3].1;
        assert_eq!(ua_cmd["userAgentMetadata"]["platform"], "Android");
    }

    #[test]
    fn desktop_turns_touch_off() {
        let d = device("desktop");
        assert!(!d.mobile && !d.touch);
        assert_eq!(d.max_touch_points, 0);
        assert_eq!(d.commands()[0].1, json!({ "enabled": false }));
    }

    /// Chromium answers `Target.setAutoAttach` by attaching its existing page
    /// (not waiting); a popup arrives later, waiting for the debugger.
    fn auto_attaching_chromium() -> (Arc<CdpConnection>, FakeChromium) {
        let (conn, chromium) = FakeChromium::start(|m| match m["method"].as_str() {
            Some("Browser.getWindowForTarget") => Some(json!({ "windowId": 7 })),
            _ => None,
        });
        (Arc::new(conn), chromium)
    }

    fn attached(session: &str, kind: &str, waiting: bool) -> Value {
        json!({ "method": "Target.attachedToTarget", "params": {
            "sessionId": session,
            "targetInfo": { "type": kind, "targetId": format!("T-{session}") },
            "waitingForDebugger": waiting,
        }})
    }

    #[test]
    fn every_page_is_emulated_before_it_runs_and_set_device_switches_them_all() {
        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start(Arc::clone(&conn), device("iphone 12 pro max")).unwrap();
        assert_eq!(window.main_session().as_deref(), Some("P1"));

        // A popup: emulated, THEN released.
        chromium.emit(attached("P2", "page", true));
        chromium.emit(attached("W1", "service_worker", true));
        let deadline = Instant::now() + Duration::from_secs(2);
        while chromium
            .methods()
            .iter()
            .filter(|(m, _)| m == "Runtime.runIfWaitingForDebugger")
            .count()
            < 2
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        let seen = chromium.methods();
        let on = |s: &str| -> Vec<String> {
            seen.iter()
                .filter(|(_, sid)| sid.as_deref() == Some(s))
                .map(|(m, _)| m.clone())
                .collect()
        };
        assert_eq!(seen[0], ("Target.setAutoAttach".to_string(), None));
        assert_eq!(
            on("P1").len(),
            9,
            "attach, Page.enable, the checked re-apply: {seen:?}"
        );
        let p2 = on("P2");
        assert_eq!(p2.len(), 6, "{seen:?}");
        assert_eq!(p2[4], "Page.enable");
        assert_eq!(p2.last().unwrap(), "Runtime.runIfWaitingForDebugger");
        assert_eq!(
            on("W1"),
            ["Runtime.runIfWaitingForDebugger"],
            "workers are not emulated"
        );

        window
            .navigate("https://www.demo.localhost:18443/")
            .unwrap();
        window.set_device(device("galaxy s24")).unwrap();
        let seen = chromium.seen.lock().clone();
        let metrics: Vec<&Value> = seen
            .iter()
            .filter(|m| m["method"] == "Emulation.setDeviceMetricsOverride")
            .map(|m| &m["params"])
            .collect();
        let s24 = device("galaxy s24");
        assert_eq!(metrics.len(), 5, "P1 twice and P2 once before, both after");
        assert!(metrics[3..].iter().all(|p| p["width"] == s24.width));
        let bounds = seen
            .iter()
            .find(|m| m["method"] == "Browser.setWindowBounds")
            .expect("resized");
        assert_eq!(bounds["params"]["bounds"]["width"], s24.width);
        assert_eq!(window.device().id, s24.id);
    }

    #[test]
    fn touch_is_reasserted_on_every_main_frame_commit_and_load() {
        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let _window = WindowCdp::start(Arc::clone(&conn), device("iphone 12 pro max")).unwrap();
        let before = chromium.methods().len();
        chromium.emit(json!({ "method": "Page.frameNavigated", "sessionId": "P1",
            "params": { "frame": { "id": "F1", "url": "https://www.demo.localhost/" } } }));
        chromium.emit(json!({ "method": "Page.frameNavigated", "sessionId": "P1",
            "params": { "frame": { "id": "F2", "parentId": "F1" } } }));
        chromium.emit(json!({ "method": "Page.loadEventFired", "sessionId": "P1", "params": {} }));
        let deadline = Instant::now() + Duration::from_secs(2);
        while chromium.methods().len() < before + 4 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        std::thread::sleep(Duration::from_millis(100));
        let after: Vec<String> = chromium.methods()[before..]
            .iter()
            .map(|(m, _)| m.clone())
            .collect();
        assert_eq!(
            after,
            [
                "Emulation.setTouchEmulationEnabled",
                "Emulation.setEmitTouchEventsForMouse",
                "Emulation.setTouchEmulationEnabled",
                "Emulation.setEmitTouchEventsForMouse",
            ],
            "main-frame commit and load re-assert touch; a subframe commit does not"
        );
    }

    #[test]
    fn a_window_whose_page_never_attaches_is_an_error() {
        let (conn, _chromium) = auto_attaching_chromium();
        let window = WindowCdp {
            conn,
            state: Arc::new((
                Mutex::new(State {
                    device: device("desktop"),
                    pages: Vec::new(),
                }),
                Condvar::new(),
            )),
        };
        assert!(matches!(
            window.await_first_page(Duration::from_millis(100)),
            Err(CdpError::WindowNotRunning(_))
        ));
    }

    #[test]
    fn dropping_the_broker_closes_the_session() {
        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start(Arc::clone(&conn), device("desktop")).unwrap();
        drop(window);
        let mut buf = [0u8; 1];
        let mut peer = chromium.peer.try_clone().unwrap();
        peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        // The fake's reader thread owns the read side; the peer sees EOF on
        // its next read once our end is shut down.
        let _ = std::io::Read::read(&mut peer, &mut buf);
        assert!(conn.call(None, "Browser.getVersion", json!({})).is_err());
    }
}
