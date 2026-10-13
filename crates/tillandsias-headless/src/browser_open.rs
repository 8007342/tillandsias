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
//!   Order 1655-urz9: Chromium runs with `--remote-debugging-pipe` under a
//!   small in-container relay (`browser_window_cdp_relay.js`), which serves
//!   the pipe on a Unix socket in a per-window host directory that only the
//!   tray creates and mounts, for the tray's one CDP session per window;
//! - opened at the device's CSS viewport (`--window-size`) on about:blank:
//!   the tray emulates the device over CDP, then navigates.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration, spec:local-web-preview

use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use sha2::{Digest, Sha256};
use tillandsias_browser_mcp::launcher::{
    BrowserContainers, ContainerHandle, ContainerLaunchRequest, Engine, LaunchError,
};

/// The shared router every project's routes go through.
const ROUTER_CONTAINER: &str = "tillandsias-router";
/// The per-window forwarder (`node -e`, from the chromium-framework image).
const FORWARDER_JS: &str = include_str!("browser_window_forwarder.js");
/// The window's entrypoint: Chromium under the CDP pipe relay (1655-urz9).
const CDP_RELAY_JS: &str = include_str!("browser_window_cdp_relay.js");
/// Where the window container sees its CDP socket directory.
const CDP_DIR_IN_CONTAINER: &str = "/run/tillandsias-cdp";
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
    extra_ports: &[u16],
) -> tillandsias_podman::ContainerSpec {
    let extra: Vec<String> = extra_ports.iter().map(u16::to_string).collect();
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
    .env("TILLANDSIAS_FWD_EXTRA_PORTS", extra.join(","))
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

    /// Start a WebKit engine window (order 1656-tjv4). The image is built on
    /// first use. Same network shape as a Chromium window (1649/1651): its
    /// own --internal network whose only other member is the SNI forwarder,
    /// here also listening on the preview port the URL names.
    fn start_webkit(
        &self,
        request: &ContainerLaunchRequest<'_>,
        certs_dir: &Path,
        display: &crate::BrowserDisplayContext,
    ) -> Result<ContainerHandle, LaunchError> {
        let version = crate::VERSION.trim();
        let root =
            crate::resolve_runtime_asset_root(version, self.debug).map_err(LaunchError::Spawn)?;
        crate::ensure_versioned_images(&root, &["webkit"], version, self.debug).map_err(|e| {
            LaunchError::Spawn(format!(
                "the {} image is not available: {e}",
                Engine::WebKit.label()
            ))
        })?;
        let preview_port = request.url.port_or_known_default().unwrap_or(443);
        let suffix = window_suffix(request.window_id);
        let handle = ContainerHandle {
            container_name: format!("tillandsias-browser-{}-{suffix}", request.project_label),
            network_name: format!("tillandsias-browser-net-{suffix}"),
            profile_dir: crate::browser_profile_root().join(request.window_id),
            cdp_socket: None,
        };
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
            let forwarder =
                forwarder_spec(&handle, request.project_label, &router_ip, &[preview_port])
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
            let forwarder_ip = forwarder_ip_on(&handle)?;
            let argv = webkit_window_spec(
                request.project_label,
                &handle,
                &certs_dir.join("intermediate.crt"),
                display,
                &WebKitTarget {
                    url: request.url.as_str(),
                    preview_port,
                    forwarder_ip,
                    playwright_context: &request.playwright_context,
                },
            )?
            .build_run_argv()
            .map_err(|e| format!("webkit container argv refused: {e}"))?;
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            podman(&argv, RUN_BUDGET)
        })();
        if let Err(err) = started {
            if self.debug {
                eprintln!("[tillandsias] browser.open (webkit): {err}; undoing the window");
            }
            self.stop(&handle);
            return Err(LaunchError::Spawn(err));
        }
        Ok(handle)
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

/// A window's CDP socket directory on the host: per window, 0700, created
/// and removed by the tray, and mounted into that window's container only.
fn cdp_dir(window_id: &str) -> PathBuf {
    crate::browser_profile_root().join(format!("{window_id}.cdp"))
}

/// The window's container spec: `build_project_browser_spec` plus the
/// window's network, the resolver rules, the pin, the device's window size,
/// and the CDP pipe relay as entrypoint. Nothing is published.
///
/// It opens about:blank: the tray emulates the device over CDP before it
/// navigates (order 1655-urz9).
pub(crate) fn browser_window_spec(
    project: &str,
    handle: &ContainerHandle,
    certs_dir: &Path,
    display: &crate::BrowserDisplayContext,
    ca_spki: &str,
    window_size: (u32, u32),
    cdp_dir: &Path,
) -> Result<tillandsias_podman::ContainerSpec, String> {
    let entrypoint = serde_json::json!(["node", "-e", CDP_RELAY_JS, "--"]).to_string();
    Ok(crate::build_project_browser_spec(
        "about:blank",
        crate::VERSION.trim(),
        &handle.profile_dir,
        certs_dir,
        display,
        &handle.container_name,
    )?
    .entrypoint(entrypoint)
    .volume(
        cdp_dir.display().to_string(),
        CDP_DIR_IN_CONTAINER,
        tillandsias_podman::MountMode::ReadWrite,
    )
    .env(
        "TILLANDSIAS_CDP_SOCKET",
        format!("{CDP_DIR_IN_CONTAINER}/cdp.sock"),
    )
    .network(&handle.network_name)
    .arg(format!(
        "--host-resolver-rules={}",
        host_resolver_rules(project)
    ))
    .arg(format!("--ignore-certificate-errors-spki-list={ca_spki}"))
    .arg(format!("--window-size={},{}", window_size.0, window_size.1)))
}

/// The WebKit engine window's container (order 1656-tjv4): Playwright's
/// Linux WebKit, headful, Wayland only, emulating the device through a
/// Playwright context, on the window's own `--internal` network.
///
/// - Names: WebKitGTK resolves through GLib, which answers EVERY `*.localhost`
///   name with loopback and never reads /etc/hosts for them (measured
///   2026-10-13). So the window's own launcher runs a loopback relay on the
///   preview port to the forwarder (`TILLANDSIAS_WEBKIT_RELAY`). Do not drop
///   the relay in favour of `--add-host`: WebKit would never see the mapping.
///   The `--add-host` entries stay for non-GLib clients. The project binding
///   is the forwarder's SNI check plus the router's strict_sni_host, unchanged.
/// - Trust: the enclave CA, bind-mounted read-only as the container's WHOLE
///   system bundle. No other root, never ignoreHTTPSErrors.
/// - `label=disable` (ContainerSpec's default) for the same reason as the
///   Chromium window (1641-xbvq, noted under 1252-qyii): without it GTK cannot
///   connect to the host compositor's socket.
pub(crate) fn webkit_window_spec(
    project: &str,
    handle: &ContainerHandle,
    ca_file: &Path,
    display: &crate::BrowserDisplayContext,
    target: &WebKitTarget<'_>,
) -> Result<tillandsias_podman::ContainerSpec, String> {
    let WebKitTarget {
        url,
        preview_port,
        forwarder_ip,
        playwright_context,
    } = *target;
    let (socket, socket_name) = display.wayland_socket()?;
    let mut spec = tillandsias_podman::ContainerSpec::new(format!(
        "tillandsias-webkit:v{}",
        crate::VERSION.trim()
    ))
    .pull_never()
    .read_only()
    .detached()
    .name(&handle.container_name)
    .network(&handle.network_name)
    .pids_limit(512)
    .tmpfs("/tmp:size=256m")
    .tmpfs("/dev/shm:size=256m")
    .bind_mount(
        ca_file.display().to_string(),
        "/etc/ssl/certs/ca-certificates.crt",
        true,
    )
    .tmpfs(format!("{WEBKIT_RUNTIME_DIR}:size=1m,mode=0700,U"))
    .volume(
        socket.display().to_string(),
        format!("{WEBKIT_RUNTIME_DIR}/{socket_name}"),
        tillandsias_podman::MountMode::ReadWrite,
    )
    .env("XDG_RUNTIME_DIR", WEBKIT_RUNTIME_DIR)
    .env("WAYLAND_DISPLAY", &socket_name)
    .env("GDK_BACKEND", "wayland")
    .env("HOME", "/tmp")
    .env("TILLANDSIAS_WEBKIT_URL", url)
    .env("TILLANDSIAS_WEBKIT_DEVICE", playwright_context.to_string())
    .env(
        "TILLANDSIAS_WEBKIT_RELAY",
        format!("{forwarder_ip}:{preview_port}"),
    );
    for name in [
        format!("www.{project}.localhost"),
        format!("web.{project}.localhost"),
    ] {
        spec = spec.add_host(&name, forwarder_ip)?;
    }
    Ok(spec)
}

/// What one WebKit window shows and where its relay points.
#[derive(Clone, Copy)]
pub(crate) struct WebKitTarget<'a> {
    pub(crate) url: &'a str,
    pub(crate) preview_port: u16,
    pub(crate) forwarder_ip: std::net::IpAddr,
    pub(crate) playwright_context: &'a serde_json::Value,
}

/// The WebKit window's private runtime dir: only the Wayland socket file.
const WEBKIT_RUNTIME_DIR: &str = "/run/user/browser";

/// The forwarder's IP on the window's own network: the address the WebKit
/// window's relay and `--add-host` entries name.
fn forwarder_ip_on(handle: &ContainerHandle) -> Result<std::net::IpAddr, String> {
    let ip = podman(
        &[
            "inspect",
            "--format",
            &format!(
                "{{{{(index .NetworkSettings.Networks \"{}\").IPAddress}}}}",
                handle.network_name
            ),
            &forwarder_name(handle),
        ],
        tillandsias_podman::OperationKind::Inspect.default_budget(),
    )?;
    ip.trim()
        .parse()
        .map_err(|e| format!("forwarder address {ip:?} on {}: {e}", handle.network_name))
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
        if request.engine == Engine::WebKit {
            return self.start_webkit(request, &certs_dir, &display);
        }
        let profile_dir = crate::browser_profile_root().join(request.window_id);
        std::fs::create_dir_all(&profile_dir)?;
        let cdp_dir = cdp_dir(request.window_id);
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new().mode(0o700).create(&cdp_dir)?;
        }

        let handle = ContainerHandle {
            container_name: format!("tillandsias-browser-{}-{suffix}", request.project_label),
            network_name: format!("tillandsias-browser-net-{suffix}"),
            profile_dir,
            cdp_socket: Some(cdp_dir.join("cdp.sock")),
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
            let forwarder = forwarder_spec(&handle, request.project_label, &router_ip, &[])
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
                request.project_label,
                &handle,
                &certs_dir,
                &display,
                &ca_spki,
                request.window_size,
                &cdp_dir,
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
        if let Some(dir) = handle.cdp_socket.as_deref().and_then(Path::parent) {
            let _ = std::fs::remove_dir_all(dir);
        }
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
            cdp_socket: None,
        };
        let argv = forwarder_spec(&handle, "acme", "10.0.42.7", &[])
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
            cdp_socket: Some(PathBuf::from(
                "/run/user/1000/tillandsias/browser/win-1.cdp/cdp.sock",
            )),
        };
        let display = crate::BrowserDisplayContext {
            wayland_display: Some("wayland-0".into()),
            xdg_runtime_dir: Some(PathBuf::from("/run/user/1000")),
        };
        let argv = browser_window_spec(
            "acme",
            &handle,
            Path::new("/tmp/ca"),
            &display,
            "PIN=",
            (428, 926),
            Path::new("/run/user/1000/tillandsias/browser/win-1.cdp"),
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
            !joined.contains("--remote-debugging-port")
                && !joined.contains("--remote-debugging-address"),
            "no DevTools port: {joined}"
        );
        // Order 1655-urz9: CDP is the pipe, relayed to a Unix socket in the
        // window's own directory; the window opens at the device's CSS size
        // on about:blank, and the tray navigates after emulating.
        let entry = argv
            .windows(2)
            .find(|w| w[0] == "--entrypoint")
            .map(|w| w[1].clone())
            .expect("an entrypoint");
        let entry: Vec<String> = serde_json::from_str(&entry).unwrap();
        assert_eq!(entry[0], "node");
        assert_eq!(entry[1], "-e");
        assert_eq!(entry[2], CDP_RELAY_JS);
        assert!(CDP_RELAY_JS.contains("'--remote-debugging-pipe'"));
        assert!(!CDP_RELAY_JS.contains("remote-debugging-port"));
        assert_eq!(CDP_RELAY_JS.matches(".listen(").count(), 1, "one listener");
        assert!(
            CDP_RELAY_JS.contains("server.listen(SOCKET,"),
            "the relay serves the Unix socket path only"
        );
        assert!(
            joined.contains("/run/user/1000/tillandsias/browser/win-1.cdp:/run/tillandsias-cdp"),
            "{joined}"
        );
        assert!(joined.contains("TILLANDSIAS_CDP_SOCKET=/run/tillandsias-cdp/cdp.sock"));
        assert!(joined.contains("--window-size=428,926"), "{joined}");
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
        assert!(joined.contains("--app=about:blank"), "{joined}");
        assert!(
            joined.contains("--ozone-platform=wayland"),
            "still Wayland-only"
        );
        assert!(
            !joined.contains("--network host") && !joined.contains("--network=host"),
            "{joined}"
        );
    }

    /// Order 1656-tjv4: the WebKit window's argv. Exactly the project's two
    /// names to the forwarder, the enclave CA as the read-only system bundle,
    /// only the Wayland socket, only its own network, nothing published, no
    /// DevTools, and the loopback relay to the forwarder on the preview port.
    #[test]
    fn webkit_window_spec_is_confined_like_the_chromium_window() {
        let handle = ContainerHandle {
            container_name: "tillandsias-browser-acme-0123456789ab".into(),
            network_name: "tillandsias-browser-net-0123456789ab".into(),
            profile_dir: PathBuf::from("/run/user/1000/tillandsias/browser/win-1"),
            cdp_socket: None,
        };
        let display = crate::BrowserDisplayContext {
            wayland_display: Some("wayland-0".into()),
            xdg_runtime_dir: Some(PathBuf::from("/run/user/1000")),
        };
        let ip: std::net::IpAddr = "10.89.1.2".parse().unwrap();
        let argv = webkit_window_spec(
            "acme",
            &handle,
            Path::new("/home/u/.local/state/tillandsias/ca/intermediate.crt"),
            &display,
            &WebKitTarget {
                url: "https://www.acme.localhost:18443/",
                preview_port: 18443,
                forwarder_ip: ip,
                playwright_context: &serde_json::json!({ "viewport": { "width": 393, "height": 852 } }),
            },
        )
        .unwrap()
        .build_run_argv()
        .unwrap();
        let joined = argv.join(" ");
        let hosts: Vec<&String> = argv
            .iter()
            .filter(|a| a.starts_with("--add-host"))
            .collect();
        assert_eq!(
            hosts,
            [
                "--add-host=www.acme.localhost:10.89.1.2",
                "--add-host=web.acme.localhost:10.89.1.2"
            ]
        );
        assert!(
            joined.contains("TILLANDSIAS_WEBKIT_RELAY=10.89.1.2:18443"),
            "{joined}"
        );
        assert!(
            joined.contains("intermediate.crt,target=/etc/ssl/certs/ca-certificates.crt")
                && joined.contains("readonly"),
            "the enclave CA is the read-only system bundle: {joined}"
        );
        assert!(
            joined.contains("/run/user/1000/wayland-0:/run/user/browser/wayland-0"),
            "{joined}"
        );
        assert!(
            !joined.contains("/run/user/1000:"),
            "never the whole runtime dir: {joined}"
        );
        let networks: Vec<_> = argv
            .windows(2)
            .filter(|w| w[0] == "--network")
            .map(|w| w[1].as_str())
            .collect();
        assert_eq!(networks, ["tillandsias-browser-net-0123456789ab"]);
        assert!(
            !argv.iter().any(|a| a == "-p" || a.starts_with("--publish")),
            "{joined}"
        );
        assert!(!joined.contains("remote-debugging") && !joined.contains("ignoreHTTPSErrors"));
        assert!(joined.contains("tillandsias-webkit:v"), "{joined}");
        assert!(joined.contains("--security-opt=label=disable"), "{joined}");
        assert!(
            joined.contains("--cap-drop=ALL") || joined.contains("--cap-drop ALL"),
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

    /// Host TCP listeners (`ss -ltnH`, local address column), sorted.
    fn host_tcp_listeners() -> Vec<String> {
        let out = std::process::Command::new("ss")
            .args(["-ltnH"])
            .output()
            .expect("ss");
        let mut rows: Vec<String> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.split_whitespace().nth(3).map(str::to_string))
            .collect();
        rows.sort();
        rows.dedup();
        rows
    }

    /// The last `[innerWidth, devicePixelRatio, maxTouchPoints]` the demo
    /// page reported (the harness's stand-in dev server logs one
    /// `GET /report?m=<json>&ua=<ua>` per change), with its UA.
    fn last_page_report(upstream: &str) -> Option<(Vec<f64>, String)> {
        fn unescape(s: &str) -> String {
            let b = s.as_bytes();
            let mut out = Vec::new();
            let mut i = 0;
            while i < b.len() {
                if b[i] == b'%'
                    && i + 2 < b.len()
                    && let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16)
                {
                    out.push(v);
                    i += 3;
                    continue;
                }
                out.push(if b[i] == b'+' { b' ' } else { b[i] });
                i += 1;
            }
            String::from_utf8_lossy(&out).into_owned()
        }
        let logs = live_podman(&["logs", upstream]);
        let line = logs
            .lines()
            .rev()
            .find(|l| l.starts_with("GET /report?m="))?;
        let query = line.strip_prefix("GET /report?")?.split(' ').next()?;
        let mut m = None;
        let mut ua = String::new();
        for pair in query.split('&') {
            match pair.split_once('=') {
                Some(("m", v)) => m = serde_json::from_str::<Vec<f64>>(&unescape(v)).ok(),
                Some(("ua", v)) => ua = unescape(v),
                _ => {}
            }
        }
        Some((m?, ua))
    }

    /// Wait until the page reports `want(width, dpr, touch_points)`.
    fn await_page_report(
        upstream: &str,
        label: &str,
        want: impl Fn(f64, f64, f64) -> bool,
    ) -> (Vec<f64>, String) {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        let mut last = None;
        while std::time::Instant::now() < deadline {
            last = last_page_report(upstream);
            if let Some((m, _)) = &last
                && m.len() == 3
                && want(m[0], m[1], m[2])
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        println!("page-report {label} {last:?}");
        last.unwrap_or_default()
    }

    /// Order 1655-urz9 live proof. Run by the same private-store harness as
    /// the 1649-xqet test. What the window emulates is measured by the PAGE:
    /// the stand-in dev server's page reports `[innerWidth, devicePixelRatio,
    /// navigator.maxTouchPoints]` back to the dev server, never through CDP.
    #[test]
    #[ignore = "live: run by the 1649-xqet harness on a private podman store"]
    fn live_browser_open_emulates_the_requested_device() {
        let port: u16 = std::env::var("TILLANDSIAS_BROWSER_E2E_PREVIEW_PORT")
            .expect("harness only")
            .parse()
            .unwrap();
        let demo_upstream =
            std::env::var("TILLANDSIAS_BROWSER_E2E_DEMO_UPSTREAM").expect("harness only");
        let store = live_podman(&["info", "--format", "{{.Store.GraphRoot}}"]);
        let home = std::env::var("HOME").unwrap_or_default();
        assert!(
            store.contains("/target/work/") && home.contains("/target/work/"),
            "refusing: store {store:?} / HOME {home:?} are not the harness's private ones"
        );
        let listeners_before = host_tcp_listeners();
        println!("host-tcp-listeners-before {listeners_before:?}");

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
            serde_json::json!({ "url": url, "device": "iphone 12 pro max", "engine": "chromium" }),
        ));
        println!("browser.open {url} device=iphone 12 pro max -> {opened}");
        let window = opened["window_id"].as_str().expect("opened").to_string();

        let (m, ua) = await_page_report(&demo_upstream, "iphone-12-pro-max", |w, d, t| {
            w == 428.0 && d == 3.0 && t > 0.0
        });
        let iphone_ok = m.len() == 3 && m[0] == 428.0 && m[1] == 3.0 && m[2] > 0.0;

        let listeners_open = host_tcp_listeners();
        let new_listeners: Vec<&String> = listeners_open
            .iter()
            .filter(|l| !listeners_before.contains(l))
            .collect();
        println!("host-tcp-listeners-new-while-open {new_listeners:?}");

        let s24 = tillandsias_core::devices::resolve("galaxy s24").expect("in the catalogue");
        let want = (
            f64::from(s24.viewport.w),
            s24.dpr,
            f64::from(s24.device.max_touch_points),
        );
        println!("galaxy-s24-catalogue {want:?} {}", s24.id);
        let switched = rt.block_on(call(
            &server,
            "browser.set_device",
            serde_json::json!({ "window_id": window, "device": "galaxy s24" }),
        ));
        println!("browser.set_device galaxy s24 -> {switched}");
        let (m2, ua2) =
            await_page_report(&demo_upstream, "galaxy-s24", |w, d, t| (w, d, t) == want);

        // The CDP socket's directory is the window's own, tray-only (0700),
        // and the window container itself listens on no TCP port: CDP is
        // the pipe.
        let dir = cdp_dir(&window);
        let mode = std::fs::metadata(&dir).map(|m| {
            use std::os::unix::fs::PermissionsExt;
            m.permissions().mode() & 0o777
        });
        println!(
            "cdp-dir {} mode {:?}",
            dir.display(),
            mode.as_ref().map(|m| format!("{m:o}"))
        );
        let name = format!("tillandsias-browser-demo-{}", window_suffix(&window));
        let tcp = live_podman(&["exec", &name, "cat", "/proc/net/tcp", "/proc/net/tcp6"]);
        let window_listeners: Vec<&str> = tcp
            .lines()
            .filter(|l| l.split_whitespace().nth(3) == Some("0A"))
            .filter_map(|l| l.split_whitespace().nth(1))
            .collect();
        println!("window-tcp-listeners {window_listeners:?}");

        let closed = rt.block_on(call(
            &server,
            "browser.close",
            serde_json::json!({ "window_id": window }),
        ));
        println!("browser.close -> {closed}");
        let dir_gone = !dir.exists();
        println!("cdp-dir-removed-on-close {dir_gone}");

        // Criterion 2 as written: a fresh window opened AS the Galaxy S24.
        let opened2 = rt.block_on(call(
            &server,
            "browser.open",
            serde_json::json!({ "url": url, "device": "galaxy s24" }),
        ));
        println!("browser.open {url} device=galaxy s24 -> {opened2}");
        let window2 = opened2["window_id"].as_str().expect("opened").to_string();
        let (m3, ua3) = await_page_report(&demo_upstream, "galaxy-s24-fresh", |w, d, t| {
            (w, d, t) == want
        });
        let closed2 = rt.block_on(call(
            &server,
            "browser.close",
            serde_json::json!({ "window_id": window2 }),
        ));
        println!("browser.close -> {closed2}");

        assert_eq!(mode.ok(), Some(0o700), "{}", dir.display());
        assert!(dir_gone, "the CDP dir outlived its window");
        assert!(
            window_listeners.is_empty(),
            "the window listens on {window_listeners:?}"
        );
        assert_eq!(
            (m3.first().copied(), m3.get(1).copied(), m3.get(2).copied()),
            (Some(want.0), Some(want.1), Some(want.2)),
            "galaxy s24 opened fresh (ua {ua3})"
        );
        assert!(
            iphone_ok,
            "iphone 12 pro max: the page saw {m:?} (ua {ua}), want [428, 3, >0]"
        );
        assert!(
            ua.contains("iPhone"),
            "the page's UA is not the device's: {ua}"
        );
        assert_eq!(
            (m2.first().copied(), m2.get(1).copied(), m2.get(2).copied()),
            (Some(want.0), Some(want.1), Some(want.2)),
            "galaxy s24 after set_device (ua {ua2})"
        );
        assert!(ua2.contains("Android"), "{ua2}");
        assert!(
            new_listeners.is_empty(),
            "the host gained TCP listeners while the window was open: {new_listeners:?}"
        );
    }

    /// LISTEN sockets in a container: (proc file, local address) pairs.
    fn container_listeners(name: &str) -> Vec<String> {
        let mut out = Vec::new();
        for file in ["/proc/net/tcp", "/proc/net/tcp6"] {
            for line in live_podman(&["exec", name, "cat", file]).lines().skip(1) {
                let cols: Vec<&str> = line.split_whitespace().collect();
                if cols.get(3) == Some(&"0A") {
                    out.push(format!("{file}:{}", cols[1]));
                }
            }
        }
        out.sort();
        out
    }

    /// Order 1656-tjv4 live proof, through the tray's own path, on the same
    /// private-store harness. `iphone 15` opens the WebKit engine window (its
    /// image built on first use by ensure_versioned_images).
    #[test]
    #[ignore = "live: run by the 1649-xqet harness on a private podman store"]
    fn live_webkit_window_for_an_apple_preset() {
        let port: u16 = std::env::var("TILLANDSIAS_BROWSER_E2E_PREVIEW_PORT")
            .expect("harness only")
            .parse()
            .unwrap();
        let demo_upstream =
            std::env::var("TILLANDSIAS_BROWSER_E2E_DEMO_UPSTREAM").expect("harness only");
        let other_upstream =
            std::env::var("TILLANDSIAS_BROWSER_E2E_OTHER_UPSTREAM").expect("harness only");
        let pem_env = |var: &str| {
            std::fs::read_to_string(std::env::var(var).expect("harness only"))
                .unwrap()
                .replace('\n', "\\n")
        };
        let store = live_podman(&["info", "--format", "{{.Store.GraphRoot}}"]);
        let home = std::env::var("HOME").unwrap_or_default();
        assert!(
            store.contains("/target/work/") && home.contains("/target/work/"),
            "refusing: store {store:?} / HOME {home:?} are not the harness's private ones"
        );
        let listeners_before = host_tcp_listeners();

        let server = tillandsias_browser_mcp::BrowserMcpServer::with_project_label(
            tillandsias_browser_mcp::McpServerConfig::default(),
            "demo",
            Some(std::sync::Arc::new(PinnedPreviewPort {
                inner: TrayBrowserContainers::new(true),
                port,
            })),
        );
        // Multi-thread, as the tray's lane connection is: the on-demand image
        // ensure uses block_in_place (see tray::serve_mcp_connection).
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let url = format!("https://www.demo.localhost:{port}/");
        let opened = rt.block_on(call(
            &server,
            "browser.open",
            serde_json::json!({ "url": url, "device": "iphone 15" }),
        ));
        println!("browser.open {url} device=iphone 15 -> {opened}");
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let suffix = window_suffix(&window);
        let name = format!("tillandsias-browser-demo-{suffix}");
        let forwarder = format!("tillandsias-browser-fwd-{suffix}");
        let image = live_podman(&["inspect", "--format", "{{.ImageName}}", &name]);
        println!("webkit-window-image {image}");

        let (m, ua) = await_page_report(&demo_upstream, "iphone-15-webkit", |w, d, _| {
            w == 393.0 && d == 3.0
        });
        let listeners_open = host_tcp_listeners();
        let new_host: Vec<&String> = listeners_open
            .iter()
            .filter(|l| !listeners_before.contains(l))
            .collect();
        println!("host-tcp-listeners-new-while-open {new_host:?}");
        let inside = container_listeners(&name);
        println!("webkit-window-listeners {inside:?}");
        let port_hex = format!("{port:04X}");
        let relay_v4 = format!("/proc/net/tcp:0100007F:{port_hex}");
        let relay_v6 = format!("/proc/net/tcp6:00000000000000000000000001000000:{port_hex}");

        let probe = crate::podman_command()
            .args([
                "exec",
                "-i",
                "-e",
                &format!("PROBE_PREVIEW_PORT={port}"),
                "-e",
                "PLAYWRIGHT_BROWSERS_PATH=/ms-playwright",
                "-e",
                "HOME=/tmp",
                "-e",
                &format!(
                    "PROBE_ENCLAVE_LEAF={}",
                    pem_env("TILLANDSIAS_BROWSER_E2E_ENCLAVE_LEAF")
                ),
                "-e",
                &format!(
                    "PROBE_ENCLAVE_KEY={}",
                    pem_env("TILLANDSIAS_BROWSER_E2E_ENCLAVE_KEY")
                ),
                "-e",
                &format!(
                    "PROBE_FOREIGN_LEAF={}",
                    pem_env("TILLANDSIAS_BROWSER_E2E_FOREIGN_LEAF")
                ),
                "-e",
                &format!(
                    "PROBE_FOREIGN_KEY={}",
                    pem_env("TILLANDSIAS_BROWSER_E2E_FOREIGN_KEY")
                ),
                &name,
                "timeout",
                "120",
                "node",
                "-",
            ])
            .output_bounded_with_stdin(
                include_bytes!("../tests/fixtures/webkit-window-probe.js"),
                Duration::from_secs(150),
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
        let fwd_log = live_podman(&["logs", &forwarder]);
        println!("forwarder-log {}", fwd_log.replace('\n', " | "));
        let other_hits = live_podman(&["logs", &other_upstream]);

        let closed = rt.block_on(call(
            &server,
            "browser.close",
            serde_json::json!({ "window_id": window }),
        ));
        println!("browser.close -> {closed}");
        let left = live_podman(&[
            "ps",
            "-a",
            "--filter",
            "name=^tillandsias-browser-",
            "--format",
            "{{.Names}}",
        ]);
        println!("after-close containers={left:?}");

        // 1. The engine and its label.
        assert_eq!(opened["engine"], "WebKit (approximates Safari)", "{opened}");
        assert!(image.contains("tillandsias-webkit:v"), "{image}");
        // 1. The page itself: the device's viewport and dpr, a WebKit UA.
        assert_eq!(
            (m.first().copied(), m.get(1).copied()),
            (Some(393.0), Some(3.0)),
            "{m:?}"
        );
        assert!(
            ua.contains("AppleWebKit") && !ua.contains("Chrome/"),
            "{ua}"
        );
        // The relay is the window's only listener: loopback, preview port.
        assert!(inside.contains(&relay_v4), "{inside:?}");
        assert!(
            inside.iter().all(|l| *l == relay_v4 || *l == relay_v6),
            "a listener other than the loopback relay: {inside:?}"
        );
        assert!(
            new_host.is_empty(),
            "the host gained TCP listeners: {new_host:?}"
        );
        // 3. Network: own project yes; another project, an outside name and a
        // raw IP no; another project's SNI is the forwarder's refusal.
        assert!(
            verdict("webkit-own-project").contains("PREVIEW-DEMO"),
            "{probe}"
        );
        for refused in [
            "webkit-other-project",
            "webkit-external-name",
            "webkit-raw-ip",
        ] {
            assert!(verdict(refused).starts_with("FAILED"), "{refused}: {probe}");
        }
        assert!(
            fwd_log.contains("refused sni=\"www.other.localhost\""),
            "{fwd_log}"
        );
        assert!(
            !other_hits.lines().any(|l| l.starts_with("GET ")),
            "{other_hits}"
        );
        assert!(verdict("raw-host-other-project").contains("421"), "{probe}");
        // Trust: the enclave CA only, never a foreign one.
        assert!(
            verdict("webkit-enclave-ca-cert").contains("LOCAL-OK"),
            "{probe}"
        );
        assert!(
            verdict("webkit-foreign-ca-cert").contains("Unacceptable TLS certificate"),
            "{probe}"
        );
        assert!(left.is_empty(), "{left}");
    }

    /// Order 1656-iktu live proof. Same private-store harness. Two lanes of
    /// project `demo`, each its own server as the tray builds one per lane
    /// connection; lane A opens a dev-mode window.
    #[test]
    #[ignore = "live: run by the 1649-xqet harness on a private podman store"]
    fn live_dev_mode_gives_only_the_owning_lane_full_cdp() {
        let port: u16 = std::env::var("TILLANDSIAS_BROWSER_E2E_PREVIEW_PORT")
            .expect("harness only")
            .parse()
            .unwrap();
        let other_upstream =
            std::env::var("TILLANDSIAS_BROWSER_E2E_OTHER_UPSTREAM").expect("harness only");
        let store = live_podman(&["info", "--format", "{{.Store.GraphRoot}}"]);
        let home = std::env::var("HOME").unwrap_or_default();
        assert!(
            store.contains("/target/work/") && home.contains("/target/work/"),
            "refusing: store {store:?} / HOME {home:?} are not the harness's private ones"
        );
        let listeners_before = host_tcp_listeners();
        println!("host-tcp-listeners-before {listeners_before:?}");

        let lane = |instance: &str| {
            tillandsias_browser_mcp::BrowserMcpServer::with_project_label(
                tillandsias_browser_mcp::McpServerConfig::default(),
                "demo",
                Some(std::sync::Arc::new(PinnedPreviewPort {
                    inner: TrayBrowserContainers::new(true),
                    port,
                })),
            )
            .with_lane(instance)
        };
        let lane_a = lane("lane-a");
        let lane_b = lane("lane-b");
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let url = format!("https://www.demo.localhost:{port}/");
        let opened = rt.block_on(call(
            &lane_a,
            "browser.open",
            serde_json::json!({ "url": url, "dev": true }),
        ));
        println!("lane-a browser.open {url} dev=true -> {opened}");
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let cdp = |server: &tillandsias_browser_mcp::BrowserMcpServer,
                   method: &str,
                   params: serde_json::Value| {
            rt.block_on(call(
                server,
                "browser.cdp",
                serde_json::json!({ "window_id": window, "method": method, "params": params }),
            ))
        };
        let text =
            |v: &serde_json::Value| v["content"][0]["text"].as_str().unwrap_or("").to_string();

        // Criterion 1: the owning lane's raw CDP.
        let two = cdp(
            &lane_a,
            "Runtime.evaluate",
            serde_json::json!({ "expression": "1+1" }),
        );
        println!("lane-a browser.cdp Runtime.evaluate 1+1 -> {two}");
        let shot_a = rt.block_on(call(
            &lane_a,
            "browser.screenshot",
            serde_json::json!({ "window_id": window }),
        ));
        let shot_a_len = shot_a["data"].as_str().map_or(0, str::len);
        println!("lane-a browser.screenshot -> {shot_a_len} base64 bytes");

        // Criterion 2: another lane, same window_id.
        let b_cdp = cdp(
            &lane_b,
            "Runtime.evaluate",
            serde_json::json!({ "expression": "1+1" }),
        );
        let b_shot = rt.block_on(call(
            &lane_b,
            "browser.screenshot",
            serde_json::json!({ "window_id": window }),
        ));
        println!("lane-b browser.cdp -> {b_cdp}");
        println!("lane-b browser.screenshot -> {b_shot}");

        // Criterion 3: no host listener; no process with a DevTools port.
        let listeners_open = host_tcp_listeners();
        let new_listeners: Vec<&String> = listeners_open
            .iter()
            .filter(|l| !listeners_before.contains(l))
            .collect();
        println!("host-tcp-listeners-new-while-open {new_listeners:?}");
        let name = format!("tillandsias-browser-demo-{}", window_suffix(&window));
        let cmdlines = live_podman(&[
            "exec",
            &name,
            "sh",
            "-c",
            "for f in /proc/[0-9]*/cmdline; do tr '\\000' ' ' < \"$f\"; echo; done",
        ]);
        let port_procs = cmdlines
            .lines()
            .filter(|l| l.contains("--remote-debugging-port"))
            .count();
        let pipe_procs = cmdlines
            .lines()
            .filter(|l| l.contains("--remote-debugging-pipe"))
            .count();
        println!(
            "container-processes remote-debugging-port={port_procs} remote-debugging-pipe={pipe_procs}"
        );

        // Criterion 4: raw CDP navigation reaches nothing a normal window
        // cannot: a public host and another project both fail.
        let public = cdp(
            &lane_a,
            "Page.navigate",
            serde_json::json!({ "url": "https://example.com/" }),
        );
        let other = cdp(
            &lane_a,
            "Page.navigate",
            serde_json::json!({ "url": format!("https://www.other.localhost:{port}/") }),
        );
        println!("lane-a Page.navigate public -> {public}");
        println!("lane-a Page.navigate other-project -> {other}");
        let other_hits = live_podman(&["logs", &other_upstream]);
        let other_reached = other_hits.lines().any(|l| l.starts_with("GET "));
        println!("other-project-upstream-hit {other_reached}");

        // The typed tools on the owning lane.
        let back = rt.block_on(call(
            &lane_a,
            "browser.navigate",
            serde_json::json!({ "window_id": window, "url": url }),
        ));
        println!("lane-a browser.navigate back -> {back}");
        let logged = rt.block_on(call(
            &lane_a,
            "browser.eval",
            serde_json::json!({ "window_id": window, "expression": "console.log('dev-mode-hello'); 6*7" }),
        ));
        println!("lane-a browser.eval -> {logged}");
        std::thread::sleep(Duration::from_millis(500));
        let console = rt.block_on(call(
            &lane_a,
            "browser.console_tail",
            serde_json::json!({ "window_id": window }),
        ));
        let network = rt.block_on(call(
            &lane_a,
            "browser.network_tail",
            serde_json::json!({ "window_id": window }),
        ));
        println!("lane-a browser.console_tail -> {console}");
        println!(
            "lane-a browser.network_tail -> {} entries, failed={:?}",
            network["entries"].as_array().map_or(0, Vec::len),
            network["entries"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|e| e["event"] == "failed")
                .map(|e| e["errorText"].clone())
                .collect::<Vec<_>>()
        );

        let closed = rt.block_on(call(
            &lane_a,
            "browser.close",
            serde_json::json!({ "window_id": window }),
        ));
        println!("lane-a browser.close -> {closed}");

        assert_eq!(two["result"]["value"], 2, "{two}");
        assert!(shot_a_len > 100, "the owning lane's screenshot: {shot_a}");
        assert!(text(&b_cdp).starts_with("WINDOW_NOT_FOUND:"), "{b_cdp}");
        assert!(text(&b_shot).starts_with("WINDOW_NOT_FOUND:"), "{b_shot}");
        assert!(new_listeners.is_empty(), "{new_listeners:?}");
        assert_eq!(port_procs, 0, "{cmdlines}");
        assert!(pipe_procs > 0, "chromium runs on the pipe: {cmdlines}");
        for (label, nav) in [("public", &public), ("other-project", &other)] {
            assert!(
                nav["errorText"].as_str().is_some_and(|e| !e.is_empty()),
                "{label} navigation was not refused: {nav}"
            );
        }
        assert!(
            !other_reached,
            "another project's upstream was reached:\n{other_hits}"
        );
        assert_eq!(logged["value"], 42, "{logged}");
        assert!(console.to_string().contains("dev-mode-hello"), "{console}");
        assert!(
            network["entries"].as_array().is_some_and(|e| !e.is_empty()),
            "{network}"
        );
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
