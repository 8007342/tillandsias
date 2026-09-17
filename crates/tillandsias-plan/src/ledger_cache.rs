//! ORDER 964-tzmp — a DERIVED, DISPOSABLE redb cache of the folded ledger.
//!
//! WHAT THIS IS NOT: a second source of truth. `plan/index.yaml` plus its
//! fragments remain authoritative, in git, reviewable and mergeable. This file
//! is a cache in the strict sense — deletable at any moment with no loss, and
//! rebuilt from the YAML whenever its fingerprint does not match.
//!
//! WHY IT EXISTS. Every consumer today loads ALL state to answer a NARROW
//! question: `status <id>` parses 8.5 MB and folds 827 fragments to print one
//! line. Measured on yoga 2026-09-17 after the fold's own quadratics were
//! fixed, that load is still ~236 ms, and a warm `--check` makes ~90 of them.
//!
//! WHY A FINGERPRINT AND NOT A LOCK. The ledger is append-mostly and its fold
//! is CRDT-semantic: G-Set packets, G-Set events, LWW fields with a monotone
//! status lattice. A write that lands after this cache was built is therefore
//! not lost — it is simply not visible through the cache, and the NEXT
//! fingerprint mismatch folds it in. That is snapshot isolation, and it is why
//! a stale cache is safe here in a way it would not be over mutable rows.
//!
//! FAIL-SOFT IN ONE DIRECTION ONLY. Every error path returns `None` and the
//! caller falls back to the full YAML load. A cache that cannot be opened, read,
//! or trusted must never fail a caller and must never answer from stale bytes —
//! so the fingerprint is checked before any value is served, and a mismatch is
//! a miss rather than a refusal.

use crate::fragments;
use redb::{Database, ReadableDatabase, TableDefinition};
use serde_yaml::Value;
use std::path::{Path, PathBuf};

const PACKETS: TableDefinition<&str, &[u8]> = TableDefinition::new("packets");
const META: TableDefinition<&str, &str> = TableDefinition::new("meta");
const FINGERPRINT_KEY: &str = "fingerprint";

/// Cheap identity for "the inputs that produced this fold".
///
/// Deliberately (path, len, mtime) rather than a content hash: this runs before
/// every cache read, so it must not read the 8.5 MB it is deciding whether to
/// skip. A same-size same-mtime edit defeats it, which on this corpus means a
/// hand-edited ledger inside one filesystem timestamp tick — and the cost of
/// that miss is a stale READ, which the CRDT argument above already tolerates.
fn fingerprint(index: &Path) -> Option<String> {
    use std::fmt::Write as _;
    let mut parts: Vec<(String, u64, i128)> = Vec::new();
    let meta = std::fs::metadata(index).ok()?;
    parts.push((
        index.to_string_lossy().to_string(),
        meta.len(),
        mtime_nanos(&meta),
    ));
    for f in fragments::fragment_paths(index) {
        if let Ok(m) = std::fs::metadata(&f) {
            parts.push((f.to_string_lossy().to_string(), m.len(), mtime_nanos(&m)));
        }
    }
    parts.sort();
    let mut acc = String::new();
    for (p, len, ts) in parts {
        let _ = write!(acc, "{p}\u{1}{len}\u{1}{ts}\u{2}");
    }
    Some(format!("{:016x}", fnv1a(acc.as_bytes())))
}

fn mtime_nanos(m: &std::fs::Metadata) -> i128 {
    m.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i128)
        .unwrap_or(-1)
}

/// FNV-1a, not a cryptographic hash and not pretending to be.
///
/// The input is a list of paths and stat values this process just read; there
/// is no adversary and no signature to forge. `sha2` is a workspace dependency
/// and would also work — this avoids pulling a hasher into a path that runs
/// before every cache read.
fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    h
}

/// Where the cache for a given index lives.
///
/// Under `.cache/` (gitignored) and keyed by a hash of the index's ABSOLUTE
/// path, so a scratch `--index` corpus cannot collide with the real ledger's
/// cache — the 42 fixture invocations in the gate all pass `--index`.
fn cache_path(index: &Path) -> Option<PathBuf> {
    let abs = std::fs::canonicalize(index).ok()?;
    let root = abs.parent()?.parent()?;
    let key = format!("{:016x}", fnv1a(abs.to_string_lossy().as_bytes()));
    Some(root.join(".cache").join("plan").join(format!("{key}.redb")))
}

/// One folded packet by id, or `None` for any reason at all.
///
/// `None` means "ask the YAML" and is returned for a missing cache, a
/// fingerprint mismatch, a corrupt database, an absent packet — every one of
/// which the caller handles the same way, which is what keeps this from having
/// a failure mode of its own.
pub fn get_packet(index: &Path, packet_id: &str) -> Option<Value> {
    let path = cache_path(index)?;
    let want = fingerprint(index)?;
    let db = Database::open(&path).ok()?;
    let tx = db.begin_read().ok()?;
    {
        let meta = tx.open_table(META).ok()?;
        let got = meta.get(FINGERPRINT_KEY).ok()??;
        if got.value() != want {
            return None;
        }
    }
    let packets = tx.open_table(PACKETS).ok()?;
    let raw = packets.get(packet_id).ok()??;
    serde_json::from_slice(raw.value()).ok()
}

/// Replace the cache with the folded state, stamped with the current
/// fingerprint. Best-effort: a failure here costs a rebuild next time and
/// NEVER the caller's answer, so errors are swallowed deliberately.
pub fn rebuild(index: &Path, folded: &Value) {
    let Some(path) = cache_path(index) else {
        return;
    };
    let Some(fp) = fingerprint(index) else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // Write to a sibling and rename, so a reader never observes a half-written
    // database and a crashed writer leaves the previous cache intact.
    let tmp = path.with_extension(format!("redb.tmp{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let Ok(db) = Database::create(&tmp) else {
        return;
    };
    {
        let Ok(tx) = db.begin_write() else { return };
        {
            let Ok(mut packets) = tx.open_table(PACKETS) else {
                return;
            };
            let mut all = Vec::new();
            crate::collect_packets(folded, &mut all);
            for p in &all {
                let Some(id) = p.get("packet_id").and_then(Value::as_str) else {
                    continue;
                };
                let Ok(bytes) = serde_json::to_vec(p) else {
                    continue;
                };
                let _ = packets.insert(id, bytes.as_slice());
            }
        }
        {
            let Ok(mut meta) = tx.open_table(META) else {
                return;
            };
            let _ = meta.insert(FINGERPRINT_KEY, fp.as_str());
        }
        if tx.commit().is_err() {
            return;
        }
    }
    drop(db);
    let _ = std::fs::rename(&tmp, &path);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_ledger(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tilland-cache-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("plan/index.d")).expect("mk");
        std::fs::write(
            dir.join("plan/index.yaml"),
            "plan_index:\n  packets:\n    - packet_id: alpha\n      status: ready\n",
        )
        .expect("write base");
        dir.join("plan/index.yaml")
    }

    fn fold_of(index: &Path) -> Value {
        let raw = std::fs::read_to_string(index).expect("read");
        let base: Value = serde_yaml::from_str(&raw).expect("parse");
        crate::fragments::fold(&base, &crate::fragments::load_all(index))
    }

    /// A cache answers only for the corpus it was built from.
    #[test]
    fn a_changed_corpus_is_a_miss_not_a_stale_answer() {
        let index = tmp_ledger("stale");
        rebuild(&index, &fold_of(&index));
        assert!(
            get_packet(&index, "alpha").is_some(),
            "the packet it was built from must hit"
        );

        // A new fragment changes the corpus. The cached bytes are now a view of
        // a ledger that no longer exists, and must not be served.
        std::fs::write(
            index.parent().unwrap().join("index.d/zz.yaml"),
            "packets:\n  - packet_id: beta\n    status: ready\n",
        )
        .expect("write fragment");
        assert!(
            get_packet(&index, "alpha").is_none(),
            "a corpus change must invalidate every key, not just the new one"
        );

        // Rebuilt against the new corpus, both are visible.
        rebuild(&index, &fold_of(&index));
        assert!(get_packet(&index, "alpha").is_some());
        assert!(
            get_packet(&index, "beta").is_some(),
            "a fragment-only packet must be present after a rebuild"
        );
        let _ = std::fs::remove_dir_all(index.parent().unwrap().parent().unwrap());
    }

    /// NEGATIVE CONTROL: no cache at all is a miss, never an error and never an
    /// empty answer that a caller could mistake for "no such packet".
    #[test]
    fn an_absent_cache_is_a_miss_not_a_failure() {
        let index = tmp_ledger("absent");
        assert!(get_packet(&index, "alpha").is_none());
        assert!(
            get_packet(&index, "nonexistent-packet").is_none(),
            "an unknown id is the same miss as an absent cache — the caller falls back either way"
        );
        let _ = std::fs::remove_dir_all(index.parent().unwrap().parent().unwrap());
    }

    /// The cached packet is the FOLDED one, not the base one — otherwise the
    /// cache would quietly serve pre-fragment state.
    #[test]
    fn the_cache_serves_the_folded_value_not_the_base() {
        let index = tmp_ledger("folded");
        std::fs::write(
            index.parent().unwrap().join("index.d/aa.yaml"),
            // The channel name is `fields` (LWW_CHANNELS), not `updates` — the
            // first draft of this test guessed and the test caught it.
            "fields:\n  - packet_id: alpha\n    field: status\n    value: completed\n    ts: \"2026-09-17T00:00:00Z\"\n    host: test\n",
        )
        .expect("write update");
        rebuild(&index, &fold_of(&index));
        let got = get_packet(&index, "alpha").expect("hit");
        assert_eq!(
            got.get("status").and_then(Value::as_str),
            Some("completed"),
            "the LWW update from the fragment must be present in the cached value"
        );
        let _ = std::fs::remove_dir_all(index.parent().unwrap().parent().unwrap());
    }
}
