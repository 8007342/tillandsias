// @trace order:1955-cfhf, spec:cloudflare-auth
//! The HOST side of the local-browser Cloudflare sign-in on a VM tray
//! (macOS, Windows): the 127.0.0.1 loopback listener lives on the HOST, where
//! the operator's browser is, and the one callback it takes is forwarded to
//! the guest over the control wire (`ControlMessage::CloudflareCallbackForward`).
//!
//! WHY (operator, 2026-11-01). `tillandsias-headless --cloudflare-login` runs
//! INSIDE the Linux guest. A loopback redirect bound there is unreachable from
//! Safari on the Mac: the browser lands on the host's own 127.0.0.1 where
//! nothing listens, a dead page. The redirect URI must still be one of the
//! registered `http://127.0.0.1:<port>/tillandsias/cloudflare/callback` URIs,
//! so the listener moves to the host and the guest is told the port through
//! [`HOST_CALLBACK_PORT_ENV`] in the PTY launch environment.
//!
//! WHAT THE HOST SEES AND KEEPS. Only `code` and `state` (or `error` and
//! `state`) from the browser's query string, validated for SHAPE only. The
//! host has no `state` expectation and no PKCE verifier: both live in the
//! guest process that started the login, which is the ONE place that judges
//! the callback. The host never logs the code, never writes it to disk, and
//! forwards it once. The page it answers with is the live success page the
//! operator asked for, with an inline artwork slot (no external resources).

use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

use crate::pty::PtyOpenOpts;

/// The loopback ports registered on the Cloudflare App (EXACT match on the
/// redirect URI, so each is its own registration). The guest's
/// `cloudflare_login::REGISTERED_LOOPBACK_PORTS` pins the same list.
pub const REGISTERED_LOOPBACK_PORTS: [u16; 3] = [48631, 48632, 48633];
/// The registered loopback redirect path.
pub const CALLBACK_PATH: &str = "/tillandsias/cloudflare/callback";
/// Handed to the guest in the PTY launch environment: the HOST port the
/// redirect must name. The guest then listens for the forwarded line instead
/// of binding its own (unreachable) loopback.
pub const HOST_CALLBACK_PORT_ENV: &str = "TILLANDSIAS_CLOUDFLARE_HOST_CALLBACK_PORT";
/// The shape Cloudflare's `code` and `state` take (URL-safe, bounded).
const SAFE_MAX: usize = 2048;
/// Requests on the port that are NOT the callback (a favicon, a stray local
/// client) are answered 404 and counted; past this many the wait ends.
const MAX_STRAY_REQUESTS: u32 = 64;

/// What the browser brought back, shape-checked, unjudged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Callback {
    /// `code` and `state`, both URL-safe and non-empty.
    Code { state: String, code: String },
    /// Cloudflare's `error` (and `state` when it sent one): the user declined
    /// or the request was refused. Forwarded so the guest can refuse by name.
    Denied { state: String, error: String },
}

impl Callback {
    /// The single line the guest's forwarded receiver reads, in the relay
    /// page's grammar (`code=…&state=…` / `error=…&state=…`). The guest
    /// re-parses and judges it: state first, then error, then code shape.
    pub fn as_line(&self) -> String {
        match self {
            Callback::Code { state, code } => format!("code={code}&state={state}"),
            Callback::Denied { state, error } => format!("error={error}&state={state}"),
        }
    }
}

fn url_safe(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= SAFE_MAX
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~'))
}

fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|kv| !kv.is_empty())
        .map(|kv| {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            (k.to_string(), v.to_string())
        })
        .collect()
}

/// Shape-check a callback query. Repeated keys, missing or malformed values
/// are `None`: the browser gets the "bad" page and the wait continues.
pub fn callback_from_query(query: &str) -> Option<Callback> {
    let params = parse_query(query);
    let one = |key: &str| -> Option<Option<&str>> {
        let mut found = params
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, v)| v.as_str());
        let first = found.next();
        if found.next().is_some() {
            return None;
        }
        Some(first)
    };
    let state = one("state")??;
    if !url_safe(state) {
        return None;
    }
    if let Some(error) = one("error")? {
        let ok = !error.is_empty()
            && error.len() <= 64
            && error.bytes().all(|b| b.is_ascii_lowercase() || b == b'_');
        return ok.then(|| Callback::Denied {
            state: state.to_string(),
            error: error.to_string(),
        });
    }
    let code = one("code")??;
    url_safe(code).then(|| Callback::Code {
        state: state.to_string(),
        code: code.to_string(),
    })
}

/// The host-side loopback listener: bound on `127.0.0.1` (never `0.0.0.0`)
/// on the first free registered port.
pub struct HostCallbackListener {
    listener: TcpListener,
    port: u16,
}

impl HostCallbackListener {
    /// Bind the first free port of [`REGISTERED_LOOPBACK_PORTS`].
    pub fn bind() -> Result<Self, String> {
        Self::bind_one_of(&REGISTERED_LOOPBACK_PORTS)
    }

    /// Bind the first free port of `ports` (a `0` asks the OS for any port;
    /// tests only, since the redirect must name a registered port).
    pub fn bind_one_of(ports: &[u16]) -> Result<Self, String> {
        for &p in ports {
            if let Ok(l) = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, p))) {
                let port = l.local_addr().map_err(|e| e.to_string())?.port();
                return Ok(Self { listener: l, port });
            }
        }
        Err(format!(
            "every registered loopback port ({}) is in use on this host",
            ports
                .iter()
                .map(u16::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ))
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The redirect URI the guest's authorize request must carry.
    pub fn redirect_uri(&self) -> String {
        format!("http://127.0.0.1:{}{CALLBACK_PATH}", self.port)
    }

    /// The launch-environment pair that tells the guest which host port the
    /// redirect names.
    pub fn env_pair(&self) -> (String, String) {
        (HOST_CALLBACK_PORT_ENV.to_string(), self.port.to_string())
    }

    /// Add [`Self::env_pair`] to a PTY launch spec (the guest child's
    /// environment is exactly `opts.env`).
    pub fn apply_to(&self, opts: &mut PtyOpenOpts) {
        opts.env.retain(|(k, _)| k != HOST_CALLBACK_PORT_ENV);
        opts.env.push(self.env_pair());
    }

    /// Take connections until ONE `GET` hits [`CALLBACK_PATH`] with a
    /// shape-valid query; answer the browser with the live page and return
    /// the callback. Other paths get 404 (counted), non-loopback peers are
    /// dropped, and the whole wait is bounded by `deadline`. Blocking; run it
    /// off the UI thread. The listener closes when `self` is dropped.
    pub fn serve_one(self, deadline: Instant) -> Result<Callback, String> {
        self.listener
            .set_nonblocking(true)
            .map_err(|e| format!("listener could not be configured: {e}"))?;
        let mut strays = 0u32;
        loop {
            if Instant::now() >= deadline {
                return Err("no callback reached the host listener within the login window".into());
            }
            match self.listener.accept() {
                Ok((mut stream, peer)) => {
                    if !peer.ip().is_loopback() {
                        continue;
                    }
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
                    match read_request_target(&mut stream) {
                        Some(target) if target.path == CALLBACK_PATH => {
                            match callback_from_query(&target.query) {
                                Some(cb) => {
                                    respond(&mut stream, "200 OK", &callback_page(&cb));
                                    return Ok(cb);
                                }
                                None => {
                                    respond(&mut stream, "400 Bad Request", &bad_page());
                                    strays += 1;
                                }
                            }
                        }
                        _ => {
                            respond(&mut stream, "404 Not Found", "");
                            strays += 1;
                        }
                    }
                    if strays >= MAX_STRAY_REQUESTS {
                        return Err(
                            "the host loopback port kept receiving requests that were not the sign-in callback"
                                .into(),
                        );
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(e) => return Err(format!("the host listener stopped accepting: {e}")),
            }
        }
    }
}

struct Target {
    path: String,
    query: String,
}

/// The request line's target, GET only. Headers are read and discarded.
fn read_request_target(stream: &mut TcpStream) -> Option<Target> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?.to_string();
    // Drain headers so the browser sees a clean exchange.
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).ok()? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
    }
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    Some(Target {
        path: path.to_string(),
        query: query.to_string(),
    })
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let _ = write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.flush();
}

/// The live page the browser lands on. No script, no external resource; the
/// code is never echoed. The inline SVG is the Mācron artwork slot
/// (1955-cfhf, art packet filed separately): keep it inline when replacing it.
pub fn callback_page(cb: &Callback) -> String {
    let (title, body) = match cb {
        Callback::Code { .. } => (
            "You're signed in",
            "Tillandsias on this computer finishes the sign-in by itself. You can close this tab.",
        ),
        Callback::Denied { .. } => (
            "Sign-in not approved",
            "Nothing was stored. Run Cloudflare Login again from the Tillandsias tray to retry.",
        ),
    };
    page(title, body)
}

fn bad_page() -> String {
    page(
        "That link is incomplete",
        "This page did not receive a usable sign-in. Run Cloudflare Login again from the Tillandsias tray.",
    )
}

/// Mācron artwork slot: an inline SVG placeholder until the canon pose from
/// macron.dev (assets/Tlatoāni + Mācron cannon guidelines.md) is produced by
/// the local image pipeline. MACRON ART SLOT — replace the inner group only.
pub const MACRON_ART_SLOT: &str = r##"<svg id="macron-art" role="img" aria-label="Mācron" viewBox="0 0 240 160" width="240" height="160"><!-- MACRON ART SLOT: replace this group with the canon Mācron pose; inline only, no external resources --><g><rect x="8" y="8" width="224" height="144" rx="18" fill="#173327" stroke="#9dbba5" stroke-width="2"/><circle cx="120" cy="72" r="34" fill="#f4f8f5"/><circle cx="108" cy="66" r="4" fill="#173327"/><circle cx="132" cy="66" r="4" fill="#173327"/><path d="M104 84 q16 12 32 0" stroke="#173327" stroke-width="3" fill="none" stroke-linecap="round"/><text x="120" y="136" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#dcebe1">Mācron art slot</text></g></svg>"##;

fn page(title: &str, body: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"referrer\" content=\"no-referrer\"><meta name=\"robots\" content=\"noindex, nofollow\"><title>Tillandsias sign-in</title><style>:root{{color-scheme:light dark;--fg:#1e4a32;--bg:#f4f8f5;--muted:#4d6b58}}@media (prefers-color-scheme:dark){{:root{{--fg:#dcebe1;--bg:#10231a;--muted:#9dbba5}}}}body{{margin:0;padding:24px 16px;font:16px/1.5 system-ui,sans-serif;color:var(--fg);background:var(--bg)}}main{{max-width:36rem;margin:0 auto;text-align:center}}h1{{font-size:1.5rem;margin:16px 0 8px}}p{{color:var(--muted)}}</style></head><body><main>{MACRON_ART_SLOT}<h1>{title}</h1><p>{body}</p></main></body></html>"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn get(port: u16, target: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(s, "GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
        let mut out = String::new();
        let _ = s.read_to_string(&mut out);
        out
    }

    /// 1955-cfhf. The host listener takes exactly one shape-valid callback,
    /// answers the LIVE page (the operator saw a dead one), never echoes the
    /// code, and 404s everything else while it waits.
    #[test]
    fn the_host_listener_serves_one_live_callback_and_forwards_code_and_state() {
        let l = HostCallbackListener::bind_one_of(&[0]).unwrap();
        let port = l.port();
        assert_eq!(
            l.redirect_uri(),
            format!("http://127.0.0.1:{port}{CALLBACK_PATH}")
        );
        let server =
            std::thread::spawn(move || l.serve_one(Instant::now() + Duration::from_secs(10)));
        // A stray request first: 404, and the wait goes on.
        let stray = get(port, "/favicon.ico");
        assert!(stray.starts_with("HTTP/1.1 404"), "{stray}");
        let page = get(
            port,
            &format!("{CALLBACK_PATH}?code=CODE-abc.123~_&state=STATE_xyz"),
        );
        assert!(page.starts_with("HTTP/1.1 200"), "{page}");
        assert!(page.contains("You're signed in"), "{page}");
        assert!(
            page.contains("id=\"macron-art\""),
            "art slot missing:\n{page}"
        );
        assert!(!page.contains("CODE-abc"), "the code was echoed:\n{page}");
        assert!(!page.contains("<script"), "{page}");
        let cb = server.join().unwrap().unwrap();
        assert_eq!(
            cb,
            Callback::Code {
                state: "STATE_xyz".into(),
                code: "CODE-abc.123~_".into()
            }
        );
        assert_eq!(cb.as_line(), "code=CODE-abc.123~_&state=STATE_xyz");
        // The port is closed after the one callback.
        assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
    }

    #[test]
    fn a_denial_is_forwarded_by_name_and_a_malformed_query_is_not_forwarded() {
        assert_eq!(
            callback_from_query("error=access_denied&state=S1"),
            Some(Callback::Denied {
                state: "S1".into(),
                error: "access_denied".into()
            })
        );
        for bad in [
            "code=abc",                     // no state
            "state=S1",                     // no code
            "code=a%20b&state=S1",          // not URL-safe
            "code=a&code=b&state=S1",       // repeated
            "error=Access-Denied&state=S1", // error outside its grammar
            "",
        ] {
            assert_eq!(callback_from_query(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_launch_spec_carries_the_host_port_to_the_guest() {
        let l = HostCallbackListener::bind_one_of(&[0]).unwrap();
        let mut opts = PtyOpenOpts {
            rows: 24,
            cols: 80,
            argv: vec![],
            env: vec![("TERM".into(), "xterm-256color".into())],
            cwd: None,
        };
        l.apply_to(&mut opts);
        assert_eq!(
            opts.env.iter().find(|(k, _)| k == HOST_CALLBACK_PORT_ENV),
            Some(&(HOST_CALLBACK_PORT_ENV.to_string(), l.port().to_string()))
        );
        assert_eq!(opts.env[0].0, "TERM");
    }
}
