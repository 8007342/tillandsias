//! One browser window's CDP broker and its device e                            .try_for_each(|(m, p)| conn.call(Some(session), m, p.clone()).map(drop))ulation (order 1655-urz9).
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
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use tillandsias_core::devices::Resolution;

use crate::cdp_client::{CdpConnection, CdpError};

/// How often one navigation is re-tried through a transient network change,
/// for its document and its subresources together (1656-iktu, 1725-cgh2).
const NAVIGATE_ATTEMPTS: u32 = 4;

/// The error Chromium gives every in-flight request when it sees the host's
/// addresses change: a freshly started window's IPv6 address settling, a
/// suspend/resume, a VPN coming up.
const NETWORK_CHANGED: &str = "net::ERR_NETWORK_CHANGED";

/// How long after a navigation starts its requests are watched for
/// NETWORK_CHANGED (1725-cgh2). A page's late subresources (an app bundle
/// loaded after the load event) are inside it; a network change an hour
/// later on a long-lived page is not this guard's business.
const NAVIGATION_WATCH: Duration = Duration::from_secs(15);

/// How long `navigate` waits for the page's load event, so a recovery during
/// it is known when browser.open answers. Best effort: a slower page simply
/// returns before it loads, still watched.
#[cfg(not(test))]
const LOAD_WAIT: Duration = Duration::from_secs(8);
#[cfg(test)]
const LOAD_WAIT: Duration = Duration::from_millis(300);

/// `commands()` starts with this many touch commands.
const TOUCH_COMMANDS: usize = 2;

/// How long `attach` waits for the window's first page to be attached.
const FIRST_PAGE_BUDGET: Duration = Duration::from_secs(10);

/// What a window emulates: one resolved catalogue device.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceEmulation {
    pub id: String,
    /// The catalogue's engine for this device: blink | webkit | gecko.
    pub engine: String,
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
            engine: d.engine.clone(),
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

    /// Playwright `browser.newContext` options for this device: what a
    /// WebKit window applies (order 1656-tjv4), the counterpart of the CDP
    /// commands above.
    pub fn playwright_context(&self) -> Value {
        json!({
            "viewport": { "width": self.width, "height": self.height },
            "deviceScaleFactor": self.dpr,
            "isMobile": self.mobile,
            "hasTouch": self.touch,
            "userAgent": self.ua,
        })
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

/// How many console and network entries a dev-mode window keeps.
const TAIL_CAPACITY: usize = 500;

#[derive(Debug)]
struct State {
    device: DeviceEmulation,
    /// Attached page sessions, the window's first page first.
    pages: Vec<String>,
    /// Development mode (order 1656-iktu): Runtime and Network are enabled
    /// on every page and their events kept for the tails.
    dev: bool,
    console: VecDeque<Value>,
    network: VecDeque<Value>,
    /// The main page's current navigation (order 1725-cgh2).
    watch: Option<NavigationWatch>,
    /// Which navigation (loaderId) each of the main page's requests belongs
    /// to, so a request of an ABANDONED load failing late is never mistaken
    /// for the current one. Cleared per navigation.
    loader_of: HashMap<String, String>,
    /// Re-navigations the guard made, for browser.open's notice.
    recoveries: u32,
    /// Order 1725-5uue: a dev window keeps its pages' service workers only
    /// when asked; otherwise every page bypasses them, so a dead preview
    /// reads as dead instead of a cached build.
    keep_service_worker: bool,
    /// The service-worker scripts the pages registered (kept mode only).
    workers: Vec<String>,
}

/// A navigation the window verifies: every request it makes, the document
/// and every subresource, must not die of NETWORK_CHANGED. One that does
/// re-navigates, bounded by NAVIGATE_ATTEMPTS.
#[derive(Debug)]
struct NavigationWatch {
    session: String,
    url: String,
    started: Instant,
    /// The loaderId of the current attempt; None until Page.navigate answers
    /// (its requests may be reported first, and count as the current one).
    loader: Option<String>,
    /// Loads this navigation abandoned: their requests keep failing after
    /// the re-navigation, and none of them may start another.
    abandoned: Vec<String>,
    attempts: u32,
    loaded: bool,
}

fn push_capped(buf: &mut VecDeque<Value>, entry: Value) {
    if buf.len() == TAIL_CAPACITY {
        buf.pop_front();
    }
    buf.push_back(entry);
}

fn tail(buf: &VecDeque<Value>, limit: usize) -> Vec<Value> {
    buf.iter()
        .skip(buf.len().saturating_sub(limit))
        .cloned()
        .collect()
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
        dev: bool,
        keep_service_worker: bool,
        budget: Duration,
    ) -> Result<Self, CdpError> {
        let conn = Arc::new(CdpConnection::connect(socket, budget)?);
        Self::start_with(conn, device, dev, keep_service_worker)
    }

    /// Take over a connected window: auto-attach every page, emulate the
    /// device on each before it runs, and wait for the first page.
    pub fn start(
        conn: Arc<CdpConnection>,
        device: DeviceEmulation,
        dev: bool,
    ) -> Result<Self, CdpError> {
        Self::start_with(conn, device, dev, false)
    }

    /// [`Self::start`], keeping the pages' service workers when
    /// `keep_service_worker` (order 1725-5uue).
    pub fn start_with(
        conn: Arc<CdpConnection>,
        device: DeviceEmulation,
        dev: bool,
        keep_service_worker: bool,
    ) -> Result<Self, CdpError> {
        let events = conn.take_events().ok_or_else(|| {
            CdpError::ConnectionFailed("the event stream is already taken".into())
        })?;
        let state = Arc::new((
            Mutex::new(State {
                device,
                pages: Vec::new(),
                dev,
                console: VecDeque::new(),
                network: VecDeque::new(),
                watch: None,
                loader_of: HashMap::new(),
                recoveries: 0,
                keep_service_worker,
                workers: Vec::new(),
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

    /// Order 1725-5uue: the service-worker scripts the pages registered,
    /// waiting up to `wait` for the first one. Empty unless the window keeps
    /// service workers.
    pub fn service_workers(&self, wait: Duration) -> Vec<String> {
        let deadline = Instant::now() + wait;
        let (lock, ready) = &*self.state;
        let mut state = lock.lock();
        while state.keep_service_worker && state.workers.is_empty() {
            if ready.wait_until(&mut state, deadline).timed_out() {
                break;
            }
        }
        state.workers.clone()
    }

    /// The last `limit` console entries (dev mode; empty otherwise).
    pub fn console_tail(&self, limit: usize) -> Vec<Value> {
        tail(&self.state.0.lock().console, limit)
    }

    /// The last `limit` network entries (dev mode; empty otherwise).
    pub fn network_tail(&self, limit: usize) -> Vec<Value> {
        tail(&self.state.0.lock().network, limit)
    }

    /// Evaluate `expression` in the window's page and return its value
    /// (promises awaited); a thrown exception is an error naming it.
    pub fn evaluate(&self, expression: &str) -> Result<Value, CdpError> {
        let session = self
            .main_session()
            .ok_or_else(|| CdpError::WindowNotRunning("no page".into()))?;
        let result = self.conn.call(
            Some(&session),
            "Runtime.evaluate",
            json!({ "expression": expression, "returnByValue": true, "awaitPromise": true }),
        )?;
        if let Some(details) = result.get("exceptionDetails") {
            let text = details
                .pointer("/exception/description")
                .or_else(|| details.get("text"))
                .and_then(Value::as_str)
                .unwrap_or("exception");
            return Err(CdpError::ProtocolError {
                code: -1,
                message: text.to_string(),
            });
        }
        Ok(result
            .pointer("/result/value")
            .cloned()
            .unwrap_or(Value::Null))
    }

    /// The page's live URL and title (order 1637-5765): the current entry of
    /// its navigation history. Read through the Page domain, never by running
    /// page script, so a window that is not in dev mode answers it too. The
    /// title follows `document.title`, so an app that retitles itself (a hot
    /// reload, a route change) is seen.
    pub fn page_info(&self) -> Result<(String, String), CdpError> {
        let session = self
            .main_session()
            .ok_or_else(|| CdpError::WindowNotRunning("no page".into()))?;
        let history = self
            .conn
            .call(Some(&session), "Page.getNavigationHistory", json!({}))?;
        let index = history
            .get("currentIndex")
            .and_then(Value::as_u64)
            .unwrap_or(0) as usize;
        let entry = history
            .get("entries")
            .and_then(|e| e.get(index))
            .ok_or_else(|| CdpError::ProtocolError {
                code: -1,
                message: "no current navigation entry".into(),
            })?;
        let field = |k: &str| {
            entry
                .get(k)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        Ok((field("url"), field("title")))
    }

    /// Load `url` in the window's page (it starts on about:blank, so the
    /// first request already carries the device's UA).
    ///
    /// `net::ERR_NETWORK_CHANGED` is retried: measured live (1656-iktu), a
    /// navigation issued right after the container starts can race the
    /// container's network settling, and Chromium aborts it with that error.
    ///
    /// Order 1725-cgh2: the navigation is VERIFIED, not only its document. A
    /// request of it that dies of NETWORK_CHANGED (a subresource, measured:
    /// flutter_bootstrap.js on a window's first open) re-navigates the page
    /// from the event worker, sharing the document's NAVIGATE_ATTEMPTS. Then
    /// this waits (LOAD_WAIT, best effort) for the load event, so a recovery
    /// is known to `network_recoveries` when browser.open answers.
    pub fn navigate(&self, url: &str) -> Result<(), CdpError> {
        let session = self
            .main_session()
            .ok_or_else(|| CdpError::WindowNotRunning("no page".into()))?;
        {
            let mut st = self.state.0.lock();
            st.loader_of.clear();
            st.watch = Some(NavigationWatch {
                session: session.clone(),
                url: url.to_string(),
                started: Instant::now(),
                loader: None,
                abandoned: Vec::new(),
                attempts: 1,
                loaded: false,
            });
        }
        loop {
            let result = self
                .conn
                .call(Some(&session), "Page.navigate", json!({ "url": url }))?;
            let err = result.get("errorText").and_then(Value::as_str);
            let retry = {
                let mut st = self.state.0.lock();
                let Some(watch) = st.watch.as_mut() else {
                    break;
                };
                match err {
                    Some(NETWORK_CHANGED) if watch.attempts < NAVIGATE_ATTEMPTS => {
                        watch.attempts += 1;
                        st.recoveries += 1;
                        true
                    }
                    _ => {
                        if watch.loader.is_none() {
                            watch.loader = result
                                .get("loaderId")
                                .and_then(Value::as_str)
                                .map(str::to_string);
                        }
                        false
                    }
                }
            };
            match err {
                _ if retry => std::thread::sleep(Duration::from_millis(500)),
                Some(err) if !err.is_empty() => {
                    self.state.0.lock().watch = None;
                    return Err(CdpError::ProtocolError {
                        code: -1,
                        message: format!("navigation to {url} failed: {err}"),
                    });
                }
                _ => break,
            }
        }
        let deadline = Instant::now() + LOAD_WAIT;
        let (lock, ready) = &*self.state;
        let mut st = lock.lock();
        while st.watch.as_ref().is_some_and(|w| !w.loaded) {
            if ready.wait_until(&mut st, deadline).timed_out() {
                break;
            }
        }
        Ok(())
    }

    /// How many times this window re-navigated a page whose requests the
    /// network change killed (order 1725-cgh2).
    pub fn network_recoveries(&self) -> u32 {
        self.state.0.lock().recoveries
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

/// Whether a failed request means the watched navigation must start over:
/// it died of NETWORK_CHANGED, on the watched page, inside NAVIGATION_WATCH,
/// and it belongs to the CURRENT attempt (a request of an abandoned load
/// failing late is ignored). Claims the attempt; returns (session, url).
fn network_changed_renavigation(
    st: &mut State,
    session: Option<&str>,
    params: &Value,
) -> Option<(String, String)> {
    if params["errorText"].as_str() != Some(NETWORK_CHANGED) {
        return None;
    }
    let loader = params["requestId"]
        .as_str()
        .and_then(|r| st.loader_of.get(r).cloned());
    let w = st.watch.as_mut()?;
    if Some(w.session.as_str()) != session
        || w.started.elapsed() > NAVIGATION_WATCH
        || w.attempts >= NAVIGATE_ATTEMPTS
    {
        return None;
    }
    match (&w.loader, &loader) {
        // An abandoned load's request, failing late.
        (_, Some(of_request)) if w.abandoned.contains(of_request) => return None,
        (Some(current), Some(of_request)) if current != of_request => return None,
        // Unattributable after a re-navigation: never a reason for another.
        (_, None) if !w.abandoned.is_empty() => return None,
        _ => {}
    }
    w.abandoned
        .extend(w.loader.take().into_iter().chain(loader));
    w.attempts += 1;
    w.loaded = false;
    let out = (w.session.clone(), w.url.clone());
    st.recoveries += 1;
    Some(out)
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
                    let (lock, ready) = state;
                    if let Some(w) = lock.lock().watch.as_mut().filter(|w| w.session == session) {
                        w.loaded = true;
                    }
                    ready.notify_all();
                }
            }
            Some("Runtime.consoleAPICalled") => {
                let text: Vec<String> = params["args"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|a| match a.get("value") {
                        Some(Value::String(s)) => s.clone(),
                        Some(v) => v.to_string(),
                        None => a["description"].as_str().unwrap_or("").to_string(),
                    })
                    .collect();
                push_capped(
                    &mut state.0.lock().console,
                    json!({ "type": params["type"], "text": text.join(" "), "timestamp": params["timestamp"] }),
                );
            }
            Some("Runtime.exceptionThrown") => {
                let d = &params["exceptionDetails"];
                let text = d
                    .pointer("/exception/description")
                    .or_else(|| d.get("text"))
                    .cloned()
                    .unwrap_or(Value::Null);
                push_capped(
                    &mut state.0.lock().console,
                    json!({ "type": "exception", "text": text, "timestamp": params["timestamp"] }),
                );
            }
            Some("Network.requestWillBeSent") => {
                let mut st = state.0.lock();
                if let (Some(request), Some(loader)) =
                    (params["requestId"].as_str(), params["loaderId"].as_str())
                    && st
                        .watch
                        .as_ref()
                        .is_some_and(|w| Some(w.session.as_str()) == event_session)
                {
                    st.loader_of.insert(request.to_string(), loader.to_string());
                }
                if st.dev {
                    push_capped(
                        &mut st.network,
                        json!({ "event": "request", "requestId": params["requestId"],
                                "method": params["request"]["method"], "url": params["request"]["url"] }),
                    );
                }
            }
            Some("Network.responseReceived") => {
                let mut st = state.0.lock();
                if st.dev {
                    push_capped(
                        &mut st.network,
                        json!({ "event": "response", "requestId": params["requestId"],
                                "status": params["response"]["status"], "url": params["response"]["url"],
                                "mimeType": params["response"]["mimeType"] }),
                    );
                }
            }
            Some("Network.loadingFailed") => {
                let renavigate = {
                    let mut st = state.0.lock();
                    if st.dev {
                        push_capped(
                            &mut st.network,
                            json!({ "event": "failed", "requestId": params["requestId"],
                                    "errorText": params["errorText"], "blockedReason": params["blockedReason"] }),
                        );
                    }
                    network_changed_renavigation(&mut st, event_session, params)
                };
                if let Some((session, url)) = renavigate {
                    tracing::info!(
                        session,
                        url,
                        "browser window: a request died of {NETWORK_CHANGED}; re-navigating (1725-cgh2)"
                    );
                    match conn.call(Some(&session), "Page.navigate", json!({ "url": url })) {
                        Ok(result) => {
                            let (lock, ready) = state;
                            if let Some(w) = lock.lock().watch.as_mut() {
                                w.loader = result
                                    .get("loaderId")
                                    .and_then(Value::as_str)
                                    .map(str::to_string);
                            }
                            ready.notify_all();
                        }
                        Err(err) => {
                            tracing::warn!(%err, session, "browser window: re-navigation failed")
                        }
                    }
                }
            }
            Some("Target.attachedToTarget") => {
                let Some(session) = params["sessionId"].as_str() else {
                    continue;
                };
                if params["targetInfo"]["type"] == "page" {
                    let (device, dev, keep_sw) = {
                        let st = state.0.lock();
                        (st.device.clone(), st.dev, st.keep_service_worker)
                    };
                    // Network on every page (1725-cgh2): the navigation guard
                    // observes failed requests. Its events reach the tails in
                    // dev mode only.
                    let mut domains =
                        vec![("Page.enable", json!({})), ("Network.enable", json!({}))];
                    if dev {
                        domains.push(("Runtime.enable", json!({})));
                        // Order 1725-5uue: a service worker's cache must not
                        // stand in for a dead preview. Bypass it (needs
                        // Network) unless the lane asked to keep it; then
                        // watch registrations so the reply can name them.
                        domains.push(if keep_sw {
                            ("ServiceWorker.enable", json!({}))
                        } else {
                            ("Network.setBypassServiceWorker", json!({ "bypass": true }))
                        });
                    }
                    if let Err(err) = apply(conn, session, &device).and_then(|()| {
                        domains
                            .iter()
                            .try_for_each(|(m, p)| conn.call(Some(session), m, p.clone()).map(drop))
                    }) {
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
            Some("ServiceWorker.workerVersionUpdated") => {
                let (lock, ready) = state;
                let mut st = lock.lock();
                for version in params["versions"].as_array().into_iter().flatten() {
                    if let Some(script) = version["scriptURL"].as_str()
                        && !st.workers.iter().any(|w| w == script)
                    {
                        st.workers.push(script.to_string());
                    }
                }
                ready.notify_all();
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

#[cfg(all(test, unix))]
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
        let window =
            WindowCdp::start(Arc::clone(&conn), device("iphone 12 pro max"), false).unwrap();
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
            10,
            "attach, Page.enable, Network.enable, the checked re-apply: {seen:?}"
        );
        let p2 = on("P2");
        assert_eq!(p2.len(), 7, "{seen:?}");
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
        let _window =
            WindowCdp::start(Arc::clone(&conn), device("iphone 12 pro max"), false).unwrap();
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

    /// Order 1656-iktu: a dev window enables Runtime and Network on each
    /// page and keeps console and network tails; a normal window does not.
    /// Order 1725-5uue: a dev window bypasses service workers on every page,
    /// after Network (the bypass is a Network setting); keeping them enables
    /// ServiceWorker instead and names the registered scripts.
    #[test]
    fn a_dev_window_bypasses_service_workers_unless_asked_to_keep_them() {
        let sw_calls = |chromium: &FakeChromium| -> Vec<Value> {
            chromium
                .seen
                .lock()
                .iter()
                .filter(|m| m["sessionId"] == "P1")
                .filter(|m| {
                    m["method"]
                        .as_str()
                        .is_some_and(|n| n == "Network.enable" || n.contains("ServiceWorker"))
                })
                .map(|m| json!([m["method"], m["params"]]))
                .collect()
        };

        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start(conn, device("desktop"), true).unwrap();
        assert_eq!(
            sw_calls(&chromium),
            [
                json!(["Network.enable", {}]),
                json!(["Network.setBypassServiceWorker", { "bypass": true }]),
            ]
        );
        assert!(window.service_workers(Duration::ZERO).is_empty());

        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start_with(conn, device("desktop"), true, true).unwrap();
        assert_eq!(
            sw_calls(&chromium),
            [
                json!(["Network.enable", {}]),
                json!(["ServiceWorker.enable", {}])
            ]
        );
        chromium.emit(
            json!({ "method": "ServiceWorker.workerVersionUpdated", "params": {
            "versions": [
                { "versionId": "1", "scriptURL": "https://www.demo.localhost:18443/sw.js" },
                { "versionId": "2", "scriptURL": "https://www.demo.localhost:18443/sw.js" },
            ] } }),
        );
        assert_eq!(
            window.service_workers(Duration::from_secs(2)),
            ["https://www.demo.localhost:18443/sw.js"]
        );

        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let _normal = WindowCdp::start(conn, device("desktop"), false).unwrap();
        assert_eq!(
            sw_calls(&chromium),
            [json!(["Network.enable", {}])],
            "a normal window leaves service workers alone"
        );
    }

    #[test]
    fn a_dev_window_enables_runtime_and_network_and_keeps_tails() {
        let (conn, chromium) = auto_attaching_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start(Arc::clone(&conn), device("desktop"), true).unwrap();
        let on_p1: Vec<String> = chromium
            .methods()
            .into_iter()
            .filter(|(_, s)| s.as_deref() == Some("P1"))
            .map(|(m, _)| m)
            .collect();
        assert!(on_p1.contains(&"Runtime.enable".to_string()), "{on_p1:?}");
        assert!(on_p1.contains(&"Network.enable".to_string()), "{on_p1:?}");
        chromium.emit(json!({ "method": "Runtime.consoleAPICalled", "sessionId": "P1",
            "params": { "type": "log", "args": [ { "type": "string", "value": "hello" }, { "type": "number", "value": 2 } ], "timestamp": 1.0 } }));
        chromium.emit(json!({ "method": "Network.requestWillBeSent", "sessionId": "P1",
            "params": { "requestId": "R1", "request": { "method": "GET", "url": "https://www.demo.localhost/" } } }));
        chromium.emit(
            json!({ "method": "Network.loadingFailed", "sessionId": "P1",
            "params": { "requestId": "R2", "errorText": "net::ERR_NAME_NOT_RESOLVED" } }),
        );
        let deadline = Instant::now() + Duration::from_secs(2);
        while window.network_tail(10).len() < 2 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(window.console_tail(10)[0]["text"], "hello 2");
        let net = window.network_tail(10);
        assert_eq!(net[0]["url"], "https://www.demo.localhost/");
        assert_eq!(net[1]["errorText"], "net::ERR_NAME_NOT_RESOLVED");
        assert_eq!(window.network_tail(1).len(), 1, "limit takes the newest");

        let (conn2, chromium2) = auto_attaching_chromium();
        chromium2.emit(attached("P1", "page", false));
        let _normal = WindowCdp::start(conn2, device("desktop"), false).unwrap();
        // Network is on for every page since 1725-cgh2 (the navigation guard
        // reads failed requests); Runtime and the tails stay dev-only.
        assert!(
            !chromium2
                .methods()
                .iter()
                .any(|(m, _)| m == "Runtime.enable"),
            "a normal window enables no Runtime"
        );
        assert!(
            chromium2
                .methods()
                .iter()
                .any(|(m, _)| m == "Network.enable"),
            "every window enables Network for the guard"
        );
        assert!(_normal.network_tail(10).is_empty(), "no tails outside dev");
    }

    /// A Chromium whose every Page.navigate starts a new load, L1, L2, …
    fn loading_chromium() -> (Arc<CdpConnection>, FakeChromium) {
        let loads = std::sync::atomic::AtomicU32::new(0);
        let (conn, chromium) = FakeChromium::start(move |m| match m["method"].as_str() {
            Some("Browser.getWindowForTarget") => Some(json!({ "windowId": 7 })),
            Some("Page.navigate") => {
                let n = loads.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                Some(json!({ "frameId": "F1", "loaderId": format!("L{n}") }))
            }
            _ => None,
        });
        (Arc::new(conn), chromium)
    }

    fn navigations(chromium: &FakeChromium) -> usize {
        chromium
            .methods()
            .iter()
            .filter(|(m, _)| m == "Page.navigate")
            .count()
    }

    fn until(what: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !what() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// One load of a page with `n` subresources: the document and each
    /// subresource is requested on `loader`; `failing` die of `error`.
    fn load(chromium: &FakeChromium, loader: &str, n: usize, failing: &[usize], error: &str) {
        for i in 0..=n {
            chromium.emit(json!({ "method": "Network.requestWillBeSent", "sessionId": "P1",
                "params": { "requestId": format!("{loader}-R{i}"), "loaderId": loader,
                            "request": { "method": "GET", "url": format!("https://www.demo.localhost/{i}") } } }));
        }
        for i in failing {
            chromium.emit(
                json!({ "method": "Network.loadingFailed", "sessionId": "P1",
                "params": { "requestId": format!("{loader}-R{i}"), "errorText": error } }),
            );
        }
    }

    /// Order 1725-cgh2, the fixture: a page with N subresources whose FIRST
    /// load loses some of them to ERR_NETWORK_CHANGED (measured live:
    /// flutter_bootstrap.js on a window's first open) is re-navigated ONCE,
    /// however many of its requests died, and the second load completes. A
    /// request of the abandoned load failing late does not start a third.
    #[test]
    fn a_first_load_that_loses_subresources_to_a_network_change_is_navigated_again() {
        let (conn, chromium) = loading_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = Arc::new(WindowCdp::start(conn, device("desktop"), false).unwrap());
        let nav = {
            let window = Arc::clone(&window);
            std::thread::spawn(move || window.navigate("https://www.demo.localhost/"))
        };
        until(|| navigations(&chromium) == 1);
        load(&chromium, "L1", 8, &[3, 5, 7], NETWORK_CHANGED);
        until(|| navigations(&chromium) == 2);
        load(&chromium, "L2", 8, &[], "");
        chromium.emit(json!({ "method": "Page.loadEventFired", "sessionId": "P1", "params": {} }));
        // The abandoned load's last request fails late: not the current load.
        chromium.emit(
            json!({ "method": "Network.loadingFailed", "sessionId": "P1",
            "params": { "requestId": "L1-R8", "errorText": NETWORK_CHANGED } }),
        );
        nav.join().unwrap().unwrap();
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(navigations(&chromium), 2, "{:?}", chromium.methods());
        assert_eq!(window.network_recoveries(), 1);
    }

    /// Only a network change restarts a load: a request refused for any
    /// other reason (a blocked host, a 404's dead link) is the page's own.
    #[test]
    fn a_subresource_failing_for_another_reason_is_left_alone() {
        let (conn, chromium) = loading_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start(conn, device("desktop"), false).unwrap();
        window.navigate("https://www.demo.localhost/").unwrap();
        load(&chromium, "L1", 4, &[1, 2], "net::ERR_NAME_NOT_RESOLVED");
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(navigations(&chromium), 1);
        assert_eq!(window.network_recoveries(), 0);
    }

    /// A network that keeps changing is not retried forever: the document's
    /// and the subresources' re-navigations share NAVIGATE_ATTEMPTS.
    #[test]
    fn re_navigation_is_bounded() {
        let (conn, chromium) = loading_chromium();
        chromium.emit(attached("P1", "page", false));
        let window = WindowCdp::start(conn, device("desktop"), false).unwrap();
        window.navigate("https://www.demo.localhost/").unwrap();
        for n in 1..=(NAVIGATE_ATTEMPTS as usize + 2) {
            until(|| navigations(&chromium) >= n.min(NAVIGATE_ATTEMPTS as usize));
            load(&chromium, &format!("L{n}"), 2, &[1], NETWORK_CHANGED);
        }
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(navigations(&chromium), NAVIGATE_ATTEMPTS as usize);
        assert_eq!(window.network_recoveries(), NAVIGATE_ATTEMPTS - 1);
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
                    dev: false,
                    watch: None,
                    loader_of: HashMap::new(),
                    recoveries: 0,
                    keep_service_worker: false,
                    workers: Vec::new(),
                    console: VecDeque::new(),
                    network: VecDeque::new(),
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
        let window = WindowCdp::start(Arc::clone(&conn), device("desktop"), false).unwrap();
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
