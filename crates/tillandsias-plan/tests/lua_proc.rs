// @trace order:1384-aixy, spec:ci-release
//
// proc.run{argv=...} — the synchronous first slice of 1384-aixy (design
// plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md section 4.1).
// One test per arm of the row's verifiable_closure that this slice covers:
// arms 1, 2, 3, 5, 6 and 7. Arm 4 (proc.spawn with line callbacks) belongs to
// the next slice. Each arm names what it FAILED on before this slice: there
// was no `proc` global at all, only the synchronous `sh.run`, whose deadline
// killed the child alone.
//
// These tests run real processes. They need bash (Linux, macOS, and Git for
// Windows all ship it) and SKIP BY NAME where it is absent.

use std::path::PathBuf;
use std::time::{Duration, Instant};
use tillandsias_plan::lua_predicate::{PredicateClass, build_environment};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

fn bash_available() -> bool {
    std::process::Command::new("bash")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Evaluate `chunk` in the OBSERVING class and return what it returns.
fn observing<T: mlua::FromLuaMulti>(chunk: &str) -> mlua::Result<T> {
    let lua = build_environment(PredicateClass::Observing).expect("observing environment");
    lua.load(chunk).eval::<T>()
}

fn lua_path(p: &std::path::Path) -> String {
    p.display().to_string().replace('\\', "/")
}

/// ARM 1: a non-zero exit is DATA, not a Lua error; and argv is argv.
#[test]
fn arm1_a_failing_program_is_a_value_and_argv_is_not_reparsed() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm1:no-bash");
        return;
    }
    let (status, code, ok): (String, i64, bool) = observing(
        r#"local f = proc.run{argv = {"false"}}
           return f.status, f.code, f.ok"#,
    )
    .expect("a non-zero exit must not raise");
    assert_eq!((status.as_str(), code, ok), ("exited", 1, false));

    let out: String =
        observing(r#"return proc.run{argv = {"printf", "%s", "a b*c"}}.stdout"#).unwrap();
    assert_eq!(
        out, "a b*c",
        "one argv element stays one token, `*` unexpanded"
    );
}

/// ARM 2: 1 MiB on stdout AND 1 MiB on stderr both come back in full.
#[test]
fn arm2_both_fds_drain_concurrently_in_full() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm2:no-bash");
        return;
    }
    let (o, e, ok): (i64, i64, bool) = observing(
        r#"local r = proc.run{argv = {"bash", "scripts/fixtures/write-both-fds.sh"}, timeout_ms = 60000}
           return #r.stdout, #r.stderr, r.ok"#,
    )
    .unwrap();
    assert_eq!((o, e, ok), (1_048_576, 1_048_576, true));
}

/// ARM 3: a deadline kills the GROUP: timed_out, no code, under 2 s, and the
/// grandchild never writes its marker. The control runs the same fixture with
/// group = false, and the grandchild survives, which proves the grouped arm
/// is not passing because the grandchild never started.
#[test]
fn arm3_a_deadline_kills_the_whole_group() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm3:no-bash");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    for (group, expect_marker) in [(true, false), (false, true)] {
        let marker = dir.path().join(format!("survived-{group}"));
        let t0 = Instant::now();
        let (status, has_code): (String, bool) = observing(&format!(
            r#"local r = proc.run{{argv = {{"bash", "scripts/fixtures/spawn-grandchild.sh", "{m}"}},
                                   timeout_ms = 500, group = {group}}}
               return r.status, r.code ~= nil"#,
            m = lua_path(&marker)
        ))
        .unwrap();
        let elapsed = t0.elapsed();
        assert_eq!(status, "timed_out", "group={group}");
        assert!(
            !has_code,
            "a timed-out child produced no exit code (group={group})"
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "deadline took {elapsed:?}"
        );
        std::thread::sleep(Duration::from_secs(6));
        assert_eq!(
            marker.exists(),
            expect_marker,
            "group={group}: grandchild {} its marker",
            if marker.exists() {
                "wrote"
            } else {
                "did not write"
            }
        );
    }
}

/// ARM 5: a shell handed a command STRING is refused, naming the declaration.
#[test]
fn arm5_a_shell_string_is_refused() {
    let err = observing::<mlua::Value>(r#"return proc.run{argv = {"bash", "-c", "true | false"}}"#)
        .unwrap_err()
        .to_string();
    assert!(err.contains("allow_shell_strings"), "{err}");
    // A script FILE given to bash is argv, not a string, and is allowed.
    if bash_available() {
        let ok: bool = observing(
            r#"return proc.run{argv = {"bash", "scripts/fixtures/write-both-fds.sh"}}.ok"#,
        )
        .unwrap();
        assert!(ok);
    }
}

/// ARM 6: bytes flow through a variable. A consumer that exits after one line
/// cannot SIGPIPE the producer, because the producer already finished.
#[test]
fn arm6_stdin_from_a_variable_has_no_pipe_to_invert() {
    if !bash_available() {
        eprintln!("skip:lua_proc:arm6:no-bash");
        return;
    }
    let (a_status, a_code, b_out): (String, i64, String) = observing(
        // The newlines come from printf's FORMAT (`%s\n`, a backslash and an
        // n), not from an argv element: a native Windows caller's embedded
        // newline is truncated by the MSYS runtime (measured: "one").
        r#"local a = proc.run{argv = {"printf", "%s\\n", "one", "two", "three"}}
           local b = proc.run{argv = {"head", "-n", "1"}, stdin = a.stdout}
           return a.status, a.code, b.stdout"#,
    )
    .unwrap();
    assert_eq!(
        (a_status.as_str(), a_code, b_out.as_str()),
        ("exited", 0, "one\n")
    );
}

/// ARM 7: the Cacheable class never gains a process.
#[test]
fn arm7_cacheable_has_no_proc() {
    let lua = build_environment(PredicateClass::Cacheable).unwrap();
    let t: String = lua.load("return type(proc)").eval().unwrap();
    assert_eq!(t, "nil");
    let t: String = observing("return type(proc) .. ':' .. type(proc.run)").unwrap();
    assert_eq!(t, "table:function");
}

/// Programmer errors RAISE: an unknown field (a misspelt `timeout` must not
/// mean "no deadline"), a relative cwd, a string argv, an empty argv.
#[test]
fn programmer_errors_raise_and_operational_failures_do_not() {
    for (chunk, needle) in [
        (
            r#"proc.run{argv = {"true"}, timeout = 5}"#,
            "unknown field 'timeout'",
        ),
        (
            r#"proc.run{argv = {"true"}, cwd = "relative/dir"}"#,
            "relative",
        ),
        (r#"proc.run{argv = "git status"}"#, "argv must be a table"),
        (r#"proc.run{argv = {}}"#, "argv is empty"),
        (r#"proc.run{"git", "status"}"#, "positional"),
    ] {
        let err = observing::<mlua::Value>(chunk).unwrap_err().to_string();
        assert!(err.contains(needle), "{chunk} -> {err}");
    }
    // A program that does not exist is DATA.
    let (status, ok): (String, bool) = observing(
        r#"local r = proc.run{argv = {"tillandsias-no-such-program-1384"}}
           return r.status, r.ok"#,
    )
    .unwrap();
    assert_eq!((status.as_str(), ok), ("spawn_failed", false));
}

/// The environment is the fixed base set: the caller's locale does not leak.
#[test]
fn the_child_environment_is_the_base_set() {
    if !bash_available() {
        eprintln!("skip:lua_proc:env:no-bash");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("env.sh");
    std::fs::write(
        &script,
        "printf '%s|%s|%s' \"$LC_ALL\" \"$TZ\" \"${UNRELATED_1384:-unset}\"\n",
    )
    .unwrap();
    // SAFETY: this test owns this variable name; nothing else reads it.
    unsafe { std::env::set_var("UNRELATED_1384", "leaked") };
    let out: String = observing(&format!(
        r#"return proc.run{{argv = {{"bash", "{s}"}}, env = {{EXTRA = "x"}}}}.stdout"#,
        s = lua_path(&script)
    ))
    .unwrap();
    unsafe { std::env::remove_var("UNRELATED_1384") };
    assert_eq!(out, "C|UTC|unset");
    let _ = repo_root();
}

/// Order 1394-mdqj: a caller that PIPES the plan binary must not wait for a
/// grandchild the script's child leaked. The CLI runs with its stdout piped to
/// this test; its script runs an UNGROUPED child that leaves a background
/// grandchild, under a 500 ms deadline. Reading the CLI's stdout reaches EOF
/// promptly only if the child did not inherit the CLI's own stdout handle.
/// PRE-FIX RESULT (native Windows, yolanda 2026-09-26): about 30.4 s, the
/// grandchild's sleep (30558 / 30421 ms), against 745 / 723 ms redirected to a
/// file. Linux does not inherit that way; the test passes there too, and says
/// nothing about Windows unless it runs there.
#[test]
fn a_piped_caller_is_not_held_by_a_leaked_grandchild() {
    if !bash_available() {
        eprintln!("skip:lua_proc:piped-caller:no-bash");
        return;
    }
    use std::io::Read as _;
    let dir = tempfile::tempdir().unwrap();
    let marker = lua_path(&dir.path().join("m"));
    let script = format!(
        r#"local r = proc.run{{argv = {{"bash", "scripts/fixtures/spawn-grandchild.sh", "{marker}"}},
                               timeout_ms = 500, group = false}}
           print(r.status)"#
    );
    let t0 = Instant::now();
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .args(["lua", "-e", &script])
        .current_dir(repo_root())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn the plan CLI");
    let mut out = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut out)
        .unwrap();
    let eof_after = t0.elapsed();
    let _ = child.wait();
    assert!(
        out.contains("timed_out"),
        "the deadline must have fired: {out:?}"
    );
    assert!(
        eof_after < Duration::from_secs(3),
        "the caller's pipe stayed open {eof_after:?}: a leaked grandchild holds it"
    );
}
