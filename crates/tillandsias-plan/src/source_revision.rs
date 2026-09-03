// @trace order:984-i4k2, spec:meta-orchestration
//
// ONE hash implementation, compiled into TWO places: `build.rs` `include!`s
// this file to bake the revision of the sources it is compiling, and the crate
// uses it at runtime to compute the revision of a checkout. If these were two
// implementations they could drift, and a drifted comparison reports skew
// forever or never — the failure this order exists to end, arriving through
// the fix for it.
//
// FNV-1a over the crate's own sources, matching
// crates/tillandsias-headless/build.rs's probe revision so the fleet has one
// idea of what "which code is this" means.

/// Hash the bytes of every `.rs` file under `dir`, plus `capabilities.txt`,
/// in a STABLE ORDER.
///
/// Sorted by path because `read_dir` order is filesystem-dependent: two hosts
/// hashing identical sources must agree, or every cross-host comparison
/// reports skew that is really just directory ordering.
pub fn source_revision(dir: &std::path::Path) -> String {
    let mut files: Vec<std::path::PathBuf> = Vec::new();
    collect_sources(dir, &mut files);
    files.sort();

    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for f in &files {
        // The PATH is hashed as well as the content, so moving a file to a new
        // name changes the revision. A rename can change behaviour (a module
        // that stops being compiled) while leaving every byte of content
        // present somewhere.
        if let Some(rel) = f.strip_prefix(dir).ok().and_then(|p| p.to_str()) {
            for b in rel.as_bytes() {
                h ^= *b as u64;
                h = h.wrapping_mul(0x0000_0100_0000_01b3);
            }
        }
        if let Ok(bytes) = std::fs::read(f) {
            for b in &bytes {
                h ^= *b as u64;
                h = h.wrapping_mul(0x0000_0100_0000_01b3);
            }
        }
    }
    format!("{h:016x}")
}

fn collect_sources(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect_sources(&p, out);
            continue;
        }
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.ends_with(".rs") || name == "capabilities.txt" {
            out.push(p);
        }
    }
}
