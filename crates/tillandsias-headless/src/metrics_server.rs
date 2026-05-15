// @trace spec:observability-metrics, gap:OBS-009
//! HTTP server for Prometheus metrics export.
//!
//! This module provides a simple HTTP server that exposes container metrics
//! in Prometheus text format at the `/metrics` endpoint.
//!
//! The server listens on `127.0.0.1:9090` (default Prometheus port) and
//! responds to GET requests with Prometheus-formatted metrics.

use hyper::service::{make_service_fn, service_fn};
use hyper::{Body, Request, Response, Server, StatusCode};
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::Mutex;
use tillandsias_metrics::{MetricsSampler, prometheus_exporter::PrometheusExporter};
use tracing::{debug, error, info};

/// Metrics server state.
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
}

impl Default for MetricsServerState {
    fn default() -> Self {
        Self::new()
    }
}

/// Start the metrics HTTP server.
///
/// This function spawns a new tokio task that runs the metrics server on
/// the specified address. The server responds to GET requests on `/metrics`
/// with Prometheus-formatted metrics.
///
/// # Arguments
///
/// * `addr` - Socket address to listen on (e.g., `127.0.0.1:9090`)
/// * `state` - Shared metrics server state
///
/// # Example
///
/// ```no_run
/// use tillandsias_headless::metrics_server::{MetricsServerState, start_metrics_server};
/// use std::net::SocketAddr;
///
/// # #[tokio::main]
/// # async fn main() {
/// let state = MetricsServerState::new();
/// let addr = "127.0.0.1:9090".parse().unwrap();
/// start_metrics_server(addr, state).await;
/// # }
/// ```
pub async fn start_metrics_server(
    addr: SocketAddr,
    state: MetricsServerState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let state = Arc::new(state);

    let make_svc = make_service_fn(move |_conn| {
        let state = Arc::clone(&state);
        async move {
            Ok::<_, Infallible>(service_fn(move |req| {
                let state = Arc::clone(&state);
                handle_request(req, state)
            }))
        }
    });

    let server = Server::bind(&addr).serve(make_svc);

    info!("Metrics server listening on {}", addr);

    server.await?;

    Ok(())
}

/// Handle incoming HTTP requests.
async fn handle_request(
    req: Request<Body>,
    state: Arc<MetricsServerState>,
) -> Result<Response<Body>, Infallible> {
    debug!("Metrics request: {} {}", req.method(), req.uri().path());

    match (req.method(), req.uri().path()) {
        (hyper::Method::GET, "/metrics") => handle_metrics(&state),
        (hyper::Method::GET, "/") => handle_root(),
        _ => Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::from("Not Found"))
            .unwrap()),
    }
}

/// Handle the `/metrics` endpoint.
fn handle_metrics(state: &MetricsServerState) -> Result<Response<Body>, Infallible> {
    match state.sampler.lock() {
        Ok(mut sampler) => {
            match state.exporter.format_metrics(&mut sampler) {
                Ok(metrics_text) => {
                    debug!("Exported metrics ({} bytes)", metrics_text.len());
                    Ok(Response::builder()
                        .status(StatusCode::OK)
                        .header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                        .body(Body::from(metrics_text))
                        .unwrap())
                }
                Err(e) => {
                    error!("Failed to format metrics: {}", e);
                    Ok(Response::builder()
                        .status(StatusCode::INTERNAL_SERVER_ERROR)
                        .body(Body::from("Internal Server Error"))
                        .unwrap())
                }
            }
        }
        Err(e) => {
            error!("Failed to acquire sampler lock: {}", e);
            Ok(Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(Body::from("Internal Server Error"))
                .unwrap())
        }
    }
}

/// Handle the root path.
fn handle_root() -> Result<Response<Body>, Infallible> {
    Ok(Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "text/plain")
        .body(Body::from("Tillandsias Metrics Server\n/metrics - Prometheus metrics endpoint\n"))
        .unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hyper::Client;

    #[tokio::test]
    async fn test_metrics_server_responds_to_root() {
        let state = MetricsServerState::new();
        let addr: SocketAddr = "127.0.0.1:0".parse().unwrap();

        let (addr, server_task) = {
            let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
            let addr = listener.local_addr().unwrap();

            let state = Arc::new(state);
            let make_svc = make_service_fn(move |_conn| {
                let state = Arc::clone(&state);
                async move {
                    Ok::<_, Infallible>(service_fn(move |req| {
                        let state = Arc::clone(&state);
                        handle_request(req, state)
                    }))
                }
            });

            let server = hyper::Server::from_tcp(
                listener.into_std().unwrap(),
            )
            .unwrap()
            .serve(make_svc);

            let task = tokio::spawn(server);

            (addr, task)
        };

        // Give the server time to start
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let client = Client::new();
        let uri = format!("http://{}/", addr).parse().unwrap();
        let resp = client.get(uri).await.unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        server_task.abort();
    }

    #[test]
    fn test_metrics_server_state_creation() {
        let state = MetricsServerState::new();
        assert!(state.sampler.lock().is_ok());
    }
}
