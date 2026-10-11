// @trace order:1584-ik5v
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
