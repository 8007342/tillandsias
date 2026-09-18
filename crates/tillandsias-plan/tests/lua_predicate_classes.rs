// @trace order:1252-hsrz, spec:ci-release
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
