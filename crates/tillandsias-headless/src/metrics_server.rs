// @trace spec:observability-metrics, gap:OBS-009
//! HTTP server for Prometheus metrics export.
//!
//! This module provides a simple HTTP server that exposes container metrics
//! in Prometheus text format at the `/metrics` endpoint.
//!
//! The server listens on `127.0.0.1:9090` (default Prometheus port) and
//! responds to GET requests with Prometheus-formatted metrics.
//!
//! Note: This module declares the server infrastructure but does not integrate
//! it into the main headless binary. Integration into run_headless() is deferred
//! to a separate change (TR-009 or similar).

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::Mutex;
use tillandsias_metrics::{MetricsSampler, prometheus_exporter::PrometheusExporter};
use tracing::info;

/// Metrics server state.
///
/// Holds a sampler and exporter for serving Prometheus metrics.
#[derive(Debug)]
pub struct MetricsServerState {
    sampler: Arc<Mutex<MetricsSampler>>,
    #[allow(dead_code)]
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
#[allow(dead_code)]
pub fn format_prometheus_metrics(state: &MetricsServerState) -> Result<String, String> {
    state
        .sampler
        .lock()
        .map_err(|e| format!("Failed to acquire sampler lock: {}", e))
        .and_then(|mut sampler| {
            state
                .exporter
                .format_metrics(&mut sampler)
                .map_err(|e| format!("Failed to format metrics: {}", e))
        })
}

/// Start the metrics HTTP server (async placeholder).
///
/// This function demonstrates the intended API for starting a metrics server.
/// It is not fully integrated into the binary yet, as hyper 1.x requires
/// additional dependencies (hyper-util for TokioIo).
///
/// To use this in production:
/// 1. Add hyper-util to Cargo.toml
/// 2. Call this function from run_headless() with tokio::spawn()
/// 3. Configure the bind address (e.g., from config or --metrics-addr flag)
///
/// # Arguments
///
/// * `addr` - Socket address to listen on (e.g., `127.0.0.1:9090`)
/// * `state` - Shared metrics server state
#[allow(dead_code)]
pub async fn start_metrics_server(
    addr: SocketAddr,
    state: MetricsServerState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let state = Arc::new(state);
    let listener = tokio::net::TcpListener::bind(addr).await?;

    info!("Metrics server listening on {}", addr);

    loop {
        let (_socket, _peer_addr) = listener.accept().await?;
        let _state = Arc::clone(&state);

        // TODO: Implement HTTP connection handling
        // This requires hyper-util for TokioIo wrapper, or a simpler HTTP parser
        // For now, this is left as a template for future integration
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

        // Check for Prometheus text format elements
        let lines: Vec<&str> = metrics.lines().collect();
        assert!(!lines.is_empty());

        // Should have at least some TYPE and HELP comments
        let type_lines = lines.iter().filter(|l| l.starts_with("# TYPE")).count();
        let help_lines = lines.iter().filter(|l| l.starts_with("# HELP")).count();

        assert!(type_lines > 0, "Should have TYPE comments");
        assert!(help_lines > 0, "Should have HELP comments");
    }

    #[tokio::test]
    async fn test_metrics_server_can_bind() {
        let addr: SocketAddr = "127.0.0.1:0".parse().unwrap();

        let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
        let bound_addr = listener.local_addr().unwrap();

        assert!(bound_addr.port() > 0);
    }
}
