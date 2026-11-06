//! Order 2002-stjb: a studio workflow queued as a job, answered with a ticket.
//!
//! @trace order:2002-stjb, spec:imagegen-studio (spec: openspec/changes/studio-asset-pipeline, not yet archived)
//!
//! `studio.run_workflow` blocks its caller for the whole batch, so a long batch
//! needed an agent attending it, and a lane restart lost it. Here:
//!
//! - `studio.queue_workflow` takes the same arguments, checks them as
//!   `run_workflow` would parse them (a malformed request fails at once), writes
//!   a ticket and runs the job on a worker thread through the same
//!   `studio_tool::call`. It answers `{ticket, status: "queued"}` immediately.
//! - `studio.job_status {ticket}` reads the ticket: `queued`, `running`,
//!   `done` (with the run's outputs, exactly what `run_workflow` returns) or
//!   `failed` (with the error).
//!
//! Tickets are JSON files on the HOST, under `<state>/tillandsias/studio-jobs/
//! <project>-<instance>/`, written atomically (temp file + rename). A lane
//! restart therefore keeps every finished ticket and its outputs. A ticket
//! left `queued` or `running` by a process that is no longer alive is reported
//! `failed` with `interrupted: the lane process that ran it (pid N) ended`,
//! never as still running; that verdict is written back once.
#![cfg_attr(not(test), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Value, json};

/// Test seam: the tickets' root directory (never the real state dir under test).
static ROOT_SEAM: Mutex<Option<PathBuf>> = Mutex::new(None);

#[cfg(test)]
pub(crate) fn set_root_for_test(root: Option<PathBuf>) {
    *ROOT_SEAM.lock().unwrap_or_else(|p| p.into_inner()) = root;
}

fn root() -> PathBuf {
    if let Some(r) = ROOT_SEAM.lock().unwrap_or_else(|p| p.into_inner()).clone() {
        return r;
    }
    Path::new(&crate::ca_dir()).with_file_name("studio-jobs")
}

/// A lane's ticket directory. Project and instance labels become one path
/// segment; anything but `[A-Za-z0-9._-]` is replaced, so no label escapes.
fn lane_dir(project: &str, instance: &str) -> PathBuf {
    let clean = |s: &str| -> String {
        s.chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || "._-".contains(c) {
                    c
                } else {
                    '_'
                }
            })
            .collect()
    };
    root().join(format!("{}-{}", clean(project), clean(instance)))
}

/// A ticket names a file, so it must be one we could have issued.
fn valid_ticket(t: &str) -> bool {
    t.starts_with("tk-")
        && t.len() <= 64
        && t.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn new_ticket() -> String {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    static SEQ: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("tk-{stamp}-{}-{n}", std::process::id())
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn write_record(dir: &Path, ticket: &str, rec: &Value) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("runtime_not_ready: studio job store: {e}"))?;
    let tmp = dir.join(format!(".{ticket}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(rec).unwrap_or_default())
        .map_err(|e| format!("runtime_not_ready: studio job store: {e}"))?;
    std::fs::rename(&tmp, dir.join(format!("{ticket}.json"))).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("runtime_not_ready: studio job store: {e}")
    })
}

fn update(dir: &Path, ticket: &str, f: impl FnOnce(&mut Value)) -> Result<(), String> {
    let path = dir.join(format!("{ticket}.json"));
    let mut rec: Value = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({"ticket": ticket}));
    f(&mut rec);
    write_record(dir, ticket, &rec)
}

#[cfg(unix)]
fn pid_alive(pid: u64) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[cfg(not(unix))]
fn pid_alive(_pid: u64) -> bool {
    true
}

/// The runner a queued job uses: `studio_tool::call` in production, a stub
/// under test.
pub(crate) type Runner = dyn Fn(&str, &str, &Value) -> Result<Value, String> + Send + Sync;

fn live_runner(project: &str, instance: &str, args: &Value) -> Result<Value, String> {
    crate::studio_tool::call(project, instance, args, &mut |_| {})
}

/// `studio.queue_workflow`.
pub fn queue(project: &str, instance: &str, args: &Value) -> Result<Value, String> {
    queue_with(project, instance, args, std::sync::Arc::new(live_runner))
}

pub(crate) fn queue_with(
    project: &str,
    instance: &str,
    args: &Value,
    runner: std::sync::Arc<Runner>,
) -> Result<Value, String> {
    // The same request parse run_workflow does, so a malformed call fails now.
    crate::studio_tool::parse_request(args)?;
    let dir = lane_dir(project, instance);
    let ticket = new_ticket();
    write_record(
        &dir,
        &ticket,
        &json!({
            "ticket": ticket,
            "status": "queued",
            "owner_pid": std::process::id(),
            "queued_at": now_secs(),
            "workflow": args.get("workflow").cloned().unwrap_or(Value::Null),
        }),
    )?;
    let (p, i, a, t, d) = (
        project.to_string(),
        instance.to_string(),
        args.clone(),
        ticket.clone(),
        dir.clone(),
    );
    std::thread::Builder::new()
        .name(format!("studio-job-{ticket}"))
        .spawn(move || {
            let _ = update(&d, &t, |r| {
                r["status"] = json!("running");
                r["started_at"] = json!(now_secs());
            });
            let out = runner(&p, &i, &a);
            let _ = update(&d, &t, |r| {
                r["finished_at"] = json!(now_secs());
                match out {
                    Ok(result) => {
                        r["status"] = json!("done");
                        r["result"] = result;
                    }
                    Err(e) => {
                        r["status"] = json!("failed");
                        r["error"] = json!(e);
                    }
                }
            });
        })
        .map_err(|e| format!("runtime_not_ready: studio job worker: {e}"))?;
    Ok(json!({
        "ticket": ticket,
        "status": "queued",
        "note": "poll studio.job_status {ticket}; the ticket survives a lane restart",
    }))
}

/// `studio.job_status`.
pub fn status(project: &str, instance: &str, args: &Value) -> Result<Value, String> {
    status_with(project, instance, args, &pid_alive)
}

pub(crate) fn status_with(
    project: &str,
    instance: &str,
    args: &Value,
    alive: &dyn Fn(u64) -> bool,
) -> Result<Value, String> {
    let ticket = args
        .get("ticket")
        .and_then(Value::as_str)
        .filter(|t| valid_ticket(t))
        .ok_or("invalid_arguments: ticket must be a tk-... value studio.queue_workflow returned")?;
    let dir = lane_dir(project, instance);
    let path = dir.join(format!("{ticket}.json"));
    let mut rec: Value = match std::fs::read(&path) {
        Ok(b) => serde_json::from_slice(&b)
            .map_err(|_| format!("runtime_not_ready: ticket {ticket} is unreadable"))?,
        Err(_) => return Err(format!("not_found: no ticket {ticket} for this lane")),
    };
    let state = rec["status"].as_str().unwrap_or("").to_string();
    let owner = rec["owner_pid"].as_u64().unwrap_or(0);
    if (state == "queued" || state == "running") && owner != 0 && !alive(owner) {
        let why = format!(
            "interrupted: the lane process that ran it (pid {owner}) ended while it was {state}; queue it again"
        );
        rec["status"] = json!("failed");
        rec["error"] = json!(why);
        let _ = write_record(&dir, ticket, &rec);
    }
    Ok(rec)
}

pub fn queue_descriptor() -> Value {
    let mut d = crate::studio_tool::descriptor();
    d["name"] = json!("studio.queue_workflow");
    d["description"] = json!(
        "Queue the same run as studio.run_workflow (same arguments) and return a ticket at once \
         instead of blocking. Poll studio.job_status {ticket}: queued, running, done (with the \
         outputs run_workflow would return) or failed (with its error). Tickets are kept on the \
         host and survive a lane restart; a job its lane process did not live to finish reports \
         failed: interrupted."
    );
    d
}

pub fn status_descriptor() -> Value {
    json!({
        "name": "studio.job_status",
        "description": "The status of a studio.queue_workflow ticket: queued, running, done \
                        (with outputs) or failed (with the error). Survives a lane restart.",
        "inputSchema": {
            "type": "object",
            "properties": {"ticket": {"type": "string", "description": "the tk-... ticket"}},
            "required": ["ticket"],
            "additionalProperties": false
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    static SERIAL: Mutex<()> = Mutex::new(());

    fn wait_for(project: &str, ticket: &str, want: &str) -> Value {
        for _ in 0..200 {
            let r = status_with(project, "a", &json!({"ticket": ticket}), &|_| true).unwrap();
            if r["status"] == want {
                return r;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("ticket {ticket} never reached {want}");
    }

    /// 2002-stjb: queueing answers a ticket at once; status walks queued /
    /// running to done with the run's outputs, or to failed with the error.
    /// Pre-fix: FAILS, there was no queue and no ticket.
    #[test]
    fn a_queued_workflow_returns_a_ticket_at_once_and_reports_its_outputs() {
        let _g = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        let tmp = tempfile::tempdir().unwrap();
        set_root_for_test(Some(tmp.path().to_path_buf()));
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let rx = Mutex::new(rx);
        let runner: Arc<Runner> = Arc::new(move |_, _, args: &Value| {
            rx.lock().unwrap().recv().ok();
            if args["workflow"] == "tool/sfx/bad.api.json" {
                Err("engine_failed: studio execution failed: KSampler".into())
            } else {
                Ok(
                    json!({"outputs": [{"path": "/work/tmp/imagegen/studio/st-1/0/x.flac", "kind": "audio"}]}),
                )
            }
        });
        let t0 = std::time::Instant::now();
        let q = queue_with(
            "game",
            "a",
            &json!({"workflow": "tool/sfx/ok.api.json"}),
            runner.clone(),
        )
        .unwrap();
        assert!(
            t0.elapsed() < std::time::Duration::from_secs(2),
            "answered at once"
        );
        let ticket = q["ticket"].as_str().unwrap().to_string();
        assert_eq!(q["status"], "queued");
        let mid = status_with("game", "a", &json!({"ticket": ticket}), &|_| true).unwrap();
        assert!(
            mid["status"] == "queued" || mid["status"] == "running",
            "{mid}"
        );
        tx.send(()).unwrap();
        let done = wait_for("game", &ticket, "done");
        assert_eq!(done["result"]["outputs"][0]["kind"], "audio");

        let bad = queue_with(
            "game",
            "a",
            &json!({"workflow": "tool/sfx/bad.api.json"}),
            runner,
        )
        .unwrap();
        tx.send(()).unwrap();
        let failed = wait_for("game", bad["ticket"].as_str().unwrap(), "failed");
        assert!(
            failed["error"].as_str().unwrap().contains("KSampler"),
            "{failed}"
        );

        // A malformed request fails at once and issues no ticket.
        let e = queue_with("game", "a", &json!({}), Arc::new(|_, _, _| Ok(json!({})))).unwrap_err();
        assert!(e.starts_with("invalid_arguments"), "{e}");
        set_root_for_test(None);
    }

    /// 2002-stjb: after a lane restart (a new process reading the same store,
    /// the old pid gone) a finished ticket reports the same status and
    /// outputs, and a ticket its process left running is failed: interrupted,
    /// never "running" forever. Pre-fix: FAILS, a restart lost every job.
    #[test]
    fn a_ticket_survives_a_lane_restart() {
        let _g = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        let tmp = tempfile::tempdir().unwrap();
        set_root_for_test(Some(tmp.path().to_path_buf()));
        let dir = lane_dir("game", "a");
        // What the previous lane process (pid 4242) left on disk.
        write_record(&dir, "tk-1-4242-0", &json!({"ticket": "tk-1-4242-0", "status": "done",
            "owner_pid": 4242, "result": {"outputs": [{"path": "/work/tmp/imagegen/studio/st-9/0/a.flac"}]}})).unwrap();
        write_record(
            &dir,
            "tk-1-4242-1",
            &json!({"ticket": "tk-1-4242-1", "status": "running",
            "owner_pid": 4242}),
        )
        .unwrap();
        let dead = |pid: u64| pid != 4242;
        let done = status_with("game", "a", &json!({"ticket": "tk-1-4242-0"}), &dead).unwrap();
        assert_eq!(done["status"], "done");
        assert_eq!(
            done["result"]["outputs"][0]["path"],
            "/work/tmp/imagegen/studio/st-9/0/a.flac"
        );
        let lost = status_with("game", "a", &json!({"ticket": "tk-1-4242-1"}), &dead).unwrap();
        assert_eq!(lost["status"], "failed");
        assert!(
            lost["error"].as_str().unwrap().contains("interrupted")
                && lost["error"].as_str().unwrap().contains("4242")
        );
        // Written back: a later read without the liveness check agrees.
        let again = status_with("game", "a", &json!({"ticket": "tk-1-4242-1"}), &|_| true).unwrap();
        assert_eq!(again["status"], "failed");
        // Another lane cannot read it, and a forged ticket names no file.
        assert!(
            status_with("game", "b", &json!({"ticket": "tk-1-4242-0"}), &dead)
                .unwrap_err()
                .starts_with("not_found")
        );
        assert!(
            status_with(
                "game",
                "a",
                &json!({"ticket": "../../ca/intermediate"}),
                &dead
            )
            .unwrap_err()
            .starts_with("invalid_arguments")
        );
        set_root_for_test(None);
    }
}
