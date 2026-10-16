// @trace spec:mcp-tool-socket, spec:host-browser-mcp, spec:tray-host-control-socket
//! The per-lane NDJSON MCP tool socket (orders 363, 505): the host-side
//! listener a forge's `host-browser` bridge connects to at
//! /run/host/tillandsias-mcp/mcp.sock, and the dispatcher behind it
//! (publish_local, service_*, browser.*).
//!
//! ORDER 1713-1dnx: moved out of the Linux tray module so it builds under the
//! `host-services` feature, which BOTH `tray` and `listen-vsock` enable. The
//! listener lives in the process that launches the forge: the tray on Linux
//! bare metal, and the per-attach `tillandsias-headless` child inside the
//! macOS/Windows VM, whose guest binary is built with `listen-vsock` only.
//! While this lived behind `tray`, every VM forge got the lane directory
//! mounted with no listener in it (host-browser CONNECTION_CLOSED).

use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use tracing::warn;

/// Base host directory holding per-lane MCP tool socket subdirectories (order 505).
/// Lives under `$XDG_RUNTIME_DIR/tillandsias/mcp` (falling back to `/run/user/<uid>/tillandsias/mcp`).
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
pub(crate) fn mcp_socket_base_dir() -> PathBuf {
    let runtime_dir = if let Ok(xdg) = env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg)
    } else {
        #[cfg(unix)]
        {
            let run_user = PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }));
            if run_user.is_dir() && std::fs::create_dir_all(run_user.join("tillandsias")).is_ok() {
                run_user
            } else {
                std::env::temp_dir().join("tillandsias-embedded")
            }
        }
        #[cfg(not(unix))]
        {
            std::env::temp_dir().join("tillandsias-embedded")
        }
    };
    runtime_dir.join("tillandsias/mcp")
}

/// Host directory holding the NDJSON MCP tool socket (`mcp.sock`) for a specific
/// lane `(project, instance)` (order 505).
///
/// @trace spec:mcp-tool-socket
pub fn mcp_socket_host_dir_for_lane(project: &str, instance: &str) -> PathBuf {
    let inst = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    mcp_socket_base_dir().join(format!("{project}-{inst}"))
}

/// Path of the NDJSON MCP tool socket served for in-forge agents of lane `(project, instance)`
/// (order 505). Lives in its OWN per-lane subdirectory
/// `$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock`
/// so ONLY that lane's directory — never any other lane's directory — is bind-mounted into
/// that lane's forge container.
///
/// The DIRECTORY — not the socket file — is bind-mounted into the container at
/// `/run/host/tillandsias-mcp` so a tray restart's re-bind stays visible inside an
/// already-running forge.
///
/// Attribution is kernel/filesystem-enforced: derived strictly from WHICH per-lane listener
/// accepted the connection. Process environ (/proc/<pid>/environ) is untrusted and never read.
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
pub fn mcp_socket_path_for_lane(project: &str, instance: &str) -> PathBuf {
    mcp_socket_host_dir_for_lane(project, instance).join("mcp.sock")
}

/// ORDER 1713-1dnx: the owner a lane's socket dir and socket are handed to,
/// given the serving process's effective uid. Linux native serves as the
/// desktop user and `--userns=keep-id` maps that uid onto the forge's, so the
/// 0700 dir and 0600 socket are already the forge's: `None`, nothing changes.
/// The WSL and macOS VM guests serve as root under rootful podman, where the
/// forge's uid 1000 met a root-owned 0700 dir and got EACCES on connect.
/// The modes stay owner-only; only the owner moves to the forge account.
pub(crate) fn forge_owner_for_euid(euid: u32) -> Option<u32> {
    // The forge image's only interactive account (see chown_tree_to_forge_uid).
    const FORGE_UID: u32 = 1000;
    (euid == 0).then_some(FORGE_UID)
}

#[cfg(unix)]
fn hand_lane_socket_to_forge_uid(socket_path: &std::path::Path) {
    let Some(uid) = forge_owner_for_euid(unsafe { libc::geteuid() }) else {
        return;
    };
    // lchown: never follow a link planted where the socket or dir should be.
    if let Some(dir) = socket_path.parent() {
        let _ = std::os::unix::fs::lchown(dir, Some(uid), Some(uid));
    }
    let _ = std::os::unix::fs::lchown(socket_path, Some(uid), Some(uid));
}

/// Legacy fallback socket path.
///
/// @trace spec:mcp-tool-socket
#[allow(dead_code)]
pub fn mcp_socket_path() -> PathBuf {
    mcp_socket_base_dir().join("mcp.sock")
}

/// Attribution identity bound to an MCP listener context (order 505).
///
/// Identity `(project, instance)` is kernel/filesystem-enforced and derived
/// from which per-lane listener accepted the connection, requiring zero `/proc`
/// reads. Process environment is untrusted and never read for attribution.
///
/// @trace spec:mcp-tool-socket
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneIdentity {
    pub project: String,
    pub instance: String,
}

impl LaneIdentity {
    pub fn new(project: impl Into<String>, instance: impl Into<String>) -> Self {
        Self {
            project: project.into(),
            instance: instance.into(),
        }
    }
}

/// Dispatch one JSON-RPC request from an MCP client against the host-side
/// tool surface (order 363: `publish_local` / `service_status` /
/// `service_stop`). The project label comes from the SESSION (peer
/// attribution), never from the request — a forge cannot publish another
/// project's worktree by naming it.
///
/// Handles the minimum MCP method surface a real client needs:
/// `initialize`, `tools/list`, `tools/call`, and `notifications/*`
/// (silently absorbed, per JSON-RPC 2.0 notifications get no reply —
/// hence `None`). Tool-level refusals (non-WEB category, unknown tool)
/// are actionable JSON-RPC errors, not silent drops.
///
/// @trace spec:host-browser-mcp, spec:subdomain-routing-via-reverse-proxy
/// Per-LINE payload ceiling on the live per-lane NDJSON MCP socket
/// (order 779-dqsv).
///
/// Deliberately the SAME number as the retired `McpFrame` per-variant cap,
/// re-exported rather than re-invented: the payload ceiling is a property of
/// what MCP carries (screenshots, large tool results), not of which transport
/// happens to carry it. Before this, the retired path had a 4 MiB cap and the
/// LIVE path had none at all — an unbounded base64 screenshot travelled as
/// one line.
pub(crate) const MAX_MCP_LINE_BYTES: usize = tillandsias_control_wire::MAX_MCP_FRAME_BYTES;

/// Render one response line, enforcing the OUTBOUND half of the per-line cap
/// (order 779-dqsv).
///
/// This is the half with a live producer: a base64 full-page
/// `browser.screenshot` can exceed any sane line length, and writing it would
/// blow the peer's own reader instead of failing here, where the reason is
/// known and can be said. The oversized result is replaced by a typed error
/// that keeps the request's `id`, so the client still correlates the failure
/// to its call.
///
/// Pure so the replacement is testable without a tool that can actually
/// produce megabytes.
pub(crate) fn cap_response_line(resp: &serde_json::Value) -> String {
    let rendered = resp.to_string();
    if rendered.len() <= MAX_MCP_LINE_BYTES {
        return rendered;
    }
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": resp.get("id").cloned().unwrap_or(serde_json::Value::Null),
        "error": {
            "code": -32000,
            "message": format!(
                "ResponseTooLarge: result exceeded the {MAX_MCP_LINE_BYTES}-byte per-line cap"
            ),
        }
    })
    .to_string()
}

/// Ask the composed browser server for its tool descriptors (order 779-3trn).
///
/// Goes through `handle_request` rather than reaching into the server's
/// internals, so the advertised list is by construction the same one
/// `tools/call` dispatches against — the drift this packet exists to close
/// was precisely a dispatcher advertising a different set than it served.
pub(crate) fn browser_tool_descriptors(
    browser: &tillandsias_browser_mcp::BrowserMcpServer,
    rt: &tokio::runtime::Runtime,
) -> Vec<serde_json::Value> {
    let request = tillandsias_browser_mcp::framing::RpcRequest {
        id: Some(0),
        method: "tools/list".to_string(),
        params: serde_json::Value::Object(Default::default()),
    };
    match rt.block_on(browser.handle_request(request)) {
        tillandsias_browser_mcp::framing::RpcResponse::Success { result, .. } => result
            .get("tools")
            .and_then(|t| t.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

pub(crate) fn handle_mcp_jsonrpc(
    project_label: &str,
    instance: &str,
    req: &serde_json::Value,
    browser: &tillandsias_browser_mcp::BrowserMcpServer,
    rt: &tokio::runtime::Runtime,
) -> Option<serde_json::Value> {
    let method = req["method"].as_str().unwrap_or("");
    if method.starts_with("notifications/") {
        return None;
    }

    let debug = true; // structured logs stay on while the tunnel hardens

    let body = match method {
        "initialize" => serde_json::json!({
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": { "tools": {} },
                "serverInfo": {
                    "name": "tillandsias-host-services",
                    "version": env!("CARGO_PKG_VERSION"),
                }
            }
        }),
        // Order 779-3trn: the host-services trio PLUS the browser family.
        // The browser descriptors come from the composed server itself, so
        // what is advertised is exactly what `tools/call` will dispatch.
        "tools/list" => {
            let mut tools = vec![
                serde_json::json!({
                    "name": "publish_local",
                    "description": "Publish this authenticated lane's WEB preview on the local reverse proxy. The managed auto profile selects static or local Wrangler; re-publishing reconciles the same live-source service. For an app that lives in a subdirectory with its own wrangler config (a monorepo), pass app_dir: that directory, relative to the project; everything is then served from inside it.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] },
                            "runtime": { "type": "string", "enum": ["auto", "static", "wrangler"], "default": "auto" },
                            "app_dir": { "type": "string", "description": "Optional. A directory relative to the project (no '..', no hidden segment) holding the app's wrangler config or site; omit it to publish the project root." }
                        },
                        "required": ["category"]
                    }
                }),
                serde_json::json!({
                    "name": "service_status",
                    "description": "Report the state of this project's published local service.",
                    "inputSchema": { "type": "object", "properties": {} }
                }),
                serde_json::json!({
                    "name": "service_stop",
                    "description": "Stop this project's published local service and remove its route.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] }
                        },
                        "required": ["category"]
                    }
                }),
                serde_json::json!({
                    "name": "service_reload",
                    "description": "Reload the authenticated lane's existing WEB preview runtime. This does not open or refresh a browser. A preview that died is recreated from its recorded profile.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] }
                        },
                        "required": ["category"]
                    }
                }),
                // 1723-2fiq: after the pinned lifecycle four.
                serde_json::json!({
                    "name": "service_logs",
                    "description": "Read the last lines of this lane's WEB preview output (its server's stdout and stderr), with its state and exit code. Use it when service_status says the preview is not serving.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] },
                            "lines": { "type": "integer", "minimum": 1, "maximum": 500, "default": 100 }
                        },
                        "required": ["category"]
                    }
                }),
                // 1637-5765: opt-in toolchains, after the lifecycle tools
                // (whose order is pinned). Prepare never blocks: the
                // forge's `flutter` shim polls it and shows the progress.
                serde_json::json!({
                    "name": "toolchain_prepare",
                    "description": "Prepare an opt-in toolchain for this lane (one time: builds the shared image). Never blocks: returns state ready, preparing (with build step and elapsed seconds) or failed. The forge's `flutter` command calls this for you.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "toolchain": { "type": "string", "enum": ["flutter"] }
                        },
                        "required": ["toolchain"]
                    }
                }),
            ];
            tools.extend(browser_tool_descriptors(browser, rt));
            serde_json::json!({ "result": { "tools": tools } })
        }
        "tools/call" => {
            let tool_name = req["params"]["name"].as_str().unwrap_or("");
            let args = req["params"]["arguments"].as_object();

            // Order 779-3trn: the browser family is served by the composed
            // BrowserMcpServer, whose project label came from the accepting
            // listener's LaneIdentity — never from this request, and never
            // from BrowserMcpServer::new()'s TILLANDSIAS_PROJECT env read.
            // Attribution stays a property of the socket (order 505).
            if tool_name.starts_with("browser.") {
                let request = tillandsias_browser_mcp::framing::RpcRequest {
                    id: req.get("id").and_then(|i| i.as_u64()),
                    method: "tools/call".to_string(),
                    params: req["params"].clone(),
                };
                let response = rt.block_on(browser.handle_request(request));
                return match response {
                    tillandsias_browser_mcp::framing::RpcResponse::Notification => None,
                    other => other
                        .to_line()
                        .ok()
                        .and_then(|line| serde_json::from_str(&line).ok()),
                };
            }

            match tool_name {
                "publish_local" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for local publish"),
                        ));
                    }
                    let runtime = match preview_runtime(args) {
                        Ok(runtime) => runtime,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    let app_dir = match preview_app_dir(args) {
                        Ok(app_dir) => app_dir,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    match rt.block_on(crate::local_web_preview::publish(
                        project_label,
                        instance,
                        runtime,
                        app_dir,
                        debug,
                    )) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "toolchain_prepare" => serde_json::json!({
                    "result": tillandsias_browser_mcp::framing::tool_result_content(
                        crate::toolchain_exec::prepare(&req["params"]["arguments"], debug)
                    )
                }),
                "service_status" => {
                    match rt.block_on(crate::local_web_preview::status(project_label, instance)) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "service_stop" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for service_stop"),
                        ));
                    }
                    match rt.block_on(crate::local_web_preview::stop(
                        project_label,
                        instance,
                        debug,
                    )) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "service_reload" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for service_reload"),
                        ));
                    }
                    match rt.block_on(crate::local_web_preview::reload(
                        project_label,
                        instance,
                        debug,
                    )) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "service_logs" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for service_logs"),
                        ));
                    }
                    let lines = args
                        .and_then(|a| a.get("lines"))
                        .and_then(serde_json::Value::as_u64)
                        .map_or(crate::local_web_preview::LOG_LINES_DEFAULT, |n| {
                            u32::try_from(n).unwrap_or(u32::MAX)
                        });
                    match rt.block_on(crate::local_web_preview::logs(
                        project_label,
                        instance,
                        lines,
                    )) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                other => serde_json::json!({
                    "error": { "code": -32601, "message": format!("Unknown tool: {other}") }
                }),
            }
        }
        other => serde_json::json!({
            "error": { "code": -32601, "message": format!("Method not found: {other}") }
        }),
    };

    let mut resp = body;
    resp["jsonrpc"] = serde_json::json!("2.0");
    if let Some(id) = req.get("id") {
        resp["id"] = id.clone();
    }
    Some(resp)
}

/// Validate WEB-category calls before invoking the host lifecycle. This keeps
/// malformed requests hermetic: no Podman, route, or source lookup side effect.
pub(crate) fn web_category(
    args: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<&str, String> {
    args.and_then(|a| a.get("category"))
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "invalid_category: category must be the string WEB".to_string())
}

/// `runtime` is intentionally a closed host-selected profile, never a command.
pub(crate) fn preview_runtime(
    args: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<&str, String> {
    let Some(value) = args.and_then(|a| a.get("runtime")) else {
        return Ok("auto");
    };
    match value.as_str() {
        Some("auto" | "static" | "wrangler") => Ok(value.as_str().expect("matched string")),
        _ => Err("invalid_runtime: runtime must be auto, static, or wrangler".to_string()),
    }
}

/// Order 1667-6rtp: an optional app directory. Only its TYPE is judged here;
/// local_web_preview validates the value before anything starts.
pub(crate) fn preview_app_dir(
    args: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<Option<&str>, String> {
    match args.and_then(|a| a.get("app_dir")) {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::String(dir)) => Ok(Some(dir.as_str())),
        Some(_) => Err("invalid_app_dir: app_dir must be a string".to_string()),
    }
}

pub(crate) fn mcp_error(req: &serde_json::Value, message: String) -> serde_json::Value {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": req.get("id").cloned().unwrap_or(serde_json::Value::Null),
        "error": { "code": -32000, "message": message }
    })
}

/// Serve one NDJSON MCP connection: one JSON-RPC object per line in, one
/// per line out (notifications get no line).
///
/// Identity `(project, instance)` comes directly from the accepting listener
/// context (order 505). An unattributable peer gets a single loud deny (-32000)
/// naming the attribution gate, then the connection closes — deny loudly, then fail closed.
///
/// Project labels are validated by EQUALITY against enumerated local projects
/// before tool dispatch. Process environ is untrusted and never read.
///
/// @trace spec:mcp-tool-socket
pub fn serve_mcp_connection(stream: UnixStream, identity: Option<LaneIdentity>) {
    use std::io::{BufRead, BufReader, Write};

    let mut writer = stream;

    let Some(identity) = identity else {
        warn!(
            spec = "mcp-tool-socket",
            "unattributable MCP connection denied and closed (-32000)"
        );
        let deny = serde_json::json!({
            "jsonrpc": "2.0",
            "id": serde_json::Value::Null,
            "error": {
                "code": -32000,
                "message": "Connection cannot be attributed to a valid project lane (listener attribution required)",
            }
        });
        let _ = writeln!(writer, "{deny}");
        return;
    };

    let project_label = identity.project;
    let lane_instance = identity.instance.clone();

    // Validate project label by equality against the known project set (never
    // sanitize). 1031-q4pb: this site carried the INVERTED spelling of the same
    // bypass — `known.is_empty() || known.iter().any(..)` evaluates to TRUE, i.e.
    // valid, on an empty enumeration. Two spellings of one bug across four sites
    // is exactly why the check now lives in one helper that fails closed.
    //
    // This is the site that matters most: it is the MCP tool socket, so the
    // label it admits is the lane an unattributed client gets to act as.
    if let Err(reason) = crate::local_projects::validate_project_label(&project_label) {
        warn!(
            spec = "mcp-tool-socket",
            project = %project_label,
            reason = %reason,
            "MCP connection for unknown project denied and closed (-32000)"
        );
        let deny = serde_json::json!({
            "jsonrpc": "2.0",
            "id": serde_json::Value::Null,
            "error": {
                "code": -32000,
                "message": reason,
            }
        });
        let _ = writeln!(writer, "{deny}");
        return;
    }

    let Ok(read_half) = writer.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(read_half);

    // Order 779-3trn: ONE browser server and ONE runtime for the whole
    // connection.
    //
    // The label is pinned from the accepting listener's LaneIdentity, so
    // `BrowserMcpServer::new()`'s TILLANDSIAS_PROJECT env read never runs —
    // reading the environment here would reintroduce exactly the forgeable
    // attribution order 505 deleted. The per-connection instance is also
    // what makes the call semaphore mean "per session".
    //
    // MULTI-thread runtime is load-bearing and now hoisted out of the
    // per-call path (it used to be rebuilt on every tools/call): the publish
    // path re-enters podman_runtime()'s RuntimeOrHandle::block_on, which uses
    // tokio::task::block_in_place — a PANIC on current-thread runtimes ("can
    // call blocking only when running on the multi-threaded runtime"; live
    // repro 2026-07-16, first tray publish_local killed its connection
    // thread). The deny/handshake paths never hit it, so only a live publish
    // exposes a regression here.
    let Ok(rt) = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    else {
        warn!(
            spec = "mcp-tool-socket",
            "could not build the MCP connection runtime; closing"
        );
        return;
    };
    // Order 1649-xqet: browser.open runs the chromium-framework container on
    // a per-launch internal network, never host Chromium.
    let browser = tillandsias_browser_mcp::BrowserMcpServer::with_project_label(
        tillandsias_browser_mcp::McpServerConfig::default(),
        &project_label,
        Some(std::sync::Arc::new(
            crate::browser_open::TrayBrowserContainers::new(false),
        )),
    )
    // Order 1656-iktu: windows record the lane that opened them; another
    // lane's window answers WINDOW_NOT_FOUND.
    .with_lane(lane_instance);
    // Order 1655-urz9: a window emulates the project's `[browser] device`
    // when browser.open names none, else desktop. The label is the
    // listener's (validated, order 505), so the path is the project's own.
    let browser = match tillandsias_core::config::load_project_config(
        &crate::local_projects::host_project_root().join(&project_label),
    )
    .browser
    .and_then(|b| b.device)
    {
        Some(device) => browser.with_default_device(device),
        None => browser,
    };

    loop {
        let mut raw = String::new();
        // BOUNDED read (order 779-dqsv): `.take(MAX + 1)` caps what a single
        // line can allocate. Reading the line first and measuring afterwards
        // would let a hostile or looping peer allocate without limit — the
        // exact hole this cap closes — so the ceiling is applied to the READ,
        // not to the result.
        let read = (&mut reader)
            .take(MAX_MCP_LINE_BYTES as u64 + 1)
            .read_line(&mut raw);
        let Ok(byte_count) = read else {
            return;
        };
        if byte_count == 0 {
            return; // clean EOF
        }
        if byte_count > MAX_MCP_LINE_BYTES && !raw.ends_with('\n') {
            // Oversized: drain to the next newline so the stream resyncs,
            // answer with a typed error, and keep serving. Draining is itself
            // bounded — a peer that never sends a newline just closes.
            let mut discarded = 0usize;
            loop {
                let mut sink = String::new();
                let Ok(n) = (&mut reader)
                    .take(MAX_MCP_LINE_BYTES as u64)
                    .read_line(&mut sink)
                else {
                    return;
                };
                if n == 0 {
                    return;
                }
                discarded += n;
                if sink.ends_with('\n') {
                    break;
                }
                if discarded > MAX_MCP_LINE_BYTES * 8 {
                    warn!(
                        spec = "mcp-tool-socket",
                        discarded, "peer kept sending an unterminated oversized line; closing"
                    );
                    return;
                }
            }
            warn!(
                spec = "mcp-tool-socket",
                project = %project_label,
                limit = MAX_MCP_LINE_BYTES,
                "MCP request line exceeded the per-line cap; refused"
            );
            let too_large = serde_json::json!({
                "jsonrpc": "2.0",
                "id": serde_json::Value::Null,
                "error": {
                    "code": -32000,
                    "message": format!(
                        "RequestTooLarge: one JSON-RPC object per line, at most {MAX_MCP_LINE_BYTES} bytes"
                    ),
                }
            });
            if writeln!(writer, "{too_large}").is_err() {
                return;
            }
            continue;
        }
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let resp = match serde_json::from_str::<serde_json::Value>(line) {
            // 1637-5765: a toolchain session takes over the connection and
            // streams frames until the command exits; nothing follows it.
            Ok(req) if req["method"] == "tillandsias/exec" => {
                crate::toolchain_exec::serve_exec(
                    &project_label,
                    &identity.instance,
                    &req["id"],
                    &req["params"],
                    reader,
                    writer,
                );
                return;
            }
            Ok(req) => handle_mcp_jsonrpc(&project_label, &identity.instance, &req, &browser, &rt),
            Err(_) => Some(serde_json::json!({
                "jsonrpc": "2.0",
                "id": serde_json::Value::Null,
                "error": {
                    "code": -32700,
                    "message": "Parse error: expected one JSON-RPC object per line",
                }
            })),
        };
        if let Some(resp) = resp {
            let rendered = cap_response_line(&resp);
            if rendered.len() != resp.to_string().len() {
                warn!(
                    spec = "mcp-tool-socket",
                    project = %project_label,
                    limit = MAX_MCP_LINE_BYTES,
                    "MCP response exceeded the per-line cap; replaced with a typed error"
                );
            }
            if writeln!(writer, "{rendered}").is_err() {
                return;
            }
        }
    }
}

/// Global registry tracking active per-lane MCP listeners.
/// This is a tuple rather than a hyphen-concatenated string: `(a-b, c)` and
/// `(a, b-c)` are distinct lanes even though their display form is identical.
pub(crate) type LaneListenerKey = (String, String);

pub(crate) static ACTIVE_LANE_LISTENERS: OnceLock<Mutex<HashSet<LaneListenerKey>>> =
    OnceLock::new();

pub(crate) fn lane_listener_registry() -> &'static Mutex<HashSet<LaneListenerKey>> {
    ACTIVE_LANE_LISTENERS.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Bind the NDJSON MCP tool socket for lane `(project, instance)` and serve
/// it from detached threads (order 505).
/// The socket is mode 0600 in `$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock`.
///
/// A reachable existing socket is treated as another live owner and is never
/// unlinked. A connection-refused socket is a stale filesystem entry from a
/// departed tray and may be removed before retrying the bind.
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
pub fn start_mcp_socket_server_for_lane(project: &str, instance: &str) -> Result<(), String> {
    let instance_clean = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    let lane_key = (project.to_owned(), instance_clean.to_owned());
    // Keep this lock through creation. Inserting only after bind + chmod makes
    // a failed first attempt retryable, and serializes same-lane callers.
    let mut registry = lane_listener_registry().lock().expect("lane registry lock");
    if registry.contains(&lane_key) {
        return Ok(());
    }

    let socket_path = mcp_socket_path_for_lane(project, instance_clean);
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create mcp socket directory: {err}"))?;
        #[cfg(unix)]
        let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
    }
    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(err) if err.kind() == std::io::ErrorKind::AddrInUse => {
            match UnixStream::connect(&socket_path) {
                // An active peer might belong to a CLI child or another tray
                // process. Never steal its pathname merely because this
                // process has not populated its own in-memory registry.
                Ok(_) => {
                    return Err(format!(
                        "mcp socket already has a live owner; refusing to unlink: {}",
                        socket_path.display()
                    ));
                }
                // A refused connection is the kernel's evidence that no
                // listener owns this pathname. It is the only stale-entry
                // case we reclaim automatically.
                Err(connect_err) if connect_err.kind() == std::io::ErrorKind::ConnectionRefused => {
                    fs::remove_file(&socket_path).map_err(|remove_err| {
                        format!(
                            "failed to remove connection-refused mcp socket {}: {remove_err}",
                            socket_path.display()
                        )
                    })?;
                    UnixListener::bind(&socket_path).map_err(|bind_err| {
                        format!("failed to bind reclaimed mcp socket: {bind_err}")
                    })?
                }
                Err(connect_err) => {
                    return Err(format!(
                        "mcp socket exists but ownership is indeterminate; refusing to unlink {}: {connect_err}",
                        socket_path.display()
                    ));
                }
            }
        }
        Err(err) => return Err(format!("failed to bind mcp socket: {err}")),
    };
    #[cfg(unix)]
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("failed to chmod mcp socket: {err}"))?;
    #[cfg(unix)]
    hand_lane_socket_to_forge_uid(&socket_path);

    registry.insert(lane_key);
    drop(registry);

    let identity = LaneIdentity::new(project, instance_clean);
    std::thread::spawn(move || {
        for incoming in listener.incoming() {
            match incoming {
                Ok(stream) => {
                    let lane_id = identity.clone();
                    std::thread::spawn(move || {
                        serve_mcp_connection(stream, Some(lane_id));
                    });
                }
                Err(err) => {
                    warn!(error = %err, lane = %format!("{}-{}", identity.project, identity.instance), "mcp socket accept failed")
                }
            }
        }
    });

    Ok(())
}
