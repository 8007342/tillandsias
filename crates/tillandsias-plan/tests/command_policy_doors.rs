// @trace order:1531-ae4a, spec:command-policies
// All processes and consent tokens live in unique scratch fixtures. The executable
// named rm below is a marker writer, NEVER the system rm or a destructive command.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};
use tillandsias_plan::command_policy as cp;

fn scratch() -> tempfile::TempDir {
    let dir = tempfile::Builder::new()
        .prefix("policy-doors-")
        .tempdir_in("/tmp/opencode")
        .unwrap();
    fs::create_dir(dir.path().join(".git")).unwrap();
    fs::create_dir(dir.path().join(".tillandsias")).unwrap();
    dir
}

fn command(root: &Path) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"));
    c.current_dir(root)
        .env_remove("CI")
        .env_remove("TILLANDSIAS_HOST_KIND")
        .env_remove("TILLANDSIAS_SKILL")
        .env_remove("TILLANDSIAS_DESTRUCTIVE_RESET_OK")
        .env("TILLANDSIAS_POLICY_REGIME", "interactive")
        .env("TILLANDSIAS_REPO_ROOT", root)
        .env("TILLANDSIAS_CONSENT_DIR", root.join("consent"));
    c
}

fn seed(root: &Path, text: &str) {
    fs::write(root.join(cp::SEED_RELATIVE_PATH), text).unwrap();
}

fn text(o: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn marker_program(root: &Path, name: &str) -> String {
    let p = root.join(name);
    fs::write(&p, "#!/bin/sh\nprintf ran >> marker\n").unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
    p.to_str().unwrap().into()
}

// Separate test-harness process avoids mutating the test runner's cwd/env.
#[test]
fn lua_worker() {
    let Ok(chunk) = std::env::var("POLICY_DOOR_LUA") else {
        return;
    };
    let lua = tillandsias_plan::lua_predicate::build_environment(
        tillandsias_plan::lua_predicate::PredicateClass::Observing,
    )
    .unwrap();
    lua.load(&chunk).exec().unwrap();
}

fn lua(root: &Path, chunk: &str) -> Output {
    let c = command(root);
    // Retain the same isolated environment but use this test binary.
    let mut worker = Command::new(std::env::current_exe().unwrap());
    worker
        .current_dir(root)
        .envs(c.get_envs().filter_map(|(k, v)| v.map(|v| (k, v))));
    for (k, v) in c.get_envs() {
        if v.is_none() {
            worker.env_remove(k);
        }
    }
    worker
        .args(["--exact", "lua_worker", "--nocapture"])
        .env("POLICY_DOOR_LUA", chunk)
        .output()
        .unwrap()
}

#[test]
fn refused_seed_never_relaxes_default_deny_or_spawns_at_any_door() {
    let d = scratch();
    let root = d.path();
    let program = marker_program(root, "harmless");
    seed(root, "version: 1\ndefault: deny\nrules: []\n");
    let deny = command(root)
        .args(["run", "--", &program])
        .output()
        .unwrap();
    assert!(!deny.status.success(), "{}", text(&deny));
    assert!(!root.join("marker").exists());
    // Positive control: exactly the same harmless program really can spawn.
    seed(root, "version: 1\ndefault: allow\nrules: []\n");
    assert!(
        command(root)
            .args(["run", "--", &program])
            .output()
            .unwrap()
            .status
            .success()
    );
    fs::remove_file(root.join("marker")).unwrap();

    for bad in ["version: [", "version: 1\ndefault: deny\nrules: [{}]\n", ""] {
        seed(root, bad);
        assert_refused(root, &program);
    }
    // A directory is deterministically unreadable as text, even as root.
    fs::remove_file(root.join(cp::SEED_RELATIVE_PATH)).unwrap();
    fs::create_dir(root.join(cp::SEED_RELATIVE_PATH)).unwrap();
    assert_refused(root, &program);
    fs::remove_dir(root.join(cp::SEED_RELATIVE_PATH)).unwrap();
    std::os::unix::fs::symlink("missing-policy", root.join(cp::SEED_RELATIVE_PATH)).unwrap();
    assert_refused(root, &program);
    fs::remove_file(root.join(cp::SEED_RELATIVE_PATH)).unwrap();
    fs::write(root.join(cp::SEED_RELATIVE_PATH), [0xff]).unwrap();
    assert_refused(root, &program);
}

#[test]
fn only_absent_default_seed_preserves_existing_floor() {
    let d = scratch();
    let root = d.path();
    let program = marker_program(root, "harmless");
    assert!(matches!(
        cp::load_seed(root, None, &[]).1,
        cp::SeedLoad::Absent
    ));
    let o = command(root)
        .args(["policy", "eval", "--", &program])
        .output()
        .unwrap();
    assert!(o.status.success(), "{}", text(&o));
    let o = command(root)
        .args(["policy", "eval", "--", "bash", "-c", "echo unused"])
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert!(
        text(&o).contains("refused:policy:no-shell-strings"),
        "{}",
        text(&o)
    );
    let missing = root.join("explicit-missing");
    for verb in ["eval", "show"] {
        let mut c = command(root);
        c.args(["policy", verb, "--seed"]).arg(&missing);
        if verb == "eval" {
            c.args(["--", &program]);
        }
        let o = c.output().unwrap();
        assert_eq!(o.status.code(), Some(1));
        assert!(
            text(&o).contains("refused:policy-seed:unreadable"),
            "{}",
            text(&o)
        );
    }
    assert!(!root.join("marker").exists());
}

fn assert_refused(root: &Path, program: &str) {
    for verb in ["eval", "show"] {
        let mut c = command(root);
        c.args(["policy", verb]);
        if verb == "eval" {
            c.args(["--", program]);
        }
        let o = c.output().unwrap();
        assert!(!o.status.success(), "{verb}: {}", text(&o));
        assert!(text(&o).contains("refused:policy-seed:"), "{}", text(&o));
        assert!(!text(&o).contains("ok:policy:allow:"), "{}", text(&o));
    }
    let o = command(root)
        .args(["run", "--json", "--", program])
        .output()
        .unwrap();
    assert!(!o.status.success(), "run: {}", text(&o));
    let value: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(value["status"], "policy_denied");
    assert!(value["run_id"].is_null());
    for chunk in [
        format!("local r = proc.run{{argv={{{program:?}}}}}; assert(r.status == 'policy_denied')"),
        format!(
            "local ok, e = pcall(function() sh.run{{{program:?}}} end); assert(not ok and tostring(e):find('refused:policy%-seed:'))"
        ),
    ] {
        let o = lua(root, &chunk);
        assert!(o.status.success(), "lua: {}", text(&o));
    }
    assert!(
        !root.join("marker").exists(),
        "refused seed spawned a child"
    );
}

#[test]
fn inspection_preserves_one_use_consent_for_first_actual_harmless_execution() {
    consent_lifecycle("cli");
}

#[test]
fn proc_execution_alone_consumes_one_use_consent() {
    consent_lifecycle("proc");
}

#[test]
fn sh_execution_alone_consumes_one_use_consent() {
    consent_lifecycle("sh");
}

fn consent_lifecycle(door: &str) {
    let d = scratch();
    let root = d.path();
    let argv = vec![
        marker_program(root, "rm"),
        "-rf".into(),
        root.with_extension("outside-unused")
            .to_str()
            .unwrap()
            .into(),
    ];
    let ctx = cp::ConsentCtx {
        dir: root.join("consent"),
        host: cp::this_host(),
        now: chrono::Utc::now(),
        evidence: cp::HostKind::BareMetal,
        skill: None,
        reset_ok: None,
    };
    let (token, _) = cp::consent_grant(&ctx, "workspace-destroy", &argv, 1800).unwrap();
    let original = fs::read(&token).unwrap();
    for _ in 0..2 {
        let o = command(root)
            .args(["policy", "eval", "--"])
            .args(&argv)
            .output()
            .unwrap();
        assert_eq!(o.status.code(), Some(4), "{}", text(&o));
        assert_eq!(fs::read(&token).unwrap(), original);
        assert!(
            command(root)
                .args(["policy", "show"])
                .output()
                .unwrap()
                .status
                .success()
        );
        assert!(!root.join("consent/consumed.jsonl").exists());
        assert!(!root.join("marker").exists());
    }
    // Even an execution request must not spend approval while its seed is refused.
    seed(root, "version: [");
    execute(root, &argv, door, false, true);
    assert_eq!(fs::read(&token).unwrap(), original);
    assert!(!root.join("marker").exists());
    fs::remove_file(root.join(cp::SEED_RELATIVE_PATH)).unwrap();
    execute(root, &argv, door, true, false);
    assert!(!token.exists());
    assert_eq!(fs::read_to_string(root.join("marker")).unwrap(), "ran");
    execute(root, &argv, door, false, false);
    assert_eq!(fs::read_to_string(root.join("marker")).unwrap(), "ran");
    assert_eq!(
        fs::read_to_string(root.join("consent/consumed.jsonl"))
            .unwrap()
            .lines()
            .count(),
        1
    );
}

fn execute(root: &Path, argv: &[String], door: &str, allowed: bool, seed_refused: bool) {
    if door == "cli" {
        let o = command(root)
            .args(["run", "--"])
            .args(argv)
            .output()
            .unwrap();
        assert_eq!(
            o.status.code(),
            Some(if allowed {
                0
            } else if seed_refused {
                1
            } else {
                4
            }),
            "{}",
            text(&o)
        );
        return;
    }
    let args = argv
        .iter()
        .map(|a| format!("{a:?}"))
        .collect::<Vec<_>>()
        .join(",");
    let chunk = if door == "proc" {
        let status = if allowed {
            "exited"
        } else if seed_refused {
            "policy_denied"
        } else {
            "policy_consent_required"
        };
        format!("local r = proc.run{{argv={{{args}}}}}; assert(r.status == '{status}', r.status)")
    } else {
        let token = if seed_refused {
            "refused:policy%-seed:"
        } else {
            "consent:policy:workspace%-destroy"
        };
        if allowed {
            format!("sh.run{{{args}}}")
        } else {
            format!(
                "local ok, e = pcall(function() sh.run{{{args}}} end); assert(not ok and tostring(e):find('{token}'), tostring(e))"
            )
        }
    };
    let o = lua(root, &chunk);
    assert!(o.status.success(), "{door}: {}", text(&o));
}
