// @trace order:1475-j9kv
//
// Shadow-pilot evidence for three existing Bash agreement guards.  Production
// callers still use those guards; this target compares their outcomes with a
// fresh, cacheable Lua environment and deliberately keeps the comparison
// harness (which may spawn Bash) separate from the evaluator (which cannot).

use mlua::{Function, Table};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};
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
}

#[derive(Debug, PartialEq, Eq)]
struct Outcome {
    id: String,
    exit: i64,
    verdict: String,
    diagnostic: String,
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

fn expected_by_id() -> BTreeMap<String, (i64, String)> {
    manifest()
        .cases
        .into_iter()
        .map(|case| (case.id, (case.expected.exit, case.expected.verdict)))
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
        let Some((exit, verdict)) = expected.get(&outcome.id) else {
            panic!("evaluator returned undeclared case {}", outcome.id);
        };
        assert_eq!(&outcome.exit, exit, "{} exit", outcome.id);
        assert_eq!(&outcome.verdict, verdict, "{} verdict", outcome.id);
        assert_eq!(
            outcome.diagnostic, outcome.verdict,
            "{} stable payload",
            outcome.id
        );
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

fn copy_to(root: &Path, destination: &str, bytes: Vec<u8>) {
    let target = root.join(destination);
    std::fs::create_dir_all(target.parent().expect("target parent")).expect("mkdir fixture parent");
    std::fs::write(target, bytes).expect("write fixture source");
}

fn legacy_outcome(case: &ManifestCase) -> (i64, String) {
    let root = repo_root();
    let temp = tempfile::tempdir().expect("temporary legacy root");
    let temp_root = temp.path();
    let guard = match case.operation.as_str() {
        "tray_process_naming" => {
            copy_to(
                temp_root,
                "scripts/check-tray-process-running-naming.sh",
                std::fs::read(root.join("scripts/check-tray-process-running-naming.sh"))
                    .expect("read guard"),
            );
            let source = case.source.as_ref().expect("tray source");
            let mut bytes = std::fs::read(root.join(source)).unwrap_or_default();
            if case.id == "tray-crlf-space-path" {
                bytes = String::from_utf8(bytes)
                    .expect("UTF-8 fixture")
                    .replace('\n', "\r\n")
                    .into_bytes();
            }
            copy_to(
                temp_root,
                "crates/tillandsias-macos-tray/src/diagnose.rs",
                bytes,
            );
            temp_root.join("scripts/check-tray-process-running-naming.sh")
        }
        "dev_embed_model_agreement" => {
            copy_to(
                temp_root,
                "scripts/check-dev-embed-model-agreement.sh",
                std::fs::read(root.join("scripts/check-dev-embed-model-agreement.sh"))
                    .expect("read guard"),
            );
            copy_to(
                temp_root,
                "images/default/config-overlay/mcp/lib-dev-env.sh",
                std::fs::read(root.join(case.hook.as_ref().expect("hook"))).unwrap_or_default(),
            );
            copy_to(
                temp_root,
                "scripts/dev-inference-ensure.sh",
                std::fs::read(root.join(case.ensure.as_ref().expect("ensure"))).unwrap_or_default(),
            );
            temp_root.join("scripts/check-dev-embed-model-agreement.sh")
        }
        "inference_container_name_agreement" => {
            copy_to(
                temp_root,
                "scripts/check-inference-container-name-agreement.sh",
                std::fs::read(root.join("scripts/check-inference-container-name-agreement.sh"))
                    .expect("read guard"),
            );
            let script = case.script.as_ref().expect("script");
            let probe = case.probe.as_ref().expect("probe");
            let script_target = temp_root.join(script);
            let probe_target = temp_root.join(probe);
            if let Some(parent) = script_target.parent() {
                std::fs::create_dir_all(parent).expect("mkdir script parent");
            }
            if let Some(parent) = probe_target.parent() {
                std::fs::create_dir_all(parent).expect("mkdir probe parent");
            }
            if root.join(script).is_file() {
                std::fs::copy(root.join(script), &script_target).expect("copy script");
            }
            std::fs::copy(root.join(probe), &probe_target).expect("copy probe");
            let output = Command::new("bash")
                .arg(temp_root.join("scripts/check-inference-container-name-agreement.sh"))
                .current_dir(temp_root)
                .env("TILLANDSIAS_DEV_INFERENCE_SCRIPT", script)
                .env("TILLANDSIAS_ACCEL_PROBE_SRC", probe)
                .output()
                .expect("run inference legacy guard");
            return (
                output.status.code().expect("legacy exit code") as i64,
                String::from_utf8(output.stdout)
                    .expect("legacy stdout")
                    .trim_end()
                    .to_string(),
            );
        }
        other => panic!("unknown operation {other}"),
    };
    let output = Command::new("bash")
        .arg(guard)
        .current_dir(temp_root)
        .output()
        .expect("run legacy guard");
    (
        output.status.code().expect("legacy exit code") as i64,
        String::from_utf8(output.stdout)
            .expect("legacy stdout")
            .trim_end()
            .to_string(),
    )
}

#[cfg(unix)]
#[test]
fn legacy_bash_and_lua_agree_on_live_and_adversarial_cases() {
    let actual: BTreeMap<_, _> = outcomes()
        .into_iter()
        .map(|outcome| (outcome.id.clone(), outcome))
        .collect();
    for case in manifest().cases {
        let lua = actual.get(&case.id).expect("Lua case outcome");
        let (exit, stdout) = legacy_outcome(&case);
        assert_eq!(lua.exit, exit, "{} exit parity", case.id);
        // The only intentionally path-specific diagnostic is an unreadable
        // temporary inference script; its exit class is the parity contract.
        if case.id != "inference-missing-file" {
            assert_eq!(lua.verdict, stdout, "{} stdout payload parity", case.id);
        }
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
        "build.sh --check must run the named shadow-parity target"
    );
}

fn percentile(mut values: Vec<Duration>, numerator: usize, denominator: usize) -> Duration {
    values.sort_unstable();
    values[(values.len() - 1) * numerator / denominator]
}

fn declared_input_bytes_per_run(cases: &[ManifestCase]) -> u64 {
    let mut total = std::fs::metadata(manifest_path())
        .expect("manifest metadata")
        .len();
    let root = repo_root();
    for case in cases {
        for path in [
            case.source.as_deref(),
            case.hook.as_deref(),
            case.ensure.as_deref(),
            case.script.as_deref(),
            case.probe.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            // Missing explicit paths contribute zero bytes; the evaluator still
            // attempts the read and returns its named blocked verdict.
            if let Ok(metadata) = std::fs::metadata(root.join(path)) {
                total += metadata.len();
            }
        }
    }
    total
}

#[cfg(unix)]
#[test]
fn thirty_warm_paired_runs_report_case_and_process_evidence() {
    let cases = manifest().cases;
    let input_bytes = declared_input_bytes_per_run(&cases);
    let _ = outcomes(); // uncounted warmup of the real module and manifest.
    let mut old = Vec::new();
    let mut new = Vec::new();
    for round in 0..30 {
        let run_new = || {
            let started = Instant::now();
            let got = outcomes();
            assert_eq!(got.len(), cases.len(), "new evaluator case denominator");
            started.elapsed()
        };
        let run_old = || {
            let started = Instant::now();
            for case in &cases {
                let (exit, _) = legacy_outcome(case);
                assert_eq!(exit, case.expected.exit, "legacy case {}", case.id);
            }
            started.elapsed()
        };
        if round % 2 == 0 {
            old.push(run_old());
            new.push(run_new());
        } else {
            new.push(run_new());
            old.push(run_old());
        }
    }

    let cold_source =
        std::fs::read_to_string(module_path()).expect("module for cold CLI measurement");
    let cold_started = Instant::now();
    let cold = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .current_dir(repo_root())
        .env("TILLANDSIAS_REPO_ROOT", repo_root())
        .args([
            "lua",
            "--class",
            "cacheable",
            "-e",
            &(cold_source + "\nlocal r = source_agreements('scripts/fixtures/source-agreements.yaml'); return r.ok"),
        ])
        .output()
        .expect("cold plan binary launch");
    assert!(cold.status.success(), "cold evaluator launch: {cold:?}");

    eprintln!(
        "MEASURE:1475-j9kv linux warm_runs=30 cases_per_run={} declared_input_bytes_per_run={} old_ms_p50={} old_ms_p95={} lua_ms_p50={} lua_ms_p95={} evaluator_child_processes=0 comparison_guard_invocations={} cold_plan_binary_ms={}",
        cases.len(),
        input_bytes,
        percentile(old.clone(), 50, 100).as_millis(),
        percentile(old, 95, 100).as_millis(),
        percentile(new.clone(), 50, 100).as_millis(),
        percentile(new, 95, 100).as_millis(),
        30 * cases.len(),
        cold_started.elapsed().as_millis(),
    );
}
