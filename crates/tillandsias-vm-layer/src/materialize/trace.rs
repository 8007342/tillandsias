//! Recipe-trace JSONL ledger (§3.8 of vm-recipe-provisioning).
//!
//! Append-only, line-delimited JSON records — one per cache lookup +
//! one per final rootfs emission + one per GC sweep that evicted at
//! least one layer. Cheap to write (single `writeln!`) and trivial to
//! grep + ingest from anywhere.
//!
//! Lives at `<cache_root>/recipe-trace.jsonl`.
//!
//! @trace spec:vm-provisioning-lifecycle (§3.8)

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use super::cache::GcReport;
use super::layer_key::LayerKey;

/// One trace record. Serialised as one line of JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum TraceEvent {
    LayerHit {
        index: usize,
        key: String,
        cached_path: PathBuf,
        unix_ts: u64,
    },
    LayerMiss {
        index: usize,
        key: String,
        written_path: PathBuf,
        unix_ts: u64,
    },
    RootfsEmitted {
        key: String,
        path: PathBuf,
        unix_ts: u64,
    },
    Gc {
        arch_dir: PathBuf,
        evicted: usize,
        unix_ts: u64,
    },
}

impl TraceEvent {
    pub fn layer_hit(index: usize, key: LayerKey, cached_path: PathBuf, ts: SystemTime) -> Self {
        TraceEvent::LayerHit {
            index,
            key: key.to_string(),
            cached_path,
            unix_ts: unix_secs(ts),
        }
    }

    pub fn layer_miss(index: usize, key: LayerKey, written_path: PathBuf, ts: SystemTime) -> Self {
        TraceEvent::LayerMiss {
            index,
            key: key.to_string(),
            written_path,
            unix_ts: unix_secs(ts),
        }
    }

    pub fn rootfs_emitted(key: LayerKey, path: PathBuf, ts: SystemTime) -> Self {
        TraceEvent::RootfsEmitted {
            key: key.to_string(),
            path,
            unix_ts: unix_secs(ts),
        }
    }

    pub fn gc(report: GcReport, ts: SystemTime) -> Self {
        TraceEvent::Gc {
            arch_dir: report.arch_dir,
            evicted: report.evicted,
            unix_ts: unix_secs(ts),
        }
    }
}

/// Append-only JSONL writer rooted at `<cache_root>/recipe-trace.jsonl`.
pub struct TraceLedger {
    file: File,
    path: PathBuf,
}

impl TraceLedger {
    /// Open (creating if absent) the JSONL ledger under `cache_root`.
    pub fn open(cache_root: &Path) -> std::io::Result<Self> {
        let path = cache_root.join("recipe-trace.jsonl");
        let file = OpenOptions::new().append(true).create(true).open(&path)?;
        Ok(Self { file, path })
    }

    /// Append one event as a single JSON line. Errors are surfaced as
    /// String so the calling materializer can fold them into its
    /// `MaterializeError` type without an extra error conversion.
    pub fn append(&mut self, event: TraceEvent) -> Result<(), String> {
        let line = serde_json::to_string(&event).map_err(|e| format!("trace serialize: {e}"))?;
        writeln!(self.file, "{line}")
            .map_err(|e| format!("trace write {}: {e}", self.path.display()))?;
        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn unix_secs(ts: SystemTime) -> u64 {
    ts.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn ledger_appends_one_line_per_event() {
        let tmp = tempfile::tempdir().unwrap();
        let mut ledger = TraceLedger::open(tmp.path()).unwrap();
        let key = "deadbeef".to_string();
        ledger
            .append(TraceEvent::LayerHit {
                index: 0,
                key: key.clone(),
                cached_path: PathBuf::from("/cache/a.tar"),
                unix_ts: 100,
            })
            .unwrap();
        ledger
            .append(TraceEvent::LayerMiss {
                index: 1,
                key,
                written_path: PathBuf::from("/cache/b.tar"),
                unix_ts: 200,
            })
            .unwrap();
        drop(ledger);
        let mut buf = String::new();
        File::open(tmp.path().join("recipe-trace.jsonl"))
            .unwrap()
            .read_to_string(&mut buf)
            .unwrap();
        let lines: Vec<&str> = buf.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("layer_hit"));
        assert!(lines[1].contains("layer_miss"));
    }

    #[test]
    fn ledger_round_trips_through_serde() {
        let original = TraceEvent::Gc {
            arch_dir: PathBuf::from("/cache/x86_64"),
            evicted: 3,
            unix_ts: 9999,
        };
        let s = serde_json::to_string(&original).unwrap();
        let parsed: TraceEvent = serde_json::from_str(&s).unwrap();
        match parsed {
            TraceEvent::Gc {
                arch_dir,
                evicted,
                unix_ts,
            } => {
                assert_eq!(arch_dir, PathBuf::from("/cache/x86_64"));
                assert_eq!(evicted, 3);
                assert_eq!(unix_ts, 9999);
            }
            other => panic!("unexpected variant: {other:?}"),
        }
    }
}
