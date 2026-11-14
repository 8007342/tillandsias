//! ORDER 1903-sj5t — an order token names one packet.
//!
//!   1  two fragments filing distinct packet_ids under the same order token:
//!      `check --strict-fragments` exits nonzero naming the order and both ids
//!      (lenovinha filed under 1874-4sqt, already a landed order, and check
//!      said "ids unique")
//!   2  next-order's suffix advisory carries no order-grammar token besides
//!      the one it minted (the misfiled id was copied from "(1874-4sqt)")

use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "order-token-uniqueness-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|t| t.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(d.join("index.d")).expect("mkdir index.d");
    std::fs::write(d.join("index.yaml"), "packets: []\n").expect("write index");
    d
}

fn packet(id: &str, order: &str) -> String {
    format!(
        "packets:\n  - packet_id: {id}\n    order: {order}\n    status: ready\n    \
         title: {id}\n    kind: bug\n"
    )
}

fn plan(d: &Path, args: &[&str]) -> (i32, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .arg("--index")
        .arg(d.join("index.yaml"))
        .args(args)
        .env("TILLANDSIAS_WORKSTATION", "fixture-host")
        .output()
        .expect("run tillandsias-plan");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// The order grammar: 3-4 digits, a hyphen, 4 lowercase alphanumerics.
fn order_tokens(s: &str) -> Vec<String> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_digit() && (i == 0 || !b[i - 1].is_ascii_alphanumeric()) {
            let mut j = i;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let digits = j - i;
            let suffix = |k: usize| {
                b.get(k)
                    .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            };
            if (3..=4).contains(&digits)
                && b.get(j) == Some(&b'-')
                && (j + 1..j + 5).all(suffix)
                && !b.get(j + 5).is_some_and(|c| c.is_ascii_alphanumeric())
            {
                out.push(s[i..j + 5].to_string());
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    out
}

#[test]
fn strict_check_refuses_one_order_on_two_packet_ids() {
    let d = scratch("dup");
    std::fs::write(
        d.join("index.d/20261027t000001z-a-fixture.yaml"),
        packet("first-packet-under-the-order", "1874-4sqt"),
    )
    .expect("write a");
    std::fs::write(
        d.join("index.d/20261027t000002z-b-fixture.yaml"),
        packet("second-packet-misfiled-under-the-same-order", "1874-4sqt"),
    )
    .expect("write b");
    let (rc, out, err) = plan(&d, &["check", "--strict-fragments"]);
    assert_ne!(
        rc, 0,
        "a duplicate order must be refused: stdout={out} stderr={err}"
    );
    assert!(err.contains("1874-4sqt"), "names the order: {err}");
    assert!(err.contains("first-packet-under-the-order"), "{err}");
    assert!(
        err.contains("second-packet-misfiled-under-the-same-order"),
        "{err}"
    );

    // Premise control: the same two packets under distinct orders pass, so the
    // refusal above is about the order and not about the scaffolding.
    std::fs::write(
        d.join("index.d/20261027t000002z-b-fixture.yaml"),
        packet("second-packet-misfiled-under-the-same-order", "1874-zzzz"),
    )
    .expect("rewrite b");
    let (rc, out, err) = plan(&d, &["check", "--strict-fragments"]);
    assert_eq!(rc, 0, "distinct orders pass: stdout={out} stderr={err}");
}

#[test]
fn next_order_advisory_names_no_order_but_the_minted_one() {
    let d = scratch("advisory");
    // An empty ledger mints `1-xxxx`, outside the grammar; seed a real order so
    // the minted token is one the grammar recognises.
    std::fs::write(d.join("index.yaml"), packet("seed-packet", "1900-seed")).expect("seed");
    let (rc, out, err) = plan(&d, &["next-order"]);
    assert_eq!(rc, 0, "{err}");
    let minted = out.lines().next().unwrap_or_default().trim().to_string();
    assert_eq!(
        order_tokens(&minted),
        vec![minted.clone()],
        "minted: {out:?}"
    );
    let advisory: Vec<&str> = err
        .lines()
        .filter(|l| l.starts_with("next-order: the suffix"))
        .collect();
    assert_eq!(advisory.len(), 1, "the suffix advisory is present: {err}");
    let foreign: Vec<String> = order_tokens(advisory[0])
        .into_iter()
        .filter(|t| *t != minted)
        .collect();
    assert!(
        foreign.is_empty(),
        "advisory cites {foreign:?}: {}",
        advisory[0]
    );
}
