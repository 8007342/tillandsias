//! Orders 2094-ay52 and 2095-kgdj: the job admission queue, rules only.
//!
//! @trace order:2094-ay52, order:2095-kgdj, order:2094-65yz, spec:job-admission-queue
//! (spec: openspec/changes/job-admission-and-host-watch, not yet archived)
//!
//! Nothing decided whether a heavy job may start: three forges and a host
//! gate could each start a 20-thread build in the same minute, and on
//! 2026-11-15 a forge's tests froze macuahuitl (2093-gfak). Here:
//!
//! - `queue.submit` takes a declared job (a name, an argv, a class, whether it
//!   is idempotent) and answers with a ticket at once. It never blocks.
//! - [`JobQueue`] admits a job only when the pressure level is calm, available
//!   memory less the reserves of recently admitted jobs covers the job's
//!   reserve plus the host floor, its class is under its running limit, and
//!   its lane's turn has come. Lanes are served round-robin; a head job
//!   skipped 3 times is `reserved` and nothing newer is admitted until it fits.
//! - Admission is evaluated on events only (a submission, an exit, a cancel, a
//!   pressure change). There is no timer; [`JobQueue::evaluations`] counts.
//! - At a `critical` level [`JobQueue::on_critical`] picks ONE job the queue
//!   started (idempotent jobs first), requeues it with a back-off, or ends a
//!   non-idempotent one as `failed` with `stopped-memory`: it is run once and
//!   never rerun. Pressure is a fixture input in this slice; the kernel
//!   pressure events are 2094-mzap's, the forge freeze 2095-wq8z's.
//! - Every refusal has one shape ([`Refusal`]): a reason from a closed set, a
//!   message, `retry_after_seconds` only when waiting can help, and the class
//!   limits when the reason concerns a class, memory or the queue's length.
//!
//! The classes and every figure are data (`job_classes.toml`), and the class
//! figures an agent reads are computed for the host that serves them.
//!
//! The admitted job runs in the submitting lane's forge (`podman exec`, the
//! argv as given, no shell). The 2081-v7qx watch registry has not landed; when
//! it does, an admitted job registers there, and [`JobQueue::may_restart`] is
//! the run-once rule the watch must consult.
// Critical, swap_free and the live launch path are read by 2094-mzap and in
// non-test builds only.
#![allow(dead_code)]

use std::collections::{BTreeMap, HashMap, VecDeque};

use serde::Deserialize;
use serde_json::{Value, json};

const GIB: u64 = 1 << 30;

/// The policy file, compiled in so the figures cannot go missing at run time.
const POLICY_TOML: &str = include_str!("job_classes.toml");

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Floor {
    pub min_gib: u64,
    pub percent: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Ceiling {
    pub reserve_multiple: u64,
    pub max_percent: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct ClassDef {
    pub name: String,
    pub meant_for: String,
    pub reserve_min_gib: u64,
    pub reserve_percent: u64,
    #[serde(default)]
    pub running_limit: Option<u64>,
    #[serde(default)]
    pub running_limit_from_forge_budget: bool,
}

/// `job_classes.toml`.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Policy {
    pub max_queued_per_lane: usize,
    pub lane_full_retry_after_seconds: u64,
    pub reserved_after_skips: u32,
    pub recent_admission_seconds: u64,
    pub calm_after_seconds: u64,
    pub bundle_minutes: u64,
    pub max_restarts: u32,
    pub restart_window_minutes: u64,
    pub wait_max_minutes: u64,
    pub max_requeues: u32,
    pub requeue_backoff_seconds: Vec<u64>,
    pub stop_interval_seconds: u64,
    pub never_retried: Vec<String>,
    pub floor: Floor,
    pub ceiling: Ceiling,
    pub class: Vec<ClassDef>,
}

impl Policy {
    pub(crate) fn shipped() -> Self {
        toml::from_str(POLICY_TOML).expect("job_classes.toml parses")
    }
}

/// What the serving host is: its memory and how many forges it can hold.
#[derive(Debug, Clone, Copy)]
pub(crate) struct HostFigures {
    pub mem_total: u64,
    pub forge_slots: u64,
}

impl HostFigures {
    /// THIS host: `MemTotal` and `ForgeBudget::concurrent_forges_on_this_host`.
    pub(crate) fn this_host() -> Self {
        let mem_total = read_meminfo("MemTotal").unwrap_or(8 * GIB);
        Self {
            mem_total,
            forge_slots:
                tillandsias_core::forge_budget::ForgeBudget::concurrent_forges_on_this_host().max(1),
        }
    }
}

/// One `/proc/meminfo` field, in bytes.
pub(crate) fn read_meminfo(field: &str) -> Option<u64> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    parse_meminfo(&text, field)
}

pub(crate) fn parse_meminfo(text: &str, field: &str) -> Option<u64> {
    text.lines().find_map(|l| {
        let rest = l.strip_prefix(field)?.strip_prefix(':')?;
        let kib: u64 = rest.trim().trim_end_matches("kB").trim().parse().ok()?;
        Some(kib * 1024)
    })
}

/// A class's figures on one host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ClassLimit {
    pub name: String,
    pub meant_for: String,
    pub reserve: u64,
    pub ceiling: u64,
    pub running_limit: u64,
}

fn percent_of(total: u64, pct: u64) -> u64 {
    (total as u128 * pct as u128 / 100) as u64
}

pub(crate) fn class_limits(policy: &Policy, host: HostFigures) -> Vec<ClassLimit> {
    policy
        .class
        .iter()
        .map(|c| {
            let reserve =
                (c.reserve_min_gib * GIB).max(percent_of(host.mem_total, c.reserve_percent));
            let ceiling = (reserve * policy.ceiling.reserve_multiple)
                .min(percent_of(host.mem_total, policy.ceiling.max_percent));
            let running_limit = if c.running_limit_from_forge_budget {
                host.forge_slots
            } else {
                c.running_limit.unwrap_or(1)
            };
            ClassLimit {
                name: c.name.clone(),
                meant_for: c.meant_for.clone(),
                reserve,
                ceiling,
                running_limit,
            }
        })
        .collect()
}

fn gib(bytes: u64) -> f64 {
    (bytes as f64 / GIB as f64 * 10.0).round() / 10.0
}

/// The class limits as every refusal and waiting status carries them.
pub(crate) fn class_limits_json(limits: &[ClassLimit]) -> Value {
    let mut m = serde_json::Map::new();
    for c in limits {
        m.insert(
            c.name.clone(),
            json!({
                "meant_for": c.meant_for,
                "reserve_gib": gib(c.reserve),
                "ceiling_gib": gib(c.ceiling),
                "running_limit": c.running_limit,
            }),
        );
    }
    Value::Object(m)
}

/// The host's floor: what must stay available after a job's reserve.
pub(crate) fn floor(policy: &Policy, host: HostFigures) -> u64 {
    (policy.floor.min_gib * GIB).max(percent_of(host.mem_total, policy.floor.percent))
}

/// The pressure level (design 3.2). A fixture input in this slice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Pressure {
    Calm,
    Tight,
    Critical,
}

/// What admission sees.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Snapshot {
    pub mem_available: u64,
    pub swap_free: u64,
    pub pressure: Pressure,
}

/// The one rule holding a queued job (closed set).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Hold {
    Pressure,
    Memory,
    ClassLimit,
    Turn,
    ReservedBehind,
    Backoff,
}

impl Hold {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Hold::Pressure => "pressure",
            Hold::Memory => "memory",
            Hold::ClassLimit => "class-limit",
            Hold::Turn => "turn",
            Hold::ReservedBehind => "reserved-behind",
            Hold::Backoff => "backoff",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum State {
    Queued,
    Running,
    Done { exit_code: i32 },
    Failed { reason: String },
    Cancelled,
    Escalated { reason: String },
}

impl State {
    fn name(&self) -> &'static str {
        match self {
            State::Queued => "queued",
            State::Running => "running",
            State::Done { .. } => "done",
            State::Failed { .. } => "failed",
            State::Cancelled => "cancelled",
            State::Escalated { .. } => "escalated",
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct Job {
    pub id: String,
    pub lane: String,
    pub name: String,
    pub argv: Vec<String>,
    pub class: usize,
    pub idempotent: bool,
    pub needs_memory: Option<u64>,
    pub seq: u64,
    pub state: State,
    pub admitted_at: Option<u64>,
    pub skips: u32,
    pub requeues: u32,
    pub hold: Option<Hold>,
    pub not_before: u64,
    /// Bumped on every event of this job; `watch.wait` waits for a change.
    pub events: u64,
    pub last_event: Option<Value>,
    pub launches: u32,
}

/// The closed set of refusal reasons.
pub(crate) const REASONS: &[&str] = &[
    "name-required",
    "command-not-argv",
    "idempotent-required",
    "unknown-class",
    "memory-exceeds-host",
    "lane-queue-full",
    "unknown-ticket",
    "running-not-cancellable",
    "already-ended",
    "timeout-above-bound",
];

/// Every refusal from the queue and watch tools has this shape.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Refusal {
    pub reason: &'static str,
    pub message: String,
    pub retry_after_seconds: Option<u64>,
    pub class_limits: Option<Box<Value>>,
}

impl Refusal {
    fn new(reason: &'static str, message: impl Into<String>) -> Self {
        debug_assert!(REASONS.contains(&reason), "{reason}");
        Self {
            reason,
            message: message.into(),
            retry_after_seconds: None,
            class_limits: None,
        }
    }

    pub(crate) fn to_json(&self) -> Value {
        let mut v = json!({"refused": true, "reason": self.reason, "message": self.message});
        if let Some(s) = self.retry_after_seconds {
            v["retry_after_seconds"] = json!(s);
        }
        if let Some(c) = &self.class_limits {
            v["class_limits"] = (**c).clone();
        }
        v
    }
}

/// The fairness rule; FIFO exists only as the control arm's seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Fairness {
    RoundRobin,
    Fifo,
}

/// What [`JobQueue::on_critical`] did to the one job it chose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Stopped {
    Requeued {
        id: String,
        retry_after_seconds: u64,
    },
    Escalated {
        id: String,
    },
    FailedRunOnce {
        id: String,
    },
}

pub(crate) struct JobQueue {
    pub policy: Policy,
    pub host: HostFigures,
    pub limits: Vec<ClassLimit>,
    jobs: BTreeMap<String, Job>,
    /// Lanes in first-seen order; the round-robin ring.
    lanes: Vec<String>,
    waiting: HashMap<String, VecDeque<String>>,
    last_served: Option<String>,
    seq: u64,
    salt: u32,
    evaluations: u64,
    last_stop: Option<u64>,
    pub fairness: Fairness,
    /// The run-once rule; false only as the control arm's seam.
    pub run_once_rule: bool,
    outbox: HashMap<String, Vec<Value>>,
}

impl JobQueue {
    pub(crate) fn new(policy: Policy, host: HostFigures) -> Self {
        let limits = class_limits(&policy, host);
        let salt = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0)
            & 0xffff;
        Self {
            policy,
            host,
            limits,
            jobs: BTreeMap::new(),
            lanes: Vec::new(),
            waiting: HashMap::new(),
            last_served: None,
            seq: 0,
            salt,
            evaluations: 0,
            last_stop: None,
            fairness: Fairness::RoundRobin,
            run_once_rule: true,
            outbox: HashMap::new(),
        }
    }

    /// How many admission evaluations have run. There is no timer: only
    /// events evaluate, and an event with nothing waiting evaluates nothing.
    pub(crate) fn evaluations(&self) -> u64 {
        self.evaluations
    }

    pub(crate) fn job(&self, id: &str) -> Option<&Job> {
        self.jobs.get(id)
    }

    fn limits_json(&self) -> Value {
        class_limits_json(&self.limits)
    }

    fn reserve(&self, job: &Job) -> u64 {
        self.limits[job.class]
            .reserve
            .max(job.needs_memory.unwrap_or(0))
    }

    fn queued_in_lane(&self, lane: &str) -> usize {
        self.waiting.get(lane).map_or(0, VecDeque::len)
    }

    /// `queue.submit`: validate, then hold the job as `queued`. The caller
    /// then delivers the submission event with [`Self::on_event`].
    pub(crate) fn submit(&mut self, lane: &str, args: &Value) -> Result<String, Refusal> {
        let name = args["name"].as_str().map(str::trim).unwrap_or("");
        if name.is_empty() {
            return Err(Refusal::new(
                "name-required",
                "name is required: a short label for this job's messages.",
            ));
        }
        let argv: Vec<String> = match &args["command"] {
            Value::Array(items)
                if !items.is_empty()
                    && items
                        .iter()
                        .all(|i| i.as_str().is_some_and(|s| !s.is_empty())) =>
            {
                items
                    .iter()
                    .map(|i| i.as_str().unwrap().to_string())
                    .collect()
            }
            _ => {
                return Err(Refusal::new(
                    "command-not-argv",
                    "command must be an argv: a JSON array of strings such as [\"cargo\", \"test\", \"-j\", \"4\"]; a single string or a shell line is never run.",
                ));
            }
        };
        let Some(idempotent) = args["idempotent"].as_bool() else {
            return Err(Refusal::new(
                "idempotent-required",
                "idempotent is required and has no default: true if the command is safe to stop and run again from its start, false if it must run at most once.",
            ));
        };
        let class_name = args["class"].as_str().unwrap_or("");
        let Some(class) = self.limits.iter().position(|c| c.name == class_name) else {
            let mut r = Refusal::new(
                "unknown-class",
                format!("class must be one of light, build or heavy; got {class_name:?}."),
            );
            r.class_limits = Some(Box::new(self.limits_json()));
            return Err(r);
        };
        let needs_memory = args["needs"]["memory_gib"]
            .as_f64()
            .map(|g| (g.max(0.0) * GIB as f64) as u64);
        if needs_memory.is_some_and(|m| m > self.host.mem_total) {
            let mut r = Refusal::new(
                "memory-exceeds-host",
                format!(
                    "needs.memory_gib is more than this computer's {} GiB of memory; split the job.",
                    gib(self.host.mem_total)
                ),
            );
            r.class_limits = Some(Box::new(self.limits_json()));
            return Err(r);
        }
        if self.queued_in_lane(lane) >= self.policy.max_queued_per_lane {
            let mut r = Refusal::new(
                "lane-queue-full",
                format!(
                    "this lane already holds {} queued jobs, the most it may; submit more when some have started.",
                    self.policy.max_queued_per_lane
                ),
            );
            r.retry_after_seconds = Some(self.policy.lane_full_retry_after_seconds);
            r.class_limits = Some(Box::new(self.limits_json()));
            return Err(r);
        }
        self.seq += 1;
        let id = format!("q{:04x}{:05}", self.salt, self.seq);
        self.jobs.insert(
            id.clone(),
            Job {
                id: id.clone(),
                lane: lane.to_string(),
                name: name.to_string(),
                argv,
                class,
                idempotent,
                needs_memory,
                seq: self.seq,
                state: State::Queued,
                admitted_at: None,
                skips: 0,
                requeues: 0,
                hold: Some(Hold::Turn),
                not_before: 0,
                events: 0,
                last_event: None,
                launches: 0,
            },
        );
        if !self.lanes.iter().any(|l| l == lane) {
            self.lanes.push(lane.to_string());
        }
        self.waiting
            .entry(lane.to_string())
            .or_default()
            .push_back(id.clone());
        Ok(id)
    }

    /// An event: evaluate admission once. Returns the ids admitted now; the
    /// caller starts each. Nothing waiting means no evaluation at all.
    pub(crate) fn on_event(&mut self, now: u64, snap: Snapshot) -> Vec<String> {
        if self.waiting.values().all(VecDeque::is_empty) {
            return Vec::new();
        }
        self.evaluations += 1;
        match self.fairness {
            Fairness::RoundRobin => self.evaluate_round_robin(now, snap),
            Fairness::Fifo => self.evaluate_fifo(now, snap),
        }
    }

    /// Why `id` does not fit now, or `None` when it does.
    fn blocked_by(&self, id: &str, now: u64, snap: Snapshot) -> Option<Hold> {
        let job = &self.jobs[id];
        if snap.pressure != Pressure::Calm {
            return Some(Hold::Pressure);
        }
        if job.not_before > now {
            return Some(Hold::Backoff);
        }
        let running_in_class = self
            .jobs
            .values()
            .filter(|j| j.state == State::Running && j.class == job.class)
            .count() as u64;
        if running_in_class >= self.limits[job.class].running_limit {
            return Some(Hold::ClassLimit);
        }
        let recent: u64 = self
            .jobs
            .values()
            .filter(|j| {
                j.state == State::Running
                    && j.admitted_at.is_some_and(|t| {
                        now.saturating_sub(t) < self.policy.recent_admission_seconds
                    })
            })
            .map(|j| self.reserve(j))
            .sum();
        let available = snap.mem_available.saturating_sub(recent);
        if available < self.reserve(job) + floor(&self.policy, self.host) {
            return Some(Hold::Memory);
        }
        None
    }

    fn admit(&mut self, id: &str, now: u64) {
        let lane = self.jobs[id].lane.clone();
        if let Some(q) = self.waiting.get_mut(&lane) {
            q.retain(|x| x != id);
        }
        let job = self.jobs.get_mut(id).unwrap();
        job.state = State::Running;
        job.admitted_at = Some(now);
        job.hold = None;
        job.skips = 0;
        job.launches += 1;
        let event = json!({"event": "admitted", "ticket": id});
        Self::record(job, &mut self.outbox, event);
    }

    fn record(job: &mut Job, outbox: &mut HashMap<String, Vec<Value>>, event: Value) {
        job.events += 1;
        job.last_event = Some(event.clone());
        outbox.entry(job.lane.clone()).or_default().push(event);
    }

    /// The oldest head job that has been skipped too often.
    fn reserved_head(&self) -> Option<String> {
        self.waiting
            .values()
            .filter_map(|q| q.front())
            .map(|id| &self.jobs[id])
            .filter(|j| j.skips >= self.policy.reserved_after_skips)
            .min_by_key(|j| j.seq)
            .map(|j| j.id.clone())
    }

    fn evaluate_round_robin(&mut self, now: u64, snap: Snapshot) -> Vec<String> {
        let mut admitted = Vec::new();
        loop {
            let n = self.lanes.len();
            let start = self
                .last_served
                .as_ref()
                .and_then(|l| self.lanes.iter().position(|x| x == l))
                .map_or(0, |i| (i + 1) % n);
            let mut admitted_this_round = false;
            let mut skipped: Vec<String> = Vec::new();
            for k in 0..n {
                let lane = self.lanes[(start + k) % n].clone();
                let Some(head) = self.waiting.get(&lane).and_then(|q| q.front()).cloned() else {
                    continue;
                };
                if let Some(r) = self.reserved_head()
                    && r != head
                {
                    self.jobs.get_mut(&head).unwrap().hold = Some(Hold::ReservedBehind);
                    continue;
                }
                match self.blocked_by(&head, now, snap) {
                    None => {
                        self.admit(&head, now);
                        self.last_served = Some(lane);
                        admitted.push(head);
                        admitted_this_round = true;
                    }
                    Some(hold) => {
                        self.jobs.get_mut(&head).unwrap().hold = Some(hold);
                        if matches!(hold, Hold::Memory | Hold::ClassLimit) {
                            skipped.push(head);
                        }
                    }
                }
            }
            if !admitted_this_round {
                break;
            }
            // A head that did not fit while another job was admitted was
            // skipped in its favour.
            for id in skipped {
                if let Some(j) = self.jobs.get_mut(&id)
                    && j.state == State::Queued
                {
                    j.skips += 1;
                }
            }
        }
        self.mark_turns();
        admitted
    }

    fn evaluate_fifo(&mut self, now: u64, snap: Snapshot) -> Vec<String> {
        let mut admitted = Vec::new();
        while let Some(head) = self
            .waiting
            .values()
            .filter_map(|q| q.front())
            .min_by_key(|id| self.jobs[*id].seq)
            .cloned()
        {
            match self.blocked_by(&head, now, snap) {
                None => {
                    self.admit(&head, now);
                    admitted.push(head);
                }
                Some(hold) => {
                    self.jobs.get_mut(&head).unwrap().hold = Some(hold);
                    break;
                }
            }
        }
        self.mark_turns();
        admitted
    }

    /// A queued job that is not its lane's head waits for its turn.
    fn mark_turns(&mut self) {
        for q in self.waiting.values() {
            for id in q.iter().skip(1) {
                if let Some(j) = self.jobs.get_mut(id) {
                    j.hold = Some(Hold::Turn);
                }
            }
        }
    }

    /// A running job exited. The caller then delivers [`Self::on_event`].
    pub(crate) fn on_exit(&mut self, id: &str, exit_code: i32) {
        let Some(job) = self.jobs.get_mut(id) else {
            return;
        };
        if job.state != State::Running {
            return;
        }
        job.state = if exit_code == 0 {
            State::Done { exit_code }
        } else {
            State::Failed {
                reason: format!("exit-code-{exit_code}"),
            }
        };
        let event = json!({"event": job.state.name(), "ticket": id, "exit_code": exit_code});
        Self::record(job, &mut self.outbox, event);
    }

    /// A job that could not be started at all.
    pub(crate) fn on_start_failed(&mut self, id: &str, reason: &str, message: &str) {
        let Some(job) = self.jobs.get_mut(id) else {
            return;
        };
        job.state = State::Failed {
            reason: reason.to_string(),
        };
        let event = json!({"event": "failed", "ticket": id, "reason": reason, "message": message});
        Self::record(job, &mut self.outbox, event);
    }

    /// Whether the watch rules may run this job's argv again (the run-once
    /// rule, 2095-kgdj): never for a job declared `idempotent: false`.
    pub(crate) fn may_restart(&self, id: &str) -> bool {
        self.jobs
            .get(id)
            .is_some_and(|j| j.idempotent || !self.run_once_rule)
    }

    /// At `critical`: stop ONE job this queue started. Idempotent jobs are
    /// chosen first; among the candidates, the lane holding the most memory
    /// (`lane_memory`, from its scope's `memory.current`), and in it the most
    /// recently admitted job. At most one every `stop_interval_seconds`.
    /// The caller delivers the stop to the process (2094-mzap).
    pub(crate) fn on_critical(
        &mut self,
        now: u64,
        lane_memory: &HashMap<String, u64>,
    ) -> Option<Stopped> {
        if self
            .last_stop
            .is_some_and(|t| now.saturating_sub(t) < self.policy.stop_interval_seconds)
        {
            return None;
        }
        let running: Vec<&Job> = self
            .jobs
            .values()
            .filter(|j| j.state == State::Running)
            .collect();
        let idempotent: Vec<&Job> = running.iter().copied().filter(|j| j.idempotent).collect();
        let pool = if self.run_once_rule && !idempotent.is_empty() {
            idempotent
        } else {
            running
        };
        let chosen = pool
            .into_iter()
            .max_by_key(|j| {
                (
                    lane_memory.get(&j.lane).copied().unwrap_or(0),
                    j.admitted_at.unwrap_or(0),
                    j.seq,
                )
            })?
            .id
            .clone();
        self.last_stop = Some(now);
        let run_once = self.run_once_rule;
        let max_requeues = self.policy.max_requeues;
        let backoffs = self.policy.requeue_backoff_seconds.clone();
        let job = self.jobs.get_mut(&chosen).unwrap();
        if !job.idempotent && run_once {
            job.state = State::Failed {
                reason: "stopped-memory".into(),
            };
            let event = json!({
                "event": "failed", "ticket": chosen, "reason": "stopped-memory",
                "message": "Stopped because this computer ran critically short of memory. It was declared idempotent: false, so it is not run again.",
                "evidence": {"pressure": "critical", "lane_memory_bytes": lane_memory.get(&job.lane).copied().unwrap_or(0)},
            });
            Self::record(job, &mut self.outbox, event);
            return Some(Stopped::FailedRunOnce { id: chosen });
        }
        job.requeues += 1;
        if job.requeues >= max_requeues {
            job.state = State::Escalated {
                reason: "memory".into(),
            };
            let event = json!({
                "event": "escalated", "ticket": chosen, "reason": "memory",
                "message": format!("Stopped for memory {max_requeues} times; it is not requeued again."),
                "requeues_used": job.requeues, "requeues_max": max_requeues,
            });
            Self::record(job, &mut self.outbox, event);
            return Some(Stopped::Escalated { id: chosen });
        }
        let wait = backoffs
            .get(job.requeues as usize - 1)
            .or(backoffs.last())
            .copied()
            .unwrap_or(120);
        job.state = State::Queued;
        job.not_before = now + wait;
        job.admitted_at = None;
        job.hold = Some(Hold::Backoff);
        let event = json!({
            "event": "requeued", "ticket": chosen, "reason": "memory",
            "message": "Stopped because this computer ran critically short of memory; it starts again from the beginning when memory allows.",
            "retry_after_seconds": wait,
            "requeues_used": job.requeues, "requeues_max": max_requeues,
        });
        let lane = job.lane.clone();
        Self::record(job, &mut self.outbox, event);
        self.waiting
            .entry(lane)
            .or_default()
            .push_front(chosen.clone());
        Some(Stopped::Requeued {
            id: chosen,
            retry_after_seconds: wait,
        })
    }

    /// The messages a lane has been sent, oldest first.
    pub(crate) fn messages(&self, lane: &str) -> &[Value] {
        self.outbox.get(lane).map_or(&[], Vec::as_slice)
    }

    fn own<'a>(&'a self, lane: &str, id: &str) -> Result<&'a Job, Refusal> {
        self.jobs.get(id).filter(|j| j.lane == lane).ok_or_else(|| {
            Refusal::new(
                "unknown-ticket",
                "No ticket with that id in this lane. A lane sees only its own tickets.",
            )
        })
    }

    /// Jobs waiting ahead of this one, all lanes counted, plus one. A count:
    /// nothing else of another lane is ever said.
    fn position(&self, job: &Job) -> usize {
        1 + self
            .waiting
            .values()
            .flatten()
            .filter(|id| self.jobs[*id].seq < job.seq)
            .count()
    }

    fn status_json(&self, job: &Job) -> Value {
        let c = &self.limits[job.class];
        let mut v = json!({
            "ticket": job.id,
            "name": job.name,
            "state": job.state.name(),
            "class": c.name,
            "idempotent": job.idempotent,
            "requeues_used": job.requeues,
            "requeues_max": self.policy.max_requeues,
        });
        match &job.state {
            State::Queued => {
                let hold = job.hold.unwrap_or(Hold::Turn);
                v["position"] = json!(self.position(job));
                v["holding"] = json!(hold.as_str());
                v["class_limits"] = self.limits_json();
                match hold {
                    Hold::Pressure => {
                        v["retry_after_seconds"] = json!(self.policy.calm_after_seconds)
                    }
                    Hold::Backoff => v["retry_after_seconds"] = json!(job.not_before),
                    _ => {}
                }
            }
            State::Done { exit_code } => v["exit_code"] = json!(exit_code),
            State::Failed { reason } | State::Escalated { reason } => v["reason"] = json!(reason),
            _ => {}
        }
        if let Some(e) = &job.last_event {
            v["last_event"] = e.clone();
        }
        v
    }

    pub(crate) fn status(&self, lane: &str, id: &str) -> Result<Value, Refusal> {
        self.own(lane, id).map(|j| self.status_json(j))
    }

    pub(crate) fn list(&self, lane: &str) -> Value {
        let tickets: Vec<Value> = self
            .jobs
            .values()
            .filter(|j| j.lane == lane)
            .map(|j| self.status_json(j))
            .collect();
        json!({ "tickets": tickets })
    }

    /// `queue.cancel`: a queued job leaves the line. A running job is not
    /// stopped by this slice: the stop path is 2094-mzap's.
    pub(crate) fn cancel(&mut self, lane: &str, id: &str) -> Result<Value, Refusal> {
        let state = self.own(lane, id)?.state.clone();
        match state {
            State::Queued => {
                if let Some(q) = self.waiting.get_mut(lane) {
                    q.retain(|x| x != id);
                }
                let job = self.jobs.get_mut(id).unwrap();
                job.state = State::Cancelled;
                let event = json!({"event": "cancelled", "ticket": id});
                Self::record(job, &mut self.outbox, event);
                Ok(json!({"ticket": id, "state": "cancelled"}))
            }
            State::Running => Err(Refusal::new(
                "running-not-cancellable",
                "This job is already running; queue.cancel removes only queued jobs. Stop it inside your forge.",
            )),
            _ => Err(Refusal::new("already-ended", "This job has already ended.")),
        }
    }

    pub(crate) fn submitted(&self, lane: &str, id: &str) -> Value {
        let job = &self.jobs[id];
        let mut v = self.status_json(job);
        if job.lane != lane {
            return json!({});
        }
        v["message"] = json!(format!(
            "Ticket {id}. Wait with watch.wait {{\"ticket\": \"{id}\"}}; do not sleep and look."
        ));
        v
    }
}

// ---------------------------------------------------------------------------
// Tool descriptions and schemas (design sections 6 and 11).
// ---------------------------------------------------------------------------

pub(crate) const SUBMIT: &str = "queue.submit";
pub(crate) const STATUS: &str = "queue.status";
pub(crate) const CANCEL: &str = "queue.cancel";
pub(crate) const LIST: &str = "queue.list";
pub(crate) const WAIT: &str = "watch.wait";

pub(crate) fn is_tool(name: &str) -> bool {
    [SUBMIT, STATUS, CANCEL, LIST, WAIT].contains(&name)
}

/// The descriptors, with this host's class figures in them.
pub(crate) fn tool_descriptors(policy: &Policy, host: HostFigures) -> Vec<Value> {
    let limits = class_limits(policy, host);
    let classes_text = limits
        .iter()
        .map(|c| {
            format!(
                "{} ({}: reserves {} GiB, ceiling {} GiB, at most {} running at once on this computer)",
                c.name,
                c.meant_for,
                gib(c.reserve),
                gib(c.ceiling),
                c.running_limit
            )
        })
        .collect::<Vec<_>>()
        .join("; ");
    let never = policy.never_retried.join("\", \"");
    let submit_desc = format!(
        "Start a heavy command when this computer has room, instead of now. Cost: no cloud tokens; the wait is local. \
         You declare the command (an argv, no shell) and its class: {classes_text}. \
         You get a ticket at once and one message when it is admitted, done, requeued or stuck. \
         If memory runs short, a job started here may be stopped and started again later, so the command must be safe to run again. \
         Submit work that is safe to stop and start again from the beginning, in bundles of a reasonable size: a job stopped for memory restarts from its start, \
         so one six-hour job loses up to six hours and twelve half-hour bundles lose at most half an hour. \
         Split a long test suite or batch into bundles that each finish in about {bundle} minutes or less and each record their own result; submit each as its own job. \
         Say idempotent: false only for a command that must not run twice (a publish, a migration); it will be run once and, if it has to be stopped, reported as failed rather than rerun. \
         A job that fails is restarted by its declared argv at most {restarts} restarts in {window} minutes; a full disk, exhausted memory and a refused permission (\"{never}\") are never retried. \
         The queue cannot run any other command and never kills your forge. Only if memory is critically short and no queued job is left to stop, \
         the forge using the most memory is frozen until the user resumes it. \
         A lane holds at most {maxq} queued jobs. Refusals carry reason, message, retry_after_seconds when waiting helps, and class_limits. \
         Not for: a command that finishes in under a minute; a job that cannot be restarted. \
         To wait, call watch.wait once; do not sleep and look.",
        bundle = policy.bundle_minutes,
        restarts = policy.max_restarts,
        window = policy.restart_window_minutes,
        maxq = policy.max_queued_per_lane,
    );
    let ticket_schema = json!({
        "type": "object",
        "properties": { "ticket": { "type": "string", "description": "A ticket id from queue.submit in this lane." } },
        "required": ["ticket"],
        "additionalProperties": false
    });
    vec![
        json!({
            "name": SUBMIT,
            "description": submit_desc,
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "description": "A short label for this job's messages." },
                    "command": {
                        "type": "array", "items": { "type": "string" }, "minItems": 1,
                        "description": "The argv to run in your forge's project checkout, e.g. [\"cargo\", \"test\", \"-p\", \"core\"]. No shell: a single string is refused."
                    },
                    "class": {
                        "type": "string",
                        "enum": limits.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                        "description": format!("Your estimate of the job's weight. On this computer: {classes_text}."),
                        "x-class-limits": class_limits_json(&limits),
                    },
                    "idempotent": {
                        "type": "boolean",
                        "description": "Required, no default. true: safe to stop and run again from its start (it may be requeued). false: must run at most once; it is never rerun, and if stopped for memory it ends failed with stopped-memory."
                    },
                    "needs": {
                        "type": "object",
                        "properties": {
                            "memory_gib": { "type": "number", "minimum": 0, "description": "Your own memory estimate; raises the class reserve, never lowers it. Above this computer's memory is refused." },
                            "gpu": { "type": "boolean", "description": "The job takes a GPU turn through the GPU queue after admission." }
                        },
                        "additionalProperties": false
                    }
                },
                "required": ["name", "command", "class", "idempotent"],
                "additionalProperties": false
            }
        }),
        json!({
            "name": STATUS,
            "description": "One ticket's state: queued (with its position, the one rule holding it: pressure, memory, class-limit, turn, reserved-behind or backoff, and this computer's class_limits), running, done, failed, cancelled or escalated. Answers for only this lane's tickets: another lane's id answers as unknown, and of other lanes you learn only a position count. Starts nothing.",
            "inputSchema": ticket_schema,
        }),
        json!({
            "name": CANCEL,
            "description": "Remove a queued job from the line. A running job is not stopped by this tool. Acts on only this lane's tickets. Starts nothing.",
            "inputSchema": ticket_schema,
        }),
        json!({
            "name": LIST,
            "description": "Every ticket of only this lane's jobs, with each one's state as queue.status gives it. Starts nothing.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
        }),
        json!({
            "name": WAIT,
            "description": format!(
                "Wait for a queued job's next event (admitted, done, failed, requeued, escalated) inside one call. Free while it waits: no tokens, no model. \
                 Returns at the event, or after timeout_minutes ({max} at most) with the current status and bound_reached: true; a return at the bound is not an event. \
                 Use it instead of a sleep loop or a scheduled wake. Waits on only this lane's tickets.",
                max = policy.wait_max_minutes
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ticket": { "type": "string", "description": "A ticket id from queue.submit in this lane." },
                    "timeout_minutes": { "type": "integer", "minimum": 1, "maximum": policy.wait_max_minutes, "default": policy.wait_max_minutes }
                },
                "required": ["ticket"],
                "additionalProperties": false
            }
        }),
    ]
}

// ---------------------------------------------------------------------------
// The live queue: one per tray process, every lane in it.
// ---------------------------------------------------------------------------

pub(crate) mod live {
    use super::*;
    use std::sync::{Condvar, Mutex, OnceLock};
    use std::time::{Duration, Instant};

    struct Live {
        queue: Mutex<JobQueue>,
        changed: Condvar,
        epoch: Instant,
    }

    fn live() -> &'static Live {
        static LIVE: OnceLock<Live> = OnceLock::new();
        LIVE.get_or_init(|| Live {
            queue: Mutex::new(JobQueue::new(Policy::shipped(), host())),
            changed: Condvar::new(),
            epoch: Instant::now(),
        })
    }

    #[cfg(not(test))]
    fn host() -> HostFigures {
        HostFigures::this_host()
    }

    /// Under test: a fixed 16 GiB host with 4 forge slots.
    #[cfg(test)]
    fn host() -> HostFigures {
        HostFigures {
            mem_total: 16 * GIB,
            forge_slots: 4,
        }
    }

    /// The live snapshot. Pressure is calm until 2094-mzap's kernel events
    /// arrive; MemAvailable and SwapFree are read when an event fires.
    #[cfg(not(test))]
    fn snapshot() -> Snapshot {
        Snapshot {
            mem_available: read_meminfo("MemAvailable").unwrap_or(0),
            swap_free: read_meminfo("SwapFree").unwrap_or(0),
            pressure: Pressure::Calm,
        }
    }

    /// Under test: no free memory, so every accepted job stays queued.
    #[cfg(test)]
    fn snapshot() -> Snapshot {
        Snapshot {
            mem_available: 0,
            swap_free: 0,
            pressure: Pressure::Calm,
        }
    }

    fn now() -> u64 {
        live().epoch.elapsed().as_secs()
    }

    fn lane_key(project: &str, instance: &str) -> String {
        format!("{project}/{instance}")
    }

    pub(crate) fn descriptors() -> Vec<Value> {
        let q = live().queue.lock().unwrap_or_else(|p| p.into_inner());
        tool_descriptors(&q.policy, q.host)
    }

    /// Run one tool for a lane. `Ok` is the result payload; `Err` a refusal
    /// payload in the one shape, answered as a tool result with isError.
    pub(crate) fn call(
        project: &str,
        instance: &str,
        tool: &str,
        args: &Value,
    ) -> Result<Value, Value> {
        let lane = lane_key(project, instance);
        let l = live();
        let ticket = args["ticket"].as_str().unwrap_or("");
        match tool {
            SUBMIT => {
                let mut q = l.queue.lock().unwrap_or_else(|p| p.into_inner());
                let id = q.submit(&lane, args).map_err(|r| r.to_json())?;
                let admitted = q.on_event(now(), snapshot());
                let reply = q.submitted(&lane, &id);
                start(&mut q, admitted);
                l.changed.notify_all();
                Ok(reply)
            }
            STATUS => {
                let q = l.queue.lock().unwrap_or_else(|p| p.into_inner());
                q.status(&lane, ticket).map_err(|r| r.to_json())
            }
            LIST => Ok(l
                .queue
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .list(&lane)),
            CANCEL => {
                let mut q = l.queue.lock().unwrap_or_else(|p| p.into_inner());
                let out = q.cancel(&lane, ticket).map_err(|r| r.to_json())?;
                let admitted = q.on_event(now(), snapshot());
                start(&mut q, admitted);
                l.changed.notify_all();
                Ok(out)
            }
            WAIT => wait(&lane, ticket, args),
            _ => Err(
                json!({"refused": true, "reason": "unknown-ticket", "message": "unknown queue tool"}),
            ),
        }
    }

    fn wait(lane: &str, ticket: &str, args: &Value) -> Result<Value, Value> {
        let l = live();
        let q = l.queue.lock().unwrap_or_else(|p| p.into_inner());
        let max = q.policy.wait_max_minutes;
        let minutes = args["timeout_minutes"].as_u64().unwrap_or(max);
        if minutes == 0 || minutes > max {
            let mut r = Refusal::new(
                "timeout-above-bound",
                format!("timeout_minutes must be from 1 to {max}."),
            );
            r.retry_after_seconds = None;
            return Err(r.to_json());
        }
        let seen = q.own(lane, ticket).map_err(|r| r.to_json())?.events;
        let deadline = Instant::now() + Duration::from_secs(minutes * 60);
        let mut q = q;
        loop {
            let events = q.job(ticket).map_or(seen, |j| j.events);
            if events != seen {
                let mut s = q.status(lane, ticket).map_err(|r| r.to_json())?;
                s["bound_reached"] = json!(false);
                return Ok(s);
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                let mut s = q.status(lane, ticket).map_err(|r| r.to_json())?;
                s["bound_reached"] = json!(true);
                s["note"] = json!(
                    "Returned at the bound; this is not an event. Call watch.wait again to keep waiting."
                );
                return Ok(s);
            }
            q = l
                .changed
                .wait_timeout(q, left)
                .map(|(g, _)| g)
                .unwrap_or_else(|p| p.into_inner().0);
        }
    }

    /// Start each admitted job in its lane's forge.
    fn start(q: &mut JobQueue, admitted: Vec<String>) {
        for id in admitted {
            let Some(job) = q.job(&id).cloned() else {
                continue;
            };
            #[cfg(test)]
            {
                let _ = job;
            }
            #[cfg(not(test))]
            spawn_in_forge(job);
        }
    }

    /// The argv, as given, in the lane's forge checkout. No shell.
    #[cfg(not(test))]
    fn spawn_in_forge(job: Job) {
        std::thread::spawn(move || {
            let (project, instance) = job.lane.split_once('/').unwrap_or((&job.lane, "default"));
            let outcome = crate::local_web_preview::resolve_live_source(project, instance)
                .and_then(|lane| {
                    let mut cmd = tillandsias_podman::podman_cmd_sync();
                    cmd.args([
                        "exec",
                        "-w",
                        &crate::studio::checkout_dir(project),
                        &lane.forge_id,
                    ])
                    .args(&job.argv)
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null());
                    let mut child = cmd
                        .spawn_caller_owned_lifetime()
                        .map_err(|e| format!("podman exec: {e}"))?;
                    child
                        .wait()
                        .map(|s| s.code().unwrap_or(-1))
                        .map_err(|e| format!("waiting for the job: {e}"))
                });
            let l = live();
            let mut q = l.queue.lock().unwrap_or_else(|p| p.into_inner());
            match outcome {
                Ok(code) => q.on_exit(&job.id, code),
                Err(e) => q.on_start_failed(&job.id, "forge-not-running", &e),
            }
            let admitted = q.on_event(now(), snapshot());
            start(&mut q, admitted);
            l.changed.notify_all();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST16: HostFigures = HostFigures {
        mem_total: 16 * GIB,
        forge_slots: 4,
    };

    fn queue() -> JobQueue {
        JobQueue::new(Policy::shipped(), HOST16)
    }

    fn snap(gib_free: f64) -> Snapshot {
        Snapshot {
            mem_available: (gib_free * GIB as f64) as u64,
            swap_free: 0,
            pressure: Pressure::Calm,
        }
    }

    fn job(name: &str, class: &str, idempotent: bool) -> Value {
        json!({"name": name, "command": ["cargo", "test", name], "class": class, "idempotent": idempotent})
    }

    fn running(q: &JobQueue) -> Vec<String> {
        q.jobs
            .values()
            .filter(|j| j.state == State::Running)
            .map(|j| j.name.clone())
            .collect()
    }

    /// On 16 GiB a build reserves 4 GiB and the floor is 4 GiB: 8.5 GiB free
    /// is room for exactly one build.
    const ROOM_FOR_ONE_BUILD: f64 = 8.5;

    #[test]
    fn the_shipped_classes_are_the_approved_table() {
        let l = class_limits(&Policy::shipped(), HOST16);
        let figures: Vec<(&str, f64, u64)> = l
            .iter()
            .map(|c| (c.name.as_str(), gib(c.reserve), c.running_limit))
            .collect();
        assert_eq!(
            figures,
            [("light", 1.0, 8), ("build", 4.0, 4), ("heavy", 8.0, 1)]
        );
        // 64 GiB: build 10% = 6.4 GiB, heavy 25% = 16 GiB, ceiling capped at 50%.
        let big = class_limits(
            &Policy::shipped(),
            HostFigures {
                mem_total: 64 * GIB,
                forge_slots: 6,
            },
        );
        assert_eq!(gib(big[1].reserve), 6.4);
        assert_eq!(gib(big[2].reserve), 16.0);
        assert_eq!(gib(big[2].ceiling), 32.0);
        assert_eq!(big[1].running_limit, 6);
    }

    /// 2095-kgdj: the class figures an agent reads are this host's.
    #[test]
    fn the_class_figures_in_the_schema_are_this_hosts() {
        let d = tool_descriptors(&Policy::shipped(), HOST16);
        let submit = d.iter().find(|t| t["name"] == SUBMIT).unwrap();
        let class = &submit["inputSchema"]["properties"]["class"];
        assert_eq!(class["x-class-limits"]["build"]["reserve_gib"], 4.0);
        assert_eq!(class["x-class-limits"]["build"]["running_limit"], 4);
        assert_eq!(class["x-class-limits"]["heavy"]["ceiling_gib"], 8.0);
        let text = class["description"].as_str().unwrap();
        assert!(
            text.contains(
                "build (a compile or a test suite: reserves 4 GiB, ceiling 8 GiB, at most 4 running"
            ),
            "{text}"
        );
        let d64 = tool_descriptors(
            &Policy::shipped(),
            HostFigures {
                mem_total: 64 * GIB,
                forge_slots: 6,
            },
        );
        assert_ne!(d, d64, "another host reads other figures");
    }

    /// 2094-ay52 arm 1.
    #[test]
    fn three_simultaneous_builds_are_admitted_one_at_a_time() {
        let mut q = queue();
        let s = snap(ROOM_FOR_ONE_BUILD);
        let mut ids = Vec::new();
        for (t, lane) in ["a", "b", "c"].iter().enumerate() {
            ids.push(q.submit(lane, &job(lane, "build", true)).unwrap());
            q.on_event(t as u64 / 2, s);
        }
        assert_eq!(running(&q), ["a"]);
        q.on_exit(&ids[0], 0);
        assert_eq!(q.on_event(5, s), [ids[1].clone()]);
        assert_eq!(running(&q), ["b"]);
        q.on_exit(&ids[1], 0);
        assert_eq!(q.on_event(9, s), [ids[2].clone()]);
        assert_eq!(running(&q), ["c"]);
    }

    /// A job admitted 10 seconds ago has not allocated yet: its reserve counts.
    #[test]
    fn a_job_that_has_just_started_still_counts() {
        let mut q = queue();
        q.submit("a", &job("a", "build", true)).unwrap();
        q.on_event(0, snap(ROOM_FOR_ONE_BUILD + 4.0));
        q.submit("b", &job("b", "build", true)).unwrap();
        // Without the rule, 12.5 GiB free fits a second build.
        q.on_event(10, snap(ROOM_FOR_ONE_BUILD + 4.0));
        assert_eq!(running(&q).len(), 2, "12.5 - 4 recent >= 4 + 4");
        q.submit("c", &job("c", "build", true)).unwrap();
        q.on_event(20, snap(ROOM_FOR_ONE_BUILD + 4.0));
        assert_eq!(running(&q).len(), 2, "12.5 - 8 recent < 8: c waits");
        let c = q.jobs.values().find(|j| j.name == "c").unwrap();
        assert_eq!(c.hold, Some(Hold::Memory));
    }

    fn lane_b_admission_rank(fairness: Fairness) -> usize {
        let mut q = queue();
        q.fairness = fairness;
        let s = snap(ROOM_FOR_ONE_BUILD);
        let mut order = Vec::new();
        for i in 0..10 {
            q.submit("a", &job(&format!("a{i}"), "build", true))
                .unwrap();
            order.extend(q.on_event(0, s));
        }
        q.submit("b", &job("b0", "build", true)).unwrap();
        order.extend(q.on_event(0, s));
        let mut t = 200;
        while order.len() < 11 {
            let last = order.last().unwrap().clone();
            q.on_exit(&last, 0);
            order.extend(q.on_event(t, s));
            t += 200;
        }
        order.iter().position(|id| q.jobs[id].lane == "b").unwrap() + 1
    }

    /// 2094-ay52 arm 2, with its control arm.
    #[test]
    fn a_lane_cannot_starve_another_by_submitting_more() {
        assert!(lane_b_admission_rank(Fairness::RoundRobin) <= 2);
        assert_eq!(
            lane_b_admission_rank(Fairness::Fifo),
            11,
            "control: FIFO admits it eleventh"
        );
    }

    /// 2094-ay52 arm 3.
    #[test]
    fn a_heavy_job_skipped_three_times_blocks_light_ones() {
        let mut q = queue();
        // heavy needs 8 + 4 = 12 GiB; lights need 1 + 4.
        let s = snap(11.9);
        let heavy = q.submit("h", &job("heavy", "heavy", true)).unwrap();
        let mut lights = Vec::new();
        for i in 0..6 {
            lights.push(
                q.submit("l", &job(&format!("light{i}"), "light", true))
                    .unwrap(),
            );
        }
        q.on_event(0, s);
        assert_eq!(q.jobs[&heavy].skips, 3);
        assert_eq!(
            running(&q).len(),
            3,
            "three lights, then the heavy one is reserved"
        );
        let blocked = q.status("l", &lights[3]).unwrap();
        assert_eq!(blocked["holding"], "reserved-behind", "{blocked}");
        // Lights exit; the heavy job fits before any newer light.
        for id in &lights[..3] {
            q.on_exit(id, 0);
        }
        let next = q.on_event(500, snap(13.0));
        assert_eq!(next.first(), Some(&heavy), "{next:?}");
    }

    /// 2094-ay52 arm 5.
    #[test]
    fn an_idle_queue_never_evaluates() {
        let mut q = queue();
        for t in (0..=1800).step_by(60) {
            q.on_event(t, snap(1.0));
        }
        assert_eq!(q.evaluations(), 0);
        q.submit("a", &job("a", "light", true)).unwrap();
        q.on_event(1801, snap(1.0));
        assert_eq!(q.evaluations(), 1);
    }

    /// 2094-ay52 arm 6 and 2095-kgdj arm 3, at the module.
    #[test]
    fn refusals_have_one_shape_and_create_no_ticket() {
        let mut q = queue();
        let mut s = job("s", "build", true);
        s["command"] = json!("cargo test && notify");
        let r = q.submit("a", &s).unwrap_err();
        assert_eq!(
            (r.reason, r.retry_after_seconds, r.class_limits.is_some()),
            ("command-not-argv", None, false)
        );
        let mut i = job("i", "build", true);
        i.as_object_mut().unwrap().remove("idempotent");
        assert_eq!(q.submit("a", &i).unwrap_err().reason, "idempotent-required");
        let r = q.submit("a", &job("c", "huge", true)).unwrap_err();
        assert_eq!(r.reason, "unknown-class");
        assert!(r.class_limits.is_some() && r.retry_after_seconds.is_none());
        let mut m = job("m", "build", true);
        m["needs"] = json!({"memory_gib": 17});
        assert_eq!(q.submit("a", &m).unwrap_err().reason, "memory-exceeds-host");
        assert!(q.jobs.is_empty());
        for n in 0..16 {
            q.submit("a", &job(&format!("j{n}"), "build", true))
                .unwrap();
        }
        let r = q.submit("a", &job("j16", "build", true)).unwrap_err();
        assert_eq!(r.reason, "lane-queue-full");
        assert!(r.retry_after_seconds.is_some() && r.class_limits.is_some());
        assert_eq!(q.jobs.len(), 16);
        for reason in [
            "command-not-argv",
            "idempotent-required",
            "unknown-class",
            "lane-queue-full",
        ] {
            assert!(REASONS.contains(&reason));
        }
    }

    fn two_running(non_idempotent_only: bool) -> (JobQueue, String, Option<String>) {
        let mut q = queue();
        let once = q.submit("a", &job("publish", "light", false)).unwrap();
        let idem =
            (!non_idempotent_only).then(|| q.submit("b", &job("tests", "light", true)).unwrap());
        q.on_event(0, snap(32.0));
        (q, once, idem)
    }

    /// 2095-kgdj arm 4: idempotent jobs are stopped first.
    #[test]
    fn at_critical_the_idempotent_job_is_stopped_first() {
        let (mut q, once, idem) = two_running(false);
        let mem: HashMap<String, u64> = [("a".into(), 9 * GIB), ("b".into(), GIB)].into();
        let stopped = q.on_critical(300, &mem).unwrap();
        let idem = idem.unwrap();
        assert!(
            matches!(&stopped, Stopped::Requeued { id, .. } if *id == idem),
            "{stopped:?}"
        );
        assert_eq!(q.jobs[&once].state, State::Running);
        let msg = q.messages("b").last().unwrap();
        assert_eq!(msg["event"], "requeued");
        assert_eq!(msg["reason"], "memory");
        assert_eq!(msg["retry_after_seconds"], 120);
        assert_eq!(msg["requeues_used"], 1);
        assert_eq!(msg["requeues_max"], 3);
        assert!(
            q.on_critical(310, &mem).is_none(),
            "at most one stop every 2 minutes"
        );
    }

    fn run_once_launches(rule: bool) -> (u32, usize, State) {
        let (mut q, once, _) = two_running(true);
        q.run_once_rule = rule;
        let before = q.messages("a").len();
        q.on_critical(300, &HashMap::new()).unwrap();
        // Memory comes back, long after any back-off.
        q.on_event(10_000, snap(32.0));
        (
            q.jobs[&once].launches,
            q.messages("a").len() - before,
            q.jobs[&once].state.clone(),
        )
    }

    /// 2095-kgdj arm 4: a non-idempotent job is run once, with its control.
    #[test]
    fn a_non_idempotent_job_is_never_rerun() {
        let (launches, messages, state) = run_once_launches(true);
        assert_eq!(launches, 1, "its command is not run again");
        assert_eq!(messages, 1, "its lane receives exactly one message");
        assert_eq!(
            state,
            State::Failed {
                reason: "stopped-memory".into()
            }
        );
        let (launches, _, _) = run_once_launches(false);
        assert_eq!(
            launches, 2,
            "control: without the rule it runs a second time"
        );
        let (q, once, _) = two_running(true);
        assert!(
            !q.may_restart(&once),
            "the watch rules may not restart it either"
        );
    }

    #[test]
    fn a_third_memory_stop_escalates() {
        let mut q = queue();
        let id = q.submit("a", &job("t", "light", true)).unwrap();
        let mut t = 0;
        for round in 1..=3 {
            q.on_event(t, snap(32.0));
            assert_eq!(q.jobs[&id].state, State::Running, "round {round}");
            t += 5000;
            q.on_critical(t, &HashMap::new()).unwrap();
            t += 5000;
        }
        assert_eq!(
            q.jobs[&id].state,
            State::Escalated {
                reason: "memory".into()
            }
        );
    }

    #[test]
    fn pressure_admits_nothing() {
        let mut q = queue();
        q.submit("a", &job("a", "light", true)).unwrap();
        let mut s = snap(32.0);
        s.pressure = Pressure::Tight;
        assert!(q.on_event(0, s).is_empty());
        let st = q.list("a")["tickets"][0].clone();
        assert_eq!(st["holding"], "pressure");
        assert_eq!(st["retry_after_seconds"], 60);
        assert!(st["class_limits"]["heavy"].is_object());
    }

    #[test]
    fn meminfo_fields_parse_to_bytes() {
        let t = "MemTotal:       65536000 kB\nMemAvailable:   1024 kB\n";
        assert_eq!(parse_meminfo(t, "MemTotal"), Some(65_536_000 * 1024));
        assert_eq!(parse_meminfo(t, "MemAvailable"), Some(1024 * 1024));
        assert_eq!(parse_meminfo(t, "Mem"), None);
    }
}
