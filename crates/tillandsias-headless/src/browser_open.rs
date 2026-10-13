//! The tray's host side of `browser.open` (order 1649-xqet).
//!
//! A window is the chromium-framework container, never host Chromium:
//!
//! - started from `build_project_browser_spec` (Wayland-only, only the
//!   compositor socket mounted; order 1641-xbvq);
//! - on its own `--internal` network, whose only other member is a per-window
//!   forwarder answering as `router` (order 1651-5t7n). It passes on only TLS
//!   whose SNI is a host of this project, to the router's :8443, and the
//!   router's strict_sni_host binds the Host header to that SNI. So even a
//!   process that bypasses Chromium reaches its own project and nothing else:
//!   no other project, no plaintext, no host, no internet;
//! - with Chromium host-resolver rules that send the project's hosts to the
//!   router and resolve every other name, and every IP literal, to nothing;
//! - trusting the enclave CA through an SPKI pin, never the host trust store;
//! - with NO DevTools port and no host listener: a host TCP port would hand
//!   full control of the window, cookies included, to every local process.
//!   Dev-mode CDP reaches a window only through a per-lane Unix socket the tray
//!   brokers (the dev-mode broker row).
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration, spec:local-web-preview

use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine;
use sha2::{Digest, Sha256};
use tillandsias_browser_mcp::launcher::{
    BrowserContainers, ContainerHandle, ContainerLaunchRequest, LaunchError,
};

/// The shared router every project's routes go through.
const ROUTER_CONTAINER: &str = "tillandsias-router";
/// The per-window forwarder (`node -e`, from the chromium-framework image).
const FORWARDER_JS: &str = include_str!("browser_window_forwarder.js");
/// The router's preview TLS listener, the forwarder's only upstream.
const ROUTER_TLS_PORT: &str = "8443";

/// One window start: the image is present (`--pull=never`), so this is a
/// wedge detector, not a performance target.
const RUN_BUDGET: Duration = Duration::from_secs(60);

/// `--host-resolver-rules` for one project's window. Chromium applies the
/// first matching rule, and a rule may carry the replacement port: the
/// project's hosts on any port go to `router:8443` (the forwarder, then the
/// router's preview TLS listener). There is no plaintext mapping: a plaintext
/// Host header cannot be bound to a project (order 1651-5t7n). `MAP * ~NOTFOUND`
/// sends every other name, and IP literals too, to NXDOMAIN (measured
/// 2026-10-12: `http://1.1.1.1/` and `https://router:8443/` both end in
/// ERR_NAME_NOT_RESOLVED).
pub(crate) fn host_resolver_rules(project: &str) -> String {
    format!("MAP *.{project}.localhost router:8443, MAP * ~NOTFOUND")
}

/// The forwarder's container name, derived from the window's network so
/// `stop` can name it from the handle alone.
fn forwarder_name(handle: &ContainerHandle) -> String {
    let suffix = handle
        .network_name
        .strip_prefix("tillandsias-browser-net-")
        .unwrap_or(&handle.network_name);
    format!("tillandsias-browser-fwd-{suffix}")
}

/// The router's address on its own (non-window) network: the enclave in
/// production. The forwarder dials this IP; it does not resolve `router`,
/// because on the window's network that name is the forwarder itself.
fn router_upstream() -> Result<(String, String), String> {
    let rows = podman(
        &[
            "inspect",
            "--format",
            "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}\n{{end}}",
            ROUTER_CONTAINER,
        ],
        tillandsias_podman::OperationKind::Inspect.default_budget(),
    )?;
    let networks: Vec<(String, String)> = rows
        .lines()
        .filter_map(|l| l.split_once(' '))
        .filter(|(net, ip)| !net.starts_with("tillandsias-browser-net-") && !ip.is_empty())
        .map(|(net, ip)| (net.to_string(), ip.to_string()))
        .collect();
    networks
        .iter()
        .find(|(net, _)| net == tillandsias_podman::ENCLAVE_NETWORK)
        .or_else(|| networks.first())
        .cloned()
        .ok_or_else(|| format!("{ROUTER_CONTAINER} has no network address"))
}

/// The forwarder's spec: on the window's network as `router`. `start` then
/// connects it to the router's network (`podman network connect`; the spec's
/// passthrough allowlist does not take a second `--network`, and the
/// forwarder dials upstream only per connection). Same hardening as every
/// container (cap-drop ALL, no-new-privileges, keep-id), read-only, nothing
/// published.
pub(crate) fn forwarder_spec(
    handle: &ContainerHandle,
    project: &str,
    router_ip: &str,
) -> tillandsias_podman::ContainerSpec {
    tillandsias_podman::ContainerSpec::new(format!(
        "tillandsias-chromium-framework:v{}",
        crate::VERSION.trim()
    ))
    .pull_never()
    .read_only()
    .detached()
    .name(forwarder_name(handle))
    .network(format!("{}:alias=router", handle.network_name))
    .pids_limit(32)
    .tmpfs("/tmp:size=8m")
    .env("TILLANDSIAS_FWD_PROJECT", project)
    .env("TILLANDSIAS_FWD_UPSTREAM_HOST", router_ip)
    .env("TILLANDSIAS_FWD_UPSTREAM_PORT", ROUTER_TLS_PORT)
    .entrypoint("node")
    .arg("-e")
    .arg(FORWARDER_JS)
}

/// Base64 SHA-256 of a PEM certificate's SubjectPublicKeyInfo: the form
/// `--ignore-certificate-errors-spki-list` takes.
///
/// The pin names the enclave CA, so it holds across leaf rotation; Chromium
/// honours it only when the CA is in the chain the server sends, which is why
/// the preview leaf is published as a full chain (`local_web_preview`).
pub(crate) fn spki_sha256_base64(pem: &str) -> Result<String, String> {
    let body: String = pem
        .lines()
        .skip_while(|line| !line.starts_with("-----BEGIN CERTIFICATE-----"))
        .skip(1)
        .take_while(|line| !line.starts_with("-----END CERTIFICATE-----"))
        .collect();
    let der = base64::engine::general_purpose::STANDARD
        .decode(body.trim())
        .map_err(|e| format!("CA certificate is not PEM: {e}"))?;
    let (_, certificate, _) = der_element(&der)?;
    let (_, tbs, _) = der_element(der_content(certificate)?)?;
    let mut rest = der_content(tbs)?;
    // version [0] EXPLICIT is optional; then serial, signature, issuer,
    // validity, subject, subjectPublicKeyInfo.
    if rest.first() == Some(&0xA0) {
        rest = der_element(rest)?.2;
    }
    for _ in 0..5 {
        rest = der_element(rest)?.2;
    }
    let (tag, spki, _) = der_element(rest)?;
    if tag != 0x30 {
        return Err("CA certificate has no SubjectPublicKeyInfo".into());
    }
    Ok(base64::engine::general_purpose::STANDARD.encode(Sha256::digest(spki)))
}

/// One DER element: (tag, the whole element, what follows it).
fn der_element(input: &[u8]) -> Result<(u8, &[u8], &[u8]), String> {
    let short = || "CA certificate DER is truncated".to_string();
    let tag = *input.first().ok_or_else(short)?;
    let first = *input.get(1).ok_or_else(short)?;
    let (length, header) = if first & 0x80 == 0 {
        (usize::from(first), 2)
    } else {
        let count = usize::from(first & 0x7F);
        if count == 0 || count > 4 {
            return Err("CA certificate DER length is unsupported".into());
        }
        let bytes = input.get(2..2 + count).ok_or_else(short)?;
        (
            bytes.iter().fold(0usize, |n, b| (n << 8) | usize::from(*b)),
            2 + count,
        )
    };
    let end = header.checked_add(length).ok_or_else(short)?;
    let element = input.get(..end).ok_or_else(short)?;
    Ok((tag, element, &input[end..]))
}

fn der_content(element: &[u8]) -> Result<&[u8], String> {
    let (_, whole, _) = der_element(element)?;
    let header = if whole[1] & 0x80 == 0 {
        2
    } else {
        2 + usize::from(whole[1] & 0x7F)
    };
    Ok(&whole[header..])
}

/// Short, name-safe id for a window's container and network.
fn window_suffix(window_id: &str) -> String {
    window_id
        .chars()
        .filter(char::is_ascii_hexdigit)
        .take(12)
        .collect()
}

pub(crate) struct TrayBrowserContainers {
    debug: bool,
}

impl TrayBrowserContainers {
    pub(crate) fn new(debug: bool) -> Self {
        Self { debug }
    }
}

fn podman(args: &[&str], budget: Duration) -> Result<String, String> {
    let output = crate::podman_command()
        .args(args)
        .output_bounded(budget)
        .map_err(|e| format!("podman {}: {e}", args.first().unwrap_or(&"")))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Err(format!(
            "podman {} failed: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

fn network_budget() -> Duration {
    tillandsias_podman::OperationKind::Network.default_budget()
}

/// The window's container spec: `build_project_browser_spec` plus the
/// window's network, the resolver rules and the pin. Nothing is published.
pub(crate) fn browser_window_spec(
    url: &str,
    project: &str,
    handle: &ContainerHandle,
    certs_dir: &Path,
    display: &crate::BrowserDisplayContext,
    ca_spki: &str,
) -> Result<tillandsias_podman::ContainerSpec, String> {
    Ok(crate::build_project_browser_spec(
        url,
        crate::VERSION.trim(),
        &handle.profile_dir,
        certs_dir,
        display,
        &handle.container_name,
    )?
    .network(&handle.network_name)
    .arg(format!(
        "--host-resolver-rules={}",
        host_resolver_rules(project)
    ))
    .arg(format!("--ignore-certificate-errors-spki-list={ca_spki}")))
}

impl BrowserContainers for TrayBrowserContainers {
    fn preview_tls_port(&self) -> Option<u16> {
        crate::local_web_preview::tls_port().ok()
    }

    fn start(&self, request: &ContainerLaunchRequest<'_>) -> Result<ContainerHandle, LaunchError> {
        let suffix = window_suffix(request.window_id);
        let router = podman(
            &[
                "inspect",
                "--format",
                "{{.State.Running}}",
                ROUTER_CONTAINER,
            ],
            tillandsias_podman::OperationKind::Inspect.default_budget(),
        );
        if router.as_deref() != Ok("true") {
            return Err(LaunchError::Spawn(format!(
                "the router ({ROUTER_CONTAINER}) is not running; publish the project's preview first"
            )));
        }
        let certs_dir = PathBuf::from(crate::ca_dir());
        let pem = std::fs::read_to_string(certs_dir.join("intermediate.crt")).map_err(|e| {
            LaunchError::Spawn(format!("the enclave CA certificate is unreadable: {e}"))
        })?;
        let ca_spki = spki_sha256_base64(&pem).map_err(LaunchError::Spawn)?;
        let display = crate::BrowserDisplayContext::from_env().map_err(LaunchError::Spawn)?;
        let profile_dir = crate::browser_profile_root().join(request.window_id);
        std::fs::create_dir_all(&profile_dir)?;

        let handle = ContainerHandle {
            container_name: format!("tillandsias-browser-{}-{suffix}", request.project_label),
            network_name: format!("tillandsias-browser-net-{suffix}"),
            profile_dir,
        };
        // From here every failure undoes what was made.
        let started = (|| {
            let label = format!("tillandsias.browser-window={}", request.window_id);
            podman(
                &[
                    "network",
                    "create",
                    "--internal",
                    "--label",
                    &label,
                    &handle.network_name,
                ],
                network_budget(),
            )?;
            let (router_network, router_ip) = router_upstream()?;
            let forwarder = forwarder_spec(&handle, request.project_label, &router_ip)
                .build_run_argv()
                .map_err(|e| format!("forwarder argv refused: {e}"))?;
            let forwarder: Vec<&str> = forwarder.iter().map(String::as_str).collect();
            podman(&forwarder, RUN_BUDGET)?;
            podman(
                &[
                    "network",
                    "connect",
                    &router_network,
                    &forwarder_name(&handle),
                ],
                network_budget(),
            )?;
            let argv = browser_window_spec(
                request.url.as_str(),
                request.project_label,
                &handle,
                &certs_dir,
                &display,
                &ca_spki,
            )?
            .build_run_argv()
            .map_err(|e| format!("browser container argv refused: {e}"))?;
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            podman(&argv, RUN_BUDGET)
        })();
        if let Err(err) = started {
            if self.debug {
                eprintln!("[tillandsias] browser.open: {err}; undoing the window");
            }
            self.stop(&handle);
            return Err(LaunchError::Spawn(err));
        }
        Ok(handle)
    }

    fn stop(&self, handle: &ContainerHandle) {
        let forwarder = forwarder_name(handle);
        let steps: [&[&str]; 3] = [
            &["rm", "-f", "-t", "0", &handle.container_name],
            &["rm", "-f", "-t", "0", &forwarder],
            &["network", "rm", "-f", &handle.network_name],
        ];
        for args in steps {
            if let Err(err) = podman(args, network_budget())
                && self.debug
            {
                eprintln!("[tillandsias] browser.close: {err}");
            }
        }
        let _ = std::fs::remove_dir_all(&handle.profile_dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fixed EC certificate; the expected pin was computed with
    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der |
    /// openssl dgst -sha256 -binary | base64`.
    const FIXTURE_PEM: &str = include_str!("../tests/fixtures/browser-open-ca.crt");
    const FIXTURE_SPKI: &str = include_str!("../tests/fixtures/browser-open-ca.spki");

    #[test]
    fn spki_pin_matches_openssl() {
        assert_eq!(
            spki_sha256_base64(FIXTURE_PEM).unwrap(),
            FIXTURE_SPKI.trim()
        );
    }

    #[test]
    fn spki_pin_refuses_a_non_certificate() {
        assert!(spki_sha256_base64("not a certificate").is_err());
    }

    #[test]
    fn resolver_rules_send_only_the_project_to_the_router() {
        let rules = host_resolver_rules("acme");
        assert_eq!(rules, "MAP *.acme.localhost router:8443, MAP * ~NOTFOUND");
        assert!(!rules.contains("8080"), "no plaintext mapping (1651-5t7n)");
    }

    /// Order 1651-5t7n: the forwarder answers as `router` on the window's
    /// network, dials the router by IP on the router's network, publishes
    /// nothing, and runs the shipped script.
    #[test]
    fn forwarder_spec_bridges_only_the_window_network_to_the_router() {
        let handle = ContainerHandle {
            container_name: "tillandsias-browser-acme-0123456789ab".into(),
            network_name: "tillandsias-browser-net-0123456789ab".into(),
            profile_dir: PathBuf::from("/tmp/x"),
        };
        let argv = forwarder_spec(&handle, "acme", "10.0.42.7")
            .build_run_argv()
            .unwrap();
        let joined = argv.join(" ");
        assert!(
            joined.contains("--name tillandsias-browser-fwd-0123456789ab"),
            "{joined}"
        );
        assert!(
            joined.contains("--network tillandsias-browser-net-0123456789ab:alias=router"),
            "{joined}"
        );
        assert_eq!(
            argv.iter().filter(|a| *a == "--network").count(),
            1,
            "only the window network at run time: {joined}"
        );
        assert!(joined.contains("TILLANDSIAS_FWD_PROJECT=acme"));
        assert!(joined.contains("TILLANDSIAS_FWD_UPSTREAM_HOST=10.0.42.7"));
        assert!(
            joined.contains("--cap-drop=ALL") || joined.contains("--cap-drop ALL"),
            "{joined}"
        );
        assert!(
            !argv.iter().any(|a| a == "-p"),
            "nothing published: {joined}"
        );
        assert!(argv.iter().any(|a| a == FORWARDER_JS));
    }

    #[test]
    fn window_spec_joins_only_its_network_and_pins_the_ca() {
        let handle = ContainerHandle {
            container_name: "tillandsias-browser-acme-0123456789ab".into(),
            network_name: "tillandsias-browser-net-0123456789ab".into(),
            profile_dir: PathBuf::from("/run/user/1000/tillandsias/browser/win-1"),
        };
        let display = crate::BrowserDisplayContext {
            wayland_display: Some("wayland-0".into()),
            xdg_runtime_dir: Some(PathBuf::from("/run/user/1000")),
        };
        let argv = browser_window_spec(
            "https://www.acme.localhost:18443/",
            "acme",
            &handle,
            Path::new("/tmp/ca"),
            &display,
            "PIN=",
        )
        .unwrap()
        .build_run_argv()
        .unwrap();
        let joined = argv.join(" ");
        let networks: Vec<_> = argv
            .windows(2)
            .filter(|w| w[0] == "--network")
            .map(|w| w[1].as_str())
            .collect();
        assert_eq!(networks, vec!["tillandsias-browser-net-0123456789ab"]);
        assert!(
            !argv.iter().any(|a| a == "-p" || a.starts_with("--publish")),
            "no host listener: {joined}"
        );
        assert!(
            !joined.contains("--remote-debugging"),
            "no DevTools port: {joined}"
        );
        assert!(
            joined.contains(
                "--host-resolver-rules=MAP *.acme.localhost router:8443, MAP * ~NOTFOUND"
            ),
            "{joined}"
        );
        assert!(
            joined.contains("--ignore-certificate-errors-spki-list=PIN="),
            "{joined}"
        );
        assert!(joined.contains("--app=https://www.acme.localhost:18443/"));
        assert!(
            joined.contains("--ozone-platform=wayland"),
            "still Wayland-only"
        );
        assert!(
            !joined.contains("--network host") && !joined.contains("--network=host"),
            "{joined}"
        );
    }

    /// The tray launcher with the preview port pinned: the live harness runs
    /// with the operator's real XDG_RUNTIME_DIR (netavark needs it), whose
    /// router dir is not ours to write a `preview-tls-port` into. Reading
    /// that file is `local_web_preview::tls_port`, unchanged.
    struct PinnedPreviewPort {
        inner: TrayBrowserContainers,
        port: u16,
    }

    impl BrowserContainers for PinnedPreviewPort {
        fn preview_tls_port(&self) -> Option<u16> {
            Some(self.port)
        }
        fn start(
            &self,
            request: &ContainerLaunchRequest<'_>,
        ) -> Result<ContainerHandle, LaunchError> {
            self.inner.start(request)
        }
        fn stop(&self, handle: &ContainerHandle) {
            self.inner.stop(handle)
        }
    }

    fn live_podman(args: &[&str]) -> String {
        podman(args, Duration::from_secs(60)).unwrap_or_else(|e| format!("ERR {e}"))
    }

    /// Chromium processes in THIS process's mount namespace, i.e. on the
    /// host rather than in a container.
    fn host_chrome_pids() -> (Vec<u32>, usize) {
        let own = std::fs::read_link("/proc/self/ns/mnt").ok();
        let (mut host, mut contained) = (Vec::new(), 0);
        for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
            let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
                continue;
            };
            let comm = std::fs::read_to_string(entry.path().join("comm")).unwrap_or_default();
            if !matches!(
                comm.trim(),
                "chrome" | "chromium" | "chromium-browse" | "headless_shell"
            ) {
                continue;
            }
            if std::fs::read_link(entry.path().join("ns/mnt")).ok() == own {
                host.push(pid);
            } else {
                contained += 1;
            }
        }
        (host, contained)
    }

    async fn call(
        server: &tillandsias_browser_mcp::BrowserMcpServer,
        name: &str,
        arguments: serde_json::Value,
    ) -> serde_json::Value {
        match server
            .handle_request(tillandsias_browser_mcp::framing::RpcRequest {
                id: Some(1),
                method: "tools/call".into(),
                params: serde_json::json!({ "name": name, "arguments": arguments }),
            })
            .await
        {
            tillandsias_browser_mcp::framing::RpcResponse::Success { result, .. } => result,
            other => serde_json::json!({ "frame": format!("{other:?}") }),
        }
    }

    /// Order 1649-xqet live proof of criteria (a) and (b). Opt-in, and only
    /// on a private podman store: `plan/evidence/1649-xqet-*/harness.sh.txt`
    /// sets one up (scratch CA in a private HOME, the real router image named
    /// tillandsias-router with preview routes for `demo` AND `other`, and the
    /// chromium-framework image with the window entry), then runs this.
    #[test]
    #[ignore = "live: run by the 1649-xqet harness on a private podman store"]
    fn live_browser_open_runs_the_container_on_its_own_network() {
        let port: u16 = std::env::var("TILLANDSIAS_BROWSER_E2E_PREVIEW_PORT")
            .expect("harness only")
            .parse()
            .unwrap();
        let host_ip = std::env::var("TILLANDSIAS_BROWSER_E2E_HOST_IP").expect("harness only");
        let other_upstream =
            std::env::var("TILLANDSIAS_BROWSER_E2E_OTHER_UPSTREAM").expect("harness only");
        let store = live_podman(&["info", "--format", "{{.Store.GraphRoot}}"]);
        let home = std::env::var("HOME").unwrap_or_default();
        assert!(
            store.contains("/target/work/") && home.contains("/target/work/"),
            "refusing: store {store:?} / HOME {home:?} are not the harness's private ones"
        );

        let (host_before, _) = host_chrome_pids();
        println!("host-chrome-before {host_before:?}");
        let server = tillandsias_browser_mcp::BrowserMcpServer::with_project_label(
            tillandsias_browser_mcp::McpServerConfig::default(),
            "demo",
            Some(std::sync::Arc::new(PinnedPreviewPort {
                inner: TrayBrowserContainers::new(true),
                port,
            })),
        );
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let url = format!("https://www.demo.localhost:{port}/");
        let opened = rt.block_on(call(
            &server,
            "browser.open",
            serde_json::json!({ "url": url }),
        ));
        println!("browser.open {url} -> {opened}");
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let suffix = window_suffix(&window);
        let name = format!("tillandsias-browser-demo-{suffix}");
        let net = format!("tillandsias-browser-net-{suffix}");

        let ps = live_podman(&[
            "ps",
            "--filter",
            "name=^tillandsias-browser-demo-",
            "--format",
            "{{.Names}} {{.Networks}} {{.Ports}}",
        ]);
        println!("podman-ps {ps}");
        assert!(ps.starts_with(&format!("{name} {net}")), "{ps}");
        // Order 1651-5t7n: the router is NOT on the window's network; the
        // window's only neighbour is its forwarder, which also sits on the
        // router's network and publishes nothing.
        let router_nets = live_podman(&[
            "inspect",
            "--format",
            "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}",
            ROUTER_CONTAINER,
        ]);
        println!("router-networks {router_nets}");
        assert!(!router_nets.split_whitespace().any(|n| n == net));
        let forwarder = format!("tillandsias-browser-fwd-{suffix}");
        let fwd = live_podman(&[
            "ps",
            "--filter",
            &format!("name=^{forwarder}$"),
            "--format",
            "{{.Names}} {{.Networks}} ports=[{{.Ports}}]",
        ]);
        println!("forwarder {fwd}");
        assert!(fwd.contains(&net) && fwd.ends_with("ports=[]"), "{fwd}");
        let members = live_podman(&[
            "ps",
            "--filter",
            &format!("network={net}"),
            "--format",
            "{{.Names}}",
        ]);
        let mut members: Vec<&str> = members.lines().collect();
        members.sort();
        println!("window-network-members {members:?}");
        let mut expected = vec![forwarder.as_str(), name.as_str()];
        expected.sort();
        assert_eq!(members, expected);

        std::thread::sleep(Duration::from_secs(3));
        let (host_after, contained) = host_chrome_pids();
        println!("host-chrome-after {host_after:?} contained-chrome-processes {contained}");
        assert!(
            host_after.iter().all(|p| host_before.contains(p)),
            "a host chrome started"
        );
        assert!(contained > 0, "no chromium in the container");

        // No host listener: the window publishes nothing, and Chromium opens
        // no DevTools port (dev-mode CDP is the tray-brokered Unix socket).
        assert!(!ps.contains("->"), "a port is published: {ps}");
        let listeners = live_podman(&["exec", &name, "cat", "/proc/net/tcp"]);
        let listening: Vec<&str> = listeners
            .lines()
            .skip(1)
            .filter(|l| l.split_whitespace().nth(3) == Some("0A"))
            .filter_map(|l| l.split_whitespace().nth(1))
            .collect();
        println!("window-tcp-listeners {listening:?}");
        assert!(listening.is_empty(), "the window listens on {listening:?}");

        // The window itself loaded the preview route: the demo dev server saw
        // its request (Host www.demo.localhost:<port>) before any probe ran.
        let demo_upstream =
            std::env::var("TILLANDSIAS_BROWSER_E2E_DEMO_UPSTREAM").expect("harness only");
        let window_hits = live_podman(&["logs", &demo_upstream]);
        let window_hit = format!("GET / host=www.demo.localhost:{port}");
        println!(
            "window-request {}",
            window_hits
                .lines()
                .find(|l| l.contains(&window_hit))
                .unwrap_or("NONE")
        );
        assert!(window_hits.contains(&window_hit), "{window_hits}");

        let probe = crate::podman_command()
            .args([
                "exec",
                "-i",
                "-e",
                &format!("PROBE_PREVIEW_PORT={port}"),
                "-e",
                &format!("PROBE_HOST_IP={host_ip}"),
                "-e",
                &format!("PROBE_OTHER_UPSTREAM={other_upstream}"),
                &name,
                "node",
                "-",
            ])
            .output_bounded_with_stdin(
                include_bytes!("../tests/fixtures/browser-open-probe.js"),
                Duration::from_secs(90),
            )
            .unwrap();
        let probe = String::from_utf8_lossy(&probe.stdout).to_string();
        for line in probe.lines() {
            println!("probe {line}");
        }
        let verdict = |label: &str| {
            probe
                .lines()
                .find_map(|l| l.strip_prefix(&format!("{label} ")))
                .unwrap_or("MISSING")
                .to_string()
        };
        assert_eq!(verdict("window-flags"), "found", "{probe}");
        assert!(
            verdict("chromium-preview-route").contains("PREVIEW-DEMO"),
            "{probe}"
        );
        assert!(
            !verdict("chromium-http-route").contains("PREVIEW-DEMO"),
            "{probe}"
        );
        assert!(!verdict("chromium-other-project").contains("PREVIEW-OTHER"));
        assert!(!verdict("chromium-external-name").contains("Example Domain"));
        assert!(verdict("net-route").starts_with("reach:"));
        for refused in [
            "net-other-project-upstream",
            "net-external-name",
            "net-external-ip",
            "net-host-lan",
            "net-host-containers-internal",
            // Order 1651-5t7n: no plaintext path from the window.
            "net-router-plaintext",
        ] {
            assert!(
                !verdict(refused).starts_with("reach:"),
                "{refused}: {probe}"
            );
        }

        // Order 1651-5t7n: the window reaches only its own project, even
        // for a client that names the router itself and picks SNI and Host.
        assert!(
            verdict("raw-own-project").contains("PREVIEW-DEMO"),
            "control: {probe}"
        );
        for escape in ["raw-sni-other-project", "raw-host-other-project"] {
            assert!(
                !verdict(escape).contains("PREVIEW-OTHER"),
                "{escape} reached another project: {probe}"
            );
        }

        let closed = rt.block_on(call(
            &server,
            "browser.close",
            serde_json::json!({ "window_id": window }),
        ));
        println!("browser.close -> {closed}");
        let ps = live_podman(&[
            "ps",
            "-a",
            "--filter",
            "name=^tillandsias-browser-",
            "--format",
            "{{.Names}}",
        ]);
        let nets = live_podman(&["network", "ls", "--format", "{{.Name}}"]);
        let router_nets = live_podman(&[
            "inspect",
            "--format",
            "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}",
            ROUTER_CONTAINER,
        ]);
        println!("after-close containers={ps:?} networks={nets:?} router-networks={router_nets}");
        assert!(ps.is_empty());
        assert!(!nets.lines().any(|n| n == net));
        assert!(!router_nets.split_whitespace().any(|n| n == net));
    }
}
