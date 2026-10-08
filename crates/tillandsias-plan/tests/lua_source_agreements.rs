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
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
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

fn outcomes_at(root: &Path, manifest_relative: &str) -> (bool, Option<String>, Vec<Outcome>) {
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
    for outcome in actual {
        let Some((exit, verdict, stderr)) = expected.get(&outcome.id) else {
            panic!("evaluator returned undeclared case {}", outcome.id);
        };
        assert_eq!(&outcome.exit, exit, "{} exit", outcome.id);
        assert_eq!(&outcome.verdict, verdict, "{} verdict", outcome.id);
        assert_eq!(&outcome.diagnostic, stderr, "{} stderr payload", outcome.id);
    }

    // Each mutation is a real failure.  An evaluator changed to always accept
    // makes this target red even if the live tree still agrees.
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
        let outcome = outcomes()
            .into_iter()
            .find(|outcome| outcome.id == id)
            .unwrap();
        assert_ne!(outcome.exit, 0, "{id} must remain a negative control");
    }
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
