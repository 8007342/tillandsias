//! @trace spec:local-web-preview
//! Opt-in live acceptance against an existing tillandsias.org forge lane.
//! Required environment: TILLANDSIAS_PREVIEW_E2E_SOCKET, _FORGE, _CA.
//! The host checkout is never edited; only a uniquely named forge asset is used.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::time::{Duration, Instant};

fn rpc(socket: &str, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(socket).expect("connect authenticated lane MCP socket");
    stream
        .set_read_timeout(Some(Duration::from_secs(120)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    writeln!(
        stream,
        "{}",
        json!({"jsonrpc":"2.0", "id":1, "method":method, "params":params})
    )
    .unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).expect("MCP response must be a JSON frame")
}

fn call(socket: &str, tool: &str, arguments: Value) -> Value {
    rpc(
        socket,
        "tools/call",
        json!({"name":tool, "arguments":arguments}),
    )
}

fn successful(response: Value) -> Value {
    assert!(response.get("error").is_none(), "MCP error: {response}");
    response.get("result").expect("MCP result").clone()
}

fn command(program: &str, args: &[&str]) -> String {
    let output = Command::new(program).args(args).output().unwrap();
    assert!(
        output.status.success(),
        "{program} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

fn https_target(url: &str) -> (String, String) {
    let parsed = reqwest::Url::parse(url).expect("valid published URL");
    assert_eq!(parsed.scheme(), "https", "HTTP cannot pass TLS acceptance");
    assert_eq!(parsed.host_str(), Some("www.tillandsias.org.localhost"));
    assert!(parsed.username().is_empty() && parsed.password().is_none());
    let port = parsed.port_or_known_default().unwrap();
    (
        parsed.to_string(),
        format!("www.tillandsias.org.localhost:{port}:127.0.0.1"),
    )
}

fn fetch(url: &str, resolve: &str, ca: &str) -> std::process::Output {
    Command::new("curl")
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--max-time",
            "5",
            "--noproxy",
            "*",
            "--cacert",
            ca,
            "--resolve",
            resolve,
            "--header",
            "Cache-Control: no-cache",
            url,
        ])
        .output()
        .expect("curl available")
}

fn await_asset(url: &str, resolve: &str, ca: &str, expected: &str) {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let output = fetch(url, resolve, ca);
        if output.status.success() && output.stdout == expected.as_bytes() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "asset watch/readiness deadline: status={}, stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        std::thread::sleep(Duration::from_millis(250));
    }
}

struct Cleanup {
    socket: String,
    forge: String,
    asset: String,
    owns_service: bool,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        if self.owns_service {
            // Cleanup must not hide the original assertion if the listener failed.
            let _ = std::panic::catch_unwind(|| {
                call(&self.socket, "service_stop", json!({"category":"WEB"}))
            });
        }
        let _ = Command::new("podman")
            .args(["exec", &self.forge, "rm", "-f", "--", &self.asset])
            .output();
    }
}

#[test]
fn https_target_preserves_explicit_port() {
    let (_, resolve) = https_target("https://www.tillandsias.org.localhost:8443/");
    assert_eq!(resolve, "www.tillandsias.org.localhost:8443:127.0.0.1");
}

#[test]
#[should_panic(expected = "HTTP cannot pass TLS acceptance")]
fn https_target_refuses_http() {
    https_target("http://www.tillandsias.org.localhost:8080/");
}

#[test]
#[ignore = "requires a running real tillandsias.org forge, lane MCP socket, local CA and Wrangler image"]
fn live_forge_assets_https_mcp_lifecycle() {
    let required = |suffix: &str| {
        std::env::var(format!("TILLANDSIAS_PREVIEW_E2E_{suffix}"))
            .unwrap_or_else(|_| panic!("missing live prerequisite: {suffix}"))
    };
    let socket = required("SOCKET");
    let forge = required("FORGE");
    let ca = required("CA");
    let root = "/home/forge/src/tillandsias.org";
    let head = command(
        "podman",
        &["exec", &forge, "git", "-C", root, "rev-parse", "HEAD"],
    );
    let anchors = command("trust", &["list", "--filter=ca-anchors"]);
    let initial = successful(call(&socket, "service_status", json!({})));
    assert_eq!(
        initial["state"], "stopped",
        "refuse to disturb an existing preview"
    );

    let tools = successful(rpc(&socket, "tools/list", json!({})));
    for name in [
        "publish_local",
        "service_status",
        "service_stop",
        "service_reload",
    ] {
        assert!(
            tools["tools"]
                .as_array()
                .unwrap()
                .iter()
                .any(|tool| tool["name"] == name)
        );
    }
    for arguments in [
        json!({"category":"WEB", "runtime":7}),
        json!({"category":"WEB", "runtime":"deploy"}),
    ] {
        assert!(
            call(&socket, "publish_local", arguments)
                .get("error")
                .is_some()
        );
    }

    let nonce = format!("__tillandsias_preview_{}.txt", std::process::id());
    let asset = format!("{root}/var/html/{nonce}");
    command("podman", &["exec", &forge, "test", "!", "-e", &asset]);
    let mut cleanup = Cleanup {
        socket: socket.clone(),
        forge: forge.clone(),
        asset: asset.clone(),
        owns_service: false,
    };
    let write = |value: &str| {
        command(
            "podman",
            &[
                "exec",
                &forge,
                "sh",
                "-c",
                "printf %s \"$1\" > \"$2\"",
                "preview-fixture",
                value,
                &asset,
            ],
        );
    };
    write("uncommitted-first");
    cleanup.owns_service = true;
    let published = successful(call(
        &socket,
        "publish_local",
        json!({"category":"WEB", "runtime":"auto"}),
    ));
    assert_eq!(published["runtime"], "wrangler");
    assert_eq!(published["watch"], true);
    assert_eq!(published["tls"]["enabled"], true);
    let (base, resolve) = https_target(published["url"].as_str().unwrap());
    let asset_url = format!("{}/{nonce}", base.trim_end_matches('/'));
    await_asset(&asset_url, &resolve, &ca, "uncommitted-first");
    write("uncommitted-second");
    await_asset(&asset_url, &resolve, &ca, "uncommitted-second");

    // Caller attribution cannot choose another project or source path.
    let repeated = successful(call(
        &socket,
        "publish_local",
        json!({"category":"WEB", "project":"not-this-project", "path":"/", "runtime":"auto"}),
    ));
    assert_eq!(repeated["url"], published["url"]);
    let reloaded = successful(call(&socket, "service_reload", json!({"category":"WEB"})));
    assert_eq!(reloaded["url"], published["url"]);
    await_asset(&asset_url, &resolve, &ca, "uncommitted-second");
    let status = successful(call(&socket, "service_status", json!({})));
    assert_eq!(status["state"], "running");
    assert_eq!(status["route_ready"], true);
    // SPA fallback may return an index page; it must never disclose config bytes.
    let config = fetch(
        &(base.trim_end_matches('/').to_owned() + "/wrangler.jsonc"),
        &resolve,
        &ca,
    );
    assert!(!String::from_utf8_lossy(&config.stdout).contains("\"assets\""));

    successful(call(&socket, "service_stop", json!({"category":"WEB"})));
    successful(call(&socket, "service_stop", json!({"category":"WEB"})));
    cleanup.owns_service = false;
    assert_eq!(
        successful(call(&socket, "service_status", json!({})))["state"],
        "stopped"
    );
    assert!(
        call(&socket, "service_reload", json!({"category":"WEB"}))["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not_running")
    );
    cleanup.owns_service = true;
    let restarted = successful(call(
        &socket,
        "publish_local",
        json!({"category":"WEB", "runtime":"wrangler"}),
    ));
    assert_eq!(restarted["url"], published["url"]);
    await_asset(&asset_url, &resolve, &ca, "uncommitted-second");
    successful(call(&socket, "service_stop", json!({"category":"WEB"})));
    cleanup.owns_service = false;
    assert_eq!(
        command(
            "podman",
            &["exec", &forge, "git", "-C", root, "rev-parse", "HEAD"]
        ),
        head
    );
    assert_eq!(command("trust", &["list", "--filter=ca-anchors"]), anchors);
    println!(
        "ok:local-web-preview:live-assets-watch-reload-stop-ca-verified; host-browser-trust=unverified"
    );
}
