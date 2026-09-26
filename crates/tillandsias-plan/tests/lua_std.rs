// @trace order:1375-btuf
//
// The verifiable closure of 1375-btuf: one lua_std registrar, by class, in every
// Lua environment the plan binary hosts, and a sandboxed `lua` CLI.
// PRE-FIX RESULT: FAILS — no test target named `lua_std` existed, and
// `tillandsias-plan lua -e 'print(os.execute)'` printed a function address
// because run_lua_cli built a raw mlua::Lua::new().

use tillandsias_plan::lua_predicate::{PredicateClass, build_environment};

fn eval_str(class: PredicateClass, code: &str) -> String {
    let lua = build_environment(class).expect("environment");
    lua.load(code).eval::<String>().expect(code)
}

#[test]
fn json_round_trips_to_the_same_bytes() {
    let out = eval_str(
        PredicateClass::Cacheable,
        r#"return json.encode(json.parse('{"a":[1,2,{"b":null}]}'))"#,
    );
    assert_eq!(out, r#"{"a":[1,2,{"b":null}]}"#);
}

#[test]
fn yaml_parse_keeps_a_block_scalars_newlines() {
    let out = eval_str(
        PredicateClass::Cacheable,
        "return yaml.parse('k: |\\n  one\\n  two\\n').k",
    );
    assert_eq!(out, "one\ntwo\n");
}

#[test]
fn hash_sha256_matches_the_known_vector() {
    let out = eval_str(PredicateClass::Cacheable, "return hash.sha256('abc')");
    assert_eq!(
        out,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[test]
fn path_join_is_lexical() {
    assert_eq!(
        eval_str(
            PredicateClass::Cacheable,
            "return path.join('a', '..', 'b')"
        ),
        "b"
    );
    assert_eq!(
        eval_str(PredicateClass::Cacheable, "return path.dirname('/x/y/z')"),
        "/x/y"
    );
    assert_eq!(
        eval_str(
            PredicateClass::Cacheable,
            "return path.basename('x/y/z.lua')"
        ),
        "z.lua"
    );
}

#[test]
fn the_cacheable_class_gets_the_pure_tables_and_no_clock() {
    let out = eval_str(
        PredicateClass::Cacheable,
        "return type(json)..type(yaml)..type(hash)..type(path)..type(time)",
    );
    assert_eq!(out, "tabletabletabletablenil");
}

#[test]
fn the_observing_class_has_the_clock_and_sh_run() {
    let out = eval_str(
        PredicateClass::Observing,
        "return math.type(time.now_ms())..' '..type(sh.run)..' '..tostring(sh.run == expert.shell)",
    );
    assert_eq!(out, "integer function true");
    let stamp = eval_str(PredicateClass::Observing, "return time.iso_utc()");
    assert!(
        stamp.len() == 16 && stamp.as_bytes()[8] == b't' && stamp.ends_with('z'),
        "fragment-filename clock shape, got {stamp}"
    );
}

#[test]
fn json_query_refuses_by_name_until_its_engine_lands() {
    let lua = build_environment(PredicateClass::Cacheable).expect("env");
    let err = lua
        .load("return json.query({}, '.')")
        .eval::<mlua::Value>()
        .unwrap_err()
        .to_string();
    assert!(err.contains("unsupported:engine-not-landed"), "{err}");
}

fn plan_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_tillandsias-plan"))
}

#[test]
fn the_lua_cli_is_sandboxed_by_default() {
    let out = std::process::Command::new(plan_bin())
        .args(["lua", "-e", "print(os.execute, json ~= nil)"])
        .output()
        .expect("run lua cli");
    assert!(out.status.success(), "{:?}", out);
    assert_eq!(String::from_utf8_lossy(&out.stdout), "nil\ttrue\n");
}

#[test]
fn the_lua_cli_unsandboxed_opt_in_keeps_the_raw_vm() {
    let out = std::process::Command::new(plan_bin())
        .args([
            "lua",
            "--unsandboxed",
            "-e",
            "print(type(os.execute), json)",
        ])
        .output()
        .expect("run lua cli");
    assert_eq!(String::from_utf8_lossy(&out.stdout), "function\tnil\n");
}

/// Coordinator ruling 2026-09-26 (A): every `lua --unsandboxed` CALLER lives in
/// scripts/archive-plan-packets.sh. Pinned by FILE, not count, because a second
/// call in that same script (560) is expected. The search is restricted to
/// shell/yaml callers so this file and main.rs, which name the flag, are not
/// counted as callers.
#[test]
fn every_unsandboxed_caller_lives_in_the_archiver_script() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let out = std::process::Command::new("git")
        .current_dir(&root)
        .args([
            "grep",
            "-l",
            "-F",
            "lua --unsandboxed",
            "--",
            "*.sh",
            "*.yaml",
            "*.yml",
            "build.sh",
        ])
        .output()
        .expect("git grep");
    let files: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_string)
        .collect();
    assert_eq!(
        files,
        vec!["scripts/archive-plan-packets.sh".to_string()],
        "the --unsandboxed opt-in spread beyond the archiver"
    );
}
