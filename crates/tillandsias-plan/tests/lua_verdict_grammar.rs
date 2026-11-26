// @trace order:1584-ik5v, order:2169-tdop, order:2193-vtbl
//! verdict.emit's legacy grammar: degraded: and down: (check-local-expert-health's
//! established lines) are emitted verbatim with their own exit codes, and a
//! prefix outside the grammar is still refused.
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn root() -> tempfile::TempDir {
    let d = tempfile::Builder::new()
        .prefix("lua-verdict-grammar-")
        .tempdir()
        .unwrap();
    fs::create_dir_all(d.path().join(".git")).unwrap();
    d
}

fn run(root: &Path, code: &str) -> Output {
    let script = root.join("s.lua");
    fs::write(&script, code).unwrap();
    Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .current_dir(root)
        .env("TILLANDSIAS_REPO_ROOT", root)
        .args(["script", "run"])
        .arg(&script)
        .output()
        .unwrap()
}

#[test]
fn degraded_is_emitted_verbatim_with_exit_zero() {
    let d = root();
    let o = run(
        d.path(),
        "verdict.emit('degraded:local-experts-model-missing:qwen2.5:0.5b', 0)\n",
    );
    assert_eq!(o.status.code(), Some(0), "{o:?}");
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "degraded:local-experts-model-missing:qwen2.5:0.5b\n"
    );
}

#[test]
fn down_is_emitted_verbatim_with_exit_one() {
    let d = root();
    let o = run(
        d.path(),
        "verdict.emit('down:local-experts-ollama-unreachable', 1)\n",
    );
    assert_eq!(o.status.code(), Some(1), "{o:?}");
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "down:local-experts-ollama-unreachable\n"
    );
}

/// Order 2169-tdop: the fleet's todo-shaped deciders (check-bare-metal-host-
/// initialized.sh prints `todo:initialize-bare-metal-host:<component>:<cmd>`
/// with rc 1, read by check-fleet-membership.lua) port with byte-identical
/// output: one line, verbatim, rc 1.
#[test]
fn todo_is_emitted_verbatim_with_exit_one() {
    let d = root();
    let o = run(
        d.path(),
        "verdict.emit('todo:initialize-bare-metal-host:vault:tillandsias --ensure-enclave', 1)\n",
    );
    assert_eq!(o.status.code(), Some(1), "{o:?}");
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "todo:initialize-bare-metal-host:vault:tillandsias --ensure-enclave\n"
    );
}

#[test]
fn a_prefix_outside_the_grammar_is_still_refused() {
    let d = root();
    let o = run(d.path(), "verdict.emit('weird:x', 0)\n");
    assert_ne!(o.status.code(), Some(0), "{o:?}");
    let all = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(all.contains("the line must start with"), "{all}");
}

/// Order 2193-vtbl: every word in the reviewed LEGACY_VERDICT_WORDS table is
/// emitted verbatim with each exit code its .sh callers pair it with, and
/// REFUSED with a code outside that set. Mirrors the table in script_run.rs.
const LEGACY: &[(&str, &[i32])] = &[
    ("unavailable:", &[2]),
    ("stale:", &[0, 1, 2]),
    ("due:", &[1]),
    ("fail:", &[0, 1, 2]),
    ("red:", &[1]),
    ("skipped:", &[0]),
    ("advisory:", &[0]),
    ("unattributable:", &[2, 3]),
    ("non-opsx:", &[2, 3]),
    ("launch-dirt:", &[5]),
    ("never:", &[1]),
    ("drift:", &[1]),
    ("missing:", &[0, 1]),
    ("claimed-elsewhere:", &[1]),
    ("unknown-packet:", &[2]),
];

#[test]
fn each_legacy_word_is_emitted_verbatim_with_each_of_its_codes() {
    let d = root();
    for (w, codes) in LEGACY {
        for c in *codes {
            let line = format!("{w}probe-{c}");
            let o = run(d.path(), &format!("verdict.emit('{line}', {c})\n"));
            assert_eq!(o.status.code(), Some(*c), "{w} code {c}: {o:?}");
            assert_eq!(
                String::from_utf8_lossy(&o.stdout),
                format!("{line}\n"),
                "{w} code {c}"
            );
        }
    }
}

#[test]
fn a_legacy_word_with_a_code_its_callers_never_use_is_refused() {
    let d = root();
    for (w, codes) in LEGACY {
        let bad = (0..=5)
            .find(|c| !codes.contains(c))
            .expect("a code outside the set");
        let o = run(d.path(), &format!("verdict.emit('{w}x', {bad})\n"));
        let all = format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        assert!(
            all.contains("legacy word whose callers pair it only with exit"),
            "{w} code {bad}: {all}"
        );
    }
}

/// The table above must stay the source's table: a word added to
/// LEGACY_VERDICT_WORDS without a test arm here (or the reverse) is refused.
#[test]
fn the_tested_table_is_the_source_table() {
    let src = include_str!("../src/script_run.rs");
    let start = src
        .find("pub(crate) const LEGACY_VERDICT_WORDS")
        .expect("table in script_run.rs");
    let body = &src[start..start + src[start..].find("];").expect("table end")];
    let in_src: Vec<&str> = body
        .lines()
        .filter_map(|l| l.trim().strip_prefix("(\"")?.split('"').next())
        .collect();
    let in_test: Vec<&str> = LEGACY.iter().map(|(w, _)| *w).collect();
    assert_eq!(
        in_src, in_test,
        "LEGACY_VERDICT_WORDS and this test's LEGACY differ"
    );
}
