// @trace spec:observability-metrics, gap:OBS-009
//! Prometheus text format exporter for CPU, memory, and disk metrics.
//!
//! This module provides a [`PrometheusExporter`] that collects metrics from
//! a [`MetricsSampler`] and formats them as Prometheus text format (also known
//! as OpenMetrics text format) suitable for scraping by Prometheus.
//!
//! The exporter produces metric families with TYPE and HELP comments, followed
//! by one or more metric lines with gauge or counter values. Metric names follow
//! Prometheus conventions:
//! - CPU seconds: `tillandsias_container_cpu_seconds_total` (counter)
//! - Memory bytes: `tillandsias_container_memory_bytes_used` (gauge)
//! - Disk bytes: `tillandsias_container_disk_bytes_used` (gauge)
//!
//! # Example
//!
//! ```no_run
//! use tillandsias_metrics::{MetricsSampler, prometheus_exporter::PrometheusExporter};
//!
//! # async fn run() -> anyhow::Result<()> {
//! let mut sampler = MetricsSampler::new();
//! let exporter = PrometheusExporter::new();
//!
//! // Collect metrics and format as Prometheus text
//! let text = exporter.format_metrics(&mut sampler)?;
//! println!("{}", text);
//! # Ok(())
//! # }
//! ```

use crate::MetricsSampler;
use crate::models::{CpuMetric, DiskMetric, MemoryMetric};
use anyhow::Result;
use std::fmt::Write as FmtWrite;

/// Exporter that collects metrics and formats them as Prometheus text.
///
/// The Prometheus text format is a simple line-based format where each metric
/// is preceded by TYPE and HELP comments. The exporter follows the OpenMetrics
/// specification for metric naming and formatting.
#[derive(Debug, Clone)]
pub struct PrometheusExporter {
    /// Optional job label to include in exported metrics.
    job_label: Option<String>,
}

impl PrometheusExporter {
    /// Create a new Prometheus exporter with default settings.
    pub fn new() -> Self {
        Self {
            job_label: Some("tillandsias".to_string()),
        }
    }

    /// Create a new Prometheus exporter with a custom job label.
    ///
    /// If `job_label` is `None`, no job label will be included in the output.
    pub fn with_job_label(job_label: Option<String>) -> Self {
        Self { job_label }
    }

    /// Collect metrics from the sampler and format them as Prometheus text.
    ///
    /// This method samples CPU, memory, and disk metrics from the sampler and
    /// formats them according to the Prometheus text format specification.
    pub fn format_metrics(&self, sampler: &mut MetricsSampler) -> Result<String> {
        let mut output = String::new();

        // Sample all metrics
        let cpu_metric = sampler.sample_cpu();
        let memory_metric = sampler.sample_memory();
        let disk_metrics = sampler.sample_disk();

        // Append CPU metrics
        self.append_cpu_metrics(&mut output, &cpu_metric)?;

        // Append memory metrics
        self.append_memory_metrics(&mut output, &memory_metric)?;

        // Append disk metrics
        self.append_disk_metrics(&mut output, &disk_metrics)?;

        Ok(output)
    }

    /// Format CPU metrics as Prometheus text.
    fn append_cpu_metrics(&self, output: &mut String, cpu: &CpuMetric) -> Result<()> {
        // CPU usage counter (converted from percentage to seconds with a fixed denominator)
        writeln!(
            output,
            "# HELP tillandsias_container_cpu_seconds_total Total CPU time in seconds"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_cpu_seconds_total counter"
        )?;

        // Convert system_percent to a counter value (percentage * 100 as a counter increment)
        // This represents cumulative CPU seconds at 100% utilization scaled to percentage
        let cpu_counter = (cpu.system_percent * 100.0).trunc() as u64;
        self.write_metric(
            output,
            "tillandsias_container_cpu_seconds_total",
            cpu_counter as f64,
            None,
        )?;

        // Per-core CPU usage as gauges
        writeln!(
            output,
            "# HELP tillandsias_container_cpu_percent Per-core CPU usage percentage"
        )?;
        writeln!(output, "# TYPE tillandsias_container_cpu_percent gauge")?;

        for (core_id, core_percent) in cpu.per_core_percent.iter().enumerate() {
            self.write_metric(
                output,
                "tillandsias_container_cpu_percent",
                *core_percent,
                Some(&[("cpu", &core_id.to_string())]),
            )?;
        }

        // Aggregate CPU percent gauge
        writeln!(
            output,
            "# HELP tillandsias_container_cpu_system_percent System CPU usage percentage"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_cpu_system_percent gauge"
        )?;
        self.write_metric(
            output,
            "tillandsias_container_cpu_system_percent",
            cpu.system_percent,
            None,
        )?;

        Ok(())
    }

    /// Format memory metrics as Prometheus text.
    fn append_memory_metrics(&self, output: &mut String, mem: &MemoryMetric) -> Result<()> {
        writeln!(
            output,
            "# HELP tillandsias_container_memory_bytes_total Total memory in bytes"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_memory_bytes_total gauge"
        )?;
        self.write_metric(
            output,
            "tillandsias_container_memory_bytes_total",
            mem.total_bytes as f64,
            None,
        )?;

        writeln!(
            output,
            "# HELP tillandsias_container_memory_bytes_used Used memory in bytes"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_memory_bytes_used gauge"
        )?;
        self.write_metric(
            output,
            "tillandsias_container_memory_bytes_used",
            mem.used_bytes as f64,
            None,
        )?;

        writeln!(
            output,
            "# HELP tillandsias_container_memory_bytes_available Available memory in bytes"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_memory_bytes_available gauge"
        )?;
        self.write_metric(
            output,
            "tillandsias_container_memory_bytes_available",
            mem.available_bytes as f64,
            None,
        )?;

        writeln!(
            output,
            "# HELP tillandsias_container_memory_percent Used memory percentage"
        )?;
        writeln!(output, "# TYPE tillandsias_container_memory_percent gauge")?;
        self.write_metric(
            output,
            "tillandsias_container_memory_percent",
            mem.used_percent(),
            None,
        )?;

        // Swap metrics
        writeln!(
            output,
            "# HELP tillandsias_container_swap_bytes_total Total swap in bytes"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_swap_bytes_total gauge"
        )?;
        self.write_metric(
            output,
            "tillandsias_container_swap_bytes_total",
            mem.swap_total_bytes as f64,
            None,
        )?;

        writeln!(
            output,
            "# HELP tillandsias_container_swap_bytes_used Used swap in bytes"
        )?;
        writeln!(output, "# TYPE tillandsias_container_swap_bytes_used gauge")?;
        self.write_metric(
            output,
            "tillandsias_container_swap_bytes_used",
            mem.swap_used_bytes as f64,
            None,
        )?;

        Ok(())
    }

    /// Format disk metrics as Prometheus text.
    fn append_disk_metrics(&self, output: &mut String, disks: &[DiskMetric]) -> Result<()> {
        if disks.is_empty() {
            return Ok(());
        }

        writeln!(
            output,
            "# HELP tillandsias_container_disk_bytes_total Total disk space in bytes"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_disk_bytes_total gauge"
        )?;

        for disk in disks {
            let mount = &disk.mount_point;
            self.write_metric(
                output,
                "tillandsias_container_disk_bytes_total",
                disk.total_bytes as f64,
                Some(&[("mount_point", mount)]),
            )?;
        }

        writeln!(
            output,
            "# HELP tillandsias_container_disk_bytes_used Used disk space in bytes"
        )?;
        writeln!(output, "# TYPE tillandsias_container_disk_bytes_used gauge")?;

        for disk in disks {
            let mount = &disk.mount_point;
            self.write_metric(
                output,
                "tillandsias_container_disk_bytes_used",
                disk.used_bytes() as f64,
                Some(&[("mount_point", mount)]),
            )?;
        }

        writeln!(
            output,
            "# HELP tillandsias_container_disk_bytes_available Available disk space in bytes"
        )?;
        writeln!(
            output,
            "# TYPE tillandsias_container_disk_bytes_available gauge"
        )?;

        for disk in disks {
            let mount = &disk.mount_point;
            self.write_metric(
                output,
                "tillandsias_container_disk_bytes_available",
                disk.available_bytes as f64,
                Some(&[("mount_point", mount)]),
            )?;
        }

        Ok(())
    }

    /// Write a single metric line in Prometheus text format.
    ///
    /// Format: `metric_name{labels} value timestamp`
    /// If labels are provided, they are formatted as `key="value"` pairs separated by commas.
    fn write_metric(
        &self,
        output: &mut String,
        metric_name: &str,
        value: f64,
        labels: Option<&[(&str, &str)]>,
    ) -> Result<()> {
        write!(output, "{}", metric_name)?;

        // Format labels
        let mut label_parts = Vec::new();

        // Add job label if configured
        if let Some(ref job) = self.job_label {
            label_parts.push(format!(r#"job="{}""#, escape_label_value(job)));
        }

        // Add additional labels
        if let Some(labels) = labels {
            for (key, value) in labels {
                label_parts.push(format!(r#"{}="{}""#, key, escape_label_value(value)));
            }
        }

        // Write labels
        if !label_parts.is_empty() {
            write!(output, "{{{}}}", label_parts.join(","))?;
        }

        // Write value
        writeln!(output, " {}", value)?;

        Ok(())
    }
}

impl Default for PrometheusExporter {
    fn default() -> Self {
        Self::new()
    }
}

/// Escape special characters in label values according to Prometheus spec.
///
/// Label values must be quoted and escape backslashes, double quotes, and newlines.
fn escape_label_value(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[test]
    fn test_prometheus_format_cpu_metric() {
        let exporter = PrometheusExporter::new();
        let cpu = CpuMetric {
            system_percent: 42.5,
            per_core_percent: vec![25.0, 60.0],
            timestamp: Utc::now(),
        };

        let mut output = String::new();
        exporter.append_cpu_metrics(&mut output, &cpu).unwrap();

        // Check that TYPE and HELP comments are present
        assert!(output.contains("# TYPE tillandsias_container_cpu_seconds_total counter"));
        assert!(output.contains("# HELP tillandsias_container_cpu_seconds_total"));

        // Check that metric values are present
        assert!(output.contains("tillandsias_container_cpu_seconds_total"));
        assert!(output.contains("tillandsias_container_cpu_percent"));
        assert!(
            output.contains("tillandsias_container_cpu_system_percent{job=\"tillandsias\"} 42.5")
        );

        // Check per-core metrics
        assert!(output.contains(r#"cpu="0""#));
        assert!(output.contains(r#"cpu="1""#));
    }

    #[test]
    fn test_prometheus_format_memory_metric() {
        let exporter = PrometheusExporter::new();
        let mem = MemoryMetric {
            total_bytes: 16_000_000_000,
            used_bytes: 8_000_000_000,
            available_bytes: 8_000_000_000,
            swap_total_bytes: 4_000_000_000,
            swap_used_bytes: 1_000_000_000,
            timestamp: Utc::now(),
        };

        let mut output = String::new();
        exporter.append_memory_metrics(&mut output, &mem).unwrap();

        // Check that TYPE and HELP comments are present
        assert!(output.contains("# TYPE tillandsias_container_memory_bytes_used gauge"));
        assert!(output.contains("# HELP tillandsias_container_memory_bytes_used"));

        // Check values
        assert!(
            output.contains(
                "tillandsias_container_memory_bytes_total{job=\"tillandsias\"} 16000000000"
            )
        );
        assert!(
            output.contains(
                "tillandsias_container_memory_bytes_used{job=\"tillandsias\"} 8000000000"
            )
        );
        assert!(output.contains(
            "tillandsias_container_memory_bytes_available{job=\"tillandsias\"} 8000000000"
        ));
        assert!(
            output
                .contains("tillandsias_container_swap_bytes_total{job=\"tillandsias\"} 4000000000")
        );
        assert!(
            output
                .contains("tillandsias_container_swap_bytes_used{job=\"tillandsias\"} 1000000000")
        );
    }

    #[test]
    fn test_prometheus_format_disk_metric() {
        let exporter = PrometheusExporter::new();
        let disks = vec![
            DiskMetric {
                mount_point: "/".to_string(),
                total_bytes: 100_000_000_000,
                available_bytes: 50_000_000_000,
                timestamp: Utc::now(),
            },
            DiskMetric {
                mount_point: "/home".to_string(),
                total_bytes: 500_000_000_000,
                available_bytes: 300_000_000_000,
                timestamp: Utc::now(),
            },
        ];

        let mut output = String::new();
        exporter.append_disk_metrics(&mut output, &disks).unwrap();

        // Check that TYPE and HELP comments are present
        assert!(output.contains("# TYPE tillandsias_container_disk_bytes_used gauge"));
        assert!(output.contains("# HELP tillandsias_container_disk_bytes_used"));

        // Check mount points are labeled
        assert!(output.contains(r#"mount_point="/""#));
        assert!(output.contains(r#"mount_point="/home""#));

        // Check values
        assert!(output.contains("tillandsias_container_disk_bytes_total{job=\"tillandsias\",mount_point=\"/\"} 100000000000"));
    }

    #[test]
    fn test_escape_label_value() {
        assert_eq!(escape_label_value("simple"), "simple");
        assert_eq!(escape_label_value("with\"quote"), "with\\\"quote");
        assert_eq!(escape_label_value("with\\backslash"), "with\\\\backslash");
        assert_eq!(escape_label_value("with\nnewline"), "with\\nnewline");
        assert_eq!(
            escape_label_value("all\\\"special\nchars"),
            "all\\\\\\\"special\\nchars"
        );
    }

    #[test]
    fn test_prometheus_exporter_with_custom_job() {
        let exporter = PrometheusExporter::with_job_label(Some("my_app".to_string()));
        let mem = MemoryMetric {
            total_bytes: 1000,
            used_bytes: 500,
            available_bytes: 500,
            swap_total_bytes: 0,
            swap_used_bytes: 0,
            timestamp: Utc::now(),
        };

        let mut output = String::new();
        exporter.append_memory_metrics(&mut output, &mem).unwrap();

        assert!(output.contains(r#"job="my_app""#));
        assert!(!output.contains(r#"job="tillandsias""#));
    }

    #[test]
    fn test_prometheus_exporter_no_job_label() {
        let exporter = PrometheusExporter::with_job_label(None);
        let mem = MemoryMetric {
            total_bytes: 1000,
            used_bytes: 500,
            available_bytes: 500,
            swap_total_bytes: 0,
            swap_used_bytes: 0,
            timestamp: Utc::now(),
        };

        let mut output = String::new();
        exporter.append_memory_metrics(&mut output, &mem).unwrap();

        // Should not contain any labels at all
        assert!(!output.contains("job="));
        // Should still contain the metric
        assert!(output.contains("tillandsias_container_memory_bytes_used 500"));
    }

    #[test]
    fn test_zero_metrics() {
        let exporter = PrometheusExporter::new();
        let mem = MemoryMetric {
            total_bytes: 0,
            used_bytes: 0,
            available_bytes: 0,
            swap_total_bytes: 0,
            swap_used_bytes: 0,
            timestamp: Utc::now(),
        };

        let mut output = String::new();
        exporter.append_memory_metrics(&mut output, &mem).unwrap();

        // Should still format correctly with zero values
        assert!(output.contains("tillandsias_container_memory_bytes_total{job=\"tillandsias\"} 0"));
        assert!(output.contains("tillandsias_container_memory_percent{job=\"tillandsias\"} 0"));
    }

    #[test]
    fn test_empty_disks() {
        let exporter = PrometheusExporter::new();
        let disks: Vec<DiskMetric> = vec![];

        let mut output = String::new();
        exporter.append_disk_metrics(&mut output, &disks).unwrap();

        // Should produce no output for empty disk list
        assert!(output.is_empty());
    }
}
