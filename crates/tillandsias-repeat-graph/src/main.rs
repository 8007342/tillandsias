use serde::Deserialize;
use serde_json::Value as JsonValue;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::IsTerminal;
use std::path::PathBuf;

const ACTIVE_STATUS_VALUES: &[&str] = &[
    "bootstrapping",
    "reading",
    "planning",
    "claimed",
    "editing",
    "verifying",
    "blocked",
    "stale",
    "in_progress",
    "done",
    "failed",
    "ready",
    "running",
];

#[derive(Debug, Deserialize, Default)]
struct PlanFile {
    #[serde(default)]
    plan_index: Option<PlanIndex>,
    #[serde(default)]
    current_state: Option<CurrentState>,
}

#[derive(Debug, Deserialize, Default)]
struct PlanIndex {
    #[serde(default)]
    steps: Vec<Node>,
}

#[derive(Debug, Deserialize, Default)]
struct CurrentState {
    #[serde(default)]
    next_graph_node: Option<String>,
    #[serde(default)]
    next_step: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
struct Node {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    outcome: Option<String>,
    #[serde(default)]
    deliverable: Option<String>,
    #[serde(default)]
    resume_prompt: Option<String>,
    #[serde(default)]
    handoff_note: Option<String>,
    #[serde(default)]
    tasks: Vec<Node>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize, Default, Clone)]
struct EventRecord {
    #[serde(default)]
    event_id: Option<String>,
    #[serde(default)]
    parent_event_id: Option<String>,
    #[serde(default)]
    task_id: Option<String>,
    #[serde(default)]
    graph_node_id: Option<String>,
    #[serde(default)]
    spec_id: Option<String>,
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default)]
    lamport_clock: Option<i64>,
    #[serde(default)]
    event_seq: Option<i64>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    progress: Option<i64>,
    #[serde(default)]
    summary: Option<String>,
    #[serde(default)]
    timestamp: Option<String>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize, Default)]
struct RepeatReport {
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    cycle: Option<i64>,
    #[serde(default)]
    branch: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    before_progress: Option<i64>,
    #[serde(default)]
    after_progress: Option<i64>,
    #[serde(default)]
    delta_progress: Option<i64>,
    #[serde(default)]
    trend_window: Option<Vec<i64>>,
    #[serde(default)]
    elapsed_seconds: Option<i64>,
    #[serde(default)]
    milestone_label: Option<String>,
    #[serde(default)]
    milestone_timestamp: Option<String>,
    #[serde(default)]
    next_action: Option<String>,
    #[serde(default)]
    blockers: Option<Vec<String>>,
    #[serde(default)]
    checkpoint_commit: Option<String>,
    #[serde(default)]
    focus_task_id: Option<String>,
    #[serde(default)]
    ready_count: Option<i64>,
    #[serde(default)]
    blocked_count: Option<i64>,
    #[serde(default)]
    task_tree: Option<JsonValue>,
    #[serde(default)]
    loop_state: Option<String>,
}

#[derive(Debug, Clone)]
struct NodeInfo {
    id: String,
    title: String,
    status: String,
    summary: String,
    parent_id: Option<String>,
    children: Vec<String>,
}

#[derive(Debug, Clone, Default)]
struct Overlay {
    status: Option<String>,
    progress: Option<i64>,
    summary: Option<String>,
}

fn clamp(value: i64) -> i64 {
    value.clamp(0, 100)
}

fn progress_bar(value: i64, width: usize) -> String {
    let clamped = clamp(value);
    let filled = ((clamped as usize) * width + 50) / 100;
    let empty = width.saturating_sub(filled);
    format!("{}{}", "█".repeat(filled), "░".repeat(empty))
}

fn spark(value: i64) -> char {
    match clamp(value) {
        0..=12 => '▁',
        13..=24 => '▂',
        25..=37 => '▃',
        38..=49 => '▄',
        50..=62 => '▅',
        63..=74 => '▆',
        75..=87 => '▇',
        _ => '█',
    }
}

fn summarize(text: &str, limit: usize) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= limit {
        compact
    } else {
        let mut out = String::new();
        for ch in compact.chars().take(limit.saturating_sub(1)) {
            out.push(ch);
        }
        out.push('…');
        out
    }
}

fn active_status(status: &str) -> bool {
    ACTIVE_STATUS_VALUES.iter().any(|value| value == &status)
}

fn read_to_string(path: &PathBuf) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

fn read_jsonl(path: &PathBuf) -> Vec<EventRecord> {
    let mut rows = Vec::new();
    let content = read_to_string(path);
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(row) = serde_json::from_str::<EventRecord>(line) {
            rows.push(row);
        }
    }
    rows
}

fn load_plan(path: &PathBuf) -> PlanFile {
    let content = read_to_string(path);
    serde_yaml::from_str::<PlanFile>(&content).unwrap_or_default()
}

fn load_report(path: &PathBuf) -> RepeatReport {
    let content = read_to_string(path);
    serde_json::from_str::<RepeatReport>(&content).unwrap_or_default()
}

fn build_index(steps: &[Node]) -> BTreeMap<String, NodeInfo> {
    fn walk(
        node: &Node,
        parent_id: Option<String>,
        index: &mut BTreeMap<String, NodeInfo>,
    ) {
        let id = node
            .id
            .clone()
            .unwrap_or_else(|| node.title.clone().unwrap_or_else(|| format!("node-{}", index.len())));
        let title = node
            .title
            .clone()
            .unwrap_or_else(|| id.clone());
        let status = node.status.clone().unwrap_or_else(|| "pending".to_string());
        let summary = node
            .handoff_note
            .clone()
            .or_else(|| node.outcome.clone())
            .or_else(|| node.resume_prompt.clone())
            .or_else(|| node.deliverable.clone())
            .unwrap_or_else(|| title.clone());
        index.insert(
            id.clone(),
            NodeInfo {
                id: id.clone(),
                title,
                status,
                summary,
                parent_id: parent_id.clone(),
                children: Vec::new(),
            },
        );
        for child in &node.tasks {
            let child_id = child
                .id
                .clone()
                .unwrap_or_else(|| child.title.clone().unwrap_or_else(|| format!("node-{}", index.len())));
            if let Some(parent) = index.get_mut(&id) {
                parent.children.push(child_id.clone());
            }
            walk(child, Some(id.clone()), index);
        }
    }

    let mut index = BTreeMap::new();
    for node in steps {
        walk(node, None, &mut index);
    }
    index
}

fn focus_path(index: &BTreeMap<String, NodeInfo>, focus: &str) -> BTreeSet<String> {
    let mut path = BTreeSet::new();
    let mut current = focus.to_string();
    while let Some(node) = index.get(&current) {
        path.insert(current.clone());
        if let Some(parent) = &node.parent_id {
            current = parent.clone();
        } else {
            break;
        }
    }
    path
}

fn node_visible(
    node_id: &str,
    index: &BTreeMap<String, NodeInfo>,
    overlay: &BTreeMap<String, Overlay>,
    focus_path: &BTreeSet<String>,
) -> bool {
    if focus_path.contains(node_id) {
        return true;
    }
    if let Some(node) = index.get(node_id) {
        let status = overlay
            .get(node_id)
            .and_then(|o| o.status.clone())
            .unwrap_or_else(|| node.status.clone());
        if active_status(&status) {
            return true;
        }
        for child_id in &node.children {
            if node_visible(child_id, index, overlay, focus_path) {
                return true;
            }
        }
    }
    false
}

fn node_progress(node_id: &str, index: &BTreeMap<String, NodeInfo>, overlay: &BTreeMap<String, Overlay>) -> i64 {
    if let Some(overlay) = overlay.get(node_id) {
        if let Some(progress) = overlay.progress {
            return clamp(progress);
        }
    }
    if let Some(node) = index.get(node_id) {
        if active_status(&node.status) {
            return match node.status.as_str() {
                "completed" | "done" | "obsoleted" => 100,
                "failed" => 10,
                "blocked" => 15,
                "stale" => 20,
                "bootstrapping" => 18,
                "reading" => 30,
                "planning" => 40,
                "claimed" => 48,
                "editing" => 64,
                "verifying" => 78,
                "ready" => 26,
                "running" => 52,
                _ => 8,
            };
        }
    }
    0
}

fn node_summary(node_id: &str, index: &BTreeMap<String, NodeInfo>, overlay: &BTreeMap<String, Overlay>) -> String {
    if let Some(overlay) = overlay.get(node_id) {
        if let Some(summary) = &overlay.summary {
            return summarize(summary, 56);
        }
    }
    index
        .get(node_id)
        .map(|node| summarize(&node.summary, 56))
        .unwrap_or_default()
}

fn render_node(
    node_id: &str,
    index: &BTreeMap<String, NodeInfo>,
    overlay: &BTreeMap<String, Overlay>,
    focus_path: &BTreeSet<String>,
    out: &mut Vec<String>,
    prefix: String,
    last: bool,
) {
    let Some(node) = index.get(node_id) else {
        return;
    };
    let visible_children: Vec<String> = node
        .children
        .iter()
        .filter(|child| node_visible(child, index, overlay, focus_path))
        .cloned()
        .collect();
    if !node_visible(node_id, index, overlay, focus_path) && visible_children.is_empty() {
        return;
    }
    let connector = if last { "└─" } else { "├─" };
    let label = if focus_path.contains(node_id) && focus_path.len() > 1 && node_id != focus_path.iter().last().cloned().unwrap_or_default() {
        format!("• {}", node.title)
    } else if focus_path.contains(node_id) {
        format!("▶ {}", node.title)
    } else {
        node.title.clone()
    };
    let progress = node_progress(node_id, index, overlay);
    let status = overlay
        .get(node_id)
        .and_then(|o| o.status.clone())
        .unwrap_or_else(|| node.status.clone());
    let summary = node_summary(node_id, index, overlay);
    out.push(format!(
        "{prefix}{connector} {label:<44} [{}] {:3}% {status} · {summary}",
        progress_bar(progress, 12),
        progress
    ));
    if !visible_children.is_empty() {
        let next_prefix = format!("{prefix}{}", if last { "   " } else { "│  " });
        for (idx, child_id) in visible_children.iter().enumerate() {
            render_node(
                child_id,
                index,
                overlay,
                focus_path,
                out,
                next_prefix.clone(),
                idx == visible_children.len() - 1,
            );
        }
    }
}

fn build_overlay(
    index: &BTreeMap<String, NodeInfo>,
    events: &[EventRecord],
    report: &RepeatReport,
    focus_hint: &str,
) -> BTreeMap<String, Overlay> {
    let mut overlay: BTreeMap<String, Overlay> = BTreeMap::new();
    let mut event_task_by_id: BTreeMap<String, String> = BTreeMap::new();

    for (idx, event) in events.iter().enumerate() {
        let task_key = event
            .task_id
            .clone()
            .or_else(|| event.graph_node_id.clone())
            .or_else(|| event.spec_id.clone())
            .or_else(|| if focus_hint.is_empty() { None } else { Some(focus_hint.to_string()) })
            .unwrap_or_default();
        if task_key.is_empty() || !index.contains_key(&task_key) {
            continue;
        }
        if let Some(event_id) = &event.event_id {
            event_task_by_id.insert(event_id.clone(), task_key.clone());
        }
        let entry = overlay.entry(task_key.clone()).or_default();
        if let Some(status) = &event.status {
            entry.status = Some(status.clone());
        }
        if let Some(progress) = event.progress {
            entry.progress = Some(progress);
        }
        if let Some(summary) = &event.summary {
            entry.summary = Some(summary.clone());
        }
        let _ = idx; // keep deterministic iteration ordering intent explicit.
    }

    if let Some(focus) = report.focus_task_id.clone().or_else(|| {
        if focus_hint.is_empty() {
            None
        } else {
            Some(focus_hint.to_string())
        }
    }) {
        if index.contains_key(&focus) {
            let entry = overlay.entry(focus).or_default();
            if let Some(status) = &report.status {
                entry.status = Some(status.clone());
            }
            if let Some(progress) = report.after_progress {
                entry.progress = Some(progress);
            }
            if let Some(summary) = &report.next_action {
                entry.summary = Some(summary.clone());
            } else if let Some(label) = &report.milestone_label {
                entry.summary = Some(label.clone());
            }
        }
    }

    overlay
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

fn main() {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if args.len() < 10 {
        eprintln!("[codex-repeat] renderer received too few arguments");
        std::process::exit(2);
    }

    let plan_path = PathBuf::from(args.remove(0));
    let events_path = PathBuf::from(args.remove(0));
    let report_path = PathBuf::from(args.remove(0));
    let history_path = PathBuf::from(args.remove(0));
    let session_id = args.remove(0);
    let cycle = args.remove(0).parse::<i64>().unwrap_or(0);
    let start_epoch = args.remove(0).parse::<i64>().unwrap_or(0);
    let loop_state = args.remove(0);
    let exit_code = args.remove(0);
    let sleep_interval = args.remove(0);

    let plan = load_plan(&plan_path);
    let report = load_report(&report_path);
    let events = read_jsonl(&events_path);
    let history = read_to_string(&history_path)
        .lines()
        .filter_map(|line| line.trim().parse::<i64>().ok())
        .collect::<Vec<_>>();

    let plan_root = plan.plan_index.unwrap_or_default();
    let index = build_index(&plan_root.steps);
    let plan_focus = plan
        .current_state
        .and_then(|state| state.next_graph_node.or(state.next_step))
        .unwrap_or_default();
    let focus_hint = report
        .focus_task_id
        .clone()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| plan_focus.clone());
    let overlay = build_overlay(&index, &events, &report, &focus_hint);
    let focus_path = focus_path(&index, &focus_hint);

    let before = report.before_progress.unwrap_or(0);
    let after = report.after_progress.unwrap_or(0);
    let delta = report.delta_progress.unwrap_or(after - before);
    let trend_values = if history.is_empty() {
        vec![after]
    } else {
        history.iter().rev().take(12).cloned().collect::<Vec<_>>().into_iter().rev().collect()
    };
    let trend_bar = trend_values.iter().map(|value| spark(*value)).collect::<String>();
    let trend_avg = if trend_values.is_empty() {
        0.0
    } else {
        trend_values.iter().sum::<i64>() as f64 / trend_values.len() as f64
    };
    let latest = trend_values.last().copied().unwrap_or(after);
    let previous = trend_values
        .get(trend_values.len().saturating_sub(2))
        .copied()
        .unwrap_or(before);
    let elapsed = report.elapsed_seconds.unwrap_or_else(|| {
        let now = chrono_like_now();
        (now - start_epoch).max(0)
    });
    let milestone_label = report
        .milestone_label
        .clone()
        .unwrap_or_else(|| "milestone".to_string());
    let milestone_timestamp = report.milestone_timestamp.clone().unwrap_or_default();
    let milestone_stamp = if milestone_timestamp.is_empty() {
        milestone_label
    } else {
        format!("{milestone_label}@{milestone_timestamp}")
    };
    let next_action = summarize(
        &report
            .next_action
            .clone()
            .unwrap_or_else(|| "continue".to_string()),
        72,
    );
    let blockers_text = report
        .blockers
        .clone()
        .filter(|blockers| !blockers.is_empty())
        .map(|blockers| blockers.into_iter().map(|item| summarize(&item, 28)).collect::<Vec<_>>().join(", "))
        .unwrap_or_else(|| "none".to_string());
    let checkpoint = report.checkpoint_commit.clone().unwrap_or_default();
    let ready_count = report.ready_count.unwrap_or(0);
    let blocked_count = report.blocked_count.unwrap_or(0);
    let branch = report.branch.clone().unwrap_or_else(|| "linux-next".to_string());
    let status = report.status.clone().unwrap_or_else(|| "running".to_string());
    let loop_state_label = match loop_state.as_str() {
        "waiting_on_agent" => "waiting on agent".to_string(),
        "agent_working" => "agent working".to_string(),
        "sleeping_until_next_iteration" => "sleeping until next iteration".to_string(),
        other => other.replace('_', " "),
    };

    let mut tree_lines = Vec::new();
    let root_ids = index
        .values()
        .filter(|node| node.parent_id.is_none())
        .map(|node| node.id.clone())
        .collect::<Vec<_>>();
    for (idx, node_id) in root_ids.iter().enumerate() {
        if node_visible(node_id, &index, &overlay, &focus_path) {
            render_node(
                node_id,
                &index,
                &overlay,
                &focus_path,
                &mut tree_lines,
                String::new(),
                idx == root_ids.len().saturating_sub(1),
            );
        }
    }
    let overlay_active_count = overlay
        .values()
        .filter(|item| item.status.as_deref().map(active_status).unwrap_or(false))
        .count();
    let plan_active_count = index
        .values()
        .filter(|node| active_status(&node.status))
        .count();
    let active_count = overlay_active_count.max(plan_active_count);

    if std::io::stdout().is_terminal() {
        print!("\x1b[H\x1b[2J");
    }

    println!(
        "[codex-repeat] cycle {:02} | {} | session={} | branch={} | elapsed={}",
        cycle,
        loop_state_label,
        session_id,
        branch,
        format_elapsed(elapsed)
    );
    println!(
        "[codex-repeat] progress {:3}% [{}]  before={:3}%  delta={:+}  status={}",
        after,
        progress_bar(after, 18),
        before,
        delta,
        status
    );
    println!(
        "[codex-repeat] trend    {}  latest={} prev={} avg={:.1}",
        trend_bar,
        latest,
        previous,
        trend_avg
    );
    println!(
        "[codex-repeat] tree     active={} ready={} blocked={} focus={} events={}",
        active_count,
        ready_count,
        blocked_count,
        if focus_hint.is_empty() { "n/a" } else { &focus_hint },
        events.len()
    );
    println!(
        "[codex-repeat] milestone {}  next={}  blockers={}",
        milestone_stamp,
        next_action,
        blockers_text
    );
    if !checkpoint.is_empty() {
        println!("[codex-repeat] checkpoint {}", checkpoint);
    }
    if !sleep_interval.is_empty() && loop_state == "sleeping_until_next_iteration" {
        println!("[codex-repeat] next wake in {} | exit={}", sleep_interval, exit_code);
    }
    println!("[codex-repeat] tree");
    for line in tree_lines {
        println!("[codex-repeat]   {}", line);
    }
}

fn chrono_like_now() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|dur| dur.as_secs() as i64)
        .unwrap_or(0)
}
