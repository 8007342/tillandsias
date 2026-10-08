// @trace order:1539-dt84, spec:command-runtime
// Linux measurements only. The second slice adds post-cleanup collection of
// registered async handles and outer-timeout rendering; registration races,
// identity-less executor errors, legacy doors and native conformance remain open.
#![cfg(target_os = "linux")]

use serde_json::Value;
use std::path::Path;
use std::process::Output;

struct Fixture {
    dir: tempfile::TempDir,
}

impl Fixture {
    fn new() -> Self {
        let base = if Path::new("/tmp/opencode").is_dir() {
            "/tmp/opencode"
        } else {
            "/tmp"
        };
        let dir = tempfile::Builder::new()
            .prefix("lua-proc-trace-")
            .tempdir_in(base)
            .unwrap();
        std::fs::create_dir(dir.path().join(".git")).unwrap();
        std::fs::create_dir(dir.path().join(".tillandsias")).unwrap();
        Self { dir }
    }

    fn write(&self, name: &str, body: &str) -> String {
        let path = self.dir.path().join(name);
        std::fs::write(&path, body).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn run(&self, body: &str, trace: bool) -> Output {
        self.run_with_timeout(body, trace, "5s")
    }

    fn run_with_timeout(&self, body: &str, trace: bool, timeout: &str) -> Output {
        let script = self.write("probe.lua", body);
        // Run the identical controls against a pinned pre-slice artifact for
        // independent red/green evidence, without rebuilding an old checkout.
        let binary = std::env::var_os("TILLANDSIAS_LUA_PROC_TRACE_TEST_BIN")
            .unwrap_or_else(|| env!("CARGO_BIN_EXE_tillandsias-plan").into());
        let mut command = std::process::Command::new(binary);
        command.args(["script", "run", &script, "--timeout", timeout]);
        if trace {
            command.arg("--trace");
        }
        command
            .current_dir(self.dir.path())
            .env("TILLANDSIAS_REPO_ROOT", self.dir.path())
            .env("TILLANDSIAS_POLICY_REGIME", "interactive")
            .env("TILLANDSIAS_CONSENT_DIR", self.dir.path().join("consent"))
            .env_remove("TILLANDSIAS_POLICY_SEED")
            .env_remove("TILLANDSIAS_CONSENT_TOKEN")
            .env_remove("CI")
            .env_remove("TILLANDSIAS_SKILL")
            .env_remove("TILLANDSIAS_DESTRUCTIVE_RESET_OK")
            .output()
            .unwrap()
    }
}

fn lines_with_prefix(bytes: &[u8], prefix: &str) -> Vec<Value> {
    std::str::from_utf8(bytes)
        .unwrap()
        .lines()
        .filter_map(|line| line.strip_prefix(prefix))
        .map(|json| serde_json::from_str(json).expect("one complete JSON record per physical line"))
        .collect()
}

fn records(output: &Output) -> Vec<Value> {
    lines_with_prefix(&output.stderr, "trace:proc:")
}

fn results(output: &Output) -> Vec<Value> {
    lines_with_prefix(&output.stdout, "result:")
}

fn correlate(record: &Value, result: &Value) {
    assert_eq!(record["kind"], "process_terminal");
    for field in ["run_id", "argv", "wall_ms", "status"] {
        assert_eq!(record[field], result[field], "correlation field {field}");
    }
    assert!(record["run_id"].as_str().is_some_and(|id| !id.is_empty()));
    assert!(record["argv"].is_array());
    assert!(record["wall_ms"].is_u64());
    assert!(!record["status"].is_null());
    assert!(
        record.get("code").is_some(),
        "code must be explicit, even when null"
    );
    assert_eq!(record["code"], result["code"]);
    for field in ["stdout", "stderr", "stdin", "env"] {
        assert!(
            record.get(field).is_none(),
            "trace must not capture {field}"
        );
    }
}

#[test]
fn trace_run_success_and_nonzero_correlate_to_actual_results() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        for _, argv in ipairs({{"printf", "literal %s", "a b*c"}, {"false"}}) do
            local r = proc.run{argv=argv}
            out.line("result:" .. json.encode(r))
        end
        verdict.ok("trace-run")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    let returned = results(&output);
    assert_eq!(actual.len(), 2, "{output:?}");
    assert_eq!(returned.len(), 2);
    for (record, result) in actual.iter().zip(&returned) {
        correlate(record, result);
    }
    assert_eq!(actual[0]["code"], 0);
    assert_eq!(actual[1]["code"], 1);
    assert_ne!(actual[0]["run_id"], actual[1]["run_id"]);
}

#[test]
fn trace_waited_spawn_records_once_across_repeated_waits() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        for _, argv in ipairs({{"printf", "spawned\n"}, {"false"}}) do
            local p = proc.spawn{argv=argv}
            local first = p:wait()
            out.line("result:" .. json.encode(first))
            local second = p:wait()
            assert(second.run_id == first.run_id and second.wall_ms == first.wall_ms)
            assert(second.code == first.code and second.stdout == first.stdout)
        end
        verdict.ok("trace-waited-spawn")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    let returned = results(&output);
    assert_eq!(actual.len(), 2, "{output:?}");
    for (record, result) in actual.iter().zip(&returned) {
        correlate(record, result);
    }
    assert_eq!(actual[1]["code"], 1);
}

#[test]
fn trace_exit_callback_mutation_does_not_change_host_record() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        local p = proc.spawn{argv={"printf", "original\n"}}
        p:on_exit(function(r)
            r.run_id = "forged"; r.code = 99; r.wall_ms = 999999
            r.argv[1] = "mutated"; r.stdout = "mutated"
        end)
        local r = p:wait()
        assert(r.code == 0 and r.stdout == "original\n" and r.argv[1] == "printf")
        out.line("result:" .. json.encode(r))
        verdict.ok("trace-immutable")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    assert_eq!(actual.len(), 1, "{output:?}");
    correlate(&actual[0], &results(&output)[0]);
}

#[test]
fn trace_observed_terminal_survives_exit_callback_error() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        local p = proc.spawn{argv={"true"}}
        p:on_exit(function(r)
            out.line("result:" .. json.encode(r))
            error("trace-callback-error")
        end)
        p:wait()
        verdict.ok("must-not-run")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stdout).contains("refused:script-error:probe"));
    let actual = records(&output);
    assert_eq!(actual.len(), 1, "{output:?}");
    correlate(&actual[0], &results(&output)[0]);
}

#[test]
fn trace_no_child_controls_invent_neither_terminal_identity_nor_code() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        for _, start in ipairs({proc.run, proc.spawn}) do
            local missing = start{argv={"trace-fixture-missing-executable-1539"}}
            assert(missing.status == "spawn_failed" and missing.run_id == nil and missing.code == nil)
            local denied = start{argv={"bash", "-c", "printf must-not-launch"}}
            assert(denied.status == "policy_denied" and denied.run_id == nil and denied.code == nil)
        end
        verdict.ok("trace-no-child")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    assert!(records(&output).is_empty(), "{output:?}");
    f.write(
        ".tillandsias/command-policies.yaml",
        "version: 1\ndefault: allow\nrules:\n  - id: fixture-consent\n    program: printf\n    decision: consent\n",
    );
    let consent = f.run(
        r#"
        for _, start in ipairs({proc.run, proc.spawn}) do
            local r = start{argv={"printf", "must-not-launch"}}
            assert(r.status == "policy_consent_required" and r.run_id == nil and r.code == nil)
        end
        verdict.ok("trace-no-consent")
        "#,
        true,
    );
    assert_eq!(consent.status.code(), Some(0), "{consent:?}");
    assert!(records(&consent).is_empty(), "{consent:?}");
}

#[test]
fn trace_json_argv_is_redacted_without_mutating_returned_argv() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        local token = "ghp_" .. string.rep("a", 40)
        local literal = "quoted\" slash\\ newline\n雪"
        local r = proc.run{argv={"printf", "%s%s", token, literal}}
        assert(r.argv[3] == token and r.argv[4] == literal)
        out.line("result:" .. json.encode(r))
        verdict.ok("trace-redaction")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    let returned = results(&output);
    assert_eq!(actual.len(), 1, "terminal records: {actual:?}");
    assert_eq!(actual[0]["argv"][2], "<redacted:token>");
    assert_eq!(actual[0]["argv"][3], returned[0]["argv"][3]);
    assert!(returned[0]["argv"][2].as_str().unwrap().starts_with("ghp_"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("ghp_"));
    for field in ["run_id", "wall_ms", "status", "code"] {
        assert_eq!(actual[0][field], returned[0][field]);
    }
}

#[test]
fn trace_deadline_has_actual_timed_out_status_and_explicit_null_code() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        local a = proc.run{argv={"sleep", "1"}, timeout_ms=20}
        local p = proc.spawn{argv={"sleep", "1"}, timeout_ms=20}
        local b = p:wait()
        for _, r in ipairs({a,b}) do
            assert(r.status == "timed_out" and r.code == nil and not r.ok)
            out.line("result:" .. json.encode(r))
        end
        verdict.ok("trace-process-deadline")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    assert_eq!(actual.len(), 2, "{output:?}");
    for (record, result) in actual.iter().zip(results(&output)) {
        correlate(record, &result);
        assert!(record["code"].is_null());
        assert_eq!(record["status"], "timed_out");
    }
}

#[test]
fn trace_signaled_completion_does_not_invent_an_exit_code() {
    let f = Fixture::new();
    let script = f.write("signal.sh", "kill -TERM \"$$\"\n");
    let output = f.run(
        &format!(
            r#"
            local p = proc.spawn{{argv={{"bash", {script:?}}}}}
            local r = p:wait()
            assert(r.status == "signaled" and r.signal == 15 and r.code == nil)
            out.line("result:" .. json.encode(r))
            verdict.ok("trace-signal")
            "#
        ),
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    assert_eq!(actual.len(), 1, "{output:?}");
    correlate(&actual[0], &results(&output)[0]);
    assert!(actual[0]["code"].is_null());
}

#[test]
fn trace_does_not_capture_stdin_environment_or_child_fd_payloads() {
    let f = Fixture::new();
    let script = f.write(
        "payload.sh",
        "read -r input\nprintf 'private-stdout-%s' \"$input\"\nprintf 'private-stderr-%s' \"$TRACE_SECRET\" >&2\n",
    );
    let output = f.run(
        &format!(
            r#"
            local r = proc.run{{argv={{"bash", {script:?}}}, stdin="private-stdin\n",
                env={{TRACE_SECRET="private-env"}}}}
            assert(r.stdout == "private-stdout-private-stdin")
            assert(r.stderr == "private-stderr-private-env")
            out.line("result:" .. json.encode(r))
            verdict.ok("trace-payload-exclusion")
            "#
        ),
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    assert_eq!(actual.len(), 1, "{output:?}");
    correlate(&actual[0], &results(&output)[0]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    for payload in [
        "private-stdin",
        "private-env",
        "private-stdout",
        "private-stderr",
    ] {
        assert!(
            !stderr.contains(payload),
            "child payload reached diagnostics: {stderr}"
        );
    }
}

#[test]
fn trace_off_on_preserves_exact_stdout_and_exit_for_success_and_refusal() {
    for verdict in [
        "verdict.ok('invariant')",
        "verdict.refused('invariant', 'detail-only')",
    ] {
        let f = Fixture::new();
        let script = format!(
            r#"
            local r = proc.run{{argv={{"printf", "literal\n"}}}}
            assert(r.stdout == "literal\n")
            local p = proc.spawn{{argv={{"false"}}}}
            assert(p:wait().code == 1)
            out.line("stable-output")
            {verdict}
            "#
        );
        let off = f.run(&script, false);
        let on = f.run(&script, true);
        assert_eq!(off.stdout, on.stdout, "{off:?}\n{on:?}");
        assert_eq!(off.status.code(), on.status.code());
        assert!(records(&off).is_empty());
        assert_eq!(records(&on).len(), 2, "{on:?}");
        assert!(!String::from_utf8_lossy(&on.stdout).contains("trace:proc:"));
        if verdict.contains("refused") {
            assert_eq!(on.status.code(), Some(1));
            assert!(String::from_utf8_lossy(&on.stderr).contains("detail-only"));
        } else {
            assert_eq!(on.status.code(), Some(0));
        }
    }
}

#[test]
fn trace_truncated_capture_retains_actual_exited_status_and_code() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        local r = proc.run{argv={"printf", "abcdef"}, capture_bytes=3}
        assert(r.status == "exited" and r.code == 0 and r.truncated and not r.ok)
        assert(r.stdout == "abc")
        out.line("result:" .. json.encode(r))
        verdict.ok("trace-clipped")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    assert_eq!(actual.len(), 1, "{output:?}");
    correlate(&actual[0], &results(&output)[0]);
    assert_eq!(actual[0]["truncated"], true);
}

#[test]
fn trace_outer_timeout_preserves_stdout_and_exit_and_renders_held_records() {
    let f = Fixture::new();
    let script = "assert(proc.run{argv={'true'}}.ok); while true do end";
    let off = f.run_with_timeout(script, false, "100ms");
    let on = f.run_with_timeout(script, true, "100ms");
    assert_eq!(off.stdout, on.stdout, "{off:?}\n{on:?}");
    assert_eq!(off.stdout, b"status=timed_out\nrefused:timed-out:probe\n");
    assert_eq!(off.status.code(), Some(124));
    assert_eq!(on.status.code(), Some(124));
    assert!(records(&off).is_empty());
    // Second slice: the outer-timeout branch renders records the host holds.
    let actual = records(&on);
    assert_eq!(actual.len(), 1, "{on:?}");
    assert_eq!(actual[0]["argv"][0], "true");
    assert_eq!(actual[0]["code"], 0);
}

// Second slice (2026-10-08): registered async handles that the script never
// waited on are collected from their authentic published Output after
// Scope::cleanup, and the outer-timeout branch renders the trace.
const COLLECTED_BASIS: &str = "launch_request_to_host_collection";

fn by_argv0<'a>(records: &'a [Value], argv0: &str) -> Vec<&'a Value> {
    records.iter().filter(|r| r["argv"][0] == argv0).collect()
}

#[test]
fn trace_outer_timeout_renders_collected_outstanding_async_terminals() {
    let f = Fixture::new();
    // Neither handle is ever waited on, so the dispatcher never pumps their
    // Finished receipts: only the post-cleanup host collector can see them.
    let script = r#"
        local a = proc.spawn{argv={"printf", "collected\n"}}
        local b = proc.spawn{argv={"false"}}
        local c = proc.spawn{argv={"sleep", "30"}}
        assert(proc.run{argv={"sleep", "0.3"}}.ok)
        while true do end
    "#;
    let off = f.run_with_timeout(script, false, "1500ms");
    let on = f.run_with_timeout(script, true, "1500ms");
    assert_eq!(off.stdout, on.stdout, "{off:?}\n{on:?}");
    assert_eq!(off.stdout, b"status=timed_out\nrefused:timed-out:probe\n");
    assert_eq!(off.status.code(), Some(124));
    assert_eq!(on.status.code(), Some(124));
    assert!(records(&off).is_empty(), "{off:?}");
    let actual = records(&on);
    // The blocking proc.run keeps its own receipt duration and no basis label.
    let run = by_argv0(&actual, "sleep");
    assert!(
        run.iter()
            .any(|r| r["argv"][1] == "0.3" && r["code"] == 0 && r.get("wall_basis").is_none()),
        "{on:?}"
    );
    let printf = by_argv0(&actual, "printf");
    assert_eq!(printf.len(), 1, "{on:?}");
    assert_eq!(printf[0]["status"], "exited");
    assert_eq!(printf[0]["code"], 0);
    assert_eq!(printf[0]["wall_basis"], COLLECTED_BASIS);
    let falsy = by_argv0(&actual, "false");
    assert_eq!(falsy.len(), 1, "{on:?}");
    assert_eq!(falsy[0]["status"], "exited");
    assert_eq!(falsy[0]["code"], 1);
    assert_eq!(falsy[0]["wall_basis"], COLLECTED_BASIS);
    // The never-completed sleeper may only carry what the executor actually
    // published when cleanup ended it: never a fabricated clean exit.
    for r in run.iter().filter(|r| r["argv"][1] == "30") {
        assert!(r["code"].is_null(), "{r}");
        assert_ne!(r["status"], "exited", "{r}");
    }
    let mut ids: Vec<_> = actual.iter().map(|r| r["run_id"].clone()).collect();
    ids.sort_by_key(|v| v.to_string());
    ids.dedup();
    assert_eq!(
        ids.len(),
        actual.len(),
        "run ids must be unique: {actual:?}"
    );
    for r in &actual {
        assert!(r["run_id"].as_str().is_some_and(|id| !id.is_empty()));
        assert!(r.get("stdout").is_none());
    }
}

#[test]
fn trace_dropped_unwaited_handle_is_collected_on_verdict_and_on_error() {
    for (ending, exit) in [("verdict.ok('dropped')", 0), ("error('dropped-error')", 1)] {
        let f = Fixture::new();
        let script = format!(
            r#"
            local p = proc.spawn{{argv={{"printf", "dropped\n"}}}}
            p = nil
            collectgarbage(); collectgarbage()
            assert(proc.run{{argv={{"sleep", "0.2"}}}}.ok)
            {ending}
            "#
        );
        let off = f.run(&script, false);
        let on = f.run(&script, true);
        assert_eq!(off.stdout, on.stdout, "{off:?}\n{on:?}");
        assert_eq!(on.status.code(), Some(exit), "{on:?}");
        assert_eq!(off.status.code(), Some(exit));
        let actual = records(&on);
        let printf = by_argv0(&actual, "printf");
        assert_eq!(printf.len(), 1, "{on:?}");
        assert_eq!(printf[0]["status"], "exited");
        assert_eq!(printf[0]["code"], 0);
        assert_eq!(printf[0]["wall_basis"], COLLECTED_BASIS);
        assert_eq!(by_argv0(&actual, "sleep").len(), 1, "{on:?}");
    }
}

#[test]
fn trace_already_delivered_handle_is_not_duplicated_or_relabelled_by_collection() {
    let f = Fixture::new();
    let output = f.run(
        r#"
        local p = proc.spawn{argv={"printf", "waited\n"}}
        out.line("result:" .. json.encode(p:wait()))
        verdict.ok("delivered")
        "#,
        true,
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let actual = records(&output);
    assert_eq!(actual.len(), 1, "{output:?}");
    correlate(&actual[0], &results(&output)[0]);
    assert!(actual[0].get("wall_basis").is_none(), "{output:?}");
}
