//! ORDER 920-pxg6 — the published spec-index entry as PUBLIC infrastructure.
//!
//! @trace spec:expert-serve-grounded-pipeline
//!
//! Hoisted from groundtruth.rs, where the 879-gidx resolution ladder and the
//! 394d loader (with its vectors/chunks arity refusal) lived as private
//! helpers only the grader could reach. The grounded pipeline and the
//! `expert-serve` front-end must read the SAME entry the grader grades
//! against — a second resolver would re-create exactly the producer/reader
//! split that kept the embedding step invisibly absent for weeks (801-a2by).
//! groundtruth.rs delegates here, so grade behavior is unchanged.

use crate::answer::Freshness;
use crate::gitref;
use crate::spec::Chunk;
use std::path::{Path, PathBuf};

/// A rung is taken only if its `vectors.jsonl` exists — what lets a stale
/// override HEAL instead of poison (879-gidx; see [`resolve_from`]).
pub fn rung_usable(dir: &str) -> bool {
    !dir.trim().is_empty() && Path::new(dir).join("vectors.jsonl").is_file()
}

/// Pure core: the ladder over already-fetched candidate values, so tests need
/// no env mutation. `roots` are entry-POINTER roots (root/current names the
/// entry); `dirs` are exact serving directories.
pub fn resolve_from(
    dirs: &[(&str, Option<String>)],
    roots: &[(&str, Option<String>)],
) -> Option<String> {
    for (name, val) in dirs {
        if let Some(d) = val {
            if rung_usable(d) {
                return Some(d.clone());
            }
            eprintln!(
                "note: {name}={d} names no usable index (no vectors.jsonl) — stale override skipped, trying the durable tier (879-gidx)"
            );
        }
    }
    for (_name, val) in roots {
        if let Some(root) = val {
            let fp = std::fs::read_to_string(Path::new(root).join("current"))
                .unwrap_or_default()
                .trim()
                .to_string();
            if !fp.is_empty() {
                let entry = format!("{root}/{fp}");
                if rung_usable(&entry) {
                    return Some(entry);
                }
            }
        }
    }
    None
}

/// ORDER 879-gidx. Resolve the spec index the way the canonical shell ladder
/// does (801-a2by: explicit dir, forge dir, forge root, podman volume, XDG),
/// VALIDATING every rung. `None` means no rung names a usable index — the
/// caller owns the typed refusal for that (groundtruth marks it
/// ENGINE_UNAVAILABLE; the pipeline refuses `unsupported:`).
pub fn resolve_dir() -> Option<String> {
    let dirs = [
        (
            "TILLANDSIAS_SPEC_INDEX_DIR",
            std::env::var("TILLANDSIAS_SPEC_INDEX_DIR").ok(),
        ),
        (
            "FORGE_SPEC_INDEX_DIR",
            std::env::var("FORGE_SPEC_INDEX_DIR").ok(),
        ),
    ];
    let xdg_root = std::env::var("XDG_CACHE_HOME")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| std::env::var("HOME").ok().map(|h| format!("{h}/.cache")))
        .map(|c| format!("{c}/tillandsias/spec-index"));
    // Rung 3 of the shell ladder: the shared podman named volume. Bounded and
    // fail-soft — a hiccup degrades to XDG, never to an error (801-a2by).
    let podman_root = if std::env::var("TILLANDSIAS_SPEC_INDEX_NO_PODMAN")
        .ok()
        .as_deref()
        == Some("1")
    {
        None
    } else {
        tillandsias_podman::podman_cmd_sync()
            .args([
                "volume",
                "inspect",
                "-f",
                "{{.Mountpoint}}",
                "tillandsias-spec-index-tillandsias",
            ])
            .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty())
    };
    let roots = [
        (
            "FORGE_SPEC_INDEX_ROOT",
            std::env::var("FORGE_SPEC_INDEX_ROOT").ok(),
        ),
        ("podman-volume", podman_root),
        ("xdg-cache", xdg_root),
    ];
    resolve_from(&dirs, &roots)
}

/// One published, content-addressed index entry, loaded whole.
///
/// The markers are the producer's (scripts/spec-index-ensure.sh): `.commit`
/// is the frame the corpus was read at (801-g9nn), `.model` the embedder that
/// wrote `vectors.jsonl`, `.prefix` the document prefix that embedding
/// applied (864-p2rk) — a non-empty prefix means queries against this entry
/// must carry the matching `search_query: ` prefix. Every marker is additive:
/// entries published before a marker existed load with the field `None`.
#[derive(Debug)]
pub struct SpecIndexEntry {
    pub dir: PathBuf,
    pub chunks: Vec<Chunk>,
    pub vectors: Vec<Vec<f32>>,
    /// Hex-validated (gitref::looks_like_sha); a malformed marker is dropped
    /// rather than stored, so the field can never carry a ref name or a
    /// truncated garbage value into a citation frame.
    pub commit: Option<String>,
    pub model: Option<String>,
    pub prefix: Option<String>,
}

fn read_marker(dir: &Path, name: &str) -> Option<String> {
    std::fs::read_to_string(dir.join(name))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

impl SpecIndexEntry {
    /// Resolve through the 879-gidx ladder, then load. `Err` carries a
    /// human-actionable message; distinguishing "no index on this host" from
    /// "the index is wrong" stays the CALLER's job (groundtruth prefixes the
    /// former with its ENGINE_UNAVAILABLE sentinel).
    pub fn load() -> Result<Self, String> {
        let dir = resolve_dir().ok_or_else(|| {
            "no rung of the resolution ladder (TILLANDSIAS_SPEC_INDEX_DIR, FORGE_SPEC_INDEX_DIR, FORGE_SPEC_INDEX_ROOT, the podman volume, XDG cache) names a directory containing vectors.jsonl — scripts/spec-index-ensure.sh builds and publishes one (801-a2by)".to_string()
        })?;
        Self::load_dir(Path::new(&dir))
    }

    /// Load one exact entry directory. The arity refusal is 394d's: a vector
    /// count that disagrees with the chunk count means a shifted pairing that
    /// answers plausibly and wrongly — refused, never served.
    pub fn load_dir(dir: &Path) -> Result<Self, String> {
        let vpath = dir.join("vectors.jsonl");
        let vtext = std::fs::read_to_string(&vpath)
            .map_err(|e| format!("read {}: {e}", vpath.display()))?;
        let mut vectors: Vec<Vec<f32>> = Vec::new();
        for (n, line) in vtext.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            vectors.push(
                serde_json::from_str::<Vec<f32>>(line)
                    .map_err(|e| format!("{}:{}: not a float vector: {e}", vpath.display(), n + 1))?,
            );
        }

        let cpath = dir.join("chunks.jsonl");
        let ctext = std::fs::read_to_string(&cpath)
            .map_err(|e| format!("read {}: {e}", cpath.display()))?;
        let mut chunks: Vec<Chunk> = Vec::new();
        for (n, line) in ctext.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            chunks.push(
                serde_json::from_str(line)
                    .map_err(|e| format!("{}:{}: not a chunk record: {e}", cpath.display(), n + 1))?,
            );
        }

        if vectors.len() != chunks.len() {
            return Err(format!(
                "index is stale: {} vectors for {} chunks. The vectors must be                  index-aligned with chunk_corpus(root); rebuild with                  scripts/spec-index-ensure.sh",
                vectors.len(),
                chunks.len()
            ));
        }

        let commit = read_marker(dir, ".commit").filter(|c| gitref::looks_like_sha(c));
        let model = read_marker(dir, ".model");
        let prefix = read_marker(dir, ".prefix");

        Ok(Self {
            dir: dir.to_path_buf(),
            chunks,
            vectors,
            commit,
            model,
            prefix,
        })
    }

    /// The FRAME this entry serves answers from (D2 / 801-g9nn): its own
    /// `.commit` (the literal `unknown` for a frameless entry — never a
    /// fabricated sha, never this process's HEAD) and its `chunks.jsonl`
    /// mtime. Deliberately NOT `Freshness::for_corpus(repo)`, which stamps
    /// the checkout this process stands in onto spans it never read there.
    pub fn freshness(&self) -> Freshness {
        let indexed_at = std::fs::metadata(self.dir.join("chunks.jsonl"))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| crate::answer::epoch_to_iso8601(d.as_secs() as i64))
            .unwrap_or_else(|| "unknown".to_string());
        Freshness::new(
            self.commit.clone().unwrap_or_else(|| "unknown".to_string()),
            indexed_at,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_entry(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tilland-sie-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("fixture dir");
        dir
    }

    fn write_chunk_line(id: usize, key: &str, kind: &str) -> String {
        serde_json::json!({
            "id": id, "path": "README.md", "line_start": 1, "line_end": 2,
            "kind": kind, "key": key, "content_hash": "0", "text": format!("{key} body"),
        })
        .to_string()
    }

    #[test]
    fn entry_loads_markers_and_validates_the_commit() {
        let dir = fixture_entry("markers");
        std::fs::write(
            dir.join("chunks.jsonl"),
            format!("{}\n", write_chunk_line(0, "k", "spec")),
        )
        .unwrap();
        std::fs::write(dir.join("vectors.jsonl"), "[0.1,0.2]\n").unwrap();
        std::fs::write(dir.join(".commit"), "abcdef1234567890abcdef1234567890abcdef12\n").unwrap();
        std::fs::write(dir.join(".model"), "nomic-embed-text\n").unwrap();
        std::fs::write(dir.join(".prefix"), "search_document: \n").unwrap();
        let entry = SpecIndexEntry::load_dir(&dir).expect("loads");
        assert_eq!(entry.chunks.len(), 1);
        assert_eq!(entry.vectors.len(), 1);
        assert_eq!(
            entry.commit.as_deref(),
            Some("abcdef1234567890abcdef1234567890abcdef12")
        );
        assert_eq!(entry.model.as_deref(), Some("nomic-embed-text"));
        assert_eq!(entry.prefix.as_deref(), Some("search_document:"));
        assert_eq!(
            entry.freshness().source_commit(),
            "abcdef1234567890abcdef1234567890abcdef12"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_malformed_commit_marker_is_dropped_not_served() {
        let dir = fixture_entry("badcommit");
        std::fs::write(
            dir.join("chunks.jsonl"),
            format!("{}\n", write_chunk_line(0, "k", "spec")),
        )
        .unwrap();
        std::fs::write(dir.join("vectors.jsonl"), "[0.1]\n").unwrap();
        std::fs::write(dir.join(".commit"), "not-a-sha\n").unwrap();
        let entry = SpecIndexEntry::load_dir(&dir).expect("loads");
        assert_eq!(entry.commit, None);
        // Frameless entries report the honest hole, never a fabricated frame.
        assert_eq!(entry.freshness().source_commit(), "unknown");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_arity_refusal_still_fires() {
        let dir = fixture_entry("arity");
        std::fs::write(
            dir.join("chunks.jsonl"),
            format!(
                "{}\n{}\n",
                write_chunk_line(0, "a", "spec"),
                write_chunk_line(1, "b", "spec")
            ),
        )
        .unwrap();
        std::fs::write(dir.join("vectors.jsonl"), "[0.1]\n").unwrap();
        let err = SpecIndexEntry::load_dir(&dir).expect_err("must refuse");
        assert!(err.contains("index is stale"), "got: {err}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
