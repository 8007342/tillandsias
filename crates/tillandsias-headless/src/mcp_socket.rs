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
    #[cfg(test)]
    if let Some(root) = test_runtime_root::get() {
        return mcp_socket_base_dir_from(Some(root));
    }
    mcp_socket_base_dir_from(env::var("XDG_RUNTIME_DIR").ok())
}

/// 1969-scp2: a THREAD-LOCAL runtime root for tests, so a test can place lane
/// sockets under a scratch dir without `std::env::set_var("XDG_RUNTIME_DIR")`,
/// which every parallel test thread would see.
#[cfg(test)]
pub(crate) mod test_runtime_root {
    use std::cell::RefCell;
    thread_local! { static ROOT: RefCell<Option<String>> = const { RefCell::new(None) }; }
    pub(crate) fn get() -> Option<String> {
        ROOT.with(|r| r.borrow().clone())
    }
    /// Set for this thread until the guard drops.
    pub(crate) fn set(root: &std::path::Path) -> Guard {
        ROOT.with(|r| *r.borrow_mut() = Some(root.to_string_lossy().into_owned()));
        Guard
    }
    pub(crate) struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            ROOT.with(|r| *r.borrow_mut() = None);
        }
    }
}

#[cfg(test)]
mod call_gate_tests {
    use super::*;

    /// ORDER 1990-mcpq: the limit concurrency owes (779-dqsv): never more
    /// than `max` calls at once, and a freed slot admits the next.
    #[test]
    fn the_call_gate_never_admits_more_than_its_limit() {
        let gate = CallGate::new(2);
        let a = gate.enter();
        let b = gate.enter();
        assert_eq!(gate.running(), 2);
        let g = gate.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let waiter = std::thread::spawn(move || {
            let _c = g.enter();
            tx.send(()).unwrap();
        });
        assert!(
            rx.recv_timeout(std::time::Duration::from_millis(200))
                .is_err(),
            "a third call waits while two run"
        );
        drop(a);
        rx.recv_timeout(std::time::Duration::from_secs(2))
            .expect("a freed slot admits it");
        waiter.join().unwrap();
        drop(b);
        assert_eq!(gate.running(), 0);
    }
}

#[cfg(all(test, unix))]
mod refused_wait_tests {
    use super::*;

    /// ORDER 1980-lsrc, deterministic: a forked child that has not exec'd yet
    /// holds the listener, so right after the drop the socket still ACCEPTS
    /// (the flake: the old fixtures asserted a refusal here). Waiting sees it
    /// refuse once the child is gone.
    #[test]
    fn a_listener_held_by_a_forked_child_is_waited_out() {
        let dir = tempfile::Builder::new()
            .prefix("lsrc")
            .tempdir_in("/tmp")
            .unwrap();
        let path = dir.path().join("s.sock");
        let listener = UnixListener::bind(&path).unwrap();
        // SAFETY: the child only closes descriptors, sleeps and _exits; it
        // runs no Rust code that could touch a lock another thread held at
        // fork time.
        //
        // 2000-envt: fork copies EVERY descriptor in this process, including
        // the flock'd lock files parallel tests hold at that instant, and this
        // child keeps them for 300 ms. A test that dropped its lock then saw it
        // still held (a_graceful_exit_leaves_another_owners_enclave_running,
        // a_second_launch_of_a_project_takes_the_next_instance). The child
        // keeps only the listener it exists to hold.
        use std::os::fd::AsRawFd as _;
        let keep = listener.as_raw_fd();
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0, "fork");
        if pid == 0 {
            unsafe {
                for fd in 3..1024 {
                    if fd != keep {
                        libc::close(fd);
                    }
                }
                libc::usleep(300_000);
                libc::_exit(0);
            }
        }
        drop(listener);
        let immediate = UnixStream::connect(&path).is_ok();
        let waited = wait_until_refused(&path);
        let mut status = 0;
        unsafe { libc::waitpid(pid, &mut status, 0) };
        assert!(
            immediate,
            "the race: a dropped listener a fork holds still accepts"
        );
        assert!(waited, "and it refuses once the fork is gone");
    }
}

/// ORDER 1980-lsrc: wait (up to ~3 s) until `path` refuses connections.
///
/// A test that drops its listener and expects the next connect to be refused
/// races every parallel test that spawns a process: between fork and exec the
/// child holds a copy of each fd, the listener included (CLOEXEC closes it
/// only at exec), so for that window the "departed" socket still accepts.
/// That made `a_cli_lane_refuses_by_name_when_another_process_owns_its_socket`
/// and the lane-adoption fixture flake on lenovinha after 1969-scp2.
#[cfg(test)]
pub(crate) fn wait_until_refused(path: &std::path::Path) -> bool {
    for _ in 0..300 {
        match UnixStream::connect(path) {
            Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => return true,
            Ok(_) => std::thread::sleep(std::time::Duration::from_millis(10)),
            Err(_) => return false,
        }
    }
    false
}

/// [`mcp_socket_base_dir`] for an explicit `XDG_RUNTIME_DIR` value, so a test
/// can pass one without touching the process environment. An empty value
/// counts as unset (order 1748-fbqe, see [`crate::nonempty_runtime_dir`]).
pub(crate) fn mcp_socket_base_dir_from(xdg: Option<String>) -> PathBuf {
    let runtime_dir = if let Some(xdg) = crate::nonempty_runtime_dir(xdg) {
        xdg
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

#[cfg(test)]
pub(crate) fn handle_mcp_jsonrpc(
    project_label: &str,
    instance: &str,
    req: &serde_json::Value,
    browser: &tillandsias_browser_mcp::BrowserMcpServer,
    rt: &tokio::runtime::Runtime,
) -> Option<serde_json::Value> {
    handle_mcp_jsonrpc_streaming(project_label, instance, req, browser, rt, &mut |_| {})
}

/// [`handle_mcp_jsonrpc`] with a sink for lines sent BEFORE the response on
/// the same stream: the MCP `notifications/progress` of a long tool
/// (image.generate, 1874-kkrc). Events, not polling.
pub(crate) fn handle_mcp_jsonrpc_streaming(
    project_label: &str,
    instance: &str,
    req: &serde_json::Value,
    browser: &tillandsias_browser_mcp::BrowserMcpServer,
    rt: &tokio::runtime::Runtime,
    emit: &mut dyn FnMut(serde_json::Value),
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
                    // 1993-cver: the release version, from VERSION.
                    "version": crate::VERSION.trim(),
                    "buildId": build_identity(),
                },
                // 1969-7qm7: the grouped index is what the agent sees FIRST.
                "instructions": crate::host_tools::instructions(),
            }
        }),
        // Order 779-3trn: the host-services trio PLUS the browser family.
        // The browser descriptors come from the composed server itself, so
        // what is advertised is exactly what `tools/call` will dispatch.
        // 1969-7qm7: canonical names are namespaced by what the tool does
        // (preview.*, toolchain.*, image.*, studio.*, browser.*, cloudflare.*,
        // webstudio.*), each description says what it starts, and the flat
        // names are listed LAST as deprecated aliases for one release.
        "tools/list" => {
            let mut tools = vec![
                serde_json::json!({
                    "name": "preview.publish",
                    "description": "Publish this lane's project as a local WEB preview at www.<project>.localhost. STARTS a sibling web container on the enclave (the managed auto profile selects a static server or local Wrangler; never a deploy). Re-publishing reconciles the same live-source service. For an app in a subdirectory with its own wrangler config (a monorepo), pass app_dir: that directory, relative to the project. Not for a framework dev server: run that inside the forge.",
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
                    "name": "preview.status",
                    "description": "Report the state of this project's local WEB preview (the sibling web container preview.publish started), with its URL and, after a failed publish, last_failure with its remedy. Starts nothing.",
                    "inputSchema": { "type": "object", "properties": {} }
                }),
                serde_json::json!({
                    "name": "preview.stop",
                    "description": "Stop this project's local WEB preview container and remove its route. Starts nothing.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] }
                        },
                        "required": ["category"]
                    }
                }),
                serde_json::json!({
                    "name": "preview.reload",
                    "description": "Reload this lane's existing local WEB preview runtime (restarts the sibling web container from its recorded profile; a preview that died is recreated). Does not open or refresh a browser: use browser.open for that.",
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
                    "name": "preview.logs",
                    "description": "Read the last lines of this lane's local WEB preview output (its server's stdout and stderr), with its state and exit code. Use it when preview.status says the preview is not serving. Starts nothing.",
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
                    "name": "toolchain.prepare",
                    "description": "Prepare an opt-in toolchain for this lane. STARTS a one-time build of the shared toolchain image (flutter) beside the forge. Never blocks: returns state ready, preparing (with retry_after_s, and while it builds the step and elapsed seconds) or failed. Preparing is not an error: call again after retry_after_s. force: true rebuilds an image whose last build failed now. The forge's `flutter` command calls this for you.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "toolchain": { "type": "string", "enum": ["flutter"] },
                            "force": { "type": "boolean", "default": false }
                        },
                        "required": ["toolchain"]
                    }
                }),
            ];
            // 1874-kkrc: local image generation, after the pinned lifecycle
            // and toolchain tools.
            tools.push(crate::imagegen_tool::descriptor());
            // 1956-x7xp: the headless studio workflow runner, beside it.
            tools.push(crate::studio_tool::descriptor());
            // 2002-stjb: the same run as a ticket, and its status.
            tools.push(crate::studio_jobs::queue_descriptor());
            tools.push(crate::studio_jobs::status_descriptor());
            // 1986-snpx: the read-only model listing beside it.
            tools.push(crate::studio_tool::models_descriptor());
            // 1969-cfyt: the studio appliance, started on demand.
            tools.extend(crate::imagegen_studio::tool_descriptors());
            // 2055-grzz: the audio studio appliance's tools, beside it.
            tools.extend(crate::audio_studio::tool_descriptors());
            // 1956-26qh: the GPU-free family contract checker, beside it.
            tools.push(validate_family_descriptor());
            // 1957-emar: the GPU arbiter's status and unload, beside them.
            tools.extend(crate::gpu_queue::tool_descriptors());
            // 1959-xsy5 (D12): the GPU-free pixel finish, beside it.
            tools.push(crate::pixel_finish::descriptor());
            // 1959-xsy5 (D13): the review contact sheet, beside it.
            tools.push(crate::contact_sheet::descriptor());
            // 1956-ucix: the CorridorKey 2.0 proof of concept, listed ONLY for
            // a project with `[imagegen] corridorkey = true` (no automatic
            // wiring for other users until Corridor has seen the demo).
            if crate::studio_key::enabled(project_label, instance) {
                tools.push(crate::studio_key::descriptor());
            }
            tools.extend(browser_tool_descriptors(browser, rt));
            // 1772-irs3: the read-only Cloudflare tools, after the browser
            // family (both lists above are pinned).
            #[cfg(feature = "vault")]
            tools.extend(crate::cloudflare_mcp::tool_descriptors());
            // 1966-47vt: cloud.usage, right after the cloudflare.* family.
            #[cfg(feature = "vault")]
            tools.push(crate::cloud_usage::descriptor());
            // 1860-auhm: the web-studio co-edit tools (webstudio.*, 1969-7qm7).
            tools.extend(crate::studio::tool_descriptors());
            // 1969-7qm7: the index tool, then the deprecated flat aliases last.
            tools.push(crate::host_tools::index_descriptor());
            // 2003-stbf: whether this lane runs the installed build.
            tools.push(serde_json::json!({
                "name": LANE_VERSION_TOOL,
                "description": "Whether the lane serving this forge runs the installed Tillandsias \
                    build: current, stale (naming both versions; the forge's tools keep the old \
                    code until it is relaunched) or unknown. Reports only; restarts nothing.",
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
            }));
            let tools = crate::host_tools::with_deprecated_aliases(tools);
            serde_json::json!({ "result": { "tools": tools } })
        }
        "tools/call" => {
            // 1969-7qm7: a deprecated flat alias runs exactly as its canonical
            // name; the dispatcher below only ever sees canonical names.
            let tool_name =
                crate::host_tools::canonical(req["params"]["name"].as_str().unwrap_or(""));
            let args = req["params"]["arguments"].as_object();

            // 2003-stbf: does the lane serving this forge run the installed build?
            if tool_name == LANE_VERSION_TOOL {
                let mut resp = serde_json::json!({
                    "jsonrpc": "2.0",
                    "result": tillandsias_browser_mcp::framing::tool_result_content(
                        lane_freshness(build_identity(), installed_build_identity().as_deref())
                    )
                });
                if let Some(id) = req.get("id") {
                    resp["id"] = id.clone();
                }
                return Some(resp);
            }
            if tool_name == crate::host_tools::INDEX_TOOL {
                let mut resp = serde_json::json!({
                    "jsonrpc": "2.0",
                    "result": tillandsias_browser_mcp::framing::tool_result_content(
                        crate::host_tools::index_result()
                    )
                });
                if let Some(id) = req.get("id") {
                    resp["id"] = id.clone();
                }
                return Some(resp);
            }

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

            // 1772-irs3: served by this process with the operator's stored
            // Cloudflare sign-in; the forge only names the tool. Nothing in
            // the request chooses the account, method or path.
            // 1966-47vt: cloud.usage reads the Vault-stored GitHub App and
            // Cloudflare tokens here, host-side; the forge only names it.
            #[cfg(feature = "vault")]
            if tool_name == crate::cloud_usage::TOOL_NAME {
                let body = match crate::cloud_usage::call_live(args, debug) {
                    Ok(result) => serde_json::json!({
                        "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                    }),
                    Err(e) => return Some(mcp_error(req, e)),
                };
                let mut resp = body;
                resp["jsonrpc"] = serde_json::json!("2.0");
                if let Some(id) = req.get("id") {
                    resp["id"] = id.clone();
                }
                return Some(resp);
            }

            #[cfg(feature = "vault")]
            if tool_name.starts_with("cloudflare.") {
                let body = match crate::cloudflare_mcp::call_live(tool_name, args, debug) {
                    Ok(result) => serde_json::json!({
                        "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                    }),
                    Err(e) => return Some(mcp_error(req, e)),
                };
                let mut resp = body;
                resp["jsonrpc"] = serde_json::json!("2.0");
                if let Some(id) = req.get("id") {
                    resp["id"] = id.clone();
                }
                return Some(resp);
            }

            // 1860-auhm: the studio co-edit tools read the lane's own forge.
            if let Some(result) = crate::studio::call(
                tool_name,
                project_label,
                instance,
                &req["params"]["arguments"],
            ) {
                let body = match result {
                    Ok(v) => serde_json::json!({
                        "result": tillandsias_browser_mcp::framing::tool_result_content(v)
                    }),
                    Err(e) => return Some(mcp_error(req, e)),
                };
                let mut resp = body;
                resp["jsonrpc"] = serde_json::json!("2.0");
                if let Some(id) = req.get("id") {
                    resp["id"] = id.clone();
                }
                return Some(resp);
            }

            match tool_name {
                "preview.publish" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for preview.publish"),
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
                "image.generate" => {
                    let token = req["params"]["_meta"]["progressToken"].clone();
                    let mut seq = 0u64;
                    let empty = serde_json::json!({});
                    let arguments = req["params"].get("arguments").unwrap_or(&empty);
                    match crate::imagegen_tool::call(project_label, instance, arguments, &mut |p| {
                        if let Some(line) =
                            crate::imagegen_tool::progress_notification(&token, &mut seq, &p)
                        {
                            emit(line);
                        }
                    }) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "studio.run_workflow" => {
                    let token = req["params"]["_meta"]["progressToken"].clone();
                    let mut seq = 0u64;
                    let empty = serde_json::json!({});
                    let arguments = req["params"].get("arguments").unwrap_or(&empty);
                    match crate::studio_tool::call(project_label, instance, arguments, &mut |p| {
                        if let Some(line) =
                            crate::imagegen_tool::progress_notification(&token, &mut seq, &p)
                        {
                            emit(line);
                        }
                    }) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 2055-grzz: one audio studio call, one appliance container.
                "audio.transform" | "audio.detect_glitches" => {
                    let empty = serde_json::json!({});
                    let arguments = req["params"].get("arguments").unwrap_or(&empty);
                    match crate::audio_studio::call(tool_name, project_label, instance, arguments)
                        .unwrap_or_else(|| Err(format!("unknown tool {tool_name}")))
                    {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 2002-stjb: queue a run as a job; read its ticket.
                "studio.queue_workflow" | "studio.job_status" => {
                    let empty = serde_json::json!({});
                    let arguments = req["params"].get("arguments").unwrap_or(&empty);
                    let out = if tool_name == "studio.queue_workflow" {
                        crate::studio_jobs::queue(project_label, instance, arguments)
                    } else {
                        crate::studio_jobs::status(project_label, instance, arguments)
                    };
                    match out {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 1969-cfyt: the forge agent starts the studio on demand.
                "studio.start" => {
                    let version = crate::VERSION.trim();
                    match crate::imagegen_studio::start_on_demand(
                        project_label,
                        &|| crate::imagegen_studio::is_running(project_label),
                        &mut || {
                            let client = tillandsias_podman::PodmanClient::new();
                            let plan = crate::imagegen_studio::plan_explicit(
                                &tillandsias_core::cache_root::cache_root(),
                            );
                            rt.block_on(crate::imagegen_studio::start(
                                &client,
                                &plan,
                                project_label,
                                version,
                                debug,
                            ))
                        },
                        &|| crate::imagegen_studio::probe_listening(project_label),
                    )
                    .and_then(|mut result| {
                        // 1985-stdu: already running: connect this forge
                        // and refresh the window route.
                        if result["started"] == false {
                            crate::imagegen_studio::reattach(project_label, debug)?;
                        }
                        result["window_url"] =
                            serde_json::json!(crate::imagegen_studio::window_url(project_label));
                        Ok(result)
                    }) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "studio.models" => {
                    let engine = crate::studio_tool::HttpStudio::for_this_host(project_label).ok();
                    let listing = crate::studio_tool::models_listing(
                        &crate::imagegen_models::models_dir(),
                        engine
                            .as_ref()
                            .map(|e| e as &dyn crate::studio_tool::StudioEngine),
                    );
                    serde_json::json!({
                        "result": tillandsias_browser_mcp::framing::tool_result_content(listing)
                    })
                }
                // 1987-smnt: a fresh container reads the tray's current folder map.
                "studio.restart" => {
                    crate::imagegen_studio::stop(project_label);
                    let version = crate::VERSION.trim();
                    let client = tillandsias_podman::PodmanClient::new();
                    let plan = crate::imagegen_studio::plan_explicit(
                        &tillandsias_core::cache_root::cache_root(),
                    );
                    match rt
                        .block_on(crate::imagegen_studio::start(
                            &client,
                            &plan,
                            project_label,
                            version,
                            debug,
                        ))
                        .and_then(|()| {
                            // 1990-stry: answer once ComfyUI listens again.
                            crate::imagegen_studio::wait_until_listening(
                                project_label,
                                &|| crate::imagegen_studio::probe_listening(project_label),
                                crate::imagegen_studio::LISTEN_BUDGET,
                                crate::imagegen_studio::LISTEN_POLL,
                            )
                        })
                        .map(|_| {
                            let mut v = crate::imagegen_studio::status_json(
                                project_label,
                                crate::imagegen_studio::is_running(project_label),
                            );
                            v["restarted"] = serde_json::json!(true);
                            v
                        }) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": format!("studio_restart_failed: {e}") }
                        }),
                    }
                }
                "studio.status" => {
                    let running = crate::imagegen_studio::is_running(project_label);
                    serde_json::json!({
                        "result": tillandsias_browser_mcp::framing::tool_result_content(
                            crate::imagegen_studio::status_json(project_label, running)
                        )
                    })
                }
                // 1957-emar: GPU status and an unload routed through the arbiter.
                "gpu.status" | "gpu.unload_model" => {
                    let empty = serde_json::json!({});
                    let arguments = req["params"].get("arguments").unwrap_or(&empty);
                    match crate::gpu_queue::call_tool(tool_name, arguments).expect("a gpu tool") {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 1956-ucix: CorridorKey 2.0 proof of concept; the call itself
                // re-checks the opt-in, CUDA and the consent gate.
                "studio.key_footage" => {
                    let token = req["params"]["_meta"]["progressToken"].clone();
                    let mut seq = 0u64;
                    let empty = serde_json::json!({});
                    let arguments = req["params"].get("arguments").unwrap_or(&empty);
                    match crate::studio_key::call(project_label, instance, arguments, &mut |p| {
                        if let Some(line) =
                            crate::imagegen_tool::progress_notification(&token, &mut seq, &p)
                        {
                            emit(line);
                        }
                    }) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 1956-26qh: pure static check of a family spec read from the
                // lane's own checkout; no GPU, nothing queued.
                "studio.validate_family" => {
                    match validate_family_in_lane(
                        project_label,
                        instance,
                        &req["params"]["arguments"],
                    ) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 1959-xsy5 (D13): a deterministic labelled review grid; no GPU.
                "studio.contact_sheet" => {
                    match crate::contact_sheet::call(
                        project_label,
                        instance,
                        &req["params"]["arguments"],
                    ) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                // 1959-xsy5 (D12): pure, integer, deterministic; no GPU.
                "studio.finish_pixels" => {
                    match crate::pixel_finish::call(
                        project_label,
                        instance,
                        &req["params"]["arguments"],
                    ) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "toolchain.prepare" => serde_json::json!({
                    "result": tillandsias_browser_mcp::framing::tool_result_content(
                        crate::toolchain_exec::prepare(&req["params"]["arguments"], debug)
                    )
                }),
                "preview.status" => {
                    match rt.block_on(crate::local_web_preview::status(project_label, instance)) {
                        Ok(result) => serde_json::json!({
                            "result": tillandsias_browser_mcp::framing::tool_result_content(result)
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "preview.stop" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for preview.stop"),
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
                "preview.reload" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for preview.reload"),
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
                "preview.logs" => {
                    let category = match web_category(args) {
                        Ok(category) => category,
                        Err(message) => return Some(mcp_error(req, message)),
                    };
                    if category != "WEB" {
                        return Some(mcp_error(
                            req,
                            format!("Category {category} is not supported for preview.logs"),
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

/// 1956-26qh: `studio.validate_family {spec}` — the family contract v1 static
/// checker (design D7). Pure: no GPU, no queue, no generation.
fn validate_family_descriptor() -> serde_json::Value {
    serde_json::json!({
        "name": "studio.validate_family",
        "description": "Check a family spec against the family contract v1 (1935-k2ib/v1) before any GPU time is spent: schema shape, palette_fails_all_gates (mandatory with reservedRamps), region_mask_colours_declared (mandatory with regions), and that every input file it names exists. spec is a path relative to the project checkout. Returns ok:family:<name>, or one refused:<check>:<detail> line per failure. Runs no generation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "spec": { "type": "string", "description": "Project-relative path of the family spec JSON, e.g. art/families/gatekeeper-v3.json." }
            },
            "required": ["spec"]
        }
    })
}

/// Snapshot the spec and the inputs it names out of the lane's live forge
/// checkout into a private host-side directory, then run the pure checker on
/// it. The forge is the one `local_web_preview` proves belongs to this lane;
/// nothing in the request names a container, and every path is proven
/// project-relative before it reaches `podman exec`.
pub(crate) fn validate_family_in_lane(
    project: &str,
    instance: &str,
    args: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    use crate::studio_contract::{project_relative, referenced_inputs, validate_family};
    let spec_rel = args
        .get("spec")
        .and_then(serde_json::Value::as_str)
        .ok_or("invalid_arguments: spec (a project-relative path) is required")?;
    let spec_rel = project_relative(spec_rel)?;
    let lane = crate::local_web_preview::resolve_live_source(project, instance)?;
    let checkout = crate::studio::checkout_dir(project);

    let snapshot = tempfile::Builder::new()
        .prefix("tillandsias-family-")
        .tempdir()
        .map_err(|e| format!("studio.validate_family: no scratch directory: {e}"))?;
    let root = snapshot.path();

    let fetch = |rel: &str| -> Result<Option<Vec<u8>>, String> {
        let guest = format!("{checkout}/{rel}");
        let mut cmd = tillandsias_podman::podman_cmd_sync();
        cmd.args(["exec", &lane.forge_id, "sh", "-c"])
            .arg("if [ -f \"$1\" ]; then cat -- \"$1\"; else exit 3; fi")
            .args(["sh", &guest]);
        let out = cmd
            .output_bounded(std::time::Duration::from_secs(20))
            .map_err(|e| format!("studio.validate_family: read in the forge failed: {e}"))?;
        match out.status.code() {
            Some(0) => Ok(Some(out.stdout)),
            Some(3) => Ok(None),
            _ => Err(format!(
                "studio.validate_family: reading {rel} in the forge failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )),
        }
    };
    let place = |rel: &str, bytes: &[u8]| -> Result<(), String> {
        let host = root.join(rel);
        if let Some(parent) = host.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("studio.validate_family: {e}"))?;
        }
        fs::write(&host, bytes).map_err(|e| format!("studio.validate_family: {e}"))
    };

    let Some(spec_bytes) = fetch(&spec_rel)? else {
        return Err(format!(
            "not_found: {spec_rel} is not a file in the project"
        ));
    };
    place(&spec_rel, &spec_bytes)?;
    // Inputs the spec names: copy those that exist; the checker reports the
    // rest as missing_input. Paths that fail project_relative are left to the
    // checker's schema refusal and never reach the forge.
    if let Ok(spec) = serde_json::from_slice::<serde_json::Value>(&spec_bytes) {
        let mut seen = HashSet::new();
        for (rel, _) in referenced_inputs(&spec) {
            let Ok(rel) = project_relative(&rel) else {
                continue;
            };
            if !seen.insert(rel.clone()) {
                continue;
            }
            if let Some(bytes) = fetch(&rel)? {
                place(&rel, &bytes)?;
            }
        }
    }

    let verdicts = validate_family(&root.join(&spec_rel), root);
    let lines: Vec<String> = verdicts.iter().map(ToString::to_string).collect();
    let ok = verdicts
        .iter()
        .all(|v| matches!(v, crate::studio_contract::Verdict::Ok { .. }));
    Ok(serde_json::json!({
        "spec": spec_rel,
        "ok": ok,
        "verdicts": lines,
    }))
}

/// ORDER 1971-mcpu: run one request's dispatch so a panic in any tool
/// becomes that call's `tool_panicked` error. Before this, a panic unwound the
/// connection thread and the forge lost every host tool ("Connection closed").
pub(crate) fn dispatch_guarded(
    req: &serde_json::Value,
    dispatch: impl FnOnce() -> Option<serde_json::Value>,
) -> Option<serde_json::Value> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(dispatch)) {
        Ok(resp) => resp,
        Err(payload) => {
            let what = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "non-string panic payload".into());
            let tool = req["params"]["name"].as_str().unwrap_or("");
            warn!(spec = "mcp-tool-socket", tool, panic = %what, "tool panicked; answered with a typed error");
            // A notification has no id and gets no reply, panic or not.
            req.get("id")?;
            Some(mcp_error(
                req,
                format!(
                    "tool_panicked: {tool} failed inside the host ({what}); the connection stays open"
                ),
            ))
        }
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
    // 1956-4pxj: the git mirror's push events reach this forge on this
    // connection. One shared writer, so a pushed notification and a response
    // line never interleave.
    let Ok(shared_half) = writer.try_clone() else {
        return;
    };
    let shared: crate::lane_events::SharedWriter =
        std::sync::Arc::new(std::sync::Mutex::new(shared_half));
    let mut push_events = Some(crate::lane_events::register(
        &project_label,
        &lane_instance,
        shared.clone(),
    ));
    let write_line = |line: &str| -> bool {
        let mut w = shared.lock().unwrap_or_else(|p| p.into_inner());
        w.write_all(format!("{line}\n").as_bytes()).is_ok()
    };

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
    let browser = lane_browser_server(
        &project_label,
        &lane_instance,
        Some(std::sync::Arc::new(
            crate::browser_open::TrayBrowserContainers::new(false),
        )),
        false,
    );
    // 1990-mcpq: shared by the per-call threads below, under one gate.
    let browser = std::sync::Arc::new(browser);
    let rt = std::sync::Arc::new(rt);
    let gate = CallGate::new(MAX_CONCURRENT_CALLS);
    // Order 1655-urz9 + 776-jcf3 (operator, 2026-10-24): browser.open with no
    // device names desktop. The per-project `[browser] device` used to be read
    // from the host checkout's `.tillandsias/config.toml`; there is no host
    // checkout any more, and a cloud project's config lives only inside its
    // ephemeral forge, so the host-side default is desktop.

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
            if !write_line(&too_large.to_string()) {
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
                // The exec session owns the stream from here: no notification
                // may land between its frames.
                drop(push_events.take());
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
            // 1971-mcpu: a panic inside one tool answers that call with a
            // typed error; it never closes the lane's connection.
            // 1990-mcpq: a tools/call runs on its own thread, so a long
            // one (a studio workflow) never holds back the next call on
            // this connection (kumbia: browser.open waited >120 s). Replies
            // go out through the one shared writer, matched by id.
            Ok(req) if req["method"] == "tools/call" => {
                let (browser, rt, shared) = (browser.clone(), rt.clone(), shared.clone());
                let (label, instance) = (project_label.clone(), identity.instance.clone());
                let id = req.get("id").cloned().unwrap_or(serde_json::Value::Null);
                // Backpressure: wait here (reading no more lines) while
                // MAX_CONCURRENT_CALLS run.
                let slot = gate.enter();
                let spawned =
                    std::thread::Builder::new()
                        .name("mcp-call".into())
                        .spawn(move || {
                            let _slot = slot;
                            let write = |line: &str| {
                                let mut w = shared.lock().unwrap_or_else(|p| p.into_inner());
                                let _ = w.write_all(format!("{line}\n").as_bytes());
                            };
                            let resp = dispatch_guarded(&req, || {
                                handle_mcp_jsonrpc_streaming(
                                    &label,
                                    &instance,
                                    &req,
                                    &browser,
                                    &rt,
                                    &mut |line| write(&cap_response_line(&line)),
                                )
                            });
                            if let Some(resp) = resp {
                                write(&cap_response_line(&resp));
                            }
                        });
                match spawned {
                    Ok(_) => None,
                    Err(e) => Some(mcp_error(
                        &serde_json::json!({ "id": id }),
                        format!("could not start a call thread: {e}"),
                    )),
                }
            }
            Ok(req) => dispatch_guarded(&req, || {
                handle_mcp_jsonrpc_streaming(
                    &project_label,
                    &identity.instance,
                    &req,
                    &browser,
                    &rt,
                    &mut |line| {
                        let _ = write_line(&cap_response_line(&line));
                    },
                )
            }),
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
            if !write_line(&rendered) {
                return;
            }
        }
    }
}

/// ORDER 1990-mcpq: at most this many tools/call run at once on ONE
/// connection. The read loop waits for a slot before starting the next call
/// (backpressure, never a refusal), so a client cannot spawn without bound.
pub(crate) const MAX_CONCURRENT_CALLS: usize = 8;

/// The per-connection call gate: `enter` blocks while `max` calls run.
pub(crate) struct CallGate {
    running: std::sync::Mutex<usize>,
    freed: std::sync::Condvar,
    max: usize,
}

impl CallGate {
    pub(crate) fn new(max: usize) -> std::sync::Arc<Self> {
        std::sync::Arc::new(CallGate {
            running: std::sync::Mutex::new(0),
            freed: std::sync::Condvar::new(),
            max,
        })
    }

    /// Wait for a slot; the returned guard frees it when dropped.
    pub(crate) fn enter(self: &std::sync::Arc<Self>) -> CallSlot {
        let mut n = self.running.lock().unwrap_or_else(|p| p.into_inner());
        while *n >= self.max {
            n = self.freed.wait(n).unwrap_or_else(|p| p.into_inner());
        }
        *n += 1;
        CallSlot(self.clone())
    }

    #[cfg(test)]
    pub(crate) fn running(&self) -> usize {
        *self.running.lock().unwrap_or_else(|p| p.into_inner())
    }
}

pub(crate) struct CallSlot(std::sync::Arc<CallGate>);

impl Drop for CallSlot {
    fn drop(&mut self) {
        let mut n = self.0.running.lock().unwrap_or_else(|p| p.into_inner());
        *n -= 1;
        self.0.freed.notify_one();
    }
}

/// Order 1754-bu07: the browser windows of each lane, for the life of this
/// process. A connection's server shares its lane's registry instead of
/// owning one, so a window outlives the connection that opened it (the
/// host-browser-mcp requirement "Window survives MCP connection drop"): a
/// one-shot `opencode run` that opened a window used to drop the registry on
/// exit, and dropping it SIGKILLed the window's containers 20 s later. Tray
/// Quit still ends every window: graceful_shutdown_async stops each
/// `tillandsias-browser-*` container.
type LaneWindows = (
    std::sync::Arc<tillandsias_browser_mcp::window_registry::WindowRegistry>,
    std::sync::Arc<tillandsias_browser_mcp::window_registry::DebounceTable>,
);

static LANE_WINDOWS: OnceLock<Mutex<std::collections::HashMap<LaneListenerKey, LaneWindows>>> =
    OnceLock::new();

/// The window registry of lane `(project, instance)`, created on first use.
pub(crate) fn lane_windows(project: &str, instance: &str) -> LaneWindows {
    let mut map = LANE_WINDOWS
        .get_or_init(|| Mutex::new(std::collections::HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    map.entry((project.to_owned(), instance.to_owned()))
        .or_insert_with(|| (Default::default(), Default::default()))
        .clone()
}

/// The browser server for one connection of lane `(project, instance)`: its
/// windows record that lane (order 1656-iktu: another lane's window answers
/// WINDOW_NOT_FOUND) and live in the lane's registry (order 1754-bu07).
/// `fake_launch` registers windows without starting containers (tests).
pub(crate) fn lane_browser_server(
    project: &str,
    instance: &str,
    containers: Option<std::sync::Arc<dyn tillandsias_browser_mcp::launcher::BrowserContainers>>,
    fake_launch: bool,
) -> tillandsias_browser_mcp::BrowserMcpServer {
    let (windows, debounce) = lane_windows(project, instance);
    tillandsias_browser_mcp::BrowserMcpServer::with_project_label_and_mode(
        tillandsias_browser_mcp::McpServerConfig::default(),
        project,
        containers,
        fake_launch,
    )
    .with_lane(instance)
    .with_windows(windows, debounce)
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

/// 1798-nwpg: the lane a CLI launch is about to serve, handed to the tray
/// companion it spawns as `<project>/<instance>`. The companion leaves that
/// lane unbound at startup, so the launch is not refused by its own
/// companion as a foreign owner.
pub(crate) const TRAY_RESERVED_LANE_ENV: &str = "TILLANDSIAS_TRAY_RESERVED_LANE";

/// Parse a [`TRAY_RESERVED_LANE_ENV`] value. Anything but exactly one
/// non-empty project and one non-empty instance reserves nothing.
#[cfg(any(feature = "tray", test))]
pub(crate) fn reserved_lane_from(value: Option<&str>) -> Option<LaneListenerKey> {
    let (project, instance) = value?.trim().split_once('/')?;
    if project.is_empty() || instance.is_empty() || instance.contains('/') {
        return None;
    }
    Some((project.to_owned(), instance.to_owned()))
}

/// 1863-eckw: the file in a lane's socket dir that hands the lane to the tray.
/// A web-mode forge outlives the CLI that launched it, so a listener bound in
/// that CLI died with it and left a socket that refused every connection for
/// the rest of the session. A launcher whose forge outlives it writes this
/// marker (`<project>\n<instance>\n`) instead of binding, and the tray's
/// adoption tick binds the lane and rebinds it after any owner dies.
pub(crate) const LANE_TRAY_MARKER: &str = "tray-owned";

/// How often the tray's adoption tick looks for an unserved marked lane.
#[cfg(feature = "tray")]
pub(crate) const LANE_ADOPT_TICK: std::time::Duration = std::time::Duration::from_millis(500);

/// Hand lane `(project, instance)` to the tray (see [`LANE_TRAY_MARKER`]).
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub(crate) fn mark_lane_tray_owned(project: &str, instance: &str) -> Result<(), String> {
    let dir = mcp_socket_host_dir_for_lane(project, instance);
    fs::create_dir_all(&dir).map_err(|e| format!("failed to create {}: {e}", dir.display()))?;
    let marker = dir.join(LANE_TRAY_MARKER);
    fs::write(&marker, format!("{project}\n{}\n", lane_instance(instance)))
        .map_err(|e| format!("failed to write {}: {e}", marker.display()))?;
    let _ = fs::set_permissions(&marker, fs::Permissions::from_mode(0o600));
    Ok(())
}

/// ORDER 1988-trkp: before a keep-forges exit, hand every lane this process
/// serves to the next tray (the marker its adoption tick binds). Returns the
/// lanes marked.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn mark_served_lanes_for_adoption() -> Vec<LaneListenerKey> {
    let lanes: Vec<LaneListenerKey> = lane_listener_registry()
        .lock()
        .expect("lane registry lock")
        .iter()
        .cloned()
        .collect();
    lanes
        .into_iter()
        .filter(|(p, i)| match mark_lane_tray_owned(p, i) {
            Ok(()) => true,
            Err(e) => {
                warn!(project = %p, instance = %i, error = %e, "1988-trkp: could not mark lane for adoption");
                false
            }
        })
        .collect()
}

fn lane_instance(instance: &str) -> &str {
    if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    }
}

/// Whether something accepts on lane `(project, instance)`'s socket.
pub(crate) fn lane_accepting(project: &str, instance: &str) -> bool {
    UnixStream::connect(mcp_socket_path_for_lane(project, instance)).is_ok()
}

/// 1961-8ats: this binary's build identity, `<VERSION>+<sha256 of the running
/// executable, 16 hex>`. Two builds at the same VERSION differ here, which is
/// the case that matters: a branch build tested beside the installed tray.
/// `+unknown` when the executable cannot be read, and an unknown never matches.
pub(crate) fn build_identity() -> &'static str {
    static ID: OnceLock<String> = OnceLock::new();
    ID.get_or_init(|| {
        use sha2::{Digest, Sha256};
        // 1984-pexe: /proc/self/exe reads the RUNNING build even after an
        // upgrade replaced its file (current_exe then names "… (deleted)").
        let digest = crate::self_exe::for_spawn()
            .and_then(fs::read)
            .map(|bytes| {
                let hash = Sha256::digest(&bytes);
                hash.iter()
                    .take(8)
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>()
            })
            .unwrap_or_else(|_| "unknown".to_owned());
        format!("{}+{digest}", crate::VERSION.trim())
    })
}

/// ORDER 2003-stbf: the tool a forge agent calls to learn whether the lane
/// serving it runs the installed build.
pub(crate) const LANE_VERSION_TOOL: &str = "tillandsias.lane_version";

fn digest8(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The version an installed binary's `--version` prints (`Tillandsias v<ver>`).
pub(crate) fn parse_version_line(out: &str) -> Option<String> {
    let v = out
        .lines()
        .next()?
        .trim()
        .strip_prefix("Tillandsias v")?
        .trim();
    (!v.is_empty()
        && v.chars()
            .all(|c| c.is_ascii_alphanumeric() || ".-+".contains(c)))
    .then(|| v.to_string())
}

/// ORDER 2003-stbf: the INSTALLED binary's identity, in [`build_identity`]'s
/// `<version>+<digest>` form: the file now at this program's installed path
/// (an upgrade replaces it under a running lane) and what its `--version`
/// prints. `None` when either cannot be read.
pub(crate) fn installed_build_identity() -> Option<String> {
    let path = crate::self_exe::for_other_process().ok()?;
    let bytes = fs::read(&path).ok()?;
    let out = std::process::Command::new(&path)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let version = parse_version_line(&String::from_utf8_lossy(&out.stdout))?;
    Some(format!("{version}+{}", digest8(&bytes)))
}

/// ORDER 2003-stbf: is a lane running `running` (a build id) current against
/// the installed build? Report only: a forge may hold live work, so nothing is
/// restarted. An unreadable installed build, or a lane that cannot name its
/// own, is `unknown`, never `current`.
pub(crate) fn lane_freshness(running: &str, installed: Option<&str>) -> serde_json::Value {
    let version = |id: &str| id.split('+').next().unwrap_or(id).to_string();
    match installed {
        None => serde_json::json!({
            "status": "unknown",
            "lane": running,
            "installed": null,
            "why": "the installed binary could not be read, so this lane cannot be called current",
        }),
        Some(_) if running.ends_with("+unknown") || running.starts_with("unanswered") => {
            serde_json::json!({
                "status": "unknown",
                "lane": running,
                "installed": installed,
                "why": "the lane did not name its own build",
            })
        }
        Some(inst) if inst == running => serde_json::json!({
            "status": "current",
            "lane": running,
            "installed": inst,
        }),
        Some(inst) => serde_json::json!({
            "status": "stale",
            "lane": running,
            "installed": inst,
            "lane_version": version(running),
            "installed_version": version(inst),
            "why": format!(
                "this lane runs {} but {} is installed; its tools keep the old code until the \
                 forge is relaunched (tillandsias <project>). Nothing is restarted automatically: \
                 the forge may hold live work.",
                version(running),
                version(inst)
            ),
        }),
    }
}

/// ORDER 2003-stbf: every lane socket on this host, by lane directory name.
pub(crate) fn lane_sockets() -> Vec<(String, std::path::PathBuf)> {
    let root = crate::control_socket_host_dir().join("mcp");
    let mut out: Vec<(String, std::path::PathBuf)> = fs::read_dir(&root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let sock = e.path().join("mcp.sock");
            sock.exists()
                .then(|| (e.file_name().to_string_lossy().into_owned(), sock))
        })
        .collect();
    out.sort();
    out
}

/// 1961-8ats: what the process answering on `socket` says it is, read from
/// its MCP `initialize` serverInfo. A tray older than 1961-8ats sends no
/// `buildId`, so it reads as `<version>+unknown`. `Err` when it does not answer.
pub(crate) fn lane_server_build(socket: &std::path::Path) -> Result<String, String> {
    use std::io::{BufRead, BufReader, Write};
    let mut stream =
        UnixStream::connect(socket).map_err(|e| format!("connect {}: {e}", socket.display()))?;
    let timeout = Some(std::time::Duration::from_secs(3));
    let _ = stream.set_read_timeout(timeout);
    let _ = stream.set_write_timeout(timeout);
    let probe = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": { "protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": { "name": "tillandsias-lane-probe", "version": crate::VERSION.trim() } }
    });
    writeln!(stream, "{probe}").map_err(|e| format!("write {}: {e}", socket.display()))?;
    let mut line = String::new();
    BufReader::new(&stream)
        .read_line(&mut line)
        .map_err(|e| format!("read {}: {e}", socket.display()))?;
    let reply: serde_json::Value =
        serde_json::from_str(line.trim()).map_err(|e| format!("initialize reply: {e}"))?;
    let info = &reply["result"]["serverInfo"];
    if let Some(id) = info["buildId"].as_str() {
        return Ok(id.to_owned());
    }
    let version = info["version"]
        .as_str()
        .ok_or_else(|| format!("initialize reply carries no serverInfo: {}", line.trim()))?;
    Ok(format!("{version}+unknown"))
}

/// 2070-mtf9: the pid of the process listening on `socket`, from the
/// kernel's peer credentials (captured at listen time). `None` when nothing
/// accepts there.
pub(crate) fn lane_listener_pid(socket: &std::path::Path) -> Option<i32> {
    let stream = UnixStream::connect(socket).ok()?;
    let creds =
        nix::sys::socket::getsockopt(&stream, nix::sys::socket::sockopt::PeerCredentials).ok()?;
    Some(creds.pid())
}

/// `" (exe deleted)"` when a `/proc/<pid>/exe` link names a replaced binary.
pub(crate) fn exe_note(exe_link: &str) -> &'static str {
    if exe_link.ends_with(" (deleted)") {
        " (exe deleted)"
    } else {
        ""
    }
}

/// 2070-mtf9: who serves a lane, for an operator report: `pid N`, plus
/// `(exe deleted)` when that process runs a binary an upgrade replaced.
pub(crate) fn describe_lane_server(socket: &std::path::Path) -> Option<String> {
    let pid = lane_listener_pid(socket)?;
    let exe = fs::read_link(format!("/proc/{pid}/exe"))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    Some(format!("pid {pid}{}", exe_note(&exe)))
}

/// 1961-8ats: the named refusal when a tray-marked lane is answered by a
/// build other than this one; `None` when nothing answers or the builds match.
/// The hand-off has no other handshake, so without this a branch build's lane
/// silently runs the installed tray's code (yoga, 2026-11-02).
pub(crate) fn lane_served_by_other_build(project: &str, instance: &str) -> Option<String> {
    let socket = mcp_socket_path_for_lane(project, instance);
    marked_lane(socket.parent()?)?;
    if !lane_accepting(project, instance) {
        return None;
    }
    let ours = build_identity();
    let theirs = lane_server_build(&socket).unwrap_or_else(|e| format!("unanswered ({e})"));
    build_mismatch_refusal(ours, &theirs)
}

fn build_mismatch_refusal(ours: &str, theirs: &str) -> Option<String> {
    if ours == theirs && !ours.ends_with("+unknown") {
        return None;
    }
    Some(format!(
        "refused:lane-tray-version-mismatch:lane={ours} tray={theirs}\n  \
         why: this lane is served by a running tray built from other code, so its tools would \
         run that build, not this one (1961-8ats)\n  \
         remedy: quit the running tray and launch again, or launch with TILLANDSIAS_NO_TRAY=1"
    ))
}

/// ORDER 1911-3dqo. Serve lane `(project, instance)` again after the process
/// that bound it died while its forge kept running (systemd-oomd killed the
/// launcher on lenovinha 2026-10-28). The lane is handed to the tray first,
/// so a tray adopts it on its next tick even if this rejoin dies too; when
/// nothing answers yet, this process binds it, reclaiming the refusing
/// socket the dead launcher left.
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub(crate) fn serve_lane_for_rejoin(project: &str, instance: &str) -> Result<(), String> {
    mark_lane_tray_owned(project, instance)?;
    if !lane_accepting(project, instance) {
        start_mcp_socket_server_for_lane(project, instance)?;
    }
    if lane_accepting(project, instance) {
        Ok(())
    } else {
        Err(format!(
            "lane {project}-{} does not answer on {}",
            lane_instance(instance),
            mcp_socket_path_for_lane(project, instance).display()
        ))
    }
}

/// The lane a socket dir's marker names, when it names exactly the dir it
/// sits in: a marker cannot point the tray at another lane's socket.
fn marked_lane(dir: &std::path::Path) -> Option<LaneListenerKey> {
    let text = fs::read_to_string(dir.join(LANE_TRAY_MARKER)).ok()?;
    let mut lines = text.lines();
    let (project, instance) = (lines.next()?.trim(), lines.next()?.trim());
    if project.is_empty() || instance.is_empty() || lines.next().is_some() {
        return None;
    }
    let plain = |c: &str| !c.contains('/') && c != "." && c != "..";
    if !plain(project) || !plain(instance) || mcp_socket_host_dir_for_lane(project, instance) != dir
    {
        return None;
    }
    Some((project.to_owned(), instance.to_owned()))
}

/// One adoption tick: bind every marked lane that nothing accepts on (never
/// bound, or its owner died and left a refusing socket). A lane with a live
/// owner is left alone. Returns the lanes this tick bound.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn adopt_marked_lanes() -> Vec<LaneListenerKey> {
    adopt_marked_lanes_where(|_| true)
}

/// [`adopt_marked_lanes`] limited to the lanes `wanted` accepts, so a test
/// adopts only its own lane and never a live session's.
pub(crate) fn adopt_marked_lanes_where(
    wanted: impl Fn(&LaneListenerKey) -> bool,
) -> Vec<LaneListenerKey> {
    let Ok(entries) = fs::read_dir(mcp_socket_base_dir()) else {
        return Vec::new();
    };
    let mut adopted = Vec::new();
    for entry in entries.flatten() {
        let Some((project, instance)) = marked_lane(&entry.path()) else {
            continue;
        };
        if !wanted(&(project.clone(), instance.clone())) {
            continue;
        }
        if lane_accepting(&project, &instance) {
            continue;
        }
        // A registry entry with a refusing socket is a listener this process
        // lost; forget it so the bind below is attempted.
        lane_listener_registry()
            .lock()
            .expect("lane registry lock")
            .remove(&(project.clone(), instance.clone()));
        match start_mcp_socket_server_for_lane(&project, &instance) {
            Ok(()) => adopted.push((project, instance)),
            Err(e) => warn!(project, instance, error = %e, "1863-eckw: lane adoption failed"),
        }
    }
    adopted
}

/// 1783-k5hm: the lane's socket path when ANOTHER live process serves it,
/// the exact case in which [`start_mcp_socket_server_for_lane`] refuses
/// ("already has a live owner"). Asked before a launch touches podman, so
/// the refusal comes before any container starts, not after the git mirror.
/// `None` when this process owns the lane or nothing answers.
pub(crate) fn lane_socket_foreign_owner(project: &str, instance: &str) -> Option<PathBuf> {
    let instance = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    let key = (project.to_owned(), instance.to_owned());
    if lane_listener_registry()
        .lock()
        .expect("lane registry lock")
        .contains(&key)
    {
        return None;
    }
    let path = mcp_socket_path_for_lane(project, instance);
    // 1863-eckw: the tray serves a marked lane for whichever launcher marked
    // it; that is not a second launcher holding the lane.
    if marked_lane(path.parent()?).is_some() {
        return None;
    }
    UnixStream::connect(&path).ok().map(|_| path)
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
    // 1956-4pxj: whoever serves a lane of this project also hears its git
    // mirror's push events (once per process), to pass on to the lane's forge.
    crate::lane_events::listen_for_project(project, crate::forge_instance_at_address);
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
                // 1863-eckw: on a tray-marked lane that peer is the tray
                // serving it, so the lane is served and this launch proceeds.
                Ok(_) if socket_path.parent().and_then(marked_lane).is_some() => {
                    // 1961-8ats: served, but only by this build.
                    if let Some(refusal) = build_mismatch_refusal(
                        build_identity(),
                        &lane_server_build(&socket_path)
                            .unwrap_or_else(|e| format!("unanswered ({e})")),
                    ) {
                        return Err(refusal);
                    }
                    return Ok(());
                }
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

#[cfg(test)]
mod lane_window_tests {
    use super::*;

    /// 1798-nwpg: only an exact `<project>/<instance>` reserves a lane.
    #[test]
    fn reserved_lane_parses_only_a_project_and_an_instance() {
        assert_eq!(
            reserved_lane_from(Some("rf3c-smoke/default")),
            Some(("rf3c-smoke".to_string(), "default".to_string()))
        );
        for bad in ["", "rf3c-smoke", "/default", "rf3c-smoke/", "a/b/c"] {
            assert_eq!(reserved_lane_from(Some(bad)), None, "{bad:?}");
        }
        assert_eq!(reserved_lane_from(None), None);
    }
    use tillandsias_browser_mcp::framing::{RpcRequest, RpcResponse};

    fn call(name: &str, arguments: serde_json::Value) -> RpcRequest {
        RpcRequest {
            id: Some(1),
            method: "tools/call".to_string(),
            params: serde_json::json!({ "name": name, "arguments": arguments }),
        }
    }

    // Order 1754-bu07, exit criterion 1: a window opened through one lane
    // connection is still there after that connection's server is gone, and
    // the next connection of the same lane lists it. RED before: each
    // connection built its own registry, so the second listed nothing.
    #[test]
    fn a_window_outlives_the_connection_that_opened_it() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let project = "bu07-outlive";
        {
            let opener = lane_browser_server(project, "default", None, true);
            let opened = rt.block_on(opener.handle_request(call(
                "browser.open",
                serde_json::json!({ "url": format!("http://web.{project}.localhost:8080/") }),
            )));
            assert!(matches!(opened, RpcResponse::Success { .. }), "{opened:?}");
        }
        let next = lane_browser_server(project, "default", None, true);
        let listed = rt
            .block_on(next.handle_request(call("browser.list_windows", serde_json::json!({}))))
            .to_line()
            .unwrap();
        assert!(
            listed.contains(&format!("web.{project}.localhost")),
            "{listed}"
        );
    }

    #[test]
    fn each_lane_has_its_own_registry() {
        let (a, _) = lane_windows("bu07-lanes", "default");
        let (again, _) = lane_windows("bu07-lanes", "default");
        let (other, _) = lane_windows("bu07-lanes", "second");
        assert!(std::sync::Arc::ptr_eq(&a, &again));
        assert!(!std::sync::Arc::ptr_eq(&a, &other));
    }
}

/// Order 1779-sq9g: the red fixtures of openspec/changes/forge-diagnostics-scope.
///
/// Operator rulings, 2026-10-18: a forge sees exactly (a) itself, (b) the
/// containers the host started for its lane, and (c) curated global events,
/// which reach every concurrent forge; sibling forges and their children are
/// never visible; retention is the current session. Each test drives the real
/// lane dispatch (`handle_mcp_jsonrpc`) as two lanes, `a` and `b`, of ONE
/// project, so project membership cannot be what isolates them. A fake podman
/// lists both lanes' forge and preview containers, each with its host-set
/// `tillandsias.lane` label, and answers `logs <name>` with `LOG-OF-<name>`.
///
/// RED until 1779-sq9g is implemented: the tools do not exist yet. Run with
/// `cargo test -p tillandsias-headless --bin tillandsias --features tray --
/// --ignored forge_diagnostics_scope_fixtures`. The implementation removes
/// the ignores.
#[cfg(test)]
mod forge_diagnostics_scope_fixtures {
    use super::*;

    const PROJECT: &str = "sq9g-scope";
    const A_FORGE: &str = "tillandsias-sq9g-scope-forge-a";
    const A_WEB: &str = "tillandsias-web-sq9g-scope-a";
    const B_FORGE: &str = "tillandsias-sq9g-scope-forge-b";
    const B_WEB: &str = "tillandsias-web-sq9g-scope-b";

    /// The fake podman: every container of both lanes, labelled by the host.
    const FAKE_PODMAN: &str = r#"#!/bin/sh
for last; do :; done
row() { printf '{"Names":["%s"],"Id":"%s","State":"running","Labels":{"tillandsias.lane":"%s","tillandsias.role":"%s"}}' "$1" "$1" "$2" "$3"; }
case "$1" in
  ps|container)
    printf '['
    row tillandsias-sq9g-scope-forge-a sq9g-scope/a forge; printf ','
    row tillandsias-web-sq9g-scope-a sq9g-scope/a web; printf ','
    row tillandsias-sq9g-scope-forge-b sq9g-scope/b forge; printf ','
    row tillandsias-web-sq9g-scope-b sq9g-scope/b web
    printf ']\n' ;;
  inspect)
    case "$last" in
      *-a) printf '[{"Name":"%s","Config":{"Labels":{"tillandsias.lane":"sq9g-scope/a"}}}]\n' "$last" ;;
      *-b) printf '[{"Name":"%s","Config":{"Labels":{"tillandsias.lane":"sq9g-scope/b"}}}]\n' "$last" ;;
      *) echo "Error: no such object: $last" >&2; exit 125 ;;
    esac ;;
  logs) echo "LOG-OF-$last" ;;
esac
"#;

    /// Holds the podman seam and the env lock, and restores what it changed.
    struct Seams {
        _podman: std::sync::MutexGuard<'static, ()>,
        _env: std::sync::MutexGuard<'static, ()>,
        _dir: tempfile::TempDir,
        saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    }

    impl Seams {
        fn new(extra: &[(&'static str, String)]) -> Self {
            let podman = crate::runtime_assets::podman_seam_lock();
            let env = crate::test_support::env_lock();
            let dir = tempfile::tempdir().unwrap();
            let bin = dir.path().join("podman");
            std::fs::write(&bin, FAKE_PODMAN).unwrap();
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let mut vars: Vec<(&'static str, String)> =
                vec![("TILLANDSIAS_PODMAN_BIN", bin.display().to_string())];
            vars.extend(extra.iter().cloned());
            let saved = vars
                .iter()
                .map(|(k, _)| (*k, std::env::var_os(k)))
                .collect();
            for (k, v) in &vars {
                // SAFETY: env_lock and the podman seam lock are held.
                unsafe { std::env::set_var(k, v) };
            }
            Self {
                _podman: podman,
                _env: env,
                _dir: dir,
                saved,
            }
        }
    }

    impl Drop for Seams {
        fn drop(&mut self) {
            for (k, v) in self.saved.drain(..) {
                // SAFETY: the locks are still held; they drop after this.
                unsafe {
                    match v {
                        Some(v) => std::env::set_var(k, v),
                        None => std::env::remove_var(k),
                    }
                }
            }
        }
    }

    /// One tools/call through the lane dispatch, as lane `instance`.
    fn ask(instance: &str, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server(PROJECT, instance, None, true);
        let req = serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": tool, "arguments": arguments },
        });
        handle_mcp_jsonrpc(PROJECT, instance, &req, &browser, &rt).expect("a reply")
    }

    fn refusal(reply: &serde_json::Value) -> &str {
        reply["error"]["message"].as_str().unwrap_or("")
    }

    /// Arm 1: a forge cannot read a sibling forge's logs, nor its children's,
    /// and cannot tell a sibling's container from one that does not exist.
    #[test]
    #[ignore = "red until 1779-sq9g is implemented (openspec/changes/forge-diagnostics-scope)"]
    fn a_forge_cannot_read_a_siblings_or_its_childrens_logs() {
        let _seams = Seams::new(&[]);
        for source in [B_WEB, B_FORGE, "tillandsias-does-not-exist"] {
            let reply = ask("a", "forge_logs", serde_json::json!({ "source": source }));
            assert_eq!(
                refusal(&reply),
                format!("refused:diagnostics-scope:not-in-scope:{source}"),
                "{reply}"
            );
            assert!(!reply.to_string().contains("LOG-OF-"), "{reply}");
        }
        let listed = ask("a", "forge_logs", serde_json::json!({}));
        assert!(
            listed.get("result").is_some(),
            "the source list answers: {listed}"
        );
        let text = listed.to_string();
        assert!(!text.contains(B_FORGE) && !text.contains(B_WEB), "{listed}");
    }

    /// Arm 2: a forge lists itself and the containers its lane started, and
    /// reads its children's logs.
    #[test]
    #[ignore = "red until 1779-sq9g is implemented (openspec/changes/forge-diagnostics-scope)"]
    fn a_forge_reads_its_own_childrens_logs() {
        let _seams = Seams::new(&[]);
        let listed = ask("a", "forge_logs", serde_json::json!({}));
        let text = listed["result"]["structuredContent"].to_string();
        assert!(text.contains(A_FORGE) && text.contains(A_WEB), "{listed}");
        let read = ask("a", "forge_logs", serde_json::json!({ "source": A_WEB }));
        assert!(
            read["result"]["structuredContent"]
                .to_string()
                .contains(&format!("LOG-OF-{A_WEB}")),
            "{read}"
        );
    }

    /// Arm 3: a producer-authored global event (a GitHub token refresh)
    /// reaches every concurrent forge, carries only the envelope and its
    /// kind's allowlisted fields, and no credential present in the producing
    /// process reaches either reply.
    #[cfg(feature = "vault")]
    #[test]
    #[ignore = "red until 1779-sq9g is implemented (openspec/changes/forge-diagnostics-scope)"]
    fn a_global_event_reaches_every_forge_with_only_allowlisted_fields() {
        let canary = format!("CANARY-sq9g-{}", std::process::id());
        let _seams = Seams::new(&[
            ("GH_TOKEN", canary.clone()),
            ("GITHUB_TOKEN", canary.clone()),
            ("VAULT_TOKEN", canary.clone()),
        ]);
        // Both lanes are live (their rings exist) before the event.
        let _ = ask("a", "forge_events", serde_json::json!({}));
        let _ = ask("b", "forge_events", serde_json::json!({}));
        crate::vault_bootstrap::github_token_check_before_use(
            || {
                Ok(crate::vault_bootstrap::DueCheck::Rotated {
                    expires_at: 1_800_000_000,
                    refresh_expires_at: None,
                })
            },
            false,
        );
        const ENVELOPE: [&str; 5] = ["schema_version", "seq", "at", "scope", "kind"];
        const ALLOWED: [&str; 2] = ["service", "outcome"];
        for lane in ["a", "b"] {
            let reply = ask(lane, "forge_events", serde_json::json!({}));
            assert!(!reply.to_string().contains(&canary), "lane {lane}: {reply}");
            let events = reply["result"]["structuredContent"]["events"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let refresh: Vec<_> = events
                .iter()
                .filter(|e| e["kind"] == "credential.refresh")
                .collect();
            assert_eq!(refresh.len(), 1, "lane {lane}: {reply}");
            let keys: Vec<&String> = refresh[0].as_object().unwrap().keys().collect();
            assert!(
                keys.iter()
                    .all(|k| ENVELOPE.contains(&k.as_str()) || ALLOWED.contains(&k.as_str())),
                "lane {lane}: only the envelope and the allowlist, got {keys:?}"
            );
            assert_eq!(refresh[0]["scope"], "global");
        }
    }
}

#[cfg(test)]
mod lane_adoption_tests {
    use super::*;

    /// ORDER 1901-8keq: each test runs under a SHORT `XDG_RUNTIME_DIR`, held
    /// for its life under the env lock. Without it the lane socket lands under
    /// macOS TMPDIR (/var/folders/<hash>/T/), past the 104-byte sun_path cap
    /// ("path must be shorter than SUN_LEN"), and on Linux under the real
    /// /run/user dir. Same remedy as 1581-sunl's short_runtime_root.
    struct ShortRuntime {
        _env: std::sync::MutexGuard<'static, ()>,
        _root: tempfile::TempDir,
        prior: Option<std::ffi::OsString>,
    }

    impl Drop for ShortRuntime {
        fn drop(&mut self) {
            match self.prior.take() {
                Some(v) => unsafe { std::env::set_var("XDG_RUNTIME_DIR", v) },
                None => unsafe { std::env::remove_var("XDG_RUNTIME_DIR") },
            }
        }
    }

    fn lane(tag: &str) -> (LaneListenerKey, ShortRuntime) {
        let env = crate::test_support::env_lock();
        let root = tempfile::Builder::new()
            .prefix("tm")
            .tempdir_in("/tmp")
            .expect("short runtime root under /tmp");
        let prior = std::env::var_os("XDG_RUNTIME_DIR");
        unsafe { std::env::set_var("XDG_RUNTIME_DIR", root.path()) };
        let key = (
            format!("eckw-{tag}-{}", std::process::id()),
            "w1".to_owned(),
        );
        (
            key,
            ShortRuntime {
                _env: env,
                _root: root,
                prior,
            },
        )
    }

    /// The state a web-mode session was left in on 2026-10-25: the launching
    /// CLI bound the lane and exited, leaving a socket file nobody listens on.
    fn leave_stale_socket((project, instance): &LaneListenerKey) -> PathBuf {
        let path = mcp_socket_path_for_lane(project, instance);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let _ = fs::remove_file(&path);
        drop(UnixListener::bind(&path).unwrap());
        // 1980-lsrc: a parallel test's fork may hold the listener until exec.
        assert!(
            wait_until_refused(&path),
            "the fixture must reproduce the refusing socket"
        );
        path
    }

    fn cleanup((project, instance): &LaneListenerKey) {
        let _ = fs::remove_dir_all(mcp_socket_host_dir_for_lane(project, instance));
    }

    #[test]
    fn a_marked_lane_whose_launcher_exited_answers_again_after_one_tray_tick() {
        let (key, _rt) = lane("adopt");
        let path = leave_stale_socket(&key);
        mark_lane_tray_owned(&key.0, &key.1).unwrap();
        // The marker's on-disk name is the contract between launcher and tray.
        assert!(path.parent().unwrap().join("tray-owned").is_file());

        let adopted = adopt_marked_lanes_where(|l| *l == key);

        let answered = UnixStream::connect(&path).is_ok();
        cleanup(&key);
        assert_eq!(adopted, vec![key.clone()]);
        assert!(answered, "pre-fix: connect() on the lane socket is refused");
    }

    /// ORDER 1911-3dqo: systemd-oomd killed the launcher and the forge kept
    /// running; the lane socket it bound was left refusing. A rejoin must make
    /// the lane answer again, and hand it to the tray so the next launcher
    /// death does not repeat this.
    #[test]
    fn a_rejoin_serves_a_lane_whose_launcher_was_killed() {
        let (key, _rt) = lane("rejoin");
        let path = leave_stale_socket(&key);

        let served = serve_lane_for_rejoin(&key.0, &key.1);

        let answered = UnixStream::connect(&path).is_ok();
        let marked = path.parent().unwrap().join(LANE_TRAY_MARKER).is_file();
        cleanup(&key);
        assert_eq!(served, Ok(()));
        assert!(answered, "pre-fix: connect() on the lane socket is refused");
        assert!(marked, "the rejoined lane is handed to the tray");
    }

    #[test]
    fn a_tick_leaves_a_lane_with_a_live_owner_alone() {
        let (key, _rt) = lane("live");
        let path = mcp_socket_path_for_lane(&key.0, &key.1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let _ = fs::remove_file(&path);
        let _owner = UnixListener::bind(&path).unwrap();
        mark_lane_tray_owned(&key.0, &key.1).unwrap();

        let adopted = adopt_marked_lanes_where(|l| *l == key);
        cleanup(&key);
        assert!(adopted.is_empty(), "{adopted:?}");
    }

    #[test]
    fn an_unmarked_stale_lane_is_not_adopted() {
        let (key, _rt) = lane("unmarked");
        leave_stale_socket(&key);
        let adopted = adopt_marked_lanes_where(|l| *l == key);
        cleanup(&key);
        assert!(adopted.is_empty(), "{adopted:?}");
    }

    #[test]
    fn a_marker_naming_another_lane_is_ignored() {
        let (key, _rt) = lane("spoof");
        let dir = mcp_socket_host_dir_for_lane(&key.0, &key.1);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(LANE_TRAY_MARKER), "default\ndefault\n").unwrap();
        let marked = marked_lane(&dir);
        cleanup(&key);
        assert_eq!(marked, None);
    }

    #[test]
    fn a_tray_owned_lane_is_not_refused_as_a_foreign_launcher() {
        let (key, _rt) = lane("foreign");
        let path = mcp_socket_path_for_lane(&key.0, &key.1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let _ = fs::remove_file(&path);
        let _owner = UnixListener::bind(&path).unwrap();
        let unmarked = lane_socket_foreign_owner(&key.0, &key.1);
        mark_lane_tray_owned(&key.0, &key.1).unwrap();
        let marked = lane_socket_foreign_owner(&key.0, &key.1);
        cleanup(&key);
        assert_eq!(unmarked, Some(path));
        assert_eq!(marked, None);
    }

    /// 1863-eckw: the launch after an adoption binds a lane the tray already
    /// serves. The tray's listener is the lane being served, not a rival.
    #[test]
    fn a_relaunch_onto_a_tray_served_lane_is_not_refused() {
        let (key, _rt) = lane("relaunch");
        let path = mcp_socket_path_for_lane(&key.0, &key.1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let _ = fs::remove_file(&path);
        stub_tray(&path, Some(build_identity()));
        mark_lane_tray_owned(&key.0, &key.1).unwrap();
        let bound = start_mcp_socket_server_for_lane(&key.0, &key.1);
        cleanup(&key);
        assert_eq!(bound, Ok(()));
    }

    /// 1961-8ats: a stub tray on `path` answering every `initialize` with
    /// `build` as its serverInfo buildId, or with none (a pre-1961 tray).
    fn stub_tray(path: &std::path::Path, build: Option<&str>) {
        use std::io::{BufRead, BufReader, Write};
        let listener = UnixListener::bind(path).unwrap();
        let build = build.map(str::to_owned);
        std::thread::spawn(move || {
            // One thread per connection, as the real tray serves them: a
            // caller may hold one connection open while it probes on another.
            for mut stream in listener.incoming().flatten() {
                let build = build.clone();
                std::thread::spawn(move || {
                    let mut line = String::new();
                    if BufReader::new(&stream).read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    let mut info = serde_json::json!({ "name": "stub-tray", "version": "56.11.1" });
                    if let Some(b) = &build {
                        info["buildId"] = serde_json::json!(b);
                    }
                    let reply = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "result": { "serverInfo": info } });
                    let _ = writeln!(stream, "{reply}");
                });
            }
        });
    }

    fn lane_with_stub_tray(name: &str, build: Option<&str>) -> (LaneListenerKey, impl Drop) {
        let (key, rt) = lane(name);
        let path = mcp_socket_path_for_lane(&key.0, &key.1);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let _ = fs::remove_file(&path);
        stub_tray(&path, build);
        mark_lane_tray_owned(&key.0, &key.1).unwrap();
        (key, rt)
    }

    /// 1961-8ats: a tray of another build never takes the lane. Both the
    /// pre-launch check and the bind refuse, naming both builds.
    #[test]
    fn a_tray_of_another_build_is_refused_the_lane_naming_both() {
        let (key, _rt) = lane_with_stub_tray("otherbuild", Some("56.11.1.1+00000000deadbeef"));
        let early = lane_served_by_other_build(&key.0, &key.1);
        let bound = start_mcp_socket_server_for_lane(&key.0, &key.1);
        cleanup(&key);
        let want = format!(
            "refused:lane-tray-version-mismatch:lane={} tray=56.11.1.1+00000000deadbeef",
            build_identity()
        );
        assert!(
            early.as_deref().is_some_and(|r| r.starts_with(&want)),
            "{early:?}"
        );
        assert!(
            bound.as_ref().is_err_and(|r| r.starts_with(&want)),
            "{bound:?}"
        );
    }

    /// 1961-8ats: the yoga case. A tray older than the handshake sends no
    /// buildId, and an unknown build is never this one.
    #[test]
    fn a_tray_without_a_build_id_is_refused_the_lane() {
        let (key, _rt) = lane_with_stub_tray("nobuildid", None);
        let early = lane_served_by_other_build(&key.0, &key.1);
        cleanup(&key);
        assert!(
            early
                .as_deref()
                .is_some_and(|r| r.contains("tray=56.11.1+unknown")),
            "{early:?}"
        );
    }

    /// 1961-8ats: the same build still takes the lane, as before.
    #[test]
    fn a_tray_of_this_build_takes_the_lane() {
        let (key, _rt) = lane_with_stub_tray("samebuild", Some(build_identity()));
        let early = lane_served_by_other_build(&key.0, &key.1);
        cleanup(&key);
        assert_eq!(early, None);
    }

    /// 1961-8ats: the real initialize reply carries this build, so a test
    /// can assert what answered it.
    #[test]
    fn initialize_names_the_serving_build() {
        assert!(
            !build_identity().ends_with("+unknown"),
            "{}",
            build_identity()
        );
        let browser = lane_browser_server("p", "default", None, true);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let req = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize" });
        let reply = handle_mcp_jsonrpc("p", "default", &req, &browser, &rt).unwrap();
        assert_eq!(reply["result"]["serverInfo"]["buildId"], build_identity());
    }
}

/// ORDER 1874-kkrc exit criterion: tools/list carries image.generate, and a
/// tools/call through the real dispatcher (engine stubbed) returns the
/// 1871-47ex schema with no base64 run over 256 characters, streams progress
/// as notifications before the response, and writes into the lane scratch dir
/// the forge sees at /work/tmp/imagegen. Pre-fix: image.generate is unknown.
#[cfg(test)]
mod image_generate_fixtures {
    use super::*;
    use crate::imagegen_tool::{Engine, EngineOut, Job, Progress, Seam, install_seam};
    use std::path::Path;

    /// A real PNG of `w`x`h` (RGBA when `alpha`), written by the `image` crate.
    struct Stub;
    impl Engine for Stub {
        fn generate(
            &self,
            job: &Job,
            out_dir: &Path,
            names: &[String],
            progress: &mut dyn FnMut(Progress),
        ) -> Result<EngineOut, String> {
            for s in 1..=job.steps {
                progress(Progress::Step {
                    done: s,
                    total: job.steps,
                });
            }
            for n in names {
                image::RgbImage::new(job.width, job.height)
                    .save(out_dir.join(n))
                    .map_err(|e| e.to_string())?;
            }
            Ok(EngineOut {
                timings: Default::default(),
                backend: "vulkan".into(),
                first_use: false,
            })
        }
    }

    fn longest_base64_run(s: &str) -> usize {
        let mut best = 0;
        let mut run = 0;
        for c in s.chars() {
            if c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=' {
                run += 1;
                best = best.max(run);
            } else {
                run = 0;
            }
        }
        best
    }

    #[test]
    fn image_generate_is_listed_and_returns_files_with_metadata_and_progress() {
        let _g = crate::imagegen_tool::SEAM_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        install_seam(Some(Seam {
            engine: std::sync::Arc::new(Stub),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I1".into(),
            // Only I0's files are "here": the tierless call runs I0 whatever
            // this host's real model cache holds (1957-5m8g).
            present: Some(vec!["I0".into()]),
        }));
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("kkrc-proj", "a", None, true);

        let list = handle_mcp_jsonrpc(
            "kkrc-proj",
            "a",
            &serde_json::json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
            &browser,
            &rt,
        )
        .unwrap();
        let tools = list["result"]["tools"].as_array().unwrap();
        let desc = tools
            .iter()
            .find(|t| t["name"] == "image.generate")
            .expect("image.generate is listed");
        assert_eq!(desc["inputSchema"]["required"][0], "prompt");
        // 1956-x7xp: the studio runner sits beside it, under the same gate.
        let studio = tools
            .iter()
            .find(|t| t["name"] == "studio.run_workflow")
            .expect("studio.run_workflow is listed");
        assert_eq!(studio["inputSchema"]["required"][0], "workflow");
        let d = desc["description"].as_str().unwrap();
        assert!(d.contains("deleted when the forge shuts down"), "{d}");
        // 1956-26qh: the family checker is listed beside it, and asks only
        // for a project-relative spec path.
        let vf = tools
            .iter()
            .find(|t| t["name"] == "studio.validate_family")
            .expect("studio.validate_family is listed");
        assert_eq!(vf["inputSchema"]["required"][0], "spec");

        let mut lines = Vec::new();
        let reply = handle_mcp_jsonrpc_streaming(
            "kkrc-proj",
            "a",
            &serde_json::json!({
                "jsonrpc":"2.0","id":2,"method":"tools/call",
                "params":{"name":"image.generate","_meta":{"progressToken":"t1"},
                          "arguments":{"prompt":"a red fox","width":640,"height":384,"steps":3,"seed":7}}
            }),
            &browser,
            &rt,
            &mut |l| lines.push(l),
        )
        .unwrap();
        install_seam(None);

        let r = &reply["result"]["structuredContent"];
        for key in [
            "path",
            "width",
            "height",
            "has_alpha",
            "thumbnail_path",
            "model",
            "licence",
            "tier",
            "backend",
            "seed",
            "steps",
            "elapsed_s",
            "ephemeral",
        ] {
            assert!(!r[key].is_null(), "result lacks {key}: {reply}");
        }
        assert_eq!(
            (r["width"].as_u64(), r["height"].as_u64()),
            (Some(640), Some(384))
        );
        assert_eq!(r["tier"], "I0", "the highest tier already here");
        assert_eq!(r["seed"], 7);
        assert_eq!(r["steps"], 3);
        assert_eq!(r["ephemeral"], true);
        let path = r["path"].as_str().unwrap();
        assert!(path.starts_with("/work/tmp/imagegen/"), "{path}");
        let host = scratch
            .path()
            .join(crate::imagegen_tool::lane_volume("kkrc-proj", "a"))
            .join(path.rsplit('/').next().unwrap());
        assert!(host.is_file(), "{}", host.display());
        crate::imagegen_tool::flush_thumbnails();
        let thumb = r["thumbnail_path"].as_str().unwrap();
        let thumb_host = scratch
            .path()
            .join(crate::imagegen_tool::lane_volume("kkrc-proj", "a"))
            .join(thumb.rsplit('/').next().unwrap());
        let (tw, th) = image::image_dimensions(&thumb_host).unwrap();
        assert!(tw <= 256 && th <= 256, "{tw}x{th}");
        let text = reply.to_string();
        assert!(
            longest_base64_run(&text) <= 256,
            "a base64 run over 256 chars: {text}"
        );

        assert_eq!(
            lines.len(),
            3,
            "one progress notification per step: {lines:?}"
        );
        assert_eq!(lines[0]["method"], "notifications/progress");
        assert_eq!(lines[0]["params"]["progressToken"], "t1");
        assert_eq!(lines[2]["params"]["progress"], 3.0);
    }

    /// ORDER 1971-mcpu: the Kumbia trial's first ControlNet call (I1,
    /// openpose, a LoRA, 768x960, count 2) closed the whole lane connection.
    /// Through the real dispatcher with a stub engine, it must answer.
    #[test]
    fn image_generate_with_control_net_and_lora_answers() {
        let _g = crate::imagegen_tool::SEAM_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        install_seam(Some(Seam {
            engine: std::sync::Arc::new(Stub),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I1".into(),
            present: Some(vec!["I0".into(), "I1".into()]),
        }));
        let vol = scratch
            .path()
            .join(crate::imagegen_tool::lane_volume("mcpu-proj", "a"))
            .join("kumbia");
        std::fs::create_dir_all(&vol).unwrap();
        image::RgbImage::new(768, 960)
            .save(vol.join("smoke.pose.png"))
            .unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("mcpu-proj", "a", None, true);
        let req = serde_json::json!({
            "jsonrpc":"2.0","id":3,"method":"tools/call",
            "params":{"name":"image.generate","arguments":{
                "prompt":"a fighter, pixel art","tier":"I1","control_net":"openpose",
                "control_image":"/work/tmp/imagegen/kumbia/smoke.pose.png",
                "loras":[{"name":"pixel-art-xl","weight":0.8}],
                "width":768,"height":960,"seed":930000,"count":2}}
        });
        let got = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            handle_mcp_jsonrpc("mcpu-proj", "a", &req, &browser, &rt)
        }));
        install_seam(None);
        let reply = got
            .expect("image.generate with control_net panicked")
            .unwrap();
        assert_eq!(reply["id"], 3, "{reply}");
        assert!(reply["error"].is_null(), "{reply}");
    }

    struct Panics;
    impl Engine for Panics {
        fn generate(
            &self,
            _: &Job,
            _: &Path,
            _: &[String],
            _: &mut dyn FnMut(Progress),
        ) -> Result<EngineOut, String> {
            panic!("models.tsv role controlnet:openpose has no sd-cli flag");
        }
    }

    /// ORDER 1971-mcpu: a tool that panics answers its own call with a typed
    /// `tool_panicked` error, and the next call on the same path still works.
    /// Pre-fix: the panic unwound the connection thread (dispatch_guarded
    /// did not exist; the lane lost all 40 host tools).
    #[test]
    fn a_panicking_tool_answers_with_a_typed_error_and_the_next_call_works() {
        let _g = crate::imagegen_tool::SEAM_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let seam = |engine: std::sync::Arc<dyn Engine>| Seam {
            engine,
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I0".into(),
            present: Some(vec!["I0".into()]),
        };
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("guard-proj", "a", None, true);
        let call = |id: u64| {
            serde_json::json!({"jsonrpc":"2.0","id":id,"method":"tools/call",
                "params":{"name":"image.generate","arguments":{"prompt":"x","seed":1}}})
        };

        install_seam(Some(seam(std::sync::Arc::new(Panics))));
        let req = call(7);
        let reply = dispatch_guarded(&req, || {
            handle_mcp_jsonrpc("guard-proj", "a", &req, &browser, &rt)
        })
        .expect("a call with an id is answered");
        assert_eq!(reply["id"], 7, "{reply}");
        let msg = reply["error"]["message"].as_str().unwrap_or("");
        assert!(
            msg.starts_with("tool_panicked: image.generate") && msg.contains("controlnet:openpose"),
            "{reply}"
        );

        install_seam(Some(seam(std::sync::Arc::new(Stub))));
        let req = call(8);
        let reply = dispatch_guarded(&req, || {
            handle_mcp_jsonrpc("guard-proj", "a", &req, &browser, &rt)
        })
        .unwrap();
        install_seam(None);
        assert!(reply["error"].is_null(), "the next call works: {reply}");
        assert_eq!(reply["id"], 8);
    }
}

/// LIVE, opt-in (1874-kkrc): a real image.generate through a real lane
/// socket, real engine, real model cache. Lane `<project>-imggen-e2e`, so no
/// operator lane is touched. Output stays in cache_root()/imagegen-scratch.
/// TILLANDSIAS_IMAGEGEN_E2E_PROJECT (default kumbia-kombat),
/// TILLANDSIAS_IMAGEGEN_E2E_ARGS (JSON arguments).
#[cfg(test)]
#[test]
#[ignore = "live: builds the imagegen image and runs a GPU generate"]
fn live_image_generate_through_the_lane_socket() {
    use std::io::{BufRead, BufReader, Write};
    let project = std::env::var("TILLANDSIAS_IMAGEGEN_E2E_PROJECT")
        .unwrap_or_else(|_| "kumbia-kombat".into());
    let args: serde_json::Value = serde_json::from_str(
        &std::env::var("TILLANDSIAS_IMAGEGEN_E2E_ARGS").unwrap_or_else(|_| {
            r#"{"prompt":"a red fox in snow, pixel art","width":512,"height":512,"seed":7}"#.into()
        }),
    )
    .unwrap();
    start_mcp_socket_server_for_lane(&project, "imggen-e2e").expect("lane listener");
    let sock = mcp_socket_path_for_lane(&project, "imggen-e2e");
    let stream = UnixStream::connect(&sock).expect("connect");
    let mut w = stream.try_clone().unwrap();
    let mut r = BufReader::new(stream);
    let t0 = std::time::Instant::now();
    writeln!(
        w,
        "{}",
        serde_json::json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
            "name":"image.generate","_meta":{"progressToken":"e2e"},"arguments":args}})
    )
    .unwrap();
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).unwrap() == 0 {
            panic!("socket closed");
        }
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        if v["method"] == "notifications/progress" {
            eprintln!(
                "[{:6.2}s] progress {}",
                t0.elapsed().as_secs_f64(),
                v["params"]["message"]
            );
            continue;
        }
        eprintln!("[{:6.2}s] reply {v}", t0.elapsed().as_secs_f64());
        assert!(v["error"].is_null(), "{v}");
        let res = &v["result"]["structuredContent"];
        let host = crate::imagegen_tool::lane_scratch_dir(&project, "imggen-e2e")
            .unwrap()
            .join(res["path"].as_str().unwrap().rsplit('/').next().unwrap());
        eprintln!("host file: {}", host.display());
        assert!(host.is_file());
        break;
    }
}

/// Order 1969-7qm7: the grouped host tool surface. A deprecated flat name
/// behaves exactly as its namespaced canonical name, every description says
/// what the tool starts, and the `initialize` reply carries the grouped index.
#[cfg(test)]
mod host_tool_discovery_fixtures {
    use super::*;

    fn list(
        browser: &tillandsias_browser_mcp::BrowserMcpServer,
        rt: &tokio::runtime::Runtime,
    ) -> Vec<serde_json::Value> {
        handle_mcp_jsonrpc(
            "p",
            "default",
            &serde_json::json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
            browser,
            rt,
        )
        .unwrap()["result"]["tools"]
            .as_array()
            .cloned()
            .unwrap()
    }

    #[test]
    fn initialize_carries_the_grouped_index_as_instructions() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("p", "default", None, true);
        let init = handle_mcp_jsonrpc(
            "p",
            "default",
            &serde_json::json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}),
            &browser,
            &rt,
        )
        .unwrap();
        let text = init["result"]["instructions"]
            .as_str()
            .expect("instructions");
        assert_eq!(text, crate::host_tools::instructions());
        for prefix in [
            "preview.*",
            "image.*",
            "studio.*",
            "browser.*",
            "webstudio.*",
        ] {
            assert!(text.contains(prefix), "{prefix}");
        }
    }

    #[test]
    fn every_renamed_tool_is_listed_under_both_names_with_one_schema() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("p", "default", None, true);
        let tools = list(&browser, &rt);
        for (canonical, alias) in crate::host_tools::RENAMED {
            let c = tools
                .iter()
                .find(|t| t["name"] == *canonical)
                .unwrap_or_else(|| panic!("{canonical} listed"));
            let a = tools
                .iter()
                .find(|t| t["name"] == *alias)
                .unwrap_or_else(|| panic!("{alias} listed"));
            assert_eq!(
                c["inputSchema"], a["inputSchema"],
                "{alias} keeps {canonical}'s schema"
            );
            let d = a["description"].as_str().unwrap();
            assert!(
                d.starts_with(&format!("Deprecated alias of {canonical}")),
                "{d}"
            );
            assert!(
                !c["description"].as_str().unwrap().contains("Deprecated"),
                "{canonical}"
            );
        }
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        let mut seen = std::collections::BTreeSet::new();
        for n in &names {
            assert!(seen.insert(*n), "{n} listed twice: {names:?}");
        }
    }

    #[test]
    fn descriptions_name_what_each_host_tool_starts() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("p", "default", None, true);
        let tools = list(&browser, &rt);
        let desc = |name: &str| -> String {
            tools
                .iter()
                .find(|t| t["name"] == name)
                .unwrap_or_else(|| panic!("{name}"))["description"]
                .as_str()
                .unwrap()
                .to_string()
        };
        assert!(desc("preview.publish").contains("STARTS a sibling web container"));
        assert!(
            desc("toolchain.prepare")
                .contains("STARTS a one-time build of the shared toolchain image")
        );
        assert!(desc("image.generate").contains("locally on this computer"));
        assert!(desc("studio.run_workflow").contains("studio container"));
        assert!(desc("webstudio.open").contains("STARTS the studio through the tray"));
        assert!(desc("webstudio.options").contains("Each option carries its affordances"));
        for n in [
            "preview.status",
            "preview.stop",
            "preview.logs",
            "webstudio.changes",
            "webstudio.publish_request",
            crate::host_tools::INDEX_TOOL,
        ] {
            assert!(
                desc(n).to_lowercase().contains("starts nothing"),
                "{n}: {}",
                desc(n)
            );
        }
    }

    /// Order 2025-e6mi: "open in a studio" from a forge launches the studio
    /// through the tray and hands the agent its URLs, for any project. RED
    /// before: webstudio.open answered an error naming `tillandsias --studio`
    /// for the operator to run, and launched nothing.
    #[test]
    fn webstudio_open_launches_from_the_lane_once_and_returns_its_urls() {
        use crate::studio::{LaneLauncher, with_test_launcher};
        use std::sync::Mutex;

        #[derive(Default)]
        struct Stub {
            launches: Mutex<Vec<(String, String, String)>>,
        }
        impl LaneLauncher for Stub {
            fn project_remote(&self, project: &str) -> Result<String, String> {
                Ok(format!("https://github.com/someone/{project}.git"))
            }
            fn launch(&self, project: &str, remote: &str, studio: &str) -> Result<bool, String> {
                let mut l = self.launches.lock().unwrap();
                let key = (project.to_string(), remote.to_string(), studio.to_string());
                if l.contains(&key) {
                    return Ok(false);
                }
                l.push(key);
                Ok(true)
            }
            fn router_port(&self) -> Option<u16> {
                Some(8080)
            }
        }

        let rt = tokio::runtime::Runtime::new().unwrap();
        let project = "e6mi-site";
        let browser = lane_browser_server(project, "default", None, true);
        let open = |studio: &str| {
            handle_mcp_jsonrpc(
                project,
                "default",
                &serde_json::json!({"jsonrpc":"2.0","id":1,"method":"tools/call",
                    "params":{"name":"webstudio.open","arguments":{"studio": studio}}}),
                &browser,
                &rt,
            )
            .unwrap()
        };
        let stub = std::sync::Arc::new(Stub::default());
        let (first, second, unknown, unbuilt) = with_test_launcher(stub.clone(), || {
            (
                open("grapesjs"),
                open("grapesjs"),
                open("nope"),
                open("onlook"),
            )
        });

        let text = |r: &serde_json::Value| r.to_string();
        assert!(first.get("error").is_none(), "{first}");
        for needle in [
            "\\\"started\\\":true",
            "window_url",
            "preview_url",
            "studio.e6mi-site.localhost:8080",
        ] {
            assert!(text(&first).contains(needle), "{needle}: {first}");
        }
        assert!(!text(&first).contains("tillandsias --studio"), "{first}");
        assert!(text(&second).contains("\\\"started\\\":false"), "{second}");
        assert_eq!(
            *stub.launches.lock().unwrap(),
            [(
                project.to_string(),
                format!("https://github.com/someone/{project}.git"),
                "grapesjs".to_string()
            )],
            "launched exactly once, with the lane's project identity"
        );
        assert!(unknown.get("error").is_some(), "{unknown}");
        assert!(unbuilt.get("error").is_some(), "{unbuilt}");
        assert!(text(&unbuilt).contains("CodeSandbox") || text(&unbuilt).contains("cloud account"));

        // The descriptor and the agent guidance no longer send the agent to
        // the operator with a command.
        let tools = list(&browser, &rt);
        let d = tools
            .iter()
            .find(|t| t["name"] == "webstudio.open")
            .unwrap()["description"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(!d.contains("starts nothing from the lane"), "{d}");
        assert!(d.contains("STARTS"), "{d}");
        let guidance =
            include_str!("../../../images/default/config-overlay/mcp/forge-agent-guidance.md");
        assert!(
            !guidance.contains("`webstudio.open` starts nothing from the lane"),
            "forge-agent-guidance.md still says webstudio.open starts nothing"
        );
    }

    #[test]
    fn a_deprecated_alias_dispatches_exactly_as_its_canonical_name() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let browser = lane_browser_server("p", "default", None, true);
        // preview.stop and preview.reload refuse a non-WEB category BEFORE any
        // host side effect, so the refusal text is the behaviour to compare.
        for (canonical, alias) in [
            ("preview.stop", "service_stop"),
            ("preview.reload", "service_reload"),
            ("preview.logs", "service_logs"),
            ("preview.publish", "publish_local"),
        ] {
            let call = |name: &str| {
                handle_mcp_jsonrpc(
                    "p",
                    "default",
                    &serde_json::json!({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":name,"arguments":{"category":"API"}}}),
                    &browser,
                    &rt,
                )
                .unwrap()
            };
            let (c, a) = (call(canonical), call(alias));
            assert_eq!(c, a, "{alias} and {canonical} answer identically");
            assert_eq!(c["id"], 9);
            assert!(
                c["error"]["message"].as_str().unwrap().contains(canonical),
                "{c}"
            );
        }
        // The index tool answers under its own name, and an unknown name is
        // still unknown (the alias table rewrites only its own rows).
        let idx = handle_mcp_jsonrpc(
            "p",
            "default",
            &serde_json::json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":crate::host_tools::INDEX_TOOL,"arguments":{}}}),
            &browser,
            &rt,
        )
        .unwrap();
        let text = idx["result"]["content"][0]["text"].as_str().unwrap();
        let payload: serde_json::Value = serde_json::from_str(text).unwrap();
        assert_eq!(
            payload["deprecated_aliases"].as_array().unwrap().len(),
            crate::host_tools::RENAMED.len()
        );
        let unknown = handle_mcp_jsonrpc(
            "p",
            "default",
            &serde_json::json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"publish.local","arguments":{}}}),
            &browser,
            &rt,
        )
        .unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
    }
}

#[cfg(test)]
mod lane_freshness_tests {
    use super::*;

    /// 2003-stbf: a lane is current only when its build matches the
    /// installed one; a different installed build is stale, naming both
    /// versions; an unreadable installed build or a lane that cannot name its
    /// own is unknown, never current. Pre-fix: FAILS, nothing compared them.
    #[test]
    fn a_lane_reports_current_stale_or_unknown_against_the_installed_build() {
        let cur = lane_freshness("56.11.6.1+aaaa", Some("56.11.6.1+aaaa"));
        assert_eq!(cur["status"], "current");
        let stale = lane_freshness("56.11.4.1+bbbb", Some("56.11.6.1+aaaa"));
        assert_eq!(stale["status"], "stale");
        assert_eq!(stale["lane_version"], "56.11.4.1");
        assert_eq!(stale["installed_version"], "56.11.6.1");
        let why = stale["why"].as_str().unwrap();
        assert!(
            why.contains("56.11.4.1") && why.contains("56.11.6.1") && why.contains("relaunched"),
            "{why}"
        );
        // A rebuild at the same version is still a different build.
        assert_eq!(
            lane_freshness("56.11.6.1+bbbb", Some("56.11.6.1+aaaa"))["status"],
            "stale"
        );
        assert_eq!(lane_freshness("56.11.6.1+aaaa", None)["status"], "unknown");
        assert_eq!(
            lane_freshness("56.11.6.1+unknown", Some("56.11.6.1+unknown"))["status"],
            "unknown"
        );
        assert_eq!(
            lane_freshness("unanswered (refused)", Some("56.11.6.1+aaaa"))["status"],
            "unknown"
        );
        assert_eq!(
            parse_version_line("Tillandsias v56.10.26.2\n").as_deref(),
            Some("56.10.26.2")
        );
        assert_eq!(parse_version_line("something else"), None);
        assert_eq!(parse_version_line("Tillandsias v$(rm -rf)"), None);
    }
}

#[cfg(test)]
mod lane_server_who_tests {
    /// 2070-mtf9: a lane socket names the process listening on it, so a
    /// tray upgrade can say WHICH old launcher still serves a lane (on
    /// macuahuitl, pid 1020477 with its exe deleted).
    #[test]
    fn a_lane_socket_names_the_process_listening_on_it() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("mcp.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        assert_eq!(
            super::lane_listener_pid(&sock),
            Some(std::process::id() as i32)
        );
        let who = super::describe_lane_server(&sock).unwrap();
        assert_eq!(who, format!("pid {}", std::process::id()));
        assert!(super::describe_lane_server(&dir.path().join("none.sock")).is_none());
    }

    #[test]
    fn a_deleted_exe_is_named() {
        assert_eq!(
            super::exe_note("/usr/bin/tillandsias (deleted)"),
            " (exe deleted)"
        );
        assert_eq!(super::exe_note("/usr/bin/tillandsias"), "");
    }
}
