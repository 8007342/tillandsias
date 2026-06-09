// @trace spec:observability-metrics, gap:OBS-009
//! HTTP server for Prometheus metrics export.
//!
//! Exposes container metrics in Prometheus text format at `GET /metrics`.
//! The handler is intentionally hand-rolled HTTP/1.1 so the headless binary
//! does not pull a hyper transitive surface; the metrics endpoint is a
//! debug/diagnostics aid, not a high-throughput service.
//!
//! Per spec:observability-metrics, a collection failure MUST surface as an
//! error to the scraper — we return `500 Internal Server Error` with the
//! error body, never a fabricated healthy `200`.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use tillandsias_logging::{ImageBuildEvent, ImageBuildEventWriter};
use tillandsias_metrics::{MetricsSampler, prometheus_exporter::PrometheusExporter};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info, warn};

/// Metrics server state.
///
/// Holds a sampler and exporter for serving Prometheus metrics.
#[derive(Debug)]
pub struct MetricsServerState {
    sampler: Arc<Mutex<MetricsSampler>>,
    exporter: PrometheusExporter,
}

impl MetricsServerState {
    /// Create a new metrics server state.
    pub fn new() -> Self {
        Self {
            sampler: Arc::new(Mutex::new(MetricsSampler::new())),
            exporter: PrometheusExporter::new(),
        }
    }

    /// Get a mutable reference to the sampler (for testing).
    #[allow(dead_code)]
    fn with_sampler<F, R>(&self, f: F) -> Option<R>
    where
        F: FnOnce(&mut MetricsSampler) -> R,
    {
        self.sampler.lock().ok().map(|mut s| f(&mut s))
    }
}

impl Default for MetricsServerState {
    fn default() -> Self {
        Self::new()
    }
}

/// Format metrics for Prometheus export.
///
/// This is the core function that generates Prometheus-formatted metrics text.
/// It can be called from any HTTP server implementation.
pub fn format_prometheus_metrics(state: &MetricsServerState) -> Result<String, String> {
    let mut output = state
        .sampler
        .lock()
        .map_err(|e| format!("Failed to acquire sampler lock: {}", e))
        .and_then(|mut sampler| {
            state
                .exporter
                .format_metrics(&mut sampler)
                .map_err(|e| format!("Failed to format metrics: {}", e))
        })?;
    output.push_str(&format_image_build_metrics(
        &ImageBuildEventWriter::default_path(),
    )?);
    Ok(output)
}

fn format_image_build_metrics(path: &Path) -> Result<String, String> {
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
        Err(e) => return Err(format!("Failed to read image build telemetry: {e}")),
    };

    let mut event_counts = BTreeMap::<(String, String, String, String, String, String), u64>::new();
    let mut duration_ms = BTreeMap::<String, (u64, u64)>::new();
    let mut size_bytes = BTreeMap::<String, u64>::new();
    let mut bytes_downloaded = BTreeMap::<String, u64>::new();
    let mut seen_builds = HashSet::<(String, String)>::new();
    let mut duplicate_builds = BTreeMap::<String, u64>::new();

    for line in contents.lines().filter(|line| !line.trim().is_empty()) {
        let event: ImageBuildEvent = serde_json::from_str(line)
            .map_err(|e| format!("Failed to parse image build telemetry: {e}"))?;
        let image = metric_label(&event.image_name);
        let event_type = metric_label(&event.metadata.event_type);
        let decision = metric_label(event.decision.as_deref().unwrap_or("unknown"));
        let reason = metric_label(event.reason.as_deref().unwrap_or("unknown"));
        let status = metric_label(&event.build_status);
        let cache_result = metric_label(event.cache_result.as_deref().unwrap_or("unknown"));
        *event_counts
            .entry((
                image.clone(),
                event_type,
                decision.clone(),
                reason,
                status,
                cache_result,
            ))
            .or_default() += 1;

        if let Some(duration) = event.duration_ms {
            let entry = duration_ms.entry(image.clone()).or_default();
            entry.0 = entry.0.saturating_add(duration);
            entry.1 = entry.1.saturating_add(1);
        }
        if event.image_size_bytes > 0 {
            size_bytes.insert(image.clone(), event.image_size_bytes);
        }
        if let Some(bytes) = event.bytes_downloaded {
            *bytes_downloaded.entry(image.clone()).or_default() += bytes;
        }
        if decision == "build"
            && event.metadata.event_type == "image.build.completed"
            && event.build_status == "success"
            && let Some(digest) = event.source_digest
            && !seen_builds.insert((image.clone(), digest))
        {
            *duplicate_builds.entry(image).or_default() += 1;
        }
    }

    let mut output = String::new();
    output.push_str("# TYPE tillandsias_image_build_events_total counter\n");
    for ((image, event_type, decision, reason, status, cache_result), count) in event_counts {
        output.push_str(&format!(
            "tillandsias_image_build_events_total{{image=\"{image}\",event_type=\"{event_type}\",decision=\"{decision}\",reason=\"{reason}\",status=\"{status}\",cache_result=\"{cache_result}\"}} {count}\n"
        ));
    }
    output.push_str("# TYPE tillandsias_image_build_duration_milliseconds_sum counter\n");
    output.push_str("# TYPE tillandsias_image_build_duration_milliseconds_count counter\n");
    for (image, (sum, count)) in duration_ms {
        output.push_str(&format!(
            "tillandsias_image_build_duration_milliseconds_sum{{image=\"{image}\"}} {sum}\n"
        ));
        output.push_str(&format!(
            "tillandsias_image_build_duration_milliseconds_count{{image=\"{image}\"}} {count}\n"
        ));
    }
    output.push_str("# TYPE tillandsias_image_build_size_bytes gauge\n");
    for (image, size) in size_bytes {
        output.push_str(&format!(
            "tillandsias_image_build_size_bytes{{image=\"{image}\"}} {size}\n"
        ));
    }
    output.push_str("# TYPE tillandsias_image_build_bytes_downloaded_total counter\n");
    for (image, bytes) in bytes_downloaded {
        output.push_str(&format!(
            "tillandsias_image_build_bytes_downloaded_total{{image=\"{image}\"}} {bytes}\n"
        ));
    }
    output.push_str("# TYPE tillandsias_image_build_duplicates_total counter\n");
    for (image, count) in duplicate_builds {
        output.push_str(&format!(
            "tillandsias_image_build_duplicates_total{{image=\"{image}\"}} {count}\n"
        ));
    }
    Ok(output)
}

fn metric_label(value: &str) -> String {
    value
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
        .take(64)
        .collect()
}

/// Outcome of routing one HTTP request line. Kept separate from the IO
/// half so it can be unit-tested without a TCP socket.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum RouteDecision {
    /// GET /metrics → render and return the Prometheus body.
    ServeMetrics,
    /// Anything else with a recognised method but unknown path.
    NotFound,
    /// A non-GET method on /metrics.
    MethodNotAllowed,
    /// The request line was malformed (missing method or path).
    BadRequest,
}

/// Parse and route a single HTTP/1.1 request line such as
/// `GET /metrics HTTP/1.1`. The parser is intentionally narrow: the
/// endpoint is read-only and accepts only `GET /metrics`. Everything else
/// gets a precise diagnostic so scraper misconfigurations are obvious.
pub(crate) fn route_request_line(request_line: &str) -> RouteDecision {
    let line = request_line.trim_end_matches(['\r', '\n']);
    let mut parts = line.split_whitespace();
    let method = match parts.next() {
        Some(m) => m,
        None => return RouteDecision::BadRequest,
    };
    let path = match parts.next() {
        Some(p) => p,
        None => return RouteDecision::BadRequest,
    };
    // The third token (HTTP/1.1) is optional from our parser's perspective.

    // Strip any query string — `/metrics?foo=bar` is still the metrics path.
    let path_only = path.split('?').next().unwrap_or(path);

    if path_only == "/metrics" {
        if method.eq_ignore_ascii_case("GET") {
            RouteDecision::ServeMetrics
        } else {
            RouteDecision::MethodNotAllowed
        }
    } else {
        RouteDecision::NotFound
    }
}

/// Maximum bytes we read while looking for the end of the HTTP request
/// headers. The endpoint is read-only and has no headers we care about, so
/// this is just to bound a slow-loris-style attack on a debug endpoint.
const MAX_REQUEST_BYTES: usize = 8 * 1024;

/// Hard ceiling on how long one client may keep the read side open before
/// we drop them. Same anti-stall purpose as MAX_REQUEST_BYTES; tuned for a
/// local Prometheus scraper, not a public-internet workload.
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Write a complete HTTP/1.1 response (status, content-type, body) and
/// close the connection. We do not implement keep-alive; each scrape is
/// one short connection and the overhead of TCP setup is fine at scrape
/// cadence.
async fn write_http_response(
    stream: &mut TcpStream,
    status_code: u16,
    status_text: &str,
    content_type: &str,
    body: &str,
) -> std::io::Result<()> {
    let response = format!(
        "HTTP/1.1 {code} {text}\r\n\
         Content-Type: {ctype}\r\n\
         Content-Length: {len}\r\n\
         Connection: close\r\n\
         \r\n\
         {body}",
        code = status_code,
        text = status_text,
        ctype = content_type,
        len = body.len(),
        body = body,
    );
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await.ok();
    Ok(())
}

/// Handle one accepted TCP connection: read the request line, route it,
/// and write the response. Errors short-circuit to a logged warning and a
/// dropped connection; the listener loop continues serving.
async fn serve_metrics_connection(mut stream: TcpStream, state: Arc<MetricsServerState>) {
    // Read up to MAX_REQUEST_BYTES OR the first \r\n\r\n, whichever comes
    // first. We only need the request line; further headers are ignored.
    let mut buf = [0u8; MAX_REQUEST_BYTES];
    let mut filled = 0usize;

    loop {
        if filled == buf.len() {
            break; // hit cap — try to parse what we have
        }
        let read_fut = stream.read(&mut buf[filled..]);
        let n = match tokio::time::timeout(READ_TIMEOUT, read_fut).await {
            Ok(Ok(0)) => break, // client closed
            Ok(Ok(n)) => n,
            Ok(Err(e)) => {
                debug!("metrics: read error {e}");
                return;
            }
            Err(_) => {
                debug!("metrics: read timed out");
                return;
            }
        };
        filled += n;
        if buf[..filled].windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }

    if filled == 0 {
        return;
    }

    // Extract first line (CRLF or LF).
    let head = &buf[..filled];
    let line_end = head.iter().position(|&b| b == b'\n').unwrap_or(head.len());
    let request_line = String::from_utf8_lossy(&head[..line_end]).into_owned();

    let decision = route_request_line(&request_line);
    debug!(?decision, request_line = %request_line.trim(), "metrics request");

    match decision {
        RouteDecision::ServeMetrics => match format_prometheus_metrics(&state) {
            Ok(body) => {
                let _ =
                    write_http_response(&mut stream, 200, "OK", "text/plain; version=0.0.4", &body)
                        .await;
            }
            Err(e) => {
                // Per spec:observability-metrics, collection failure MUST
                // be visible to the scraper — return 500 with the error,
                // never fabricate a healthy 200.
                warn!("metrics: collection failed: {e}");
                let body = format!("metrics collection failed: {e}\n");
                let _ = write_http_response(
                    &mut stream,
                    500,
                    "Internal Server Error",
                    "text/plain; charset=utf-8",
                    &body,
                )
                .await;
            }
        },
        RouteDecision::NotFound => {
            let _ = write_http_response(
                &mut stream,
                404,
                "Not Found",
                "text/plain; charset=utf-8",
                "Not Found\nThe metrics endpoint is GET /metrics\n",
            )
            .await;
        }
        RouteDecision::MethodNotAllowed => {
            let _ = write_http_response(
                &mut stream,
                405,
                "Method Not Allowed",
                "text/plain; charset=utf-8",
                "Method Not Allowed\nThe metrics endpoint accepts GET only\n",
            )
            .await;
        }
        RouteDecision::BadRequest => {
            let _ = write_http_response(
                &mut stream,
                400,
                "Bad Request",
                "text/plain; charset=utf-8",
                "Bad Request\n",
            )
            .await;
        }
    }
}

/// Start the metrics HTTP server.
///
/// Binds `addr` and serves `GET /metrics` returning the Prometheus body
/// from `format_prometheus_metrics`. Each accepted connection is spawned
/// onto the runtime so a slow scraper cannot stall the listener.
///
/// Returns `Err` only if `bind()` itself fails — once the listener is up,
/// individual connection errors are logged but the loop continues until
/// the JoinHandle is aborted (typically on tray/headless shutdown).
///
/// # Arguments
///
/// * `addr` - Socket address to listen on (e.g., `127.0.0.1:9090`)
/// * `state` - Shared metrics server state
pub async fn start_metrics_server(
    addr: SocketAddr,
    state: MetricsServerState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let state = Arc::new(state);
    let listener = tokio::net::TcpListener::bind(addr).await?;

    info!("Metrics server listening on http://{}/metrics", addr);

    loop {
        let (socket, peer_addr) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                warn!("metrics: accept error {e}");
                continue;
            }
        };
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            debug!(peer = %peer_addr, "metrics: connection accepted");
            serve_metrics_connection(socket, state).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncBufReadExt;

    #[test]
    fn test_metrics_server_state_creation() {
        let state = MetricsServerState::new();
        assert!(state.sampler.lock().is_ok());
    }

    #[test]
    fn test_metrics_server_state_default() {
        let state = MetricsServerState::default();
        assert!(state.sampler.lock().is_ok());
    }

    #[test]
    fn test_metrics_server_state_shared() {
        let state = Arc::new(MetricsServerState::new());
        let _state_clone = Arc::clone(&state);
        assert!(state.sampler.lock().is_ok());
    }

    #[test]
    fn test_format_prometheus_metrics() {
        let state = MetricsServerState::new();
        let result = format_prometheus_metrics(&state);
        assert!(result.is_ok());

        let metrics = result.unwrap();
        assert!(metrics.contains("tillandsias_container_cpu"));
        assert!(metrics.contains("tillandsias_container_memory"));
        assert!(metrics.contains("# TYPE"));
        assert!(metrics.contains("# HELP"));
    }

    #[test]
    fn test_format_prometheus_metrics_contains_valid_format() {
        let state = MetricsServerState::new();
        let metrics = format_prometheus_metrics(&state).unwrap();

        let lines: Vec<&str> = metrics.lines().collect();
        assert!(!lines.is_empty());

        let type_lines = lines.iter().filter(|l| l.starts_with("# TYPE")).count();
        let help_lines = lines.iter().filter(|l| l.starts_with("# HELP")).count();

        assert!(type_lines > 0, "Should have TYPE comments");
        assert!(help_lines > 0, "Should have HELP comments");
    }

    #[test]
    fn image_build_metrics_use_bounded_labels_and_stable_units() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("image-build-events.jsonl");
        let writer = ImageBuildEventWriter::new(&path);
        let first = ImageBuildEvent::lifecycle(
            "image.build.completed",
            "build-1",
            "tillandsias-init",
            "forge",
            "localhost/tillandsias-forge:sha256-abc",
        )
        .with_identity(
            "sha256:abc",
            "localhost/tillandsias-forge:v1",
            "localhost/tillandsias-forge:latest",
        )
        .with_decision("build", "digest_missing")
        .with_cache("layers", "miss")
        .with_outcome("success", 1250, 0)
        .with_size(1234);
        let second = first.clone();
        writer.append(&first).unwrap();
        writer.append(&second).unwrap();

        let metrics = format_image_build_metrics(&path).unwrap();
        assert!(metrics.contains("tillandsias_image_build_events_total"));
        assert!(metrics.contains("tillandsias_image_build_duration_milliseconds_sum"));
        assert!(metrics.contains("tillandsias_image_build_size_bytes"));
        assert!(metrics.contains("tillandsias_image_build_duplicates_total{image=\"forge\"} 1"));
        assert!(!metrics.contains("sha256:abc"));
        assert!(!metrics.contains("build-1"));
    }

    /// Routing matrix pinning: each branch maps to exactly one decision so
    /// scraper misconfigurations get a precise diagnostic instead of a
    /// silent 200/empty body.
    #[test]
    fn route_request_line_matrix() {
        assert_eq!(
            route_request_line("GET /metrics HTTP/1.1\r\n"),
            RouteDecision::ServeMetrics
        );
        // Query string on /metrics still routes to ServeMetrics.
        assert_eq!(
            route_request_line("GET /metrics?label=foo HTTP/1.1\r\n"),
            RouteDecision::ServeMetrics
        );
        // Lowercase method is tolerated — RFC 7230 calls method
        // case-sensitive, but we want the diagnostic at this layer to
        // identify intent, not punish for casing in a debug endpoint.
        assert_eq!(
            route_request_line("get /metrics HTTP/1.1\r\n"),
            RouteDecision::ServeMetrics
        );
        assert_eq!(
            route_request_line("POST /metrics HTTP/1.1\r\n"),
            RouteDecision::MethodNotAllowed
        );
        assert_eq!(
            route_request_line("GET / HTTP/1.1\r\n"),
            RouteDecision::NotFound
        );
        assert_eq!(
            route_request_line("GET /healthz HTTP/1.1\r\n"),
            RouteDecision::NotFound
        );
        assert_eq!(route_request_line("\r\n"), RouteDecision::BadRequest);
        assert_eq!(route_request_line("GET"), RouteDecision::BadRequest);
    }

    #[tokio::test]
    async fn test_metrics_server_can_bind() {
        let addr: SocketAddr = "127.0.0.1:0".parse().unwrap();

        let listener = match tokio::net::TcpListener::bind(addr).await {
            Ok(listener) => listener,
            Err(err)
                if err.kind() == std::io::ErrorKind::PermissionDenied
                    || err.raw_os_error() == Some(1) =>
            {
                eprintln!(
                    "skipping metrics server bind test in restricted environment: {}",
                    err
                );
                return;
            }
            Err(err) => panic!("unexpected bind failure: {}", err),
        };
        let bound_addr = listener.local_addr().unwrap();

        assert!(bound_addr.port() > 0);
    }

    /// End-to-end: bind the server on an ephemeral port, spawn it, send a
    /// real `GET /metrics` over TCP, and verify the response carries the
    /// Prometheus body and a `200 OK`. This is the integration test that
    /// proves the hand-rolled HTTP handler is wire-compatible with real
    /// scrapers and not just routes-in-a-vacuum.
    #[tokio::test]
    async fn end_to_end_get_metrics_returns_prometheus_body() {
        let listener = match tokio::net::TcpListener::bind("127.0.0.1:0").await {
            Ok(l) => l,
            Err(err)
                if err.kind() == std::io::ErrorKind::PermissionDenied
                    || err.raw_os_error() == Some(1) =>
            {
                eprintln!("skipping end-to-end test in restricted env: {err}");
                return;
            }
            Err(err) => panic!("bind: {err}"),
        };
        let addr = listener.local_addr().unwrap();
        let state = Arc::new(MetricsServerState::new());

        // Hand-spawn the accept-once handler so the test can join cleanly.
        let server_state = Arc::clone(&state);
        let server = tokio::spawn(async move {
            let (sock, _peer) = listener.accept().await.expect("accept");
            serve_metrics_connection(sock, server_state).await;
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client
            .write_all(b"GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .expect("write");
        client.shutdown().await.ok();

        let mut reader = tokio::io::BufReader::new(client);
        let mut status_line = String::new();
        reader.read_line(&mut status_line).await.expect("status");
        assert!(
            status_line.starts_with("HTTP/1.1 200 OK"),
            "got status: {status_line:?}"
        );

        // Drain to end and check that the body contains a known metric name.
        let mut rest = String::new();
        reader.read_to_string(&mut rest).await.expect("body");
        assert!(
            rest.contains("Content-Type: text/plain; version=0.0.4"),
            "missing Prometheus content-type, response was: {rest}"
        );
        assert!(
            rest.contains("tillandsias_container_cpu"),
            "missing metric body, response was: {rest}"
        );

        server.await.expect("server join");
    }

    /// 404 path: a request for the wrong URL gets a precise 404 rather
    /// than a silent empty body — scraper misconfigs surface immediately.
    #[tokio::test]
    async fn end_to_end_unknown_path_returns_404() {
        let listener = match tokio::net::TcpListener::bind("127.0.0.1:0").await {
            Ok(l) => l,
            Err(_) => return,
        };
        let addr = listener.local_addr().unwrap();
        let state = Arc::new(MetricsServerState::new());

        let server_state = Arc::clone(&state);
        let server = tokio::spawn(async move {
            let (sock, _peer) = listener.accept().await.expect("accept");
            serve_metrics_connection(sock, server_state).await;
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client
            .write_all(b"GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .expect("write");
        client.shutdown().await.ok();

        let mut reader = tokio::io::BufReader::new(client);
        let mut status_line = String::new();
        reader.read_line(&mut status_line).await.expect("status");
        assert!(
            status_line.starts_with("HTTP/1.1 404 Not Found"),
            "got status: {status_line:?}"
        );

        server.await.expect("server join");
    }
}
