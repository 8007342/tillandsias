//! ORDER 1431-k6s7 — `set-field` refuses a write to an ARCHIVED order.
//!
//! `Ledger::resolve` consults plan/archive/ last, so an order that exists only
//! there used to resolve, print ok:, and file a fragment the live fold drops.
//! These arms drive the real binary against a scratch ledger that has an
//! `archive/` beside its index, exactly the layout `collect_archive` reads.
//!
//!   1  an archived-only order is REFUSED naming it archived; no fragment written
//!   2  a live order still writes (control: the refusal is not blanket)
//!   3  an unknown order is still refused as before, and writes nothing

use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch() -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "set-field-archive-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|t| t.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(d.join("index.d")).expect("mkdir index.d");
    std::fs::create_dir_all(d.join("archive")).expect("mkdir archive");
    std::fs::write(
        d.join("index.yaml"),
        "packets:\n  - packet_id: live-packet\n    order: 900-live\n    status: ready\n    \
         title: a live packet\n    kind: bug\n",
    )
    .expect("write index");
    std::fs::write(
        d.join("archive").join("packets-2026-08.yaml"),
        "packets:\n  - packet_id: archived-packet\n    order: 606-um5s\n    status: completed\n    \
         title: an archived packet\n    kind: bug\n",
    )
    .expect("write archive");
    d
}

fn fragments(d: &Path) -> usize {
    std::fs::read_dir(d.join("index.d"))
        .map(|r| r.filter_map(Result::ok).count())
        .unwrap_or(0)
}

fn set_field(d: &Path, order: &str) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .arg("--index")
        .arg(d.join("index.yaml"))
        .args([
            "set-field",
            order,
            "next_action",
            "fixture note",
            "--host",
            "fixture-host",
        ])
        .env(
            "TILLANDSIAS_AGENT_ID",
            "linux-fixture-set-field-archive-20260101t000000z",
        )
        .output()
        .expect("run tillandsias-plan");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    (out.status.code().unwrap_or(-1), text)
}

#[test]
fn set_field_refuses_an_archived_order() {
    let d = scratch();

    // ARM 1 — archived-only: refused, named archived, nothing written.
    let (rc, text) = set_field(&d, "606-um5s");
    assert_ne!(rc, 0, "an archived order must be refused; got rc=0: {text}");
    assert!(
        text.contains("ARCHIVED") && text.contains("archived-packet"),
        "the refusal must name the target as archived: {text}"
    );
    assert!(!text.contains("ok:"), "a refusal must not print ok: {text}");
    assert_eq!(
        fragments(&d),
        0,
        "no fragment may be written for an archived order"
    );

    // ARM 2 — live control: still writes exactly one fragment.
    let (rc, text) = set_field(&d, "900-live");
    assert_eq!(rc, 0, "a live order must still write: {text}");
    assert_eq!(
        fragments(&d),
        1,
        "the live write must produce one fragment: {text}"
    );

    // ARM 3 — unknown: still refused as before, writes nothing more.
    let (rc, text) = set_field(&d, "999-none");
    assert_ne!(rc, 0, "an unknown order must still be refused: {text}");
    assert!(
        !text.contains("ARCHIVED"),
        "an unknown order must not be reported as archived: {text}"
    );
    assert_eq!(fragments(&d), 1, "an unknown order must write nothing");

    let _ = std::fs::remove_dir_all(&d);
}
