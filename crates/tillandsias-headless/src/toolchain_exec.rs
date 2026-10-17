// @trace spec:local-web-preview, order:1637-5765
//
// toolchain_exec.rs — run an opt-in toolchain (Flutter) for a live forge lane in
// a SIBLING container, streamed back over the lane's own MCP socket.
//
// WHY A SIBLING. The Flutter SDK is 2.5 GB unpacked (measured 2026-10-14,
// plan/evidence/1637-5765-flutter-host-measurement-2026-10-14/). Baking it into
// the forge image makes every user pay for it; installing it per project into
// the cache volume costs 2.5 GB per project. One shared image, built on the
// first `flutter` call, costs it once and only for users who ask.
//
// THE TWO ENTRY POINTS, both reached from the forge's `flutter` shim:
//
//   tools/call toolchain_prepare {toolchain}   request/response, never blocks:
//       {state: ready|preparing|failed, step?, total?, elapsed_s?, reason?}.
//       The first call starts the image build on a detached thread; later
//       calls report its progress from the build log. A multi-minute build is
//       therefore never a silent hang (1660-kuaa class).
//
//   tillandsias/exec {toolchain, argv, cwd, tty, rows, cols}   STREAMING:
//       after a one-line JSON-RPC result the connection carries NDJSON frames
//       until the command exits. Up (shim -> host):
//           {"in": "<base64>"}  {"eof": true}  {"sig": "INT"|"TERM"|"HUP"}
//           {"winch": [rows, cols]}
//       Down (host -> shim):
//           {"out": "<base64>", "fd": 1|2}  {"exit": <code>}
//       A tty session merges stdout/stderr on fd 1 through a host pty, so
//       Ctrl-C and `r`/`R` reach `flutter run` as bytes; a non-tty session
//       keeps the streams apart and forwards signals to podman, whose
//       sig-proxy hands them to the container.
//
// LIFETIME. The container runs `--rm` and belongs to the connection: when the
// shim disconnects (the forge exited, or the agent's process died) the host
// stops podman, which removes the container. Nothing outlives the lane.
//
// CONFINEMENT. Only the lane that accepted the connection is served (listener
// attribution, order 505). The project root and the cache volume are read from
// that lane's LIVE forge, never from the request; `cwd` is a relative path the
// host checks before it is joined to the project root. The image, its network
// (the internal enclave, egress only through the proxy) and every podman flag
// are chosen here; the request supplies only flutter's own argv.

use base64::Engine as _;
use serde_json::{Value, json};
use std::io::{BufRead, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The toolchains this module can run. Closed: a name is an image this crate
/// builds, never a request-chosen image.
const TOOLCHAINS: &[&str] = &["flutter"];

/// Where the forge mounts its tool cache; PUB_CACHE lives under it
/// (lib-common.sh: PROJECT_CACHE=/home/forge/.cache/tillandsias-project).
const FORGE_CACHE_DIR: &str = "/home/forge/.cache/tillandsias-project";

const MAX_ARGS: usize = 256;
const MAX_ARG_BYTES: usize = 4096;
/// Bytes per output frame before base64; keeps each NDJSON line far below the
/// socket's 4 MiB line cap.
const OUT_CHUNK: usize = 32 * 1024;

fn image_tag(toolchain: &str) -> String {
    crate::versioned_image_tag(toolchain, crate::VERSION.trim())
}

fn known_toolchain(params: &Value) -> Result<&'static str, String> {
    let name = params["toolchain"].as_str().unwrap_or("");
    TOOLCHAINS
        .iter()
        .copied()
        .find(|t| *t == name)
        .ok_or_else(|| "invalid_toolchain: expected \"flutter\"".to_string())
}

// ── toolchain_prepare ─────────────────────────────────────────────────────

/// One build at a time per toolchain, owned by this process. The image lock in
/// ensure_image_exists still serialises builds across processes.
struct Preparing {
    started: Instant,
    outcome: Option<Result<(), String>>,
}

static PREPARING: Mutex<Option<Preparing>> = Mutex::new(None);

fn image_present(tag: &str) -> Result<bool, String> {
    let out = crate::podman_command()
        .args(["image", "exists", tag])
        .output_bounded(Duration::from_secs(10))
        .map_err(|_| "runtime_unavailable: podman did not answer (image exists)".to_string())?;
    Ok(out.status.success())
}

/// Non-blocking: start the image build if needed and report where it is.
pub(crate) fn prepare(params: &Value, debug: bool) -> Value {
    let toolchain = match known_toolchain(params) {
        Ok(t) => t,
        Err(reason) => return json!({"state": "failed", "reason": reason}),
    };
    let tag = image_tag(toolchain);
    let mut slot = PREPARING.lock().unwrap_or_else(|p| p.into_inner());
    match image_present(&tag) {
        Ok(true) => {
            *slot = None;
            return json!({"state": "ready", "image": tag});
        }
        Ok(false) => {}
        Err(reason) => return json!({"state": "failed", "reason": reason}),
    }
    if let Some(p) = slot.as_ref() {
        if let Some(Err(reason)) = &p.outcome {
            let reason = reason.clone();
            // A failed build is reported once, then a later call retries.
            *slot = None;
            return json!({"state": "failed", "reason": reason});
        }
    } else {
        *slot = Some(Preparing {
            started: Instant::now(),
            outcome: None,
        });
        let tag_for_build = tag.clone();
        std::thread::spawn(move || {
            let result =
                crate::resolve_runtime_asset_root(crate::VERSION.trim(), debug).and_then(|root| {
                    crate::ensure_image_exists(&root, toolchain, &tag_for_build, debug)
                });
            let mut slot = PREPARING.lock().unwrap_or_else(|p| p.into_inner());
            if let Some(p) = slot.as_mut() {
                p.outcome = Some(result.map_err(|_| {
                    "runtime_unavailable: the toolchain image build failed on the host; see the tray log"
                        .to_string()
                }));
            }
        });
    }
    let elapsed = slot
        .as_ref()
        .map(|p| p.started.elapsed().as_secs())
        .unwrap_or(0);
    let mut answer = json!({
        "state": "preparing",
        "toolchain": toolchain,
        "elapsed_s": elapsed,
        "message": format!("Preparing {toolchain} (one time, a few minutes): building the shared toolchain image"),
    });
    // 1776-pr0g: the one parser every on-demand image uses.
    if let Some((step, total, what)) = crate::image_build_progress::image_build_progress(toolchain)
    {
        answer["step"] = json!(step);
        answer["total"] = json!(total);
        answer["doing"] = json!(what);
    }
    answer
}

// ── tillandsias/exec ──────────────────────────────────────────────────────

/// A validated exec request. Everything podman sees comes from here or from
/// the live forge, never straight from the request.
#[derive(Debug, PartialEq)]
pub(crate) struct ExecRequest {
    pub toolchain: &'static str,
    pub argv: Vec<String>,
    pub cwd: String,
    pub tty: bool,
    pub rows: u16,
    pub cols: u16,
}

/// `cwd` is relative to the project root: no absolute path, no `..`, no empty
/// or `.` component, no NUL. The empty string is the root itself.
fn safe_cwd(cwd: &str) -> Result<String, String> {
    if cwd.is_empty() || cwd == "." {
        return Ok(String::new());
    }
    let ok = !cwd.starts_with('/')
        && !cwd.contains('\0')
        && cwd
            .trim_end_matches('/')
            .split('/')
            .all(|c| !c.is_empty() && c != "." && c != "..");
    if ok {
        Ok(cwd.trim_end_matches('/').to_string())
    } else {
        Err("invalid_cwd: expected a path relative to the project root, without '..'".into())
    }
}

pub(crate) fn parse_exec(params: &Value) -> Result<ExecRequest, String> {
    let toolchain = known_toolchain(params)?;
    let argv = params["argv"]
        .as_array()
        .ok_or("invalid_argv: expected an array of strings")?;
    if argv.len() > MAX_ARGS {
        return Err(format!("invalid_argv: at most {MAX_ARGS} arguments"));
    }
    let argv = argv
        .iter()
        .map(|a| {
            a.as_str()
                .filter(|s| s.len() <= MAX_ARG_BYTES && !s.contains('\0'))
                .map(str::to_string)
                .ok_or_else(|| {
                    format!("invalid_argv: each argument a string of at most {MAX_ARG_BYTES} bytes")
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let cwd = safe_cwd(params["cwd"].as_str().unwrap_or(""))?;
    let dim = |key: &str, default: u16| {
        params[key]
            .as_u64()
            .and_then(|v| u16::try_from(v).ok())
            .filter(|v| *v > 0)
            .unwrap_or(default)
    };
    Ok(ExecRequest {
        toolchain,
        argv,
        cwd,
        tty: params["tty"].as_bool().unwrap_or(false),
        rows: dim("rows", 24),
        cols: dim("cols", 80),
    })
}

/// The port a routed dev server listens on INSIDE its own container. Every
/// session has its own network namespace, so a fixed port never collides; the
/// router, not the agent, maps a hostname to it.
const DEV_SERVER_PORT: u16 = 8080;

/// `flutter run -d web-server …` serves the app for a browser and hot-reloads
/// into it. Such a session is routed: its listen flags are the host's
/// (all interfaces, DEV_SERVER_PORT), any the agent passed are replaced.
/// CanvasKit is served from the SDK (`--no-web-resources-cdn`): a browser.open
/// window resolves only its project's hosts, so the default gstatic CDN load
/// fails and the app never starts (measured 2026-10-14, 1637-5765).
/// Returns the rewritten argv, or None for any other command.
pub(crate) fn dev_server_argv(argv: &[String]) -> Option<Vec<String>> {
    if argv.first().map(String::as_str) != Some("run") {
        return None;
    }
    let mut web_server = false;
    let mut out = Vec::with_capacity(argv.len() + 2);
    let mut i = 0;
    while i < argv.len() {
        let a = &argv[i];
        let device = if a == "-d" || a == "--device-id" {
            argv.get(i + 1).map(String::as_str)
        } else {
            a.strip_prefix("--device-id=")
                .or_else(|| a.strip_prefix("-d").filter(|v| !v.is_empty()))
        };
        if device == Some("web-server") {
            web_server = true;
        }
        if a == "--web-hostname" || a == "--web-port" {
            i += 2;
            continue;
        }
        if a.starts_with("--web-hostname=")
            || a.starts_with("--web-port=")
            || a == "--web-resources-cdn"
            || a == "--no-web-resources-cdn"
        {
            i += 1;
            continue;
        }
        out.push(a.clone());
        i += 1;
    }
    if !web_server {
        return None;
    }
    out.push("--web-hostname=0.0.0.0".into());
    out.push(format!("--web-port={DEV_SERVER_PORT}"));
    out.push("--no-web-resources-cdn".into());
    Some(out)
}

/// The forge's tool-cache volume, read from the LIVE forge's mounts.
fn forge_cache_volume(forge_id: &str) -> Result<String, String> {
    let out = crate::podman_command()
        .args(["inspect", "--type", "container", forge_id])
        .output_bounded(Duration::from_secs(10))
        .map_err(|_| "runtime_unavailable: podman did not answer (inspect)".to_string())?;
    let rows: Vec<Value> = serde_json::from_slice(&out.stdout)
        .map_err(|_| "live_worktree_unavailable: invalid forge inspect".to_string())?;
    rows.first()
        .and_then(|r| r["Mounts"].as_array())
        .into_iter()
        .flatten()
        .find(|m| m["Destination"] == FORGE_CACHE_DIR && m["Type"] == "volume")
        .and_then(|m| m["Name"].as_str())
        .map(str::to_string)
        .ok_or_else(|| "live_worktree_unavailable: forge has no tool cache volume".into())
}

/// The podman argv for one session. Pure, so the confinement is unit-tested.
pub(crate) fn build_exec_args(
    req: &ExecRequest,
    project: &str,
    name: &str,
    source_volume: &str,
    cache_volume: &str,
    forge_id: &str,
    proxy_env: &[String],
) -> Vec<String> {
    let guest_root = format!("/home/forge/src/{project}");
    let workdir = if req.cwd.is_empty() {
        guest_root.clone()
    } else {
        format!("{guest_root}/{}", req.cwd)
    };
    let mut args: Vec<String> = vec![
        "run".into(),
        "--rm".into(),
        "--interactive".into(),
        "--name".into(),
        name.into(),
        "--network".into(),
        crate::ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=1024".into(),
        "--label".into(),
        format!("tillandsias.toolchain={}", req.toolchain),
        "--label".into(),
        format!("tillandsias.toolchain.forge={forge_id}"),
        // The forge's own project directory, read-write, at the forge's path,
        // so paths in flutter's output mean the same thing in the forge.
        "--mount".into(),
        format!("type=volume,source={source_volume},target={guest_root},volume-subpath={project}"),
        // The forge's tool cache: PUB_CACHE (217 MB measured) stays on disk,
        // never on the RAM project volume.
        "--mount".into(),
        format!("type=volume,source={cache_volume},target={FORGE_CACHE_DIR}"),
        "--env".into(),
        format!("PUB_CACHE={FORGE_CACHE_DIR}/pub"),
        "--workdir".into(),
        workdir,
    ];
    if req.tty {
        args.push("--tty".into());
        args.push("--env".into());
        args.push("TERM=xterm-256color".into());
    }
    args.extend(proxy_env.iter().cloned());
    args.push(image_tag(req.toolchain));
    args.push(req.toolchain.into());
    args.extend(req.argv.iter().cloned());
    args
}

/// Serialises frames from the output threads onto the one socket.
#[derive(Clone)]
struct Frames(Arc<Mutex<UnixStream>>);

impl Frames {
    fn send(&self, frame: &Value) -> bool {
        let mut w = self.0.lock().unwrap_or_else(|p| p.into_inner());
        writeln!(w, "{frame}").is_ok()
    }
}

fn pump_output(mut src: impl Read, fd: u8, frames: Frames) {
    let mut buf = vec![0u8; OUT_CHUNK];
    loop {
        match src.read(&mut buf) {
            // EIO is how a pty master reports that the slave side closed.
            Ok(0) | Err(_) => return,
            Ok(n) => {
                let data = base64::engine::general_purpose::STANDARD.encode(&buf[..n]);
                if !frames.send(&json!({"out": data, "fd": fd})) {
                    return;
                }
            }
        }
    }
}

fn signal_child(child: &Child, sig: nix::sys::signal::Signal) {
    if let Ok(pid) = i32::try_from(child.id()) {
        let _ = nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), sig);
    }
}

fn set_winsize(master: &OwnedFd, rows: u16, cols: u16) {
    let ws = nix::libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ on a pty master we own, with a valid winsize.
    unsafe {
        nix::libc::ioctl(master.as_raw_fd(), nix::libc::TIOCSWINSZ, &ws);
    }
}

/// Run one session. `reader` is the connection's buffered read half (the
/// request line already consumed); `writer` its write half. Returns when the
/// command has exited or the shim has gone.
pub(crate) fn serve_exec(
    project: &str,
    instance: &str,
    id: &Value,
    params: &Value,
    reader: impl BufRead + Send + 'static,
    writer: UnixStream,
) {
    let frames = Frames(Arc::new(Mutex::new(writer)));
    let fail = |reason: String| {
        frames.send(&json!({
            "jsonrpc": "2.0", "id": id,
            "error": {"code": -32000, "message": reason},
        }));
    };
    let mut req = match parse_exec(params) {
        Ok(r) => r,
        Err(reason) => return fail(reason),
    };
    let dev_server = dev_server_argv(&req.argv);
    if let Some(argv) = &dev_server {
        req.argv = argv.clone();
    }
    match image_present(&image_tag(req.toolchain)) {
        Ok(true) => {}
        Ok(false) => {
            return fail(format!(
                "runtime_not_ready: the {} image is not prepared yet; call toolchain_prepare until it is ready",
                req.toolchain
            ));
        }
        Err(reason) => return fail(reason),
    }
    let live = match crate::local_web_preview::resolve_live_source(project, instance) {
        Ok(l) => l,
        Err(reason) => return fail(reason),
    };
    let cache = match forge_cache_volume(&live.forge_id) {
        Ok(c) => c,
        Err(reason) => return fail(reason),
    };
    let name = format!(
        "tillandsias-{project}-{}-{}-{}",
        req.toolchain,
        std::process::id(),
        SESSION.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let args = build_exec_args(
        &req,
        project,
        &name,
        &live.volume,
        &cache,
        &live.forge_id,
        &crate::proxy_env_args(),
    );

    let spawn = |stdin: Stdio, stdout: Stdio, stderr: Stdio| {
        let mut cmd = crate::podman_command();
        cmd.args(&args).stdin(stdin).stdout(stdout).stderr(stderr);
        cmd.spawn_caller_owned_lifetime()
    };
    // A dev server gets a hostname for this session. Caddy resolves the
    // upstream per request, so the route may precede the container's DNS name.
    let notice = match &dev_server {
        Some(_) => match crate::local_web_preview::add_dev_route(
            req.toolchain,
            project,
            &name,
            DEV_SERVER_PORT,
            false,
        ) {
            Ok(url) => Some(format!(
                "Dev server routed: open {url} in a browser (browser.open) and hot reload reaches it."
            )),
            Err(reason) => return fail(reason),
        },
        None => None,
    };
    let session = Session {
        tty: req.tty,
        rows: req.rows,
        cols: req.cols,
        label: format!("{project}/{name}"),
        notice,
    };
    run_session(&frames, id, reader, &session, spawn);
    if dev_server.is_some()
        && let Err(reason) =
            crate::local_web_preview::remove_dev_route(req.toolchain, project, &name, false)
    {
        tracing::warn!(
            spec = "local-web-preview",
            project = %project,
            reason = %reason,
            "dev server route not removed"
        );
    }
}

/// What the engine needs to know about one session beyond its argv.
struct Session {
    tty: bool,
    rows: u16,
    cols: u16,
    /// For logs only.
    label: String,
    /// Sent to the shim once, right after the session starts.
    notice: Option<String>,
}

/// The session engine: spawn through `spawn` (podman in production, any
/// program in tests), answer the JSON-RPC request, then pump frames until the
/// program exits (send `{"exit"}`) or the shim disconnects (stop it).
fn run_session<F>(
    frames: &Frames,
    id: &Value,
    mut reader: impl BufRead + Send + 'static,
    session: &Session,
    spawn: F,
) where
    F: FnOnce(Stdio, Stdio, Stdio) -> std::io::Result<Child>,
{
    let fail = |reason: &str| {
        frames.send(&json!({
            "jsonrpc": "2.0", "id": id,
            "error": {"code": -32000, "message": reason},
        }));
    };
    let mut master: Option<OwnedFd> = None;
    let spawned = if session.tty {
        let winsize = nix::pty::Winsize {
            ws_row: session.rows,
            ws_col: session.cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let Ok(pty) = nix::pty::openpty(Some(&winsize), None) else {
            return fail("runtime_unavailable: could not allocate a terminal");
        };
        let slave = pty.slave;
        let (Ok(s1), Ok(s2)) = (slave.try_clone(), slave.try_clone()) else {
            return fail("runtime_unavailable: could not allocate a terminal");
        };
        master = Some(pty.master);
        // The slave copies move into the child's Stdio and are dropped with
        // the spawn's Command, so the master reads EIO when the child exits.
        spawn(Stdio::from(slave), Stdio::from(s1), Stdio::from(s2))
    } else {
        spawn(Stdio::piped(), Stdio::piped(), Stdio::piped())
    };
    let mut child = match spawned {
        Ok(c) => c,
        Err(_) => return fail("runtime_unavailable: could not start the toolchain"),
    };
    tracing::info!(
        spec = "local-web-preview",
        session = %session.label,
        tty = session.tty,
        "toolchain session started"
    );
    if !frames.send(&json!({
        "jsonrpc": "2.0", "id": id,
        "result": {"session": session.label, "tty": session.tty},
    })) {
        signal_child(&child, nix::sys::signal::Signal::SIGTERM);
        let _ = child.wait();
        return;
    }
    if let Some(notice) = &session.notice {
        frames.send(&json!({"notice": notice}));
    }

    // Output: the pty master, or stdout and stderr separately.
    let mut pumps = Vec::new();
    let mut stdin_sink: Option<Box<dyn Write + Send>> = None;
    if let Some(m) = master.as_ref() {
        let (Ok(rd), Ok(wr)) = (m.try_clone(), m.try_clone()) else {
            signal_child(&child, nix::sys::signal::Signal::SIGTERM);
            let _ = child.wait();
            return;
        };
        let f = frames.clone();
        pumps.push(std::thread::spawn(move || {
            pump_output(std::fs::File::from(rd), 1, f)
        }));
        stdin_sink = Some(Box::new(std::fs::File::from(wr)));
    } else {
        if let Some(out) = child.stdout.take() {
            let f = frames.clone();
            pumps.push(std::thread::spawn(move || pump_output(out, 1, f)));
        }
        if let Some(err) = child.stderr.take() {
            let f = frames.clone();
            pumps.push(std::thread::spawn(move || pump_output(err, 2, f)));
        }
        if let Some(stdin) = child.stdin.take() {
            stdin_sink = Some(Box::new(stdin));
        }
    }

    // Input: frames from the shim, until EOF or the child exits. A reader
    // thread owns the socket's read half; the child is polled here.
    let (tx, rx) = std::sync::mpsc::channel::<Option<Value>>();
    std::thread::spawn(move || {
        loop {
            let mut line = String::new();
            match (&mut reader).take(1 << 20).read_line(&mut line) {
                Ok(0) | Err(_) => {
                    let _ = tx.send(None);
                    return;
                }
                Ok(_) => {
                    if let Ok(v) = serde_json::from_str::<Value>(line.trim())
                        && tx.send(Some(v)).is_err()
                    {
                        return;
                    }
                }
            }
        }
    });

    let status = loop {
        if let Ok(Some(status)) = child.try_wait() {
            break Some(status);
        }
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Some(frame)) => {
                if let Some(data) = frame["in"].as_str()
                    && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data)
                    && let Some(sink) = stdin_sink.as_mut()
                {
                    let _ = sink.write_all(&bytes);
                    let _ = sink.flush();
                } else if frame["eof"] == true {
                    if session.tty {
                        // ^D at line start: the terminal's own end of input.
                        if let Some(sink) = stdin_sink.as_mut() {
                            let _ = sink.write_all(b"\x04");
                        }
                    } else {
                        stdin_sink = None;
                    }
                } else if let Some(sig) = frame["sig"].as_str() {
                    use nix::sys::signal::Signal;
                    let sig = match sig {
                        "INT" => Some(Signal::SIGINT),
                        "TERM" => Some(Signal::SIGTERM),
                        "HUP" => Some(Signal::SIGHUP),
                        _ => None,
                    };
                    if let Some(sig) = sig {
                        signal_child(&child, sig);
                    }
                } else if let Some(dims) = frame["winch"].as_array()
                    && let (Some(r), Some(c)) = (dims.first(), dims.get(1))
                    && let (Some(r), Some(c)) = (r.as_u64(), c.as_u64())
                    && let Some(m) = master.as_ref()
                {
                    set_winsize(
                        m,
                        r.min(u16::MAX as u64) as u16,
                        c.min(u16::MAX as u64) as u16,
                    );
                    // podman holds no controlling terminal here, so the kernel
                    // sends it no SIGWINCH; it re-reads the size on this one.
                    signal_child(&child, nix::sys::signal::Signal::SIGWINCH);
                }
            }
            Ok(None) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                // The shim is gone: the forge exited or the agent's process
                // died. Stop podman; `--rm` removes the container.
                signal_child(&child, nix::sys::signal::Signal::SIGTERM);
                let deadline = Instant::now() + Duration::from_secs(10);
                while Instant::now() < deadline {
                    if let Ok(Some(_)) = child.try_wait() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
                let _ = child.kill();
                let _ = child.wait();
                tracing::info!(
                    spec = "local-web-preview",
                    session = %session.label,
                    "toolchain session ended: the forge side disconnected"
                );
                return;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
    };
    drop(stdin_sink);
    drop(master);
    for p in pumps {
        let _ = p.join();
    }
    let code = status.and_then(|s| s.code()).unwrap_or(1);
    frames.send(&json!({"exit": code}));
    tracing::info!(
        spec = "local-web-preview",
        session = %session.label,
        code,
        "toolchain session finished"
    );
}

static SESSION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

#[cfg(test)]
mod tests {
    use super::*;

    fn req(argv: &[&str], cwd: &str, tty: bool) -> Value {
        json!({"toolchain": "flutter", "argv": argv, "cwd": cwd, "tty": tty})
    }

    #[test]
    fn exec_request_is_validated() {
        let ok = parse_exec(&req(&["build", "web"], "apps/game", false)).unwrap();
        assert_eq!(ok.toolchain, "flutter");
        assert_eq!(ok.argv, vec!["build", "web"]);
        assert_eq!(ok.cwd, "apps/game");
        assert_eq!((ok.rows, ok.cols), (24, 80));
        assert_eq!(parse_exec(&req(&[], "", true)).unwrap().cwd, "");
        assert_eq!(parse_exec(&req(&[], ".", true)).unwrap().cwd, "");
        for cwd in ["/etc", "../other", "a/../../b", "a//b", "a/./b", "a\0b"] {
            let err = parse_exec(&req(&["build"], cwd, false)).unwrap_err();
            assert!(err.starts_with("invalid_cwd:"), "{cwd}: {err}");
        }
        let err = parse_exec(&json!({"toolchain": "bash", "argv": []})).unwrap_err();
        assert!(err.starts_with("invalid_toolchain:"), "{err}");
        let err = parse_exec(&json!({"toolchain": "flutter", "argv": [1]})).unwrap_err();
        assert!(err.starts_with("invalid_argv:"), "{err}");
        let many: Vec<String> = (0..=MAX_ARGS).map(|i| i.to_string()).collect();
        let err = parse_exec(&json!({"toolchain": "flutter", "argv": many})).unwrap_err();
        assert!(err.starts_with("invalid_argv:"), "{err}");
    }

    #[test]
    fn exec_args_confine_the_session_to_the_lane() {
        let r = parse_exec(&req(&["pub", "add", "flame"], "app", true)).unwrap();
        let args = build_exec_args(
            &r,
            "demo",
            "tillandsias-demo-flutter-1-0",
            "tillandsias-source-abc",
            "tillandsias-forge-cache-demo",
            "f0rge",
            &["--env".into(), "HTTPS_PROXY=http://proxy:3128".into()],
        );
        let joined = args.join(" ");
        assert!(args.starts_with(&["run".into(), "--rm".into(), "--interactive".into()]));
        assert!(joined.contains("--network tillandsias-enclave"), "{joined}");
        assert!(joined.contains(
            "type=volume,source=tillandsias-source-abc,target=/home/forge/src/demo,volume-subpath=demo"
        ));
        assert!(joined.contains(
            "type=volume,source=tillandsias-forge-cache-demo,target=/home/forge/.cache/tillandsias-project"
        ));
        assert!(joined.contains("--workdir /home/forge/src/demo/app"));
        assert!(joined.contains("--cap-drop=ALL"));
        assert!(joined.contains("--tty"));
        assert!(joined.contains("HTTPS_PROXY=http://proxy:3128"));
        assert!(joined.contains("tillandsias.toolchain.forge=f0rge"));
        // The image and the program are the module's; the request supplies
        // only what follows them.
        let tail = &args[args.len() - 5..];
        assert!(
            tail[0].starts_with("localhost/tillandsias-flutter:v"),
            "{tail:?}"
        );
        assert_eq!(&tail[1..], &["flutter", "pub", "add", "flame"]);
        // No host path is ever bind-mounted.
        assert!(!args.iter().any(|a| a == "-v" || a == "--volume"));
    }

    /// A fake lane host: answers toolchain_prepare with `ready` and runs each
    /// exec session through the REAL engine, with `sh -c <script>` in place
    /// of podman. Returns the socket path.
    fn fake_host(dir: &std::path::Path, script: &'static str) -> std::path::PathBuf {
        let sock = dir.join("mcp.sock");
        let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                std::thread::spawn(move || {
                    let writer = stream.try_clone().unwrap();
                    let mut reader = std::io::BufReader::new(stream);
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    let req: Value = serde_json::from_str(line.trim()).unwrap();
                    let frames = Frames(Arc::new(Mutex::new(writer)));
                    if req["method"] == "tillandsias/exec" {
                        let parsed = parse_exec(&req["params"]).unwrap();
                        let session = Session {
                            tty: parsed.tty,
                            rows: parsed.rows,
                            cols: parsed.cols,
                            label: "test".into(),
                            notice: Some("hello from the host".into()),
                        };
                        let argv = parsed.argv.clone();
                        run_session(&frames, &req["id"], reader, &session, |i, o, e| {
                            std::process::Command::new("sh")
                                .arg("-c")
                                .arg(script)
                                .arg("flutter")
                                .args(&argv)
                                .stdin(i)
                                .stdout(o)
                                .stderr(e)
                                .spawn()
                        });
                    } else {
                        frames.send(&json!({"jsonrpc": "2.0", "id": req["id"], "result": tillandsias_browser_mcp::framing::tool_result_content(json!({"state": "ready"}))}));
                    }
                });
            }
        });
        sock
    }

    fn shim(
        dir: &std::path::Path,
        sock: &std::path::Path,
        args: &[&str],
    ) -> Option<std::process::Command> {
        let python = ["/usr/bin/python3", "/usr/local/bin/python3"]
            .into_iter()
            .find(|p| std::path::Path::new(p).exists())?;
        let shim = std::path::PathBuf::from(
            std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"),
        )
        .join("../../images/default/cli/flutter");
        let mut cmd = std::process::Command::new(python);
        cmd.arg(shim)
            .args(args)
            .env("TILLANDSIAS_CONTROL_SOCKET", sock)
            .env("TILLANDSIAS_PROJECT", "demo")
            .env("TILLANDSIAS_PROJECT_ROOT", dir)
            .current_dir(dir);
        Some(cmd)
    }

    #[test]
    fn shim_streams_stdin_stdout_stderr_and_the_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let sock = fake_host(
            dir.path(),
            r#"read line; echo "got $line args=$*"; echo err-line >&2; exit 3"#,
        );
        // `run` is interactive (r/R/q), so its piped stdin is forwarded.
        let Some(mut cmd) = shim(dir.path(), &sock, &["run", "-d", "web-server"]) else {
            eprintln!("skip: no python3 on this host");
            return;
        };
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let out = child.wait_with_output().unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(
            out.status.code(),
            Some(3),
            "stdout={stdout} stderr={stderr}"
        );
        assert_eq!(stdout, "got hello args=run -d web-server\n");
        assert_eq!(stderr, "hello from the host\nerr-line\n");
    }

    /// A one-shot command never reads stdin (1637-5765): `bash -s <<EOF`
    /// with a `flutter create` line must run the lines after it, not hand
    /// them to flutter and exit 0. The toolchain sees EOF, and the shim
    /// leaves the caller's stdin where it was.
    #[test]
    fn shim_leaves_stdin_unread_for_a_one_shot_command() {
        use std::io::{Seek, SeekFrom};
        let dir = tempfile::tempdir().unwrap();
        let sock = fake_host(
            dir.path(),
            r#"if read line; then echo "swallowed $line"; else echo "eof args=$*"; fi"#,
        );
        let Some(mut cmd) = shim(dir.path(), &sock, &["create", "app"]) else {
            eprintln!("skip: no python3 on this host");
            return;
        };
        let mut script = tempfile::tempfile().unwrap();
        script.write_all(b"echo after-flutter\n").unwrap();
        script.seek(SeekFrom::Start(0)).unwrap();
        let mut probe = script.try_clone().unwrap();
        let out = cmd
            .stdin(Stdio::from(script))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert_eq!(out.status.code(), Some(0), "stdout={stdout}");
        assert_eq!(stdout, "eof args=create app\n");
        assert_eq!(
            probe.stream_position().unwrap(),
            0,
            "the shim read the caller's stdin"
        );
    }

    #[test]
    fn shim_forwards_ctrl_c_to_the_toolchain() {
        let dir = tempfile::tempdir().unwrap();
        let sock = fake_host(
            dir.path(),
            r#"trap 'echo stopped-by-int; exit 7' INT; echo ready; while :; do sleep 0.05; done"#,
        );
        let Some(mut cmd) = shim(dir.path(), &sock, &["run", "-d", "web-server"]) else {
            eprintln!("skip: no python3 on this host");
            return;
        };
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdout = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut first = String::new();
        stdout.read_line(&mut first).unwrap();
        assert_eq!(first, "ready\n");
        signal_child(&child, nix::sys::signal::Signal::SIGINT);
        let mut rest = String::new();
        stdout.read_to_string(&mut rest).unwrap();
        let status = child.wait().unwrap();
        assert_eq!(rest, "stopped-by-int\n");
        assert_eq!(status.code(), Some(7));
    }

    #[test]
    fn a_departed_shim_stops_the_toolchain() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("still-running");
        let script: &'static str = Box::leak(
            format!(
                "echo ready; trap 'exit 0' TERM; while :; do touch '{}'; sleep 0.05; done",
                marker.display()
            )
            .into_boxed_str(),
        );
        let sock = fake_host(dir.path(), script);
        let Some(mut cmd) = shim(dir.path(), &sock, &["run"]) else {
            eprintln!("skip: no python3 on this host");
            return;
        };
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdout = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut first = String::new();
        stdout.read_line(&mut first).unwrap();
        assert_eq!(first, "ready\n");
        // The forge side dies without a word: SIGKILL, no frames.
        child.kill().unwrap();
        child.wait().unwrap();
        // The host notices the disconnect and stops the program.
        std::thread::sleep(Duration::from_millis(600));
        std::fs::remove_file(&marker).unwrap();
        std::thread::sleep(Duration::from_millis(400));
        assert!(
            !marker.exists(),
            "the toolchain kept running after its shim was gone"
        );
    }

    #[test]
    fn a_tty_session_gives_the_toolchain_a_terminal_input_and_resize() {
        let dir = tempfile::tempdir().unwrap();
        let sock = fake_host(
            dir.path(),
            r#"tty -s && echo is-a-tty; read line; echo "got:$line"; stty size; exit 4"#,
        );
        let mut s = UnixStream::connect(&sock).unwrap();
        let req = json!({"jsonrpc": "2.0", "id": 9, "method": "tillandsias/exec",
            "params": {"toolchain": "flutter", "argv": [], "tty": true, "rows": 24, "cols": 80}});
        writeln!(s, "{req}").unwrap();
        let mut reader = std::io::BufReader::new(s.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let first: Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(first["result"]["tty"], true, "{first}");
        writeln!(s, "{}", json!({"winch": [40, 100]})).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        let input = base64::engine::general_purpose::STANDARD.encode(b"abc\r");
        writeln!(s, "{}", json!({"in": input})).unwrap();
        let mut output = Vec::new();
        let code = loop {
            line.clear();
            if reader.read_line(&mut line).unwrap() == 0 {
                panic!(
                    "no exit frame; output so far: {}",
                    String::from_utf8_lossy(&output)
                );
            }
            let f: Value = serde_json::from_str(line.trim()).unwrap();
            if let Some(out) = f["out"].as_str() {
                assert_eq!(f["fd"], 1, "a tty session merges onto fd 1");
                output.extend(
                    base64::engine::general_purpose::STANDARD
                        .decode(out)
                        .unwrap(),
                );
            } else if let Some(code) = f["exit"].as_i64() {
                break code;
            }
        };
        let text = String::from_utf8_lossy(&output);
        assert_eq!(code, 4, "{text}");
        assert!(text.contains("is-a-tty"), "{text}");
        assert!(text.contains("got:abc"), "{text}");
        assert!(
            text.contains("40 100"),
            "the resize did not reach the terminal: {text}"
        );
    }

    #[test]
    fn a_web_server_run_is_routed_with_host_chosen_listen_flags() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let routed = dev_server_argv(&v(&["run", "-d", "web-server"])).unwrap();
        assert_eq!(
            routed,
            v(&[
                "run",
                "-d",
                "web-server",
                "--web-hostname=0.0.0.0",
                "--web-port=8080",
                "--no-web-resources-cdn"
            ])
        );
        // The agent's own listen flags are replaced, in both spellings, and
        // a CDN request is overridden: the window cannot reach the CDN.
        let routed = dev_server_argv(&v(&[
            "run",
            "--device-id=web-server",
            "--web-port",
            "5000",
            "--web-hostname=127.0.0.1",
            "--web-resources-cdn",
            "--release",
        ]))
        .unwrap();
        assert_eq!(
            routed,
            v(&[
                "run",
                "--device-id=web-server",
                "--release",
                "--web-hostname=0.0.0.0",
                "--web-port=8080",
                "--no-web-resources-cdn"
            ])
        );
        assert!(dev_server_argv(&v(&["run", "-dweb-server"])).is_some());
        // Anything else is not a dev server and is left alone.
        assert_eq!(dev_server_argv(&v(&["run", "-d", "chrome"])), None);
        assert_eq!(dev_server_argv(&v(&["build", "web"])), None);
        assert_eq!(dev_server_argv(&v(&["pub", "add", "flame"])), None);
        assert_eq!(dev_server_argv(&[]), None);
    }

    /// 1776-pr0g: prepare reads progress through the one shared parser,
    /// which also reads a multi-stage build's prefixed STEP line.
    #[test]
    fn image_build_progress_is_the_toolchain_parser() {
        let dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
        let src = std::fs::read_to_string(std::path::Path::new(&dir).join("src/toolchain_exec.rs"))
            .expect("read toolchain_exec.rs");
        assert!(src.contains(concat!(
            "image_build_progress::",
            "image_build_progress(toolchain)"
        )));
        assert!(
            !src.contains(concat!("fn parse_", "step(")),
            "no private parser remains"
        );
        let log = "[tillandsias] building image flutter (t, digest_missing); x\n[2/3] STEP 12/14: COPY . .\n";
        assert_eq!(
            crate::image_build_progress::progress_in_log("flutter", log),
            Some((12, 14, "copying files".to_string()))
        );
    }
}
