use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::env;
use std::error::Error;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio::task;
use tokio::time;

type AnyError = Box<dyn Error + Send + Sync>;

const DEFAULT_PROFILE: &str = "tillandsias";

const PROMPT_PREFIX: &str = "Repeat-mode automation contract:\n\
- Return exactly one compact JSON object as the final response.\n\
- Do not stream file-by-file diffs, chain-of-thought, or raw tool chatter.\n\
- Use the repo-local plan and methodology as the source of truth.\n\
- Emit an immediate bootstrap refinement note in ./methodology/events/ or ./plan/issues/ before making edits.\n\
- Refresh that note after each meaningful substep, blocker, or verification milestone.\n\
- Do not wait until the end of the session to produce the first update.\n\
- Do not finalize the session until you have created at least one visible bootstrap note or documented a blocking reason with the chosen graph node.\n\
- While working, file refinement notes or ambiguity updates in ./methodology/events/ or ./plan/issues/ as soon as a meaningful substep completes or a blocker appears.\n\
- Each refinement note must be idempotent and cold-start readable; assume a different agent may pick up the next step.\n\
- If you are actively working but have nothing new to say, update the existing note rather than remaining silent.\n\
- If cheaply available from existing metadata, include tokens_spent, prompt_tokens, completion_tokens, tokens_remaining_percent, and rate_limit_remaining_percent in the final report and in any relevant task-tree nodes.\n\
- Provide before_progress, after_progress, delta_progress, trend_window, milestone_label, milestone_timestamp, next_action, blockers, checkpoint_commit, status, session_id, focus_task_id, ready_count, blocked_count, loop_state, and a compact task_tree if available.\n\
- Keep the answer minimal, tree-friendly, and cold-start readable.\n";

#[derive(Debug, Clone)]
struct RepeatArgs {
    prompt: String,
    interval: String,
    codex_bin: PathBuf,
    renderer_bin: PathBuf,
    state_root: PathBuf,
    plan_root: PathBuf,
    trend_window: usize,
    refresh_secs: u64,
}

#[derive(Debug)]
enum Signal {
    StdoutLine(String),
    FsChanged,
}

fn parse_args() -> Result<RepeatArgs, AnyError> {
    let mut prompt = None;
    let mut interval = None;
    let mut codex_bin = env::var_os("CODEX_BIN").map(PathBuf::from);
    let mut renderer_bin = None;
    let mut state_root = env::var_os("CODEX_REPEAT_STATE_DIR").map(PathBuf::from);
    let mut plan_root = env::current_dir()?.join("plan");
    let mut trend_window = env::var("CODEX_REPEAT_TREND_WINDOW")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(5);
    let mut refresh_secs = env::var("CODEX_REPEAT_REFRESH_SECS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(2);

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--prompt" => prompt = args.next(),
            "--interval" => interval = args.next(),
            "--codex-bin" => codex_bin = args.next().map(PathBuf::from),
            "--renderer-bin" => renderer_bin = args.next().map(PathBuf::from),
            "--state-root" => state_root = args.next().map(PathBuf::from),
            "--plan-root" => plan_root = PathBuf::from(args.next().unwrap_or_else(|| "plan".to_string())),
            "--trend-window" => {
                trend_window = args
                    .next()
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(trend_window);
            }
            "--refresh-secs" => {
                refresh_secs = args
                    .next()
                    .and_then(|value| value.parse::<u64>().ok())
                    .unwrap_or(refresh_secs);
            }
            _ if prompt.is_none() => prompt = Some(arg),
            _ if interval.is_none() => interval = Some(arg),
            _ => {}
        }
    }

    let prompt = prompt.ok_or("missing prompt")?;
    let interval = interval.ok_or("missing interval")?;
    let codex_bin = codex_bin.unwrap_or_else(|| find_in_path("codex").unwrap_or_else(|| PathBuf::from("codex")));
    let renderer_bin = renderer_bin.unwrap_or_else(|| env::current_dir().unwrap().join("target/debug/tillandsias-repeat-graph"));
    let state_root = state_root.unwrap_or_else(|| env::current_dir().unwrap().join("plan/localwork/codex-repeat"));

    Ok(RepeatArgs {
        prompt,
        interval,
        codex_bin,
        renderer_bin,
        state_root,
        plan_root,
        trend_window,
        refresh_secs,
    })
}

fn find_in_path(binary: &str) -> Option<PathBuf> {
    let path_var = env::var_os("PATH")?;
    for path in env::split_paths(&path_var) {
        let candidate = path.join(binary);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn write_schema(schema_file: &Path) -> Result<(), AnyError> {
    let schema = r#"{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "session_id",
    "cycle",
    "branch",
    "status",
    "before_progress",
    "after_progress",
    "delta_progress",
    "trend_window",
    "elapsed_seconds",
    "elapsed_human",
    "milestone_label",
    "milestone_timestamp",
    "next_action",
    "blockers",
    "checkpoint_commit",
    "output_mode"
  ],
  "properties": {
    "session_id": { "type": "string" },
    "cycle": { "type": "integer", "minimum": 1 },
    "branch": { "type": "string" },
    "status": { "type": "string" },
    "before_progress": { "type": "integer", "minimum": 0, "maximum": 100 },
    "after_progress": { "type": "integer", "minimum": 0, "maximum": 100 },
    "delta_progress": { "type": "integer" },
    "trend_window": {
      "type": "array",
      "items": { "type": "integer", "minimum": 0, "maximum": 100 }
    },
    "current_bar": { "type": "string" },
    "trend_bar": { "type": "string" },
    "elapsed_seconds": { "type": "integer", "minimum": 0 },
    "elapsed_human": { "type": "string" },
    "milestone_label": { "type": "string" },
    "milestone_timestamp": { "type": "string" },
    "next_action": { "type": "string" },
    "blockers": {
      "type": "array",
      "items": { "type": "string" }
    },
    "checkpoint_commit": { "type": "string" },
    "focus_task_id": { "type": "string" },
    "ready_count": { "type": "integer" },
    "blocked_count": { "type": "integer" },
    "tokens_spent": { "type": "integer" },
    "prompt_tokens": { "type": "integer" },
    "completion_tokens": { "type": "integer" },
    "tokens_remaining_percent": { "type": "integer", "minimum": 0, "maximum": 100 },
    "rate_limit_remaining_percent": { "type": "integer", "minimum": 0, "maximum": 100 },
    "task_tree": { "type": "array" },
    "loop_state": { "type": "string" },
    "output_mode": { "type": "string" }
  }
}"#;
    fs::write(schema_file, schema)?;
    Ok(())
}

fn ensure_dir(path: &Path) -> Result<(), AnyError> {
    if !path.exists() {
        fs::create_dir_all(path)?;
    }
    Ok(())
}

fn ensure_renderer(renderer_bin: &Path) -> Result<(), AnyError> {
    if renderer_bin.is_file() {
        return Ok(());
    }
    let status = std::process::Command::new("cargo")
        .args([
            "build",
            "--quiet",
            "--offline",
            "--manifest-path",
            "crates/tillandsias-repeat-graph/Cargo.toml",
        ])
        .status()?;
    if !status.success() {
        return Err("failed to build repeat renderer".into());
    }
    if renderer_bin.is_file() {
        Ok(())
    } else {
        Err(format!("missing renderer binary: {}", renderer_bin.display()).into())
    }
}

fn format_elapsed(total: i64) -> String {
    let total = total.max(0);
    let hours = total / 3600;
    let minutes = (total % 3600) / 60;
    let seconds = total % 60;
    if hours > 0 {
        format!("{hours:02}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

fn parse_interval(input: &str) -> Result<Duration, AnyError> {
    let mut total = 0u64;
    let mut number = String::new();
    for ch in input.chars() {
        if ch.is_ascii_digit() {
            number.push(ch);
            continue;
        }
        let value = number.parse::<u64>()?;
        number.clear();
        total += match ch {
            'h' => value.saturating_mul(3600),
            'm' => value.saturating_mul(60),
            's' => value,
            _ => return Err(format!("invalid interval suffix: {ch}").into()),
        };
    }
    if !number.is_empty() {
        total += number.parse::<u64>()?;
    }
    Ok(Duration::from_secs(total.max(1)))
}

fn current_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|dur| dur.as_secs() as i64)
        .unwrap_or(0)
}

fn repeat_prompt_prefix() -> &'static str {
    PROMPT_PREFIX
}

async fn render_snapshot(
    renderer_bin: PathBuf,
    plan_index: PathBuf,
    event_log: PathBuf,
    last_message: PathBuf,
    history: PathBuf,
    session_id: String,
    cycle: i64,
    start_epoch: i64,
    loop_state: String,
    exit_code: i32,
    sleep_interval: String,
) -> Result<(), AnyError> {
    task::spawn_blocking(move || {
        let status = std::process::Command::new(renderer_bin)
            .args([
                plan_index.as_os_str(),
                event_log.as_os_str(),
                last_message.as_os_str(),
                history.as_os_str(),
                OsStr::new(&session_id),
                OsStr::new(&cycle.to_string()),
                OsStr::new(&start_epoch.to_string()),
                OsStr::new(&loop_state),
                OsStr::new(&exit_code.to_string()),
                OsStr::new(&sleep_interval),
            ])
            .status()?;
        if status.success() { Ok(()) } else { Err(format!("renderer exited with {status}").into()) }
    })
    .await?
}

fn print_cycle_start(session_id: &str, cycle: i64, interval: &str, elapsed: i64) {
    println!(
        "[codex-repeat] cycle {:02} start | waiting on agent | session={} | interval={} | elapsed={}",
        cycle,
        session_id,
        interval,
        format_elapsed(elapsed)
    );
}

fn print_sleeping(cycle: i64, status: i32, interval: &str) {
    println!(
        "[codex-repeat] cycle {:02} sleeping until next iteration | exit={} | sleep={}",
        cycle, status, interval
    );
}

fn count_lines(path: &Path) -> usize {
    fs::read_to_string(path)
        .map(|content| content.lines().count())
        .unwrap_or(0)
}

async fn run() -> Result<(), AnyError> {
    let args = parse_args()?;
    ensure_renderer(&args.renderer_bin)?;

    ensure_dir(&args.state_root)?;
    let session_id = format!("repeat-{}-{}", chrono_like_timestamp(), std::process::id());
    let session_dir = args.state_root.join(format!("session.{}", chrono_like_timestamp()));
    ensure_dir(&session_dir)?;

    let schema_file = session_dir.join("report-schema.json");
    let last_message_file = session_dir.join("last-message.json");
    let event_log_file = session_dir.join("events.jsonl");
    let stderr_file = session_dir.join("stderr.log");
    let history_file = session_dir.join("history.txt");
    write_schema(&schema_file)?;

    let (signal_tx, mut signal_rx) = mpsc::unbounded_channel::<Signal>();
    let watch_root = env::current_dir()?;
    let methodology_events = watch_root.join("methodology/events");
    let plan_issues = watch_root.join("plan/issues");
    ensure_dir(&methodology_events)?;
    ensure_dir(&plan_issues)?;

    let signal_tx_fs = signal_tx.clone();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| {
            if res.is_ok() {
                let _ = signal_tx_fs.send(Signal::FsChanged);
            }
        },
        Config::default(),
    )?;
    watcher.watch(&methodology_events, RecursiveMode::Recursive)?;
    watcher.watch(&plan_issues, RecursiveMode::Recursive)?;

    let prompt = format!("{}\n\n{}", repeat_prompt_prefix(), args.prompt);
    let interval = parse_interval(&args.interval)?;
    let start_epoch = current_epoch();
    let mut cycle: i64 = 0;
    let mut history_values: Vec<i64> = Vec::new();

    loop {
        cycle += 1;
        fs::write(&event_log_file, "")?;
        print_cycle_start(&session_id, cycle, &args.interval, current_epoch() - start_epoch);
        render_snapshot(
            args.renderer_bin.clone(),
            args.plan_root.join("index.yaml"),
            event_log_file.clone(),
            last_message_file.clone(),
            history_file.clone(),
            session_id.clone(),
            cycle,
            start_epoch,
            "agent_working".to_string(),
            0,
            String::new(),
        )
        .await?;

        let mut codex_cmd = if let Some(stdbuf) = find_in_path("stdbuf") {
            let mut cmd = Command::new(stdbuf);
            cmd.args(["-oL", "-eL", args.codex_bin.to_string_lossy().as_ref()]);
            cmd
        } else {
            Command::new(&args.codex_bin)
        };

        codex_cmd.args([
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--color",
            "never",
            "--json",
            "--output-schema",
            schema_file.to_string_lossy().as_ref(),
            "--output-last-message",
            last_message_file.to_string_lossy().as_ref(),
            "-p",
            DEFAULT_PROFILE,
            "-c",
            r#"profiles.tillandsias.writable_roots=["/run/user/1000","/var/home/machiyotl"]"#,
        ]);
        codex_cmd.stdin(Stdio::piped());
        codex_cmd.stdout(Stdio::piped());
        codex_cmd.stderr(Stdio::piped());
        let mut child = codex_cmd.spawn()?;

        if let Some(mut stdin) = child.stdin.take() {
            let prompt = prompt.clone();
            tokio::spawn(async move {
                use tokio::io::AsyncWriteExt;
                let _ = stdin.write_all(prompt.as_bytes()).await;
            });
        }

        let stdout = child.stdout.take().ok_or("missing stdout pipe")?;
        let stderr = child.stderr.take().ok_or("missing stderr pipe")?;
        let tx_stdout = signal_tx.clone();
        let tx_stderr = signal_tx.clone();
        let event_log_clone = event_log_file.clone();
        let stderr_clone = stderr_file.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(mut file) = tokio::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&event_log_clone)
                    .await
                {
                    let _ = tokio::io::AsyncWriteExt::write_all(&mut file, line.as_bytes()).await;
                    let _ = tokio::io::AsyncWriteExt::write_all(&mut file, b"\n").await;
                }
                let _ = tx_stdout.send(Signal::StdoutLine(line));
            }
        });
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(mut file) = tokio::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&stderr_clone)
                    .await
                {
                    let _ = tokio::io::AsyncWriteExt::write_all(&mut file, line.as_bytes()).await;
                    let _ = tokio::io::AsyncWriteExt::write_all(&mut file, b"\n").await;
                }
                let _ = tx_stderr.send(Signal::FsChanged);
            }
        });

        let mut tick = time::interval(Duration::from_secs(args.refresh_secs.max(1)));
        let mut last_signature = String::new();
        let mut child_exit = 0;
        let mut child_finished = false;

        loop {
            tokio::select! {
                maybe_signal = signal_rx.recv() => {
                    match maybe_signal {
                        Some(Signal::StdoutLine(_line)) => {
                            let sig = format!("stdout:{}", count_lines(&event_log_file));
                            if sig != last_signature {
                                last_signature = sig;
                                render_snapshot(
                                    args.renderer_bin.clone(),
                                    args.plan_root.join("index.yaml"),
                                    event_log_file.clone(),
                                    last_message_file.clone(),
                                    history_file.clone(),
                                    session_id.clone(),
                                    cycle,
                                    start_epoch,
                                    "agent_working".to_string(),
                                    0,
                                    String::new(),
                                ).await?;
                            }
                        }
                        Some(Signal::FsChanged) => {
                            let sig = format!("fs:{}:{}", count_lines(&event_log_file), count_lines(&history_file));
                            if sig != last_signature {
                                last_signature = sig;
                                render_snapshot(
                                    args.renderer_bin.clone(),
                                    args.plan_root.join("index.yaml"),
                                    event_log_file.clone(),
                                    last_message_file.clone(),
                                    history_file.clone(),
                                    session_id.clone(),
                                    cycle,
                                    start_epoch,
                                    "agent_working".to_string(),
                                    0,
                                    String::new(),
                                ).await?;
                            }
                        }
                        None => break,
                    }
                }
                _ = tick.tick() => {
                    render_snapshot(
                        args.renderer_bin.clone(),
                        args.plan_root.join("index.yaml"),
                        event_log_file.clone(),
                        last_message_file.clone(),
                        history_file.clone(),
                        session_id.clone(),
                        cycle,
                        start_epoch,
                        "agent_working".to_string(),
                        0,
                        String::new(),
                    ).await?;
                }
                status = child.wait(), if !child_finished => {
                    child_exit = status?.code().unwrap_or(1);
                    child_finished = true;
                }
            }
            if child_finished {
                break;
            }
        }

        let report_json = tokio::fs::read_to_string(&last_message_file).await.unwrap_or_else(|_| {
            "{\"session_id\":\"".to_string() + &session_id + "\",\"cycle\":1,\"branch\":\"linux-next\",\"status\":\"failed\",\"before_progress\":0,\"after_progress\":0,\"delta_progress\":0,\"trend_window\":[],\"elapsed_seconds\":0,\"elapsed_human\":\"00:00\",\"milestone_label\":\"fallback\",\"milestone_timestamp\":\"\",\"next_action\":\"inspect stderr log\",\"blockers\":[\"no structured report emitted\"],\"checkpoint_commit\":\"\",\"focus_task_id\":\"\",\"ready_count\":0,\"blocked_count\":0,\"task_tree\":[],\"loop_state\":\"running\",\"output_mode\":\"compact-json\"}"
        });
        let after_progress = extract_after_progress(&report_json).unwrap_or(0);
        history_values.push(after_progress);
        while history_values.len() > args.trend_window {
            history_values.remove(0);
        }
        let history_text = history_values
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        tokio::fs::write(&history_file, format!("{history_text}\n")).await?;

        render_snapshot(
            args.renderer_bin.clone(),
            args.plan_root.join("index.yaml"),
            event_log_file.clone(),
            last_message_file.clone(),
            history_file.clone(),
            session_id.clone(),
            cycle,
            start_epoch,
            "sleeping_until_next_iteration".to_string(),
            child_exit,
            args.interval.clone(),
        )
        .await?;
        print_sleeping(cycle, child_exit, &args.interval);

        time::sleep(interval).await;
    }
}

fn chrono_like_timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|dur| dur.as_secs())
        .unwrap_or(0);
    format!("{now}")
}

fn extract_after_progress(report_json: &str) -> Option<i64> {
    let parsed: serde_json::Value = serde_json::from_str(report_json).ok()?;
    parsed.get("after_progress").and_then(|value| value.as_i64())
}

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("[codex-repeat] {err}");
        std::process::exit(2);
    }
}
