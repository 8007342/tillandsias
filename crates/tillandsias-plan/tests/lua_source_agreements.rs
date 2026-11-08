// @trace order:1475-j9kv
//
// Production evidence for the three retired Bash agreement guards. The pure
// evaluator is checked independently, then the real `script run` CLI is driven
// over every fixed live/adversarial input and compared byte-for-byte with the
// captured pre-cutover contract.

use mlua::{Function, Table};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use tillandsias_plan::lua_predicate::{PredicateClass, build_environment};

static REPO_ROOT_ENV: Mutex<()> = Mutex::new(());

#[derive(Debug, Deserialize)]
struct Manifest {
    cases: Vec<ManifestCase>,
}

#[derive(Debug, Deserialize)]
struct ManifestCase {
    id: String,
    operation: String,
    expected: Expected,
    source: Option<String>,
    hook: Option<String>,
    ensure: Option<String>,
    script: Option<String>,
    probe: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Expected {
    exit: i64,
    verdict: String,
    stderr: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
struct Outcome {
    id: String,
    exit: i64,
    verdict: String,
    diagnostic: Option<String>,
}

struct RestoreRepoRoot(Option<OsString>);

impl Drop for RestoreRepoRoot {
    fn drop(&mut self) {
        unsafe {
            match self.0.take() {
                Some(value) => std::env::set_var("TILLANDSIAS_REPO_ROOT", value),
                None => std::env::remove_var("TILLANDSIAS_REPO_ROOT"),
            }
        }
    }
}

fn repo_root() -> PathBuf {
    // Runtime read (1590-j20f, 1610-d6ra): a compile-time env! path names the
    // checkout that compiled this binary, which a shared target may reuse.
    Path::new(&std::env::var("CARGO_MANIFEST_DIR").expect("cargo test sets CARGO_MANIFEST_DIR"))
        .join("../..")
}

fn module_path() -> PathBuf {
    repo_root().join("scripts/lua/source-agreements.lua")
}

fn manifest_path() -> PathBuf {
    repo_root().join("scripts/fixtures/source-agreements.yaml")
}

fn manifest() -> Manifest {
    serde_yaml::from_str(&std::fs::read_to_string(manifest_path()).expect("read manifest"))
        .expect("manifest is valid YAML")
}

fn with_repo_root<T>(root: &Path, f: impl FnOnce() -> T) -> T {
    let _lock = REPO_ROOT_ENV
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let previous = std::env::var_os("TILLANDSIAS_REPO_ROOT");
    unsafe { std::env::set_var("TILLANDSIAS_REPO_ROOT", root) };
    let _restore = RestoreRepoRoot(previous);
    f()
}

thread_local! {
    // Full evaluator runs performed on THIS thread. Each run reads the real
    // module, builds a VM, parses the manifest and reads every named source.
    // Pre-fix (1604-fsxu) one assertion set evaluated the manifest nine times:
    // once for the expected-value comparison and once more per negative
    // control. Thread-local, because libtest runs sibling tests on their own
    // threads and a process-wide count would attribute their runs to this one.
    static EVALUATOR_RUNS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn evaluator_runs() -> usize {
    EVALUATOR_RUNS.with(|runs| runs.get())
}

fn outcomes_at(root: &Path, manifest_relative: &str) -> (bool, Option<String>, Vec<Outcome>) {
    EVALUATOR_RUNS.with(|runs| runs.set(runs.get() + 1));
    with_repo_root(root, || {
        let source = std::fs::read_to_string(module_path())
            .expect("the real Lua module must exist at runtime");
        let lua =
            build_environment(PredicateClass::Cacheable).expect("fresh cacheable environment");
        lua.load(&source)
            .exec()
            .expect("load source-agreements Lua module");
        let evaluator: Function = lua
            .globals()
            .get("source_agreements")
            .expect("source_agreements function");
        let summary: Table = evaluator
            .call(manifest_relative)
            .expect("evaluate explicit case manifest");
        let ok: bool = summary.get("ok").expect("summary ok flag");
        let error: Option<String> = summary.get("error").expect("summary error field");
        let cases: Table = summary.get("cases").expect("summary cases");
        let outcomes = cases
            .sequence_values::<Table>()
            .map(|value| {
                let value = value.expect("case table");
                Outcome {
                    id: value.get("id").expect("case id"),
                    exit: value.get("exit").expect("case exit"),
                    verdict: value.get("verdict").expect("case verdict"),
                    diagnostic: value.get("diagnostic").expect("case diagnostic"),
                }
            })
            .collect();
        (ok, error, outcomes)
    })
}

fn outcomes() -> Vec<Outcome> {
    let (ok, error, outcomes) =
        outcomes_at(&repo_root(), "scripts/fixtures/source-agreements.yaml");
    assert!(
        !ok,
        "the manifest deliberately includes named negative controls"
    );
    assert!(
        error.is_none(),
        "the checked manifest itself must be valid: {error:?}"
    );
    outcomes
}

fn expected_by_id() -> BTreeMap<String, (i64, String, Option<String>)> {
    manifest()
        .cases
        .into_iter()
        .map(|case| {
            (
                case.id,
                (
                    case.expected.exit,
                    case.expected.verdict,
                    case.expected.stderr,
                ),
            )
        })
        .collect()
}

#[test]
fn explicit_manifest_cases_match_their_expected_guard_verdicts() {
    let expected = expected_by_id();
    let runs_before = evaluator_runs();
    let actual = outcomes();
    assert!(
        !actual.is_empty(),
        "an empty or unselected suite must not pass"
    );
    assert_eq!(
        actual.len(),
        expected.len(),
        "every named case must execute once"
    );
    for outcome in &actual {
        let Some((exit, verdict, stderr)) = expected.get(&outcome.id) else {
            panic!("evaluator returned undeclared case {}", outcome.id);
        };
        assert_eq!(&outcome.exit, exit, "{} exit", outcome.id);
        assert_eq!(&outcome.verdict, verdict, "{} verdict", outcome.id);
        assert_eq!(&outcome.diagnostic, stderr, "{} stderr payload", outcome.id);
    }

    // Each mutation is a real failure.  An evaluator changed to always accept
    // makes this target red even if the live tree still agrees. The outcome
    // map captured above already holds every case; re-evaluating the manifest
    // per control (the pre-1604-fsxu shape) proved nothing the one run did not.
    for id in [
        "tray-old-field",
        "tray-removed-new-field",
        "dev-model-changed",
        "dev-model-missing-declaration",
        "inference-renamed-container",
        "inference-prose-only-match",
        "inference-missing-declaration",
        "inference-missing-file",
    ] {
        let outcome = actual
            .iter()
            .find(|outcome| outcome.id == id)
            .unwrap_or_else(|| panic!("negative control {id} missing from the evaluated manifest"));
        assert_ne!(outcome.exit, 0, "{id} must remain a negative control");
    }

    // ORDER 1604-fsxu. One assertion set, one evaluator run. The pre-fix
    // body ran the evaluator nine times on this thread (1 + 8 controls), so
    // this count is what the fix changes and what a regression would move.
    let runs = evaluator_runs() - runs_before;
    assert_eq!(
        runs, 1,
        "the explicit manifest is evaluated once per assertion set, not {runs} times"
    );
}

#[test]
fn malformed_empty_and_duplicate_manifests_fail_closed() {
    let root = repo_root();
    let source = std::fs::read_to_string(module_path()).expect("real module");
    with_repo_root(&root, || {
        let lua = build_environment(PredicateClass::Cacheable).expect("fresh environment");
        lua.load(&source).exec().expect("load module");
        let evaluator: Function = lua
            .globals()
            .get("source_agreements_text")
            .expect("text evaluator");
        for (input, expected) in [
            ("cases: []\n", "blocked:manifest-empty"),
            (
                "cases:\n  - {id: duplicate, operation: tray_process_naming}\n  - {id: duplicate, operation: tray_process_naming}\n",
                "blocked:duplicate-case-id:duplicate",
            ),
            ("cases: [\n", "blocked:manifest-malformed"),
        ] {
            let summary: Table = evaluator.call(input).expect("manifest result");
            assert!(!summary.get::<bool>("ok").expect("ok"), "{input:?}");
            assert_eq!(summary.get::<String>("error").expect("error"), expected);
        }

        let summary: Table = evaluator
            .call("cases:\n  - {id: unknown, operation: no_such_agreement}\n")
            .expect("unknown operation result");
        assert!(!summary.get::<bool>("ok").expect("unknown-operation ok"));
        let cases: Table = summary.get("cases").expect("unknown-operation cases");
        let case: Table = cases.get(1).expect("unknown-operation case");
        assert_eq!(case.get::<i64>("exit").expect("unknown-operation exit"), 2);
        assert_eq!(
            case.get::<String>("verdict")
                .expect("unknown-operation verdict"),
            "blocked:unknown-operation:no_such_agreement"
        );
    });
}

#[test]
fn pure_environment_has_no_process_or_mutating_capabilities() {
    let lua = build_environment(PredicateClass::Cacheable).expect("fresh cacheable environment");
    let shape: String = lua
        .load("return table.concat({type(proc), type(sh), type(time), type(os), type(io), type(loadfile), type(dofile), type(require), type(fs.write), type(fs.list), type(expert.shell)}, ',')")
        .eval()
        .expect("probe purity boundary");
    assert_eq!(shape, "nil,nil,nil,nil,nil,nil,nil,nil,nil,nil,nil");
}

#[test]
fn crlf_and_space_bearing_paths_are_explicitly_supported() {
    let temp = tempfile::tempdir().expect("temporary repository root");
    let root = temp.path();
    let source = root.join("fixtures/space path/tray source.rs");
    std::fs::create_dir_all(source.parent().expect("source parent")).expect("mkdir source parent");
    std::fs::write(
        &source,
        b"// CRLF input\r\npub tray_process_running: bool,\r\n",
    )
    .expect("write CRLF source");
    std::fs::write(
        root.join("manifest.yaml"),
        "cases:\n  - id: crlf-space\n    operation: tray_process_naming\n    source: fixtures/space path/tray source.rs\n",
    )
    .expect("write manifest");
    let (ok, error, actual) = outcomes_at(root, "manifest.yaml");
    assert!(ok, "{error:?}");
    assert_eq!(actual.len(), 1);
    assert_eq!(actual[0].verdict, "ok:tray-process-naming:3 checked");
}

#[test]
fn build_check_names_and_runs_this_nonempty_target() {
    let build = std::fs::read_to_string(repo_root().join("build.sh")).expect("read build.sh");
    assert!(
        build.contains("cargo test -p tillandsias-plan --test lua_source_agreements"),
        "build.sh --check must run the named production integration target"
    );
}

#[test]
fn cutover_callers_name_inputs_and_leave_no_bash_fallback() {
    let root = repo_root();
    for retired in [
        "scripts/check-tray-process-running-naming.sh",
        "scripts/check-dev-embed-model-agreement.sh",
        "scripts/check-inference-container-name-agreement.sh",
        "scripts/test-inference-container-name-agreement.sh",
    ] {
        assert!(
            !root.join(retired).exists(),
            "the atomic cutover must retire {retired}"
        );
    }
    let build = std::fs::read_to_string(root.join("build.sh")).expect("read build caller");
    let local_ci =
        std::fs::read_to_string(root.join("scripts/local-ci.sh")).expect("read local-ci caller");
    for named_input in [
        "tray_process_naming crates/tillandsias-macos-tray/src/diagnose.rs",
        "dev_embed_model_agreement images/default/config-overlay/mcp/lib-dev-env.sh",
        "scripts/dev-inference-ensure.sh 2>&1",
        "inference_container_name_agreement scripts/dev-inference-ensure.sh",
        "crates/tillandsias-headless/src/accel_probe.rs 2>&1",
    ] {
        assert!(
            build.contains(named_input),
            "build caller names {named_input}"
        );
    }
    assert!(
        local_ci
            .contains("script run scripts/lua/source-agreements.lua -- dev_embed_model_agreement"),
        "local-ci reaches the same typed production runner"
    );
    for legacy in [
        "check-tray-process-running-naming.sh",
        "check-dev-embed-model-agreement.sh",
        "check-inference-container-name-agreement.sh",
        "test-inference-container-name-agreement.sh",
    ] {
        assert!(
            !build.contains(legacy),
            "build has no Bash fallback {legacy}"
        );
        assert!(
            !local_ci.contains(legacy),
            "local-ci has no Bash fallback {legacy}"
        );
    }
}

fn runner_args(case: &ManifestCase) -> Vec<&str> {
    let mut args = vec![case.operation.as_str()];
    match case.operation.as_str() {
        "tray_process_naming" => args.push(case.source.as_deref().expect("tray source")),
        "dev_embed_model_agreement" => {
            args.push(case.hook.as_deref().expect("dev hook"));
            args.push(case.ensure.as_deref().expect("dev ensure"));
        }
        "inference_container_name_agreement" => {
            args.push(case.script.as_deref().expect("inference script"));
            args.push(case.probe.as_deref().expect("inference probe"));
        }
        other => panic!("unknown operation {other}"),
    }
    args
}

#[test]
fn production_script_run_preserves_pinned_exit_stdout_and_stderr_bytes() {
    let root = repo_root();
    let binary = env!("CARGO_BIN_EXE_tillandsias-plan");
    let cases = manifest().cases;
    assert!(
        !cases.is_empty(),
        "the selected production suite must be nonempty"
    );

    for case in cases {
        let args = runner_args(&case);
        let output = Command::new(binary)
            .current_dir(&root)
            .env("TILLANDSIAS_REPO_ROOT", &root)
            .args(["script", "run", "scripts/lua/source-agreements.lua", "--"])
            .args(args)
            .output()
            .expect("run the production Lua decider");
        assert_eq!(
            output.status.code(),
            Some(case.expected.exit as i32),
            "{} exit",
            case.id
        );
        assert_eq!(
            output.stdout,
            format!("{}\n", case.expected.verdict).as_bytes(),
            "{} stdout bytes",
            case.id
        );
        let expected_stderr = case
            .expected
            .stderr
            .as_deref()
            .map(|s| format!("{s}\n"))
            .unwrap_or_default();
        assert_eq!(
            output.stderr,
            expected_stderr.as_bytes(),
            "{} stderr bytes",
            case.id
        );
    }
}

// ---------------------------------------------------------------------------
// ORDER 2031-dwwy (R1 of design 2029-39bt §4.1, risk "Two builders drift
// again"): the child environment has ONE builder, child_env.rs. No other file
// of the plan crate clears a child's environment or walks the runner's
// TILLANDSIAS_* names. PRE-FIX: two of each (lua_predicate::base_env_command
// and run_verb::base_env/execute).
// ---------------------------------------------------------------------------
#[test]
fn child_environment_has_one_builder() {
    let src = repo_root().join("crates/tillandsias-plan/src");
    let mut offenders = Vec::new();
    let mut builder_seen = false;
    for entry in std::fs::read_dir(&src).expect("read the plan crate's src") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let body = std::fs::read_to_string(&path).expect("read a source file");
        if name == "child_env.rs" {
            builder_seen = body.contains("env_clear()") && body.contains("\"TILLANDSIAS_\"");
            continue;
        }
        for (i, line) in body.lines().enumerate() {
            if line.contains("starts_with(\"TILLANDSIAS_\")") || line.contains(".env_clear()") {
                offenders.push(format!("{name}:{}: {}", i + 1, line.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "a second child-environment builder exists outside child_env.rs:\n{}",
        offenders.join("\n")
    );
    assert!(
        builder_seen,
        "child_env.rs is missing or no longer builds the environment (premise)"
    );
}

// ---------------------------------------------------------------------------
// ORDER 2031-dwwy (tasks 1.2): the Rust credential shape
// (child_env::credential_shape) and the namespace-hygiene guard's shape
// (scripts/lua/check-env-namespace-hygiene.lua) are ONE rule. The guard itself
// is RUN — not a replica of it — over a scratch tree holding every
// TILLANDSIAS_ name in the checkout's code plus one probe per arm of the rule,
// and the names it refuses must be exactly the names the Rust rule calls
// credential-shaped, minus the guard's own listed credentials and retired
// spellings. PRE-FIX (the guard of 2031-z4rm): it passed PASSWD, PASSPHRASE,
// CREDENTIAL(S), COOKIE, SESSION terminals and ACCESS_KEY / SIGNING_KEY /
// CREDENTIAL infixes that the Rust rule (design §4.2 A2) blocks.
// ---------------------------------------------------------------------------

fn tillandsias_names_in(text: &str, into: &mut std::collections::BTreeSet<String>) {
    let re = regex::Regex::new(r"TILLANDSIAS_[A-Z0-9_]*[A-Z0-9]").unwrap();
    for m in re.find_iter(text) {
        into.insert(m.as_str().to_string());
    }
}

fn code_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_dir() {
            if p.file_name().is_some_and(|n| n == "target" || n == ".git") {
                continue;
            }
            code_files(&p, out);
        } else if ft.is_file()
            && p.extension()
                .and_then(|x| x.to_str())
                .is_some_and(|x| matches!(x, "sh" | "lua" | "rs"))
        {
            out.push(p);
        }
    }
}

/// The names a Lua table literal `local <table> = { NAME = ..., }` lists.
fn lua_table_names(src: &str, table: &str) -> Vec<String> {
    let open = format!("local {table} = {{");
    let start = src
        .find(&open)
        .unwrap_or_else(|| panic!("{table} in the guard"));
    let body = &src[start + open.len()..];
    let body = &body[..body.find("\n}").expect("table end")];
    let re = regex::Regex::new(r"(?m)^\s*(TILLANDSIAS_[A-Z0-9_]+)\s*=").unwrap();
    re.captures_iter(body).map(|c| c[1].to_string()).collect()
}

#[test]
fn rust_and_lua_credential_shapes_agree() {
    use tillandsias_plan::child_env::{
        CREDENTIAL_CONTAINS, CREDENTIAL_TERMINAL, LOCATOR_SUFFIXES, PROJECT_CREDENTIAL_NAMES,
        credential_shape,
    };
    let root = repo_root().canonicalize().expect("repo root");
    let guard_path = root.join("scripts/lua/check-env-namespace-hygiene.lua");
    let guard = std::fs::read_to_string(&guard_path).expect("read the guard");
    let listed_credentials = lua_table_names(&guard, "CREDENTIAL_NAMES");
    let retired = lua_table_names(&guard, "RETIRED_NAMES");

    // The two credential lists are one list.
    let mut rust_list: Vec<String> = PROJECT_CREDENTIAL_NAMES
        .iter()
        .map(|s| s.to_string())
        .collect();
    let mut lua_list = listed_credentials.clone();
    rust_list.sort();
    lua_list.sort();
    assert_eq!(
        rust_list, lua_list,
        "child_env::PROJECT_CREDENTIAL_NAMES and the guard's CREDENTIAL_NAMES differ"
    );
    // A listed or retired name the Rust rule would pass would be a dead entry.
    for n in listed_credentials.iter().chain(retired.iter()) {
        assert!(
            credential_shape(n).is_some(),
            "{n} is listed but not shaped"
        );
    }

    // The sample: the checkout's names, plus one probe per arm of the rule.
    let mut names = std::collections::BTreeSet::new();
    let mut files = Vec::new();
    for d in ["scripts", "crates", "images"] {
        code_files(&root.join(d), &mut files);
    }
    files.push(root.join("build.sh"));
    for f in &files {
        if let Ok(t) = std::fs::read_to_string(f) {
            tillandsias_names_in(&t, &mut names);
        }
    }
    assert!(names.len() > 100, "premise: the census found the namespace");
    for t in CREDENTIAL_TERMINAL {
        names.insert(format!("TILLANDSIAS_DWWY_PROBE_{t}"));
        for l in LOCATOR_SUFFIXES {
            names.insert(format!("TILLANDSIAS_DWWY_PROBE_{t}{l}"));
        }
    }
    for c in CREDENTIAL_CONTAINS {
        names.insert(format!("TILLANDSIAS_DWWY_PROBE_{c}_MODE"));
    }
    for not in ["SESSION_MODE", "AUTH_MODE", "KEYS_MODE", "PASS_OUT"] {
        names.insert(format!("TILLANDSIAS_DWWY_PROBE_{not}"));
    }

    // A scratch tree the guard scans: ONE file holding every name. Repo-
    // relative (the guard skips any path containing /target/ when absolute).
    let rel = format!(
        "target/plan-scratch/dwwy-shape-agreement-{}",
        std::process::id()
    );
    let scratch = root.join(&rel);
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(scratch.join("scripts")).unwrap();
    let body: String = names.iter().map(|n| format!("export {n}\n")).collect();
    std::fs::write(scratch.join("scripts/probe.sh"), body).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .current_dir(&root)
        .env("TILLANDSIAS_REPO_ROOT", &root)
        .env("TILLANDSIAS_ENV_HYGIENE_SCAN_ROOT", &rel)
        .args([
            "script",
            "run",
            "scripts/lua/check-env-namespace-hygiene.lua",
        ])
        .output()
        .expect("run the guard");
    let _ = std::fs::remove_dir_all(&scratch);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let refused: std::collections::BTreeSet<String> = stdout
        .lines()
        .filter_map(|l| l.strip_prefix("violation:env-namespace:credential-shape:"))
        .map(|rest| rest.split(':').next().unwrap_or("").to_string())
        .collect();
    let expected: std::collections::BTreeSet<String> = names
        .iter()
        .filter(|n| credential_shape(n).is_some())
        .filter(|n| !listed_credentials.contains(n) && !retired.contains(n))
        .cloned()
        .collect();
    assert!(
        !expected.is_empty() && output.status.code() == Some(1),
        "premise: the probes must make the guard refuse (exit {:?})",
        output.status.code()
    );
    let only_lua: Vec<_> = refused.difference(&expected).collect();
    let only_rust: Vec<_> = expected.difference(&refused).collect();
    assert!(
        only_lua.is_empty() && only_rust.is_empty(),
        "the shapes disagree\n  refused by the guard only: {only_lua:?}\n  shaped by Rust only: {only_rust:?}"
    );
}

// ORDER 2031-dwwy (tasks 1.4): every profile and every name a profile passes
// appears in design 2029-39bt §5.3 (the proxy names' lower-case twins are
// named there in prose: "and lower-case twins"). The design lives in the
// openspec change lua-door-environment-inheritance (PR #1000) or its archived
// copy; on a tree carrying neither this SKIPS BY NAME, and becomes live when
// the change lands.
#[test]
fn every_profile_name_appears_in_the_design_classification() {
    let root = repo_root();
    let mut candidates =
        vec![root.join("openspec/changes/lua-door-environment-inheritance/design.md")];
    if let Ok(rd) = std::fs::read_dir(root.join("openspec/changes/archive")) {
        for e in rd.flatten() {
            if e.file_name()
                .to_string_lossy()
                .ends_with("lua-door-environment-inheritance")
            {
                candidates.push(e.path().join("design.md"));
            }
        }
    }
    let Some(design) = candidates
        .iter()
        .find_map(|p| std::fs::read_to_string(p).ok())
    else {
        eprintln!("skip:profile-design-agreement:design-2029-39bt-not-in-this-tree");
        return;
    };
    let start = design.find("### 5.3 Classification").expect("design §5.3");
    let section = &design[start..];
    let section = &section[..section.find("### 5.4").unwrap_or(section.len())];
    for (profile, vars) in tillandsias_plan::child_env::ENV_INHERIT_PROFILES {
        assert!(
            section.contains(&format!("`{profile}`")),
            "profile {profile}"
        );
        for (var, _, _) in *vars {
            let twin = var.to_ascii_uppercase();
            let named = section.contains(&format!("`{var}`"))
                || (twin != *var
                    && section.contains(&format!("`{twin}`"))
                    && section.contains("lower-case twins"));
            assert!(named, "{profile}: {var} is not in design §5.3");
        }
    }
}
