// @trace spec:log-aggregation, gap:OBS-013
//! Log aggregation for merging logs from multiple container sources.
//!
//! Provides functionality to:
//! - Aggregate logs from multiple containers (proxy, git, forge, inference)
//! - Merge into a unified stream sorted by timestamp
//! - Filter by container name, component, spec, or log level
//! - Support efficient querying across multiple sources

use crate::error::Result;
use crate::log_entry::LogEntry;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Container source identifier
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ContainerSource {
    /// Container name (e.g., "tillandsias-proxy", "tillandsias-git", "tillandsias-forge")
    pub name: String,
    /// Unique container ID
    pub id: String,
}

impl ContainerSource {
    /// Create a new container source
    pub fn new(name: impl Into<String>, id: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            id: id.into(),
        }
    }
}

/// Filter criteria for aggregating logs
#[derive(Clone, Debug)]
pub struct AggregationFilter {
    /// Optional container names to include (if empty, include all)
    pub containers: Vec<String>,
    /// Optional components to include (if empty, include all)
    pub components: Vec<String>,
    /// Optional specs to include (if empty, include all)
    pub specs: Vec<String>,
    /// Optional log levels to include (if empty, include all)
    pub levels: Vec<String>,
}

impl Default for AggregationFilter {
    fn default() -> Self {
        Self {
            containers: Vec::new(),
            components: Vec::new(),
            specs: Vec::new(),
            levels: Vec::new(),
        }
    }
}

impl AggregationFilter {
    /// Create a new empty filter (matches all)
    pub fn new() -> Self {
        Self::default()
    }

    /// Add container filter
    pub fn with_container(mut self, container: impl Into<String>) -> Self {
        self.containers.push(container.into());
        self
    }

    /// Add component filter
    pub fn with_component(mut self, component: impl Into<String>) -> Self {
        self.components.push(component.into());
        self
    }

    /// Add spec filter
    pub fn with_spec(mut self, spec: impl Into<String>) -> Self {
        self.specs.push(spec.into());
        self
    }

    /// Add level filter
    pub fn with_level(mut self, level: impl Into<String>) -> Self {
        self.levels.push(level.into());
        self
    }

    /// Check if a log entry matches this filter
    fn matches(&self, entry: &AggregatedLogEntry) -> bool {
        if !self.containers.is_empty() && !self.containers.contains(&entry.container) {
            return false;
        }
        if !self.components.is_empty() && !self.components.contains(&entry.entry.component) {
            return false;
        }
        if !self.levels.is_empty() && !self.levels.contains(&entry.entry.level) {
            return false;
        }
        if !self.specs.is_empty() {
            let entry_spec = entry.entry.spec_trace.as_deref().unwrap_or("");
            if !self.specs.iter().any(|s| entry_spec.contains(s)) {
                return false;
            }
        }
        true
    }
}

/// A log entry with its container source information
#[derive(Clone, Debug)]
pub struct AggregatedLogEntry {
    /// Container name this log came from
    pub container: String,
    /// Container ID this log came from
    pub container_id: String,
    /// The actual log entry
    pub entry: LogEntry,
}

impl AggregatedLogEntry {
    /// Create a new aggregated log entry
    pub fn new(
        container: impl Into<String>,
        container_id: impl Into<String>,
        entry: LogEntry,
    ) -> Self {
        Self {
            container: container.into(),
            container_id: container_id.into(),
            entry,
        }
    }
}

/// Log aggregator for merging logs from multiple container sources
pub struct LogAggregator {
    /// Logs grouped by container source
    logs: Arc<RwLock<HashMap<String, Vec<AggregatedLogEntry>>>>,
    /// Track container sources
    sources: Arc<RwLock<HashMap<String, ContainerSource>>>,
}

impl LogAggregator {
    /// Create a new log aggregator
    pub fn new() -> Self {
        Self {
            logs: Arc::new(RwLock::new(HashMap::new())),
            sources: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Register a container source
    pub async fn register_source(&self, source: ContainerSource) {
        let mut sources = self.sources.write().await;
        sources.insert(source.id.clone(), source.clone());

        let mut logs = self.logs.write().await;
        logs.entry(source.id.clone()).or_insert_with(Vec::new);
    }

    /// Add a log entry from a container
    pub async fn add_log(
        &self,
        container: impl Into<String>,
        container_id: impl Into<String>,
        entry: LogEntry,
    ) -> Result<()> {
        let container_str = container.into();
        let container_id_str = container_id.into();

        let mut logs = self.logs.write().await;
        logs.entry(container_id_str.clone())
            .or_insert_with(Vec::new)
            .push(AggregatedLogEntry::new(
                container_str,
                container_id_str,
                entry,
            ));

        Ok(())
    }

    /// Get all aggregated logs sorted by timestamp (oldest first)
    pub async fn get_all_logs(&self) -> Result<Vec<AggregatedLogEntry>> {
        let logs = self.logs.read().await;
        let mut all_entries: Vec<AggregatedLogEntry> =
            logs.values().flat_map(|v| v.clone()).collect();

        // Sort by timestamp ascending (oldest first)
        all_entries.sort_by(|a, b| a.entry.timestamp.cmp(&b.entry.timestamp));
        Ok(all_entries)
    }

    /// Get aggregated logs with filtering
    pub async fn get_logs_filtered(
        &self,
        filter: &AggregationFilter,
    ) -> Result<Vec<AggregatedLogEntry>> {
        let all_logs = self.get_all_logs().await?;
        let filtered: Vec<AggregatedLogEntry> = all_logs
            .into_iter()
            .filter(|entry| filter.matches(entry))
            .collect();
        Ok(filtered)
    }

    /// Get logs from a specific container
    pub async fn get_logs_by_container(
        &self,
        container_id: &str,
    ) -> Result<Vec<AggregatedLogEntry>> {
        let logs = self.logs.read().await;
        match logs.get(container_id) {
            Some(entries) => {
                let mut sorted = entries.clone();
                sorted.sort_by(|a, b| a.entry.timestamp.cmp(&b.entry.timestamp));
                Ok(sorted)
            }
            None => Ok(Vec::new()),
        }
    }

    /// Get logs from multiple containers
    pub async fn get_logs_by_containers(
        &self,
        container_ids: &[String],
    ) -> Result<Vec<AggregatedLogEntry>> {
        let logs = self.logs.read().await;
        let mut all_entries: Vec<AggregatedLogEntry> = container_ids
            .iter()
            .filter_map(|id| logs.get(id))
            .flat_map(|v| v.clone())
            .collect();

        all_entries.sort_by(|a, b| a.entry.timestamp.cmp(&b.entry.timestamp));
        Ok(all_entries)
    }

    /// Get logs grouped by container
    pub async fn get_logs_grouped(&self) -> Result<HashMap<String, Vec<AggregatedLogEntry>>> {
        let logs = self.logs.read().await;
        let mut result: HashMap<String, Vec<AggregatedLogEntry>> = HashMap::new();

        for (container_id, entries) in logs.iter() {
            let mut sorted = entries.clone();
            sorted.sort_by(|a, b| a.entry.timestamp.cmp(&b.entry.timestamp));
            result.insert(container_id.clone(), sorted);
        }

        Ok(result)
    }

    /// Get logs grouped by container name (not ID)
    pub async fn get_logs_grouped_by_name(
        &self,
    ) -> Result<HashMap<String, Vec<AggregatedLogEntry>>> {
        let all_logs = self.get_all_logs().await?;
        let mut result: HashMap<String, Vec<AggregatedLogEntry>> = HashMap::new();

        for entry in all_logs {
            result
                .entry(entry.container.clone())
                .or_insert_with(Vec::new)
                .push(entry);
        }

        Ok(result)
    }

    /// Get logs grouped by component
    pub async fn get_logs_grouped_by_component(
        &self,
    ) -> Result<HashMap<String, Vec<AggregatedLogEntry>>> {
        let all_logs = self.get_all_logs().await?;
        let mut result: HashMap<String, Vec<AggregatedLogEntry>> = HashMap::new();

        for entry in all_logs {
            result
                .entry(entry.entry.component.clone())
                .or_insert_with(Vec::new)
                .push(entry);
        }

        Ok(result)
    }

    /// Get logs grouped by spec trace
    pub async fn get_logs_grouped_by_spec(
        &self,
    ) -> Result<HashMap<String, Vec<AggregatedLogEntry>>> {
        let all_logs = self.get_all_logs().await?;
        let mut result: HashMap<String, Vec<AggregatedLogEntry>> = HashMap::new();

        for entry in all_logs {
            let spec = entry
                .entry
                .spec_trace
                .as_deref()
                .unwrap_or("unspecified")
                .to_string();
            result.entry(spec).or_insert_with(Vec::new).push(entry);
        }

        Ok(result)
    }

    /// Get count of logs per container
    pub async fn get_counts_by_container(&self) -> Result<HashMap<String, usize>> {
        let logs = self.logs.read().await;
        let mut counts: HashMap<String, usize> = HashMap::new();

        for (container_id, entries) in logs.iter() {
            counts.insert(container_id.clone(), entries.len());
        }

        Ok(counts)
    }

    /// Get count of logs per level
    pub async fn get_counts_by_level(&self) -> Result<HashMap<String, usize>> {
        let all_logs = self.get_all_logs().await?;
        let mut counts: HashMap<String, usize> = HashMap::new();

        for entry in all_logs {
            *counts.entry(entry.entry.level.clone()).or_insert(0) += 1;
        }

        Ok(counts)
    }

    /// Clear all logs (for testing)
    pub async fn clear(&self) {
        let mut logs = self.logs.write().await;
        logs.clear();
    }

    /// Get total number of logs
    pub async fn count_all(&self) -> Result<usize> {
        let logs = self.logs.read().await;
        let count = logs.values().map(|v| v.len()).sum();
        Ok(count)
    }

    /// Get registered sources
    pub async fn get_sources(&self) -> Result<Vec<ContainerSource>> {
        let sources = self.sources.read().await;
        Ok(sources.values().cloned().collect())
    }
}

impl Default for LogAggregator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[tokio::test]
    async fn test_aggregator_creation() {
        let aggregator = LogAggregator::new();
        let count = aggregator.count_all().await.unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn test_register_source() {
        let aggregator = LogAggregator::new();
        let source = ContainerSource::new("tillandsias-proxy", "proxy-id-123");
        aggregator.register_source(source.clone()).await;

        let sources = aggregator.get_sources().await.unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].name, "tillandsias-proxy");
    }

    #[tokio::test]
    async fn test_add_single_log_entry() {
        let aggregator = LogAggregator::new();
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "proxy".to_string(),
            "cache hit".to_string(),
        );

        aggregator
            .add_log("tillandsias-proxy", "proxy-id-123", entry)
            .await
            .unwrap();

        let count = aggregator.count_all().await.unwrap();
        assert_eq!(count, 1);
    }

    #[tokio::test]
    async fn test_add_multiple_logs_from_different_containers() {
        let aggregator = LogAggregator::new();
        let mut now = Utc::now();

        // Proxy container logs
        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "proxy msg 1".to_string(),
                ),
            )
            .await
            .unwrap();

        now = now + chrono::Duration::seconds(1);
        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "WARN".to_string(),
                    "proxy".to_string(),
                    "proxy msg 2".to_string(),
                ),
            )
            .await
            .unwrap();

        // Git service logs
        now = now + chrono::Duration::seconds(1);
        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "git msg 1".to_string(),
                ),
            )
            .await
            .unwrap();

        // Forge logs
        now = now + chrono::Duration::seconds(1);
        aggregator
            .add_log(
                "tillandsias-forge",
                "forge-id",
                LogEntry::new(
                    now,
                    "ERROR".to_string(),
                    "forge".to_string(),
                    "forge msg 1".to_string(),
                ),
            )
            .await
            .unwrap();

        let count = aggregator.count_all().await.unwrap();
        assert_eq!(count, 4);
    }

    #[tokio::test]
    async fn test_get_all_logs_sorted_by_timestamp() {
        let aggregator = LogAggregator::new();
        let base_time = Utc::now();

        // Add logs in non-chronological order
        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    base_time + chrono::Duration::seconds(3),
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "third".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    base_time,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "first".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-forge",
                "forge-id",
                LogEntry::new(
                    base_time + chrono::Duration::seconds(1),
                    "INFO".to_string(),
                    "forge".to_string(),
                    "second".to_string(),
                ),
            )
            .await
            .unwrap();

        let all_logs = aggregator.get_all_logs().await.unwrap();
        assert_eq!(all_logs.len(), 3);

        // Verify sorted order
        assert_eq!(all_logs[0].entry.message, "first");
        assert_eq!(all_logs[1].entry.message, "second");
        assert_eq!(all_logs[2].entry.message, "third");
    }

    #[tokio::test]
    async fn test_filter_by_container() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg".to_string(),
                ),
            )
            .await
            .unwrap();

        let filter = AggregationFilter::new().with_container("tillandsias-proxy");
        let filtered = aggregator.get_logs_filtered(&filter).await.unwrap();

        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].container, "tillandsias-proxy");
    }

    #[tokio::test]
    async fn test_filter_by_component() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-forge",
                "forge-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "inference".to_string(),
                    "msg".to_string(),
                ),
            )
            .await
            .unwrap();

        let filter = AggregationFilter::new().with_component("proxy");
        let filtered = aggregator.get_logs_filtered(&filter).await.unwrap();

        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].entry.component, "proxy");
    }

    #[tokio::test]
    async fn test_filter_by_level() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "ERROR".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        let filter = AggregationFilter::new().with_level("ERROR");
        let filtered = aggregator.get_logs_filtered(&filter).await.unwrap();

        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].entry.level, "ERROR");
    }

    #[tokio::test]
    async fn test_filter_by_spec() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                )
                .with_spec_trace("spec:enclave-network"),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg2".to_string(),
                )
                .with_spec_trace("spec:git-mirror-service"),
            )
            .await
            .unwrap();

        let filter = AggregationFilter::new().with_spec("git-mirror");
        let filtered = aggregator.get_logs_filtered(&filter).await.unwrap();

        assert_eq!(filtered.len(), 1);
        assert!(
            filtered[0]
                .entry
                .spec_trace
                .as_ref()
                .unwrap()
                .contains("git-mirror")
        );
    }

    #[tokio::test]
    async fn test_get_logs_by_container() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now + chrono::Duration::seconds(1),
                    "WARN".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg".to_string(),
                ),
            )
            .await
            .unwrap();

        let proxy_logs = aggregator.get_logs_by_container("proxy-id").await.unwrap();
        assert_eq!(proxy_logs.len(), 2);
        assert_eq!(proxy_logs[0].entry.level, "INFO");
        assert_eq!(proxy_logs[1].entry.level, "WARN");
    }

    #[tokio::test]
    async fn test_get_logs_grouped_by_container() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        let grouped = aggregator.get_logs_grouped().await.unwrap();
        assert_eq!(grouped.len(), 2);
        assert!(grouped.contains_key("proxy-id"));
        assert!(grouped.contains_key("git-id"));
    }

    #[tokio::test]
    async fn test_get_logs_grouped_by_name() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id-1",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id-2",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg3".to_string(),
                ),
            )
            .await
            .unwrap();

        let grouped = aggregator.get_logs_grouped_by_name().await.unwrap();
        assert_eq!(grouped.len(), 2);
        assert_eq!(grouped["tillandsias-proxy"].len(), 2);
        assert_eq!(grouped["tillandsias-git"].len(), 1);
    }

    #[tokio::test]
    async fn test_get_logs_grouped_by_component() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-forge",
                "forge-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg3".to_string(),
                ),
            )
            .await
            .unwrap();

        let grouped = aggregator.get_logs_grouped_by_component().await.unwrap();
        assert_eq!(grouped.len(), 2);
        assert_eq!(grouped["proxy"].len(), 2);
        assert_eq!(grouped["git-service"].len(), 1);
    }

    #[tokio::test]
    async fn test_get_logs_grouped_by_spec() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                )
                .with_spec_trace("spec:network"),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg2".to_string(),
                )
                .with_spec_trace("spec:git"),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-forge",
                "forge-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "forge".to_string(),
                    "msg3".to_string(),
                ),
            )
            .await
            .unwrap();

        let grouped = aggregator.get_logs_grouped_by_spec().await.unwrap();
        assert_eq!(grouped["spec:network"].len(), 1);
        assert_eq!(grouped["spec:git"].len(), 1);
        assert_eq!(grouped["unspecified"].len(), 1);
    }

    #[tokio::test]
    async fn test_get_counts_by_container() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg3".to_string(),
                ),
            )
            .await
            .unwrap();

        let counts = aggregator.get_counts_by_container().await.unwrap();
        assert_eq!(counts["proxy-id"], 2);
        assert_eq!(counts["git-id"], 1);
    }

    #[tokio::test]
    async fn test_get_counts_by_level() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "ERROR".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "ERROR".to_string(),
                    "git-service".to_string(),
                    "msg3".to_string(),
                ),
            )
            .await
            .unwrap();

        let counts = aggregator.get_counts_by_level().await.unwrap();
        assert_eq!(counts["INFO"], 1);
        assert_eq!(counts["ERROR"], 2);
    }

    #[tokio::test]
    async fn test_multiple_filters_combined() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                )
                .with_spec_trace("spec:network"),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "ERROR".to_string(),
                    "proxy".to_string(),
                    "msg2".to_string(),
                )
                .with_spec_trace("spec:network"),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "ERROR".to_string(),
                    "git-service".to_string(),
                    "msg3".to_string(),
                )
                .with_spec_trace("spec:network"),
            )
            .await
            .unwrap();

        let filter = AggregationFilter::new()
            .with_container("tillandsias-proxy")
            .with_level("ERROR")
            .with_spec("network");

        let filtered = aggregator.get_logs_filtered(&filter).await.unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].container, "tillandsias-proxy");
        assert_eq!(filtered[0].entry.level, "ERROR");
    }

    #[tokio::test]
    async fn test_clear_logs() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg".to_string(),
                ),
            )
            .await
            .unwrap();

        assert_eq!(aggregator.count_all().await.unwrap(), 1);

        aggregator.clear().await;

        assert_eq!(aggregator.count_all().await.unwrap(), 0);
    }

    #[tokio::test]
    async fn test_get_logs_by_multiple_containers() {
        let aggregator = LogAggregator::new();
        let now = Utc::now();

        aggregator
            .add_log(
                "tillandsias-proxy",
                "proxy-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "proxy".to_string(),
                    "msg1".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-git",
                "git-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "git-service".to_string(),
                    "msg2".to_string(),
                ),
            )
            .await
            .unwrap();

        aggregator
            .add_log(
                "tillandsias-forge",
                "forge-id",
                LogEntry::new(
                    now,
                    "INFO".to_string(),
                    "forge".to_string(),
                    "msg3".to_string(),
                ),
            )
            .await
            .unwrap();

        let logs = aggregator
            .get_logs_by_containers(&["proxy-id".to_string(), "forge-id".to_string()])
            .await
            .unwrap();

        assert_eq!(logs.len(), 2);
        assert!(logs.iter().any(|l| l.container == "tillandsias-proxy"));
        assert!(logs.iter().any(|l| l.container == "tillandsias-forge"));
    }
}
