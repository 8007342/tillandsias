//! ORDER 1874-4sqt — the plan CLI as an agent meets it in a forge.
//!
//!   1  `next-order --quiet` prints exactly one token on stdout and nothing on
//!      stderr, and without --quiet the token is still the first stdout line
//!   2  the advisory says differing suffixes across calls are expected
//!   3  the MCP tool names `plan_status` and `plan_next` run as their CLI verbs,
//!      and an unknown underscore name is still refused

use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch() -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "next-order-ergonomics-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|t| t.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(d.join("index.d")).expect("mkdir index.d");
    std::fs::write(
        d.join("index.yaml"),
        "packets:\n  - packet_id: live-packet\n    order: 900-live\n    status: ready\n    \
         title: a live packet\n    kind: bug\n",
    )
    .expect("write index");
    d
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

fn is_token(s: &str) -> bool {
    match s.split_once('-') {
        Some((n, x)) => {
            !n.is_empty()
                && n.bytes().all(|b| b.is_ascii_digit())
                && x.len() == 4
                && x.bytes().all(|b| b.is_ascii_alphanumeric())
        }
        None => false,
    }
}

#[test]
fn next_order_quiet_prints_only_the_token() {
    let d = scratch();
    let (rc, out, err) = plan(&d, &["next-order", "--quiet"]);
    assert_eq!(rc, 0, "stdout={out} stderr={err}");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 1, "exactly one stdout line: {out:?}");
    assert!(is_token(lines[0]), "not a token: {out:?}");
    assert!(
        err.trim().is_empty(),
        "--quiet must print nothing else: {err}"
    );

    let (rc, out, err) = plan(&d, &["next-order", "901", "--quiet"]);
    assert_eq!(rc, 0, "a prefix with --quiet: {err}");
    assert!(out.trim().starts_with("901-"), "{out}");
}

#[test]
fn next_order_explains_that_suffixes_differ() {
    let d = scratch();
    let (rc, out, err) = plan(&d, &["next-order"]);
    assert_eq!(rc, 0, "{err}");
    assert!(
        out.lines().next().is_some_and(is_token),
        "the token is the first line: {out:?}"
    );
    assert!(
        err.contains("different suffixes") && err.contains("expected"),
        "the advisory must say differing suffixes are expected: {err}"
    );
}

#[test]
fn mcp_tool_names_are_cli_aliases() {
    let d = scratch();
    for (alias, verb, rest) in [
        ("plan_status", "status", &["900-live"][..]),
        ("plan_next", "next", &[][..]),
    ] {
        let (rc_a, out_a, err_a) = plan(&d, &[&[alias][..], rest].concat());
        let (rc_v, out_v, _) = plan(&d, &[&[verb][..], rest].concat());
        assert_eq!(rc_a, 0, "{alias} must run, not print usage: {err_a}");
        assert_eq!(rc_a, rc_v, "{alias} exits as {verb}: {err_a}");
        assert_eq!(out_a, out_v, "{alias} answers as {verb}");
        assert!(
            alias == "plan_next" || out_a.contains("900-live"),
            "{out_a}"
        );
    }
    let (rc, _, _) = plan(&d, &["plan_no_such_tool"]);
    assert_ne!(rc, 0, "an unknown underscore name is still refused");
}
