// @trace gap:OBS-010
//! Log field cardinality analyzer.
//!
//! Detects high-cardinality fields that could cause log explosion.
//! Analyzes recent log entries and warns if any field has unbounded cardinality.

use crate::Result;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use tokio::fs;
use tokio::io::{AsyncBufReadExt, BufReader};
use tracing::warn;

/// Cardinality analysis report
#[derive(Clone, Debug)]
pub struct CardinalityReport {
    pub total_entries: usize,
    pub high_cardinality_fields: Vec<HighCardinalityField>,
}

/// High cardinality field detection
#[derive(Clone, Debug)]
pub struct HighCardinalityField {
    pub field_name: String,
    pub unique_count: usize,
    pub sample_values: Vec<String>,
}

/// Analyzer for log field cardinality
pub struct CardinalityAnalyzer {
    /// Threshold above which a field is considered high-cardinality
    high_cardinality_threshold: usize,
    /// Max entries to analyze in a scan
    max_entries_to_scan: usize,
    /// Max sample values to collect per field
    max_samples: usize,
}

impl Default for CardinalityAnalyzer {
    fn default() -> Self {
        Self {
            high_cardinality_threshold: 1000,
            max_entries_to_scan: 10_000,
            max_samples: 5,
        }
    }
}

impl CardinalityAnalyzer {
    /// Create a new analyzer with custom threshold
    pub fn with_threshold(threshold: usize) -> Self {
        Self {
            high_cardinality_threshold: threshold,
            ..Default::default()
        }
    }

    /// Analyze log file for field cardinality
    pub async fn analyze_log_file(&self, log_path: &Path) -> Result<CardinalityReport> {
        let mut field_values: HashMap<String, HashSet<String>> = HashMap::new();
        let mut entry_count = 0;

        // Check if file exists
        if !log_path.exists() {
            return Ok(CardinalityReport {
                total_entries: 0,
                high_cardinality_fields: Vec::new(),
            });
        }

        let file = fs::File::open(log_path).await?;
        let reader = BufReader::new(file);
        let mut lines = reader.lines();

        // Scan recent entries (up to max_entries_to_scan)
        while let Some(line) = lines.next_line().await? {
            if entry_count >= self.max_entries_to_scan {
                break;
            }

            // Try to parse as JSON log entry
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&line) {
                if let Some(context) = json.get("context").and_then(|c| c.as_object()) {
                    for (key, value) in context {
                        let value_str = match value {
                            Value::String(s) => s.clone(),
                            Value::Number(n) => n.to_string(),
                            _ => value.to_string(),
                        };

                        field_values
                            .entry(key.clone())
                            .or_default()
                            .insert(value_str);
                    }
                }

                // Also check top-level fields (component, level, etc)
                for key in &["component", "level"] {
                    if let Some(val) = json.get(key).and_then(|v| v.as_str()) {
                        field_values
                            .entry(key.to_string())
                            .or_default()
                            .insert(val.to_string());
                    }
                }
            }

            entry_count += 1;
        }

        // Identify high-cardinality fields
        let mut high_cardinality = Vec::new();
        for (field_name, values) in field_values {
            if values.len() > self.high_cardinality_threshold {
                let mut sample_values: Vec<String> =
                    values.iter().take(self.max_samples).cloned().collect();
                sample_values.sort();

                high_cardinality.push(HighCardinalityField {
                    field_name,
                    unique_count: values.len(),
                    sample_values,
                });
            }
        }

        // Sort by cardinality (highest first)
        high_cardinality.sort_by(|a, b| b.unique_count.cmp(&a.unique_count));

        Ok(CardinalityReport {
            total_entries: entry_count,
            high_cardinality_fields: high_cardinality,
        })
    }

    /// Emit warnings for high-cardinality fields
    pub fn warn_high_cardinality(&self, report: &CardinalityReport) {
        if !report.high_cardinality_fields.is_empty() {
            warn!(
                target: "tillandsias",
                "Log cardinality analysis: {} high-cardinality fields detected",
                report.high_cardinality_fields.len()
            );

            for field in &report.high_cardinality_fields {
                warn!(
                    target: "tillandsias",
                    field = %field.field_name,
                    cardinality = field.unique_count,
                    "High-cardinality field detected: {} has {} unique values (samples: {:?})",
                    field.field_name,
                    field.unique_count,
                    field.sample_values.iter().take(3).collect::<Vec<_>>()
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[tokio::test]
    async fn test_cardinality_analyzer_empty_file() {
        let analyzer = CardinalityAnalyzer::default();
        let report = analyzer
            .analyze_log_file(Path::new("/nonexistent/path"))
            .await
            .unwrap();

        assert_eq!(report.total_entries, 0);
        assert!(report.high_cardinality_fields.is_empty());
    }

    #[tokio::test]
    async fn test_cardinality_analyzer_detects_high_cardinality() {
        let mut file = NamedTempFile::new().unwrap();

        // Write log entries with high-cardinality field
        for i in 0..1500 {
            let json = serde_json::json!({
                "schema_version": "1.0",
                "timestamp": "2026-05-14T10:00:00Z",
                "level": "INFO",
                "component": "test",
                "message": "test message",
                "context": {
                    "container_id": format!("container_{}", i),
                    "status": "running"
                }
            });
            writeln!(file, "{}", json.to_string()).unwrap();
        }

        let analyzer = CardinalityAnalyzer::with_threshold(1000);
        let report = analyzer.analyze_log_file(file.path()).await.unwrap();

        assert!(report.total_entries > 0);
        assert!(!report.high_cardinality_fields.is_empty());

        // Check that container_id was detected as high-cardinality
        let container_field = report
            .high_cardinality_fields
            .iter()
            .find(|f| f.field_name == "container_id");
        assert!(container_field.is_some());
        assert!(container_field.unwrap().unique_count > 1000);
    }

    #[tokio::test]
    async fn test_cardinality_analyzer_respects_threshold() {
        let mut file = NamedTempFile::new().unwrap();

        // Write log entries with low-cardinality field
        for i in 0..500 {
            let json = serde_json::json!({
                "schema_version": "1.0",
                "timestamp": "2026-05-14T10:00:00Z",
                "level": "INFO",
                "component": "test",
                "message": "test message",
                "context": {
                    "status": if i % 2 == 0 { "running" } else { "idle" }
                }
            });
            writeln!(file, "{}", json.to_string()).unwrap();
        }

        let analyzer = CardinalityAnalyzer::with_threshold(1000);
        let report = analyzer.analyze_log_file(file.path()).await.unwrap();

        // No field should exceed the 1000 threshold
        assert!(report.high_cardinality_fields.is_empty());
    }

    #[tokio::test]
    async fn test_cardinality_warning_emission() {
        let analyzer = CardinalityAnalyzer::default();
        let report = CardinalityReport {
            total_entries: 5000,
            high_cardinality_fields: vec![HighCardinalityField {
                field_name: "container_id".to_string(),
                unique_count: 2500,
                sample_values: vec!["c001".to_string(), "c002".to_string()],
            }],
        };

        // Should not panic or error
        analyzer.warn_high_cardinality(&report);
    }
}
