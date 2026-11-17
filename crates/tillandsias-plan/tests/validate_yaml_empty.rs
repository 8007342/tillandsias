//! ORDER 1117-66qv — `validate-yaml` must not answer `ok:yaml-loads` for an
//! EMPTY file.
//!
//! serde_yaml loads the empty document as `Null`, so a zero-byte file (a
//! heredoc that failed to write) used to answer with the strongest verdict this
//! reader emits. The closure order flips status before committing evidence, so
//! that window is exactly when a failed write would be read as validated
//! evidence.
//!
//! Arms:
//!   1. zero-byte            -> blocked:yaml-empty, non-zero exit, never ok:
//!   2. whitespace-only      -> blocked:yaml-empty
//!   3. explicit empty doc   -> ok:yaml-loads (NEGATIVE CONTROL: we flag
//!      `---`                  EMPTINESS, not the Null a writer may mean)
//!   4. unparseable          -> blocked:yaml-load-failed (distinct verdict)
//!   5. ordinary document    -> ok:yaml-loads (the fix is not a blanket refusal)

use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch() -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "validate-yaml-empty-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|t| t.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(&d).expect("mkdir scratch");
    d
}

fn validate(d: &Path, name: &str, contents: &str) -> (i32, String) {
    let p = d.join(name);
    std::fs::write(&p, contents).expect("write fixture");
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .arg("validate-yaml")
        .arg(&p)
        .output()
        .expect("run tillandsias-plan");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
}

#[test]
fn zero_byte_file_is_refused_as_empty() {
    let d = scratch();
    let (rc, out) = validate(&d, "empty.yaml", "");
    assert_ne!(rc, 0, "an empty file must not exit 0: {out:?}");
    assert!(
        out.contains("blocked:yaml-empty:"),
        "expected blocked:yaml-empty, got {out:?}"
    );
    assert!(
        !out.contains("ok:yaml-loads"),
        "an empty file must never read as loaded: {out:?}"
    );
}

#[test]
fn whitespace_only_file_is_refused_as_empty() {
    let d = scratch();
    let (rc, out) = validate(&d, "spaces.yaml", "  \n\t\n");
    assert_ne!(rc, 0, "whitespace-only must not exit 0: {out:?}");
    assert!(
        out.contains("blocked:yaml-empty:"),
        "expected blocked:yaml-empty, got {out:?}"
    );
}

#[test]
fn explicit_empty_document_still_loads() {
    // Negative control: `---` is a written, intentional empty document. It must
    // stay `ok:yaml-loads`, proving the guard tests emptiness rather than Null.
    let d = scratch();
    let (rc, out) = validate(&d, "written-empty.yaml", "---\n");
    assert_eq!(rc, 0, "an explicit empty document is valid YAML: {out:?}");
    assert!(
        out.contains("ok:yaml-loads:"),
        "expected ok:yaml-loads, got {out:?}"
    );
}

#[test]
fn unparseable_file_keeps_its_own_verdict() {
    let d = scratch();
    let (rc, out) = validate(&d, "bad.yaml", "a: [unterminated\n");
    assert_ne!(rc, 0, "{out:?}");
    assert!(
        out.contains("blocked:yaml-load-failed:"),
        "expected blocked:yaml-load-failed, got {out:?}"
    );
    assert!(
        !out.contains("blocked:yaml-empty:"),
        "unparseable is not empty: {out:?}"
    );
}

#[test]
fn ordinary_document_still_loads() {
    let d = scratch();
    let (rc, out) = validate(&d, "good.yaml", "packets: []\n");
    assert_eq!(rc, 0, "{out:?}");
    assert!(
        out.contains("ok:yaml-loads:"),
        "expected ok:yaml-loads, got {out:?}"
    );
}
