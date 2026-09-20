// @trace order:1287-h6qn, spec:spec-traceability
//
// ONE hash implementation, compiled into TWO places, the same shape
// src/source_revision.rs uses for 984-i4k2: `build.rs` `include!`s this file to
// EMBED the hash of the surface it is compiling, and the crate uses it at
// runtime to hash the surface a checkout currently holds. Two implementations
// could drift, and a drifted comparison reports skew forever or never.
//
// WHY A CONTENT HASH AND NOT AN mtime. The plan-only lane used to ask "was this
// binary rebuilt after these files were touched". The question it needs answered
// is "was this binary built FROM THESE BYTES". `git rebase` rewrites every file
// it touches with a fresh mtime and identical content, so the two questions
// disagree for free, and a byte-for-byte correct binary is condemned with no
// instrument on the push path able to say otherwise (measured on pirria
// 2026-09-20: rebuild, remove the stamp, `touch` a source without changing it,
// and scripts/check-plan-binary-current.sh declines to stamp). 1172-dyvd already
// ruled this for the fleet: currency is a content probe, never an mtime, because
// a same-second fake proves any mtime rule blind — and a rebase is that fake
// produced by git itself.
//
// FNV-1a, matching source_revision.rs, so the crate has one idea of "hash".

/// Parse the surface manifest into (repo-relative files, Cargo.lock dep names).
///
/// The manifest is the SINGLE definition of the surface. Returning the inputs
/// rather than only the hash is what lets `build.rs` emit a
/// `cargo:rerun-if-changed` for each one: a build after a real edit must
/// re-embed, or the embedded hash is itself stale and the instrument lies in
/// the direction that looks healthy.
pub fn validator_surface_inputs(root: &std::path::Path) -> (Vec<String>, Vec<String>) {
    let manifest = root.join("crates/tillandsias-plan/validator-surface.manifest");
    let mut files = Vec::new();
    let mut deps = Vec::new();
    let Ok(text) = std::fs::read_to_string(&manifest) else {
        return (files, deps);
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("file ") {
            files.push(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("lock-dep ") {
            deps.push(rest.trim().to_string());
        }
    }
    files.sort();
    files.dedup();
    (files, deps)
}

/// Hash the surface as `root` currently holds it.
///
/// Returns None when the manifest is missing or names no files — "cannot ask"
/// is not "fresh", and every caller must treat it as unknown rather than pass.
pub fn validator_surface_hash(root: &std::path::Path) -> Option<String> {
    let (files, deps) = validator_surface_inputs(root);
    if files.is_empty() {
        return None;
    }

    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for b in bytes {
            h ^= *b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };

    for rel in &files {
        // The PATH is hashed with the content, as source_revision does: moving a
        // surface file to a new name changes behaviour while leaving every byte
        // present somewhere.
        eat(rel.as_bytes());
        match std::fs::read(root.join(rel)) {
            Ok(bytes) => eat(&bytes),
            // A manifest naming a file that is gone is a REAL difference, not a
            // reason to skip: hash the absence distinctly so it cannot collide
            // with an empty file.
            Err(_) => eat(b"\x00<absent>"),
        }
    }

    // A dependency bump changes what validate-yaml accepts without changing one
    // line of our own source, which is why the lock stanzas were in the shell
    // surface and stay in this one.
    if let Ok(lock) = std::fs::read_to_string(root.join("Cargo.lock")) {
        for dep in &deps {
            eat(dep.as_bytes());
            match lock_stanza(&lock, dep) {
                Some(stanza) => eat(stanza.as_bytes()),
                None => eat(b"\x00<absent>"),
            }
        }
    }

    Some(format!("{h:016x}"))
}

/// The `[[package]]` stanza for `want`, or None.
fn lock_stanza(lock: &str, want: &str) -> Option<String> {
    let needle = format!("name = \"{want}\"");
    let mut current = String::new();
    let mut keep = false;
    for line in lock.lines() {
        if line.starts_with("[[package]]") {
            if keep {
                return Some(current);
            }
            current.clear();
            current.push_str(line);
            current.push('\n');
            keep = false;
            continue;
        }
        current.push_str(line);
        current.push('\n');
        if line.trim() == needle {
            keep = true;
        }
    }
    if keep { Some(current) } else { None }
}
