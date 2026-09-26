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

/// 1375-btuf criterion: json.query(doc, '.a[] | select(. > 1)') returns {2}.
/// PRE-FIX RESULT (before 1375-rn9b landed): it refused by name,
/// "unsupported:engine-not-landed".
#[test]
fn json_query_runs_the_rn9b_engine_and_returns_a_sequence() {
    let out = eval_str(
        PredicateClass::Cacheable,
        r#"local r = json.query(json.parse('{"a":[1,2,{"b":null}]}'), '.a[] | select(. > 1)')
           return #r .. ':' .. json.encode(r)"#,
    );
    // The row's criterion text says {2}. jq orders objects ABOVE numbers, so
    // `{"b":null} > 1` is true and real jq 1.8.1 prints [2,{"b":null}] for this
    // exact input; the engine agrees with jq, and jq parity is 1375-rn9b's
    // contract. Pinned to jq; the criterion correction is an event on the row.
    assert_eq!(out, r#"2:[2,{"b":null}]"#);
    let two = eval_str(
        PredicateClass::Cacheable,
        r#"local r = json.query(json.parse('{"a":[1,2,3]}'), '.a[] | select(. == 2)')
           return #r .. ':' .. tostring(r[1])"#,
    );
    assert_eq!(two, "1:2");
    let bound = eval_str(
        PredicateClass::Cacheable,
        r#"local r = json.query(json.parse('{"k":"v"}'), '.k == $want', {want = "v"})
           return tostring(r[1])"#,
    );
    assert_eq!(bound, "true");
}

#[test]
fn json_query_errors_carry_the_engines_kind_prefix() {
    let lua = build_environment(PredicateClass::Cacheable).expect("env");
    let parse = lua
        .load("return json.query({}, '.a[')")
        .eval::<mlua::Value>()
        .unwrap_err()
        .to_string();
    assert!(parse.contains("json.query: parse:"), "{parse}");
    let unsupported = lua
        .load("return json.query({}, 'reduce .[] as $x (0; . + $x)')")
        .eval::<mlua::Value>()
        .unwrap_err()
        .to_string();
    assert!(
        unsupported.contains("json.query: unsupported:"),
        "{unsupported}"
    );
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
/// call in that same script (560) is expected. The search covers only places
/// that EXECUTE: shell scripts, build.sh, litmus YAML and CI workflows. Not
/// plan/ or methodology YAML — ledger prose quotes the flag (the amendment and
/// 1380-u7sq rows do), and a pin that counts its own documentation reports
/// itself; nor this file or main.rs, which name the flag.
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
            "build.sh",
            "openspec/litmus-tests/*.yaml",
            ".github/workflows/*.yml",
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

/// Coordinator ruling on the land hazard (2026-09-26): a plan binary that
/// PREDATES 1375-btuf reads `--unsandboxed` as a script path and fails, while
/// WITHOUT the flag it already is the raw VM. archive-plan-packets.sh therefore
/// feature-detects the flag. An old-binary stand-in (rejects the flag exactly as
/// the trunk binary did, runs the raw VM otherwise) must still sweep: the
/// completed row is archived and the open row stays.
/// PRE-FIX RESULT: FAILS — with the flag passed unconditionally the archiver
/// printed "Error: read --unsandboxed: No such file or directory" and exited 1
/// (measured by yoga 2026-09-26 with the trunk binary).
#[cfg(unix)]
#[test]
fn the_archiver_still_sweeps_with_a_plan_binary_that_predates_the_flag() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let work = std::env::temp_dir().join(format!("btuf-oldbin-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(work.join("plan/index.d")).unwrap();
    std::fs::create_dir_all(work.join("plan/archive")).unwrap();
    std::fs::write(
        work.join("plan/index.yaml"),
        "plan_index:\n  version: v1\n  steps:\n    - packet_id: fixture-done-row\n      order: 9998-done\n      status: completed\n      kind: defect\n      priority: p2\n      title: done row\n      events:\n        - type: completed\n          ts: \"2026-09-01T00:00:00Z\"\n          host: yoga\n          summary: done\n          evidence_refs: [fixture]\n    - packet_id: fixture-open-row\n      order: 9998-open\n      status: ready\n      kind: defect\n      priority: p2\n      title: open row\n",
    )
    .unwrap();
    let old = work.join("old-plan");
    std::fs::write(
        &old,
        format!(
            "#!/bin/sh\n\
             if [ \"$1\" = lua ] && [ \"$2\" = --unsandboxed ]; then echo 'Error: read --unsandboxed: No such file or directory (os error 2)' >&2; exit 1; fi\n\
             if [ \"$1\" = lua ]; then shift; exec '{real}' lua --unsandboxed \"$@\"; fi\n\
             exec '{real}' \"$@\"\n",
            real = plan_bin().display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o755)).unwrap();

    let premise = std::process::Command::new(&old)
        .args(["lua", "--unsandboxed", "-e", ""])
        .output()
        .unwrap();
    assert!(
        !premise.status.success(),
        "the stand-in must reject the flag like a pre-btuf binary"
    );

    let out = std::process::Command::new("bash")
        .current_dir(&root)
        .env("TILLANDSIAS_PLAN_BIN", &old)
        .arg("scripts/archive-plan-packets.sh")
        .arg("--index")
        .arg(work.join("plan/index.yaml"))
        .arg("--archive")
        .arg(work.join("plan/archive"))
        .output()
        .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let index = std::fs::read_to_string(work.join("plan/index.yaml")).unwrap();
    let _ = std::fs::remove_dir_all(&work);
    assert!(out.status.success(), "old-binary sweep failed: {text}");
    assert!(text.contains("Archived 1 packets."), "{text}");
    assert!(
        index.contains("fixture-open-row") && !index.contains("fixture-done-row"),
        "{index}"
    );
}
