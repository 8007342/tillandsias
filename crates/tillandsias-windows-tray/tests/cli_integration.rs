//! End-to-end CLI integration tests. Each test invokes the **real**
//! `tillandsias-tray.exe` binary (located via Cargo's
//! `CARGO_BIN_EXE_tillandsias-tray` env var) and asserts on the actual
//! captured output — complementing the inline pin tests in
//! `notify_icon::tests` which only assert against the test struct
//! `baseline_diagnose_report()`. These tests would catch:
//!
//! - A panic in `collect_report` (the inline tests can't observe this).
//! - An `env!("WORKSPACE_VERSION")` / `env!("BUILD_COMMIT_SHA")` that
//!   resolves to the wrong string at compile time (build.rs regression).
//! - A serialization failure that produces invalid JSON.
//! - A regression in the no-WSL fallback (e.g. shelling out failing the
//!   whole process instead of returning `None`).
//!
//! Windows-only because the binary uses Win32 APIs that don't link on
//! Linux. On macOS/Linux the file is `#[cfg]`'d down to an empty module
//! so `cargo test --workspace` from Linux dev boxes stays green.
//!
//! @trace spec:windows-native-tray

#![cfg(target_os = "windows")]

use std::process::Command;

/// Path to the built `tillandsias-tray.exe` for this test's profile.
/// Cargo sets `CARGO_BIN_EXE_<bin_name>` when compiling integration tests
/// in `tests/`. The binary is built on demand before the test runs, so
/// this is always-fresh.
const TRAY_EXE: &str = env!("CARGO_BIN_EXE_tillandsias-tray");

/// `--version` exits 0 + prints a single line containing both the
/// workspace VERSION (baked from `../../VERSION` via build.rs) and the
/// build commit SHA. Catches: env-var resolution failure, version-line
/// formatting regression.
#[test]
fn version_line_has_workspace_version_and_commit() {
    let output = Command::new(TRAY_EXE)
        .arg("--version")
        .output()
        .expect("run --version");
    assert!(
        output.status.success(),
        "--version should exit 0, got {:?}",
        output.status
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains(env!("WORKSPACE_VERSION")),
        "--version output should contain WORKSPACE_VERSION: {stdout}"
    );
    assert!(
        stdout.contains(env!("BUILD_COMMIT_SHA")),
        "--version output should contain BUILD_COMMIT_SHA: {stdout}"
    );
    assert!(
        stdout.starts_with("tillandsias-tray "),
        "--version output should start with binary name: {stdout}"
    );
}

/// `--help` exits 0 and includes every documented CLI mode / option / env
/// var / section header. Catches: a mode added to `main.rs` without a
/// corresponding `help_text()` entry (the inline
/// `help_text_documents_all_cli_modes` already covers this, but here we
/// check the REAL captured stdout of the binary, not just the test
/// helper's return value).
#[test]
fn help_text_includes_all_documented_surfaces() {
    let output = Command::new(TRAY_EXE)
        .arg("--help")
        .output()
        .expect("run --help");
    assert!(output.status.success(), "--help should exit 0");
    let stdout = String::from_utf8_lossy(&output.stdout);
    for needle in [
        // CLI modes
        "--provision-once",
        "--status-once",
        "--diagnose",
        "--logs",
        "--help",
        "--version",
        // Options
        "--no-provision",
        // Env vars
        "RUST_LOG",
        "TILLANDSIAS_NO_PROVISION",
        "BUILD_COMMIT_SHA_OVERRIDE",
        // Section headers
        "USAGE:",
        "MODES:",
        "OPTIONS",
        "ENVIRONMENT:",
        "OUTPUT NOTE:",
        // Cheatsheet pointer
        "cheatsheets/runtime/windows-tray-diagnostics.md",
    ] {
        assert!(
            stdout.contains(needle),
            "--help output should contain {needle:?}, but got:\n{stdout}"
        );
    }
}

/// `--diagnose --json` exits 0/1/2 (any of the contract values are valid;
/// the test host's wire state determines which) and emits valid JSON
/// containing every pinned top-level key. Catches: a panic in
/// `collect_report`, a serialization failure, an env-var that doesn't
/// resolve at compile time (would yield an empty `version` string), or a
/// regression in a sniffer that fails the whole process instead of
/// returning `None`.
#[test]
fn diagnose_json_has_all_16_top_level_keys() {
    let output = Command::new(TRAY_EXE)
        .args(["--diagnose", "--json"])
        .output()
        .expect("run --diagnose --json");
    // 0 = healthy, 2 = degraded, 1 = hard fail. 0 and 2 are both valid
    // "report ran to completion" outcomes; only 1 means the binary itself
    // is broken in a way the test should fail on.
    let code = output.status.code();
    assert!(
        code == Some(0) || code == Some(2),
        "--diagnose --json exit should be 0 or 2, got {code:?}\nstderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value =
        serde_json::from_str(&stdout).expect("--diagnose --json stdout should be valid JSON");
    let obj = json.as_object().expect("top-level should be a JSON object");
    for key in [
        "version",
        "build_commit",
        "install_path",
        "log_path",
        "log_exists",
        "log_size_bytes",
        "wsl_version",
        "os_version",
        "wt_present",
        "distro",
        "distro_registered",
        "distro_running",
        "release_tag",
        "manifest_pin_x86_64_tar",
        "wire",
        "recent_log_tail",
    ] {
        assert!(
            obj.contains_key(key),
            "--diagnose --json should include top-level key {key:?}, got: {}",
            obj.keys().cloned().collect::<Vec<_>>().join(", ")
        );
    }
    // Spot-check: `version` field should match what the build.rs baked.
    assert_eq!(
        obj.get("version").and_then(|v| v.as_str()),
        Some(env!("WORKSPACE_VERSION")),
        "--diagnose --json `version` should equal WORKSPACE_VERSION"
    );
}

/// `--status-once --json` emits a valid 7-key `StatusReport` JSON object
/// regardless of wire state. On a host where the WSL VM is idled (the
/// expected steady state when no tray session is keepaliving it), the
/// `reachable` field is `false`, `error` carries a descriptive string, and
/// `exit_code` matches the process exit. Pins both the schema + the
/// exit-code self-consistency: a regression that flipped them out of sync
/// would surface here.
#[test]
fn status_once_json_has_all_7_keys_and_exit_code_matches() {
    let output = Command::new(TRAY_EXE)
        .args(["--status-once", "--json"])
        .output()
        .expect("run --status-once --json");
    let code = output.status.code();
    // 0 = Ready, 2 = reachable-not-Ready, 1 = unreachable. Any of these is
    // a valid "report ran to completion" outcome.
    assert!(
        code == Some(0) || code == Some(1) || code == Some(2),
        "--status-once --json exit should be 0/1/2, got {code:?}\nstderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value =
        serde_json::from_str(&stdout).expect("--status-once --json stdout should be valid JSON");
    let obj = json.as_object().expect("top-level should be a JSON object");
    for key in [
        "reachable",
        "wire_version",
        "phase",
        "podman_ready",
        "last_event",
        "error",
        "exit_code",
    ] {
        assert!(
            obj.contains_key(key),
            "--status-once --json should include top-level key {key:?}, got: {}",
            obj.keys().cloned().collect::<Vec<_>>().join(", ")
        );
    }
    // The pre-computed exit_code in the JSON must match the process exit.
    let json_exit = obj
        .get("exit_code")
        .and_then(|v| v.as_i64())
        .expect("exit_code should be a number");
    assert_eq!(
        Some(json_exit as i32),
        code,
        "in-JSON exit_code ({json_exit}) should match process exit ({code:?}) — \
         the two are guaranteed self-consistent by status_exit_code()"
    );
}

/// `--logs` (no flags) reads the live `tray.log` and exits 0 when it
/// exists. The actual content is host-dependent (tracing emits varying
/// lines per session), so this test asserts only the contract: exit 0
/// AND stdout is valid UTF-8. Together with the inline
/// `select_log_tail_handles_all_cases` test (which pins the tail
/// arithmetic) this covers `--logs` end-to-end. Init_tracing creates the
/// log file on every startup, so a fresh test host that has never run
/// the tray before would still have a file to read (this test runs the
/// binary which calls init_tracing as a side effect of `--logs`).
#[test]
fn logs_no_flags_reads_live_log_and_exits_0() {
    let output = Command::new(TRAY_EXE)
        .arg("--logs")
        .output()
        .expect("run --logs");
    assert_eq!(
        output.status.code(),
        Some(0),
        "--logs should exit 0 (live log always exists after init_tracing); got {:?}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    // stdout must be valid UTF-8 (the file is tracing-fmt's text output).
    // Content is host-dependent so we don't pin substrings; the
    // existence-and-readable contract is what matters.
    let _stdout = std::str::from_utf8(&output.stdout).expect("--logs stdout should be valid UTF-8");
}

/// `--diagnose` (HUMAN mode, no `--json`) emits the bundled report as
/// labeled rows. Catches: a regression in `print_human` that drops a
/// section label, panics, or prints to the wrong stream. Different code
/// path from `print_json`; `diagnose_json_has_all_16_top_level_keys`
/// doesn't cover this one. Asserts exit ∈ {0, 2} (1 = binary broken)
/// + the presence of the canonical section labels that the cheatsheet documents.
#[test]
fn diagnose_human_includes_pinned_section_labels() {
    let output = Command::new(TRAY_EXE)
        .arg("--diagnose")
        .output()
        .expect("run --diagnose");
    let code = output.status.code();
    assert!(
        code == Some(0) || code == Some(2),
        "--diagnose exit should be 0 or 2, got {code:?}\nstderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    // Pin the labels the cheatsheet's Quick reference table lists as the
    // "~13 rows" of the human report. A future refactor that drops or
    // renames a label surfaces here pre-build instead of as a
    // documentation-stale incident in the field.
    for label in [
        "tillandsias-tray --diagnose",
        "Version:",
        "Build commit:",
        "Install path:",
        "Log file:",
        "Log exists:",
        "WSL:",
        "OS:",
        "wt.exe:",
        "Distro `",
        "Release tag:",
        "Manifest pin:",
    ] {
        assert!(
            stdout.contains(label),
            "--diagnose human output should contain section label {label:?}, got:\n{stdout}"
        );
    }
}

/// `--logs --bak` when `tray.log.bak` does not exist exits 1 with a
/// descriptive stderr. Pin the missing-bak path because it's the user-
/// facing message most operators hit on first `--bak` invocation (before
/// any rotation has fired).
#[test]
fn logs_bak_when_missing_exits_1_with_pointer_to_live_file() {
    // Best-effort: remove the existing bak so the test sees the missing
    // path. Tolerant of "no .bak existed in the first place" — that's
    // also the missing case.
    let log_dir = std::env::var("LOCALAPPDATA")
        .ok()
        .map(|p| std::path::PathBuf::from(p).join("tillandsias").join("logs"))
        .expect("LOCALAPPDATA env var");
    let bak = log_dir.join("tray.log.bak");
    let _ = std::fs::remove_file(&bak);

    let output = Command::new(TRAY_EXE)
        .args(["--logs", "--bak"])
        .output()
        .expect("run --logs --bak");
    assert_eq!(
        output.status.code(),
        Some(1),
        "--logs --bak with no backup should exit 1, got {:?}",
        output.status
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("--bak"),
        "stderr should reference --bak so operator knows which flag's missing target it is: {stderr}"
    );
    assert!(
        stderr.contains("drop --bak") || stderr.contains("live log"),
        "stderr should point operator at the live-file fallback path: {stderr}"
    );
}
