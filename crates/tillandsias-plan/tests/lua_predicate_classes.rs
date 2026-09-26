// @trace order:1252-hsrz, order:1367-q9yc, spec:ci-release
//
// The verifiable closure of 1252-hsrz, one test per exit criterion, each naming
// the PRE-FIX result the packet recorded.

use std::io::Write;
use tillandsias_plan::lua_predicate::{PredicateClass, PredicateRegistry, build_environment};

/// CRITERION 1. A predicate registered in the CACHEABLE class and calling the
/// shell verb FAILS TO RESOLVE THE SYMBOL.
/// PRE-FIX: FAILS — there is no predicate class distinction today, so nothing
/// can be asserted about it.
///
/// The assertion is on the FAILURE MODE, not merely on failure: "attempt to call
/// a nil value" is the symbol being absent. A test that accepted any error would
/// also pass if the verb existed and merely errored, which is the documented-rule
/// outcome this packet exists to replace with a structural one.
#[test]
fn a_cacheable_predicate_cannot_resolve_the_shell_verb() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "wants_shell",
        PredicateClass::Cacheable,
        "function wants_shell(arg) local r = expert.shell{'true'}; return r.ok end",
    )
    .expect("registration compiles; the symbol is missing at CALL time, not load time");

    let err = reg.eval("wants_shell", "x").unwrap_err().to_string();
    assert!(
        err.contains("nil value"),
        "expected an unresolved-symbol failure, got: {err}"
    );
}

/// CRITERION 1, CONTROL: the same predicate source in the OBSERVING class works.
/// Without this, criterion 1 would pass against a runtime where the shell verb
/// does not exist for anyone.
#[test]
fn the_same_predicate_resolves_in_the_observing_class() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "wants_shell",
        PredicateClass::Observing,
        "function wants_shell(arg) local r = expert.shell{'true'}; return r.ok end",
    )
    .expect("register");
    assert!(reg.eval("wants_shell", "x").expect("eval"));
}

/// CRITERION 2. An OBSERVING predicate's result is NEVER served from cache,
/// proven by MUTATING THE OBSERVED STATE between two calls and asserting the
/// verdict changes.
/// PRE-FIX: FAILS — no cache and no classes exist.
#[test]
fn an_observing_verdict_is_never_served_from_cache() {
    let dir = std::env::temp_dir().join(format!("hsrz-observe-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir");
    let probe = dir.join("state");
    std::fs::write(&probe, "absent").expect("write");

    let src = format!(
        "function observes(arg) local r = expert.shell{{'cat', '{}'}}; \
         return r.stdout == 'present' end",
        probe.display()
    );

    let mut reg = PredicateRegistry::new();
    reg.register("observes", PredicateClass::Observing, &src)
        .expect("register");

    assert!(!reg.eval("observes", "x").expect("first"));
    std::fs::write(&probe, "present").expect("mutate the observed world");
    assert!(
        reg.eval("observes", "x").expect("second"),
        "an observing predicate must re-run; a cached verdict here is a green gate that ran nothing"
    );
    assert_eq!(reg.cache_hits, 0, "observing results must never be cached");

    let _ = std::fs::remove_dir_all(&dir);
}

/// CRITERION 2, THE OTHER HALF: a CACHEABLE verdict IS memoised. Without this the
/// test above would pass against a runtime with no cache at all, which is the
/// fixture-tests-nothing shape this session has already paid for twice.
#[test]
fn a_cacheable_verdict_is_served_from_cache() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "pure",
        PredicateClass::Cacheable,
        "function pure(arg) return #arg > 3 end",
    )
    .expect("register");

    assert!(reg.eval("pure", "abcd").expect("first"));
    assert_eq!(reg.cache_hits, 0);
    assert!(reg.eval("pure", "abcd").expect("second"));
    assert_eq!(
        reg.cache_hits, 1,
        "the second call must be served from cache"
    );
}

/// CRITERION 3. A forge agent adds a NEW predicate for an UNCOMMITTED spec and it
/// EXECUTES, with no recompilation of the host binary. This is the packet's whole
/// justification: an agent inside the forge has no place to rebuild a binary.
///
/// The test writes a .lua file at runtime — code that did not exist when this
/// test binary was compiled — and runs it.
#[test]
fn a_predicate_authored_at_runtime_executes_without_recompilation() {
    let dir = std::env::temp_dir().join(format!("hsrz-forge-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir");

    // An "uncommitted spec" and a predicate an agent just wrote about it.
    let spec = dir.join("uncommitted-spec.md");
    std::fs::write(
        &spec,
        "# a spec authored after this binary was built\nSHALL hold.\n",
    )
    .expect("write spec");

    let pred = dir.join("spec_declares_shall.lua");
    let mut f = std::fs::File::create(&pred).expect("create");
    writeln!(
        f,
        "function spec_declares_shall(path)\n  \
           local r = expert.shell{{'cat', path}}\n  \
           return r.ok and string.find(r.stdout, 'SHALL') ~= nil\n\
         end"
    )
    .expect("write predicate");

    let mut reg = PredicateRegistry::new();
    reg.register_file("spec_declares_shall", PredicateClass::Observing, &pred)
        .expect("a runtime-authored predicate must load");

    assert!(
        reg.eval("spec_declares_shall", spec.to_str().unwrap())
            .expect("eval"),
        "the agent-authored predicate must execute against its uncommitted spec"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// CRITERION 4. The runtime exposes an ENUMERABLE verb list and it matches the
/// audited set EXACTLY — so widening the capability set is a visible diff rather
/// than an accident.
///
/// Asserted from INSIDE Lua, because what the audit cares about is what a
/// predicate can actually reach, not what a Rust constant says it can.
#[test]
fn the_verb_enumeration_matches_the_audited_set_exactly() {
    for (class, expected) in [
        (PredicateClass::Cacheable, vec!["log_info", "verbs"]),
        (
            PredicateClass::Observing,
            vec!["log_info", "now_ms", "shell", "verbs"],
        ),
    ] {
        let lua = build_environment(class).expect("env");
        let listed: Vec<String> = lua
            .load("local t = expert.verbs(); return t")
            .eval()
            .expect("verbs()");
        assert_eq!(listed, expected, "enumeration drifted for {class:?}");

        // AND the enumeration must describe REALITY: every listed verb resolves,
        // and nothing outside the list does. An enumeration that is merely a
        // string list would satisfy the check above while lying.
        for v in &expected {
            let present: bool = lua
                .load(format!("return type(expert.{v}) == 'function'"))
                .eval()
                .expect("probe");
            assert!(
                present,
                "{v} is enumerated but does not resolve in {class:?}"
            );
        }
        if class == PredicateClass::Cacheable {
            let leaked: bool = lua
                .load("return expert.shell ~= nil or expert.now_ms ~= nil")
                .eval()
                .expect("probe");
            assert!(!leaked, "an unlisted verb resolves in the cacheable class");
        }
    }
}

/// `now_ms` is withheld from the cacheable class, and that is a FINDING rather
/// than an inherited rule: a clock read is an observation exactly as a shell call
/// is, so a cached predicate that branches on it returns an answer computed at a
/// time that has passed.
#[test]
fn the_cacheable_class_cannot_read_the_clock() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "reads_clock",
        PredicateClass::Cacheable,
        "function reads_clock(arg) return expert.now_ms() > 0 end",
    )
    .expect("register");
    let err = reg.eval("reads_clock", "x").unwrap_err().to_string();
    assert!(err.contains("nil value"), "got: {err}");
}

/// The shell verb is ARGV ONLY: a string is not a command line to be parsed, and
/// an empty argv is refused rather than guessed at.
#[test]
fn the_shell_verb_refuses_an_empty_argv() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "empty",
        PredicateClass::Observing,
        "function empty(arg) local r = expert.shell{}; return r.ok end",
    )
    .expect("register");
    let err = reg.eval("empty", "x").unwrap_err().to_string();
    assert!(err.contains("empty argv"), "got: {err}");
}

/// A timed-out shell call is reported as `timed_out`, NOT as an ordinary
/// non-zero exit — the distinction tillandsias-exec's three-case Completion
/// carries, surfaced into Lua so a predicate cannot confuse them.
#[test]
fn a_timed_out_shell_call_is_distinguishable_in_lua() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "slow",
        PredicateClass::Observing,
        "function slow(arg) local r = expert.shell{'sh','-c',\"trap '' TERM; sleep 60\", \
         timeout_ms=400}; return r.status == 'timed_out' and r.code == nil end",
    )
    .expect("register");
    assert!(
        reg.eval("slow", "x").expect("eval"),
        "a killed child must report timed_out and invent no exit code"
    );
}

/// CRITERION 5. `lua_runtime.rs` states what containment IS, and states that
/// SELinux is NOT relied upon, so the next reader cannot infer a guarantee that
/// does not exist.
///
/// THIS IS A TEST AND NOT ONLY PROSE ON PURPOSE. The whole argument of this
/// packet is that a documented rule drifts and an enforced one does not. A
/// disclaimer that any future edit can silently delete is exactly the shape the
/// packet rejects, so the disclaimer is pinned by the same discipline as the
/// verb set. If you are deleting this test, you are deleting the claim.
#[test]
fn lua_runtime_states_containment_and_disclaims_selinux() {
    let src = include_str!("../src/lua_runtime.rs");
    for required in [
        "WHAT CONTAINMENT IS, AND WHAT IT IS NOT",
        "SELINUX IS NOT RELIED UPON",
        "PROVENANCE IS A SEPARATE, UNSOLVED PROBLEM",
    ] {
        assert!(
            src.contains(required),
            "lua_runtime.rs must state: {required}"
        );
    }
}

// ---------------------------------------------------------------------------
// ORDER 1367-upz6. Purity by symbol absence has to cover the Lua STDLIB, not
// only the `expert` table: removing os.execute and io.open still left
// os.time, io.lines and os.remove reachable, so a "cacheable" verdict could
// read the clock or the disk and then be replayed as if it had not.
// PRE-FIX: all three stdlib arms below RESOLVE under Cacheable and the
// allow-list arm lists os, io, print, load and collectgarbage as extras.

/// Every global a Cacheable predicate can see, named. An allow-list: a new
/// global appearing here is a trust-boundary change and must be a diff to
/// this list, not an accident of a wider stdlib.
const CACHEABLE_GLOBALS: &[&str] = &[
    "_G",
    "_VERSION",
    "assert",
    "error",
    "expect",
    "expert",
    "fs",
    "getmetatable",
    "hash", // 1375-btuf lua_std (pure)
    "ipairs",
    "json", // 1375-btuf lua_std (pure)
    "math",
    "pairs",
    "path", // 1375-btuf lua_std (pure, lexical)
    "pcall",
    "rawequal",
    "rawget",
    "rawlen",
    "rawset",
    "select",
    "setmetatable",
    "string",
    "table",
    "tonumber",
    "tostring",
    "type",
    "utf8",
    "xpcall",
    "yaml", // 1375-btuf lua_std (pure)
];

#[test]
fn the_cacheable_global_set_is_exactly_the_allow_list() {
    let lua = build_environment(PredicateClass::Cacheable).expect("env");
    let mut seen: Vec<String> = lua
        .load("local n = {} for k in pairs(_G) do n[#n + 1] = k end return n")
        .eval()
        .expect("enumerate globals");
    seen.sort();
    let mut want: Vec<String> = CACHEABLE_GLOBALS.iter().map(|s| s.to_string()).collect();
    want.sort();
    assert_eq!(
        seen, want,
        "the cacheable global set drifted from the allow-list"
    );

    // math stays, but its non-deterministic half does not.
    let random: bool = lua
        .load("return math.random ~= nil or math.randomseed ~= nil")
        .eval()
        .expect("probe");
    assert!(
        !random,
        "math.random is reachable from a cacheable predicate"
    );
}

fn cacheable_call_fails_as_absent(body: &str) {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "impure",
        PredicateClass::Cacheable,
        &format!("function impure(arg) {body} return true end"),
    )
    .expect("registration compiles; the symbol is missing at CALL time");
    let err = reg.eval("impure", "x").unwrap_err().to_string();
    assert!(
        err.contains("nil value"),
        "`{body}` must fail as an absent symbol in the cacheable class, got: {err}"
    );
}

#[test]
fn a_cacheable_predicate_cannot_read_the_clock_through_the_stdlib() {
    cacheable_call_fails_as_absent("local t = os.time()");
}

#[test]
fn a_cacheable_predicate_cannot_read_a_file_through_the_stdlib() {
    // Review of 1367-q9yc (c). `fs.read` now lets a cacheable predicate read,
    // so this test keeps its meaning by pinning that EVERY RAW stdlib route to
    // a file stays absent: the repo-rooted, read-logged shim is the only reader,
    // and it is the one the content-addressed memo can see.
    cacheable_call_fails_as_absent("for l in io.lines('VERSION') do end");
    cacheable_call_fails_as_absent("io.open('VERSION')");
    cacheable_call_fails_as_absent("io.read()");
    cacheable_call_fails_as_absent("loadfile('VERSION')");
    cacheable_call_fails_as_absent("dofile('VERSION')");
    cacheable_call_fails_as_absent("os.rename('VERSION', 'VERSION')");
    // ... and the shim itself refuses outside the root.
    let mut reg = PredicateRegistry::new();
    reg.register(
        "raw_probe",
        PredicateClass::Cacheable,
        "function raw_probe(p) return fs.read(p) ~= nil end",
    )
    .expect("register");
    let err = reg
        .eval("raw_probe", "/etc/hostname")
        .unwrap_err()
        .to_string();
    assert!(err.contains("outside repository root"), "{err}");
}

/// Review of 1367-q9yc (a). PRE-FIX RESULT: FAILS — the memo was keyed on
/// (name, arg) only, so after the file changed the SECOND eval replayed the
/// first verdict (true) from cache. Post-fix the memo is keyed on the content
/// of every file `fs.read` touched, so an edit forces re-evaluation while an
/// unchanged file is still served from cache.
#[test]
fn a_cacheable_verdict_is_re_evaluated_when_a_file_it_read_changes() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let rel = format!("target/lua-memo-probe-{}.txt", std::process::id());
    let file = root.join(&rel);
    std::fs::create_dir_all(file.parent().unwrap()).expect("mkdir target");
    std::fs::write(&file, "alpha").expect("write probe");

    let mut reg = PredicateRegistry::new();
    reg.register(
        "memo_probe",
        PredicateClass::Cacheable,
        "function memo_probe(p) return fs.read(p) == 'alpha' end",
    )
    .expect("register");

    assert!(reg.eval("memo_probe", &rel).expect("eval 1"));
    assert!(reg.eval("memo_probe", &rel).expect("eval 2"));
    assert_eq!(
        reg.cache_hits, 1,
        "an unchanged input must be served from cache"
    );

    std::fs::write(&file, "beta").expect("edit probe");
    let after = reg.eval("memo_probe", &rel).expect("eval 3");
    let _ = std::fs::remove_file(&file);
    assert!(
        !after,
        "a stale verdict was served after the file it read changed"
    );
    assert_eq!(
        reg.cache_hits, 1,
        "the edited input must NOT be a cache hit"
    );
}

#[test]
fn a_cacheable_predicate_cannot_remove_a_file_through_the_stdlib() {
    let victim = std::env::temp_dir().join(format!("upz6-victim-{}", std::process::id()));
    std::fs::write(&victim, b"x").expect("write victim");
    let path = victim.display().to_string().replace('\\', "/");
    cacheable_call_fails_as_absent(&format!("os.remove('{path}')"));
    assert!(
        victim.exists(),
        "the file was removed by a cacheable predicate"
    );
    let _ = std::fs::remove_file(&victim);
}

// ---------------------------------------------------------------------------
// ORDER 1367-q9yc. Pure shims: repo-rooted `fs.read` and `expect.*` assertions.
// PRE-FIX RESULT: fs and expect are nil in both classes, so all arms fail.

/// CRITERION 1. A Cacheable predicate calls `fs.read` on a repo file and gets its bytes.
#[test]
fn a_cacheable_predicate_reads_repo_files_via_fs_read() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "reads_repo_file",
        PredicateClass::Cacheable,
        "function reads_repo_file(path)
            local content = fs.read(path)
            return expect.contains(content, 'tillandsias-plan')
        end",
    )
    .expect("register");

    let verdict = reg
        .eval("reads_repo_file", "crates/tillandsias-plan/Cargo.toml")
        .expect("eval");
    assert!(verdict, "expected fs.read to read Cargo.toml successfully");
}

/// CRITERION 2. fs.read on `../x`, on an absolute path outside the repo, and on
/// `/etc/passwd` RAISES a named error.
#[test]
fn fs_read_refuses_outside_paths_and_traversals() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "read_probe",
        PredicateClass::Cacheable,
        "function read_probe(path) return fs.read(path) end",
    )
    .expect("register");

    for bad_path in ["../x", "/etc/passwd", "/tmp/definitely_outside_file"] {
        let err = reg.eval("read_probe", bad_path).unwrap_err().to_string();
        assert!(
            err.contains("outside repository root") || err.contains("refused"),
            "expected refusal for bad path '{bad_path}', got: {err}"
        );
    }
}

/// CRITERION 3. expect.contains, expect.matches and expect.eq return a verdict
/// VALUE (not an exit status), and a false expectation fails the predicate with
/// the expected and actual values in the message.
#[test]
fn expect_shims_return_verdict_values_and_fail_loud() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "pure_assertions",
        PredicateClass::Cacheable,
        r#"function pure_assertions(arg)
            local c = expect.contains('hello world', 'world')
            local m = expect.matches('v1.2.3', [[^v[0-9]+\.[0-9]+\.[0-9]+$]])
            local e1 = expect.eq(42, 42)
            local e2 = expect.eq('alpha', 'alpha')
            return c and m and e1 and e2
        end"#,
    )
    .expect("register");

    let verdict = reg.eval("pure_assertions", "").expect("eval");
    assert!(
        verdict,
        "expected pure assertions to pass and return boolean true"
    );

    // Negative control 1: expect.contains mismatch fails loud with expected and actual.
    reg.register(
        "fail_contains",
        PredicateClass::Cacheable,
        "function fail_contains(arg) return expect.contains('actual_haystack', 'missing_needle') end",
    )
    .expect("register");
    let err_contains = reg.eval("fail_contains", "").unwrap_err().to_string();
    assert!(
        err_contains.contains("missing_needle") && err_contains.contains("actual_haystack"),
        "expected error to carry expected and actual values, got: {err_contains}"
    );

    // Negative control 2: expect.matches mismatch fails loud with expected and actual.
    reg.register(
        "fail_matches",
        PredicateClass::Cacheable,
        "function fail_matches(arg) return expect.matches('actual_text', [[^[0-9]+$]]) end",
    )
    .expect("register");
    let err_matches = reg.eval("fail_matches", "").unwrap_err().to_string();
    assert!(
        err_matches.contains("^[0-9]+$") && err_matches.contains("actual_text"),
        "expected error to carry expected and actual values, got: {err_matches}"
    );

    // Negative control 3: expect.eq mismatch fails loud with expected and actual.
    reg.register(
        "fail_eq",
        PredicateClass::Cacheable,
        "function fail_eq(arg) return expect.eq('actual_str', 'expected_str') end",
    )
    .expect("register");
    let err_eq = reg.eval("fail_eq", "").unwrap_err().to_string();
    assert!(
        err_eq.contains("expected_str") && err_eq.contains("actual_str"),
        "expected error to carry expected and actual values, got: {err_eq}"
    );
}

/// CONTROL: Pure shims `fs.read` and `expect.*` are also available in the Observing class.
#[test]
fn pure_shims_available_in_observing_class_too() {
    let mut reg = PredicateRegistry::new();
    reg.register(
        "observing_shims",
        PredicateClass::Observing,
        "function observing_shims(path)
            local content = fs.read(path)
            return expect.contains(content, 'tillandsias')
        end",
    )
    .expect("register");

    let verdict = reg
        .eval("observing_shims", "crates/tillandsias-plan/Cargo.toml")
        .expect("eval");
    assert!(verdict);
}

// ---------------------------------------------------------------------------
// 1395-ue3i. fs.list(dir): sorted names, rooted, and part of the memo's input set.

fn scratch_dir(tag: &str) -> (std::path::PathBuf, String) {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let rel = format!("target/fs-list-{tag}-{}", std::process::id());
    let dir = root.join(&rel);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("mkdir");
    (dir, rel)
}

/// Operator ruling (2026-09-26, on 1395-ue3i): fs.list is for orchestration,
/// not hard tests, so it exists in the OBSERVING class and is ABSENT from the
/// Cacheable one; no memoized verdict can depend on a directory's membership.
#[test]
fn fs_list_is_observing_only_and_absent_from_the_cacheable_class() {
    let obs = tillandsias_plan::lua_predicate::build_environment(PredicateClass::Observing)
        .expect("observing env");
    let ty: String = obs.load("return type(fs.list)").eval().expect("observing");
    assert_eq!(ty, "function");
    let cac = tillandsias_plan::lua_predicate::build_environment(PredicateClass::Cacheable)
        .expect("cacheable env");
    let ty: String = cac.load("return type(fs.list)").eval().expect("cacheable");
    assert_eq!(ty, "nil", "fs.list must not reach a memoized verdict");
    let read: String = cac
        .load("return type(fs.read)")
        .eval()
        .expect("cacheable read");
    assert_eq!(
        read, "function",
        "Cacheable keeps fs.read (named files, content-addressed)"
    );
}

#[test]
fn fs_list_returns_regular_file_names_in_byte_order_and_never_a_symlink() {
    let (dir, rel) = scratch_dir("order");
    for n in ["b", "a", "C", "é"] {
        std::fs::write(dir.join(n), "").expect("seed");
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink("/etc", dir.join("zz-link")).expect("symlink");
    let lua =
        tillandsias_plan::lua_predicate::build_environment(PredicateClass::Observing).expect("env");
    let got: String = lua
        .load(format!(r#"return table.concat(fs.list("{rel}"), ",")"#))
        .eval()
        .expect("fs.list");
    let _ = std::fs::remove_dir_all(&dir);
    // Regular files only, in UTF-8 byte order; the symlink is EXCLUDED (so
    // it is never followed), which is fs.list's contract since 1380-u7sq.
    assert_eq!(got, "C,a,b,é");
}

#[test]
fn fs_list_refuses_outside_the_root_by_name() {
    let lua =
        tillandsias_plan::lua_predicate::build_environment(PredicateClass::Observing).expect("env");
    for bad in ["../", "/etc"] {
        let err = lua
            .load(format!(r#"return fs.list("{bad}")"#))
            .eval::<mlua::Value>()
            .unwrap_err()
            .to_string();
        assert!(err.contains("fs.list: refused"), "{bad}: {err}");
    }
}
