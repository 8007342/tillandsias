// @trace order:2049-w2q6, order:2049-r4fx
//! `script run --helper`: a sourced-function helper, not a decider. Its
//! stdout is the script's alone, `verdict.*` is refused, a Lua error exits 1,
//! and its children get the base environment only.
use std::process::{Command, Output};

fn run(src: &str, extra: &[&str], env: &[(&str, &str)]) -> Output {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("helper.lua");
    std::fs::write(&f, src).unwrap();
    let mut c = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"));
    c.args(["script", "run", "--helper"]);
    c.args(extra);
    c.arg(&f).args(["--", "A1"]);
    for (k, v) in env {
        c.env(k, v);
    }
    c.output().unwrap()
}

fn s(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn a_clean_helper_exits_zero_with_only_its_own_stdout() {
    let o = run("print('one')\nprint(arg[1])\n", &[], &[]);
    assert_eq!(o.status.code(), Some(0), "{}", s(&o.stderr));
    assert_eq!(s(&o.stdout), "one\nA1\n");
}

#[test]
fn a_helper_that_calls_verdict_is_refused_off_stdout() {
    let o = run(
        "print('before')\nverdict.ok('x')\nprint('after')\n",
        &[],
        &[],
    );
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(
        s(&o.stdout),
        "before\n",
        "no verdict line and nothing after it"
    );
    assert!(
        s(&o.stderr).contains("refused:helper-called-verdict:helper"),
        "{}",
        s(&o.stderr)
    );
}

#[test]
fn a_lua_error_is_exit_one_with_a_stderr_diagnostic() {
    let o = run("error('boom')\n", &[], &[]);
    assert_eq!(o.status.code(), Some(1));
    assert!(o.stdout.is_empty());
    let e = s(&o.stderr);
    assert!(
        e.contains("refused:script-error:helper") && e.contains("boom"),
        "{e}"
    );
}

#[test]
fn timeout_still_applies_and_stays_off_stdout() {
    let o = run("while true do end\n", &["--timeout", "300ms"], &[]);
    assert_eq!(o.status.code(), Some(124));
    assert!(o.stdout.is_empty(), "{}", s(&o.stdout));
    assert!(s(&o.stderr).contains("refused:timed-out:helper"));
}

#[test]
fn without_helper_the_same_script_is_still_a_verdictless_decider() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("helper.lua");
    std::fs::write(&f, "print('x')\n").unwrap();
    let o = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .args(["script", "run"])
        .arg(&f)
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert!(s(&o.stdout).contains("refused:no-verdict:helper"));
}

/// 2049-r4fx (2029-39bt, 1551-nyzb): a helper's child does not inherit the
/// caller's proxy or a secret-named variable.
#[cfg(unix)]
#[test]
fn a_helper_child_gets_the_base_environment_only() {
    let o = run(
        "local r = proc.run{ argv = { 'env' } }\nio.write(r.stdout)\n",
        &[],
        &[
            ("HTTPS_PROXY", "http://leak.example:3128"),
            ("TILLANDSIAS_COORD_CLIENT_SECRET", "s3cr3t-control"),
            ("TILLANDSIAS_X_VISIBLE", "passes"),
        ],
    );
    assert_eq!(o.status.code(), Some(0), "{}", s(&o.stderr));
    let out = s(&o.stdout);
    assert!(!out.contains("leak.example"), "proxy leaked: {out}");
    assert!(!out.contains("s3cr3t-control"), "secret leaked");
    assert!(
        out.contains("TILLANDSIAS_X_VISIBLE=passes"),
        "control: TILLANDSIAS_* passes: {out}"
    );
}
