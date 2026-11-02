//! One GPU queue per host, shared by every image engine (1955-rjv3, moved
//! here by 1956-x7xp so `image.generate` and `studio.run_workflow` take turns
//! on the same device; studio-asset-pipeline design D3).
//!
//! A ticket queue: calls wait in arrival order (never a refusal) and report
//! how many jobs are ahead. The turn is held only while an engine is on the
//! device; dropping it wakes the next ticket.
//! @trace order:1955-rjv3, order:1956-x7xp (spec: openspec/changes/studio-asset-pipeline, not yet archived)
#![cfg_attr(not(test), allow(dead_code))]

use std::sync::{Condvar, Mutex, OnceLock};

struct GpuQueue {
    state: Mutex<(u64, u64)>, // (next ticket, now serving)
    turn: Condvar,
}

fn gpu_queue() -> &'static GpuQueue {
    static Q: OnceLock<GpuQueue> = OnceLock::new();
    Q.get_or_init(|| GpuQueue {
        state: Mutex::new((0, 0)),
        turn: Condvar::new(),
    })
}

/// Holds the device until dropped; dropping wakes the next ticket.
pub struct GpuTurn(());

impl Drop for GpuTurn {
    fn drop(&mut self) {
        let q = gpu_queue();
        let mut st = q.state.lock().unwrap_or_else(|e| e.into_inner());
        st.1 += 1;
        q.turn.notify_all();
    }
}

/// Take a ticket and wait for the device. `queued` is told the number of
/// jobs ahead each time it changes (only while waiting; a free device says
/// nothing).
pub fn wait_for_gpu(queued: &mut dyn FnMut(usize)) -> GpuTurn {
    let q = gpu_queue();
    let mut st = q.state.lock().unwrap_or_else(|e| e.into_inner());
    let ticket = st.0;
    st.0 += 1;
    let mut last = None;
    while st.1 != ticket {
        let ahead = (ticket - st.1) as usize;
        if last != Some(ahead) {
            last = Some(ahead);
            queued(ahead);
        }
        st = q.turn.wait(st).unwrap_or_else(|e| e.into_inner());
    }
    GpuTurn(())
}

/// Who holds GPU memory now (nvidia-smi compute apps), when it can say.
pub fn vram_holders() -> Option<String> {
    let out = std::process::Command::new("nvidia-smi")
        .args([
            "--query-compute-apps=pid,process_name,used_memory",
            "--format=csv,noheader",
        ])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !text.is_empty()).then_some(text)
}

/// 1955-rjv3: turn an engine failure into one that says what happened.
pub fn explain_engine_failure(err: &str, holders: Option<String>) -> String {
    // 1957-emar: sd.cpp's own memory line wins over the exit code: an OOM
    // that went on to exit 139 is still an OOM, not a bare crash.
    if let Some(oom) = GpuOutOfMemory::from_engine_log(err, holders.clone()) {
        return oom.to_string();
    }
    if err.contains("cannot make enough memory available")
        || err.contains("CUDA out of memory")
        || err.contains("OutOfMemoryError")
    {
        let who = holders.map_or_else(
            || "another process (nvidia-smi could not say which; an inference container such as ollama is the usual one)".to_string(),
            |h| format!("these processes (pid, name, memory): {}", h.replace('\n', "; ")),
        );
        return format!(
            "gpu_memory_busy: the GPU does not have enough free memory for this model; it is held by {who}. \
             Stop or unload it, or retry later. Engine said: {}",
            err.lines().last().unwrap_or(err)
        );
    }
    if err.contains("exited 139") || err.contains("signal 11") {
        return format!(
            "{err} (the engine crashed; the usual cause is too little free GPU memory)"
        );
    }
    err.to_string()
}

// ---------------------------------------------------------------------------
// 1957-emar: the arbiter. The inference engine (ollama) is a GPU holder like
// any engine, so it sits under the same queue: before a job that needs N
// bytes of VRAM the arbiter compares that against free VRAM and, when short,
// asks ollama to unload its resident models (POST /api/generate
// {model, keep_alive: 0}) or waits for their keep_alive expiry. Ollama
// reloads a model on its next request, so inference is displaced for one job,
// never disabled. Measured on macuahuitl 2026-11-02: qwen2.5:14b held 22.2 GB
// of the A5000's 24 GB and sd.cpp OOMed into exit 139.
// ---------------------------------------------------------------------------

use std::sync::Arc;
use std::time::{Duration, Instant};

/// The inference engine's API, as the arbiter needs it.
pub trait LlmEngine: Send + Sync {
    /// The `/api/ps` body, or `None` when the engine could not be asked.
    fn ps(&self) -> Option<String>;
    /// Unload `model` now: `POST /api/generate {"model", "keep_alive": 0}`.
    fn unload(&self, model: &str) -> Result<(), String>;
}

/// Free device memory, in bytes, or `None` when this host cannot say.
pub trait VramMeter: Send + Sync {
    fn free_bytes(&self) -> Option<u64>;
}

/// What the arbiter does with a resident model in the way of a job.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Policy {
    /// Unload it now.
    Evict,
    /// Wait for its keep_alive to expire when that is within `max`; evict otherwise.
    WaitForExpiry { max: Duration },
}

/// A model the inference engine holds on the device.
#[derive(Clone, Debug, PartialEq)]
pub struct Resident {
    pub name: String,
    pub vram_bytes: u64,
    pub expires_at: Option<chrono::DateTime<chrono::Utc>>,
}

/// The models in an `/api/ps` body that hold device memory, largest first.
/// `None` when the body is not an `/api/ps` answer (could not ask is not
/// "nothing resident").
pub fn parse_ps(body: &str) -> Option<Vec<Resident>> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let mut out: Vec<Resident> = v
        .get("models")?
        .as_array()?
        .iter()
        .filter_map(|m| {
            let vram_bytes = m.get("size_vram").and_then(|b| b.as_u64()).unwrap_or(0);
            let name = m
                .get("name")
                .or_else(|| m.get("model"))?
                .as_str()?
                .to_string();
            let expires_at = m
                .get("expires_at")
                .and_then(|e| e.as_str())
                .and_then(|e| chrono::DateTime::parse_from_rfc3339(e).ok())
                .map(|e| e.with_timezone(&chrono::Utc));
            (vram_bytes > 0).then_some(Resident {
                name,
                vram_bytes,
                expires_at,
            })
        })
        .collect();
    out.sort_by_key(|r| std::cmp::Reverse(r.vram_bytes));
    Some(out)
}

const GB: f64 = 1_000_000_000.0;

fn gb(bytes: u64) -> f64 {
    (bytes as f64 / GB * 100.0).round() / 100.0
}

/// A holder the arbiter displaced for a job: `how` is "evicted" or "waited".
#[derive(Clone, Debug, PartialEq)]
pub struct Evicted {
    pub name: String,
    pub vram_gb: f64,
    pub how: &'static str,
}

impl Evicted {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({ "name": self.name, "kind": "llm", "vram_gb": self.vram_gb, "how": self.how })
    }
}

pub struct Arbiter {
    pub llm: Arc<dyn LlmEngine>,
    pub meter: Arc<dyn VramMeter>,
    pub policy: Policy,
    /// How long an unloaded model may take to leave `/api/ps`.
    pub settle: Duration,
}

impl Arbiter {
    /// Make room for a job needing `need` bytes. Only called while the caller
    /// holds the [`GpuTurn`], so no other engine starts in between. A host
    /// that cannot measure free VRAM displaces nothing: evicting the user's
    /// LLM on a guess is worse than the engine's own refusal, which
    /// [`explain_engine_failure`] names.
    pub fn admit(&self, need: u64) -> Vec<Evicted> {
        let mut evicted = Vec::new();
        let Some(mut free) = self.meter.free_bytes() else {
            return evicted;
        };
        if free >= need {
            return evicted;
        }
        let Some(residents) = self.llm.ps().as_deref().and_then(parse_ps) else {
            return evicted;
        };
        for r in residents {
            if free >= need {
                break;
            }
            let how = match self.policy {
                Policy::WaitForExpiry { max }
                    if r.expires_at.is_some_and(|at| {
                        (at - chrono::Utc::now())
                            .to_std()
                            .is_ok_and(|left| left <= max)
                    }) =>
                {
                    "waited"
                }
                _ => {
                    if let Err(e) = self.llm.unload(&r.name) {
                        tracing::warn!(model = %r.name, error = %e, "1957-emar: unload refused");
                        continue;
                    }
                    "evicted"
                }
            };
            if self.gone(&r.name, how == "waited") {
                evicted.push(Evicted {
                    name: r.name.clone(),
                    vram_gb: gb(r.vram_bytes),
                    how,
                });
            }
            free = self
                .meter
                .free_bytes()
                .unwrap_or(free.saturating_add(r.vram_bytes));
        }
        evicted
    }

    /// Whether `model` has left `/api/ps` within the settle time (or, when
    /// waiting, within its expiry plus the settle time).
    fn gone(&self, model: &str, waiting: bool) -> bool {
        let limit = match (waiting, self.policy) {
            (true, Policy::WaitForExpiry { max }) => max + self.settle,
            _ => self.settle,
        };
        let deadline = Instant::now() + limit;
        loop {
            let still = self
                .llm
                .ps()
                .as_deref()
                .and_then(parse_ps)
                .is_none_or(|rs| rs.iter().any(|r| r.name == model));
            if !still {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// gpu.status: who holds the device and how much is free.
    pub fn status(&self) -> serde_json::Value {
        let residents = self.llm.ps().as_deref().and_then(parse_ps);
        let holders: Vec<serde_json::Value> = residents
            .iter()
            .flatten()
            .map(|r| serde_json::json!({ "name": r.name, "kind": "llm", "vram_gb": gb(r.vram_bytes) }))
            .collect();
        serde_json::json!({
            "holders": holders,
            "inference_engine_answered": residents.is_some(),
            "free_vram_gb": self.meter.free_bytes().map(gb),
        })
    }

    /// gpu.unload_model: unload one resident model, through the queue so it
    /// never lands in the middle of another engine's job.
    pub fn unload_model(&self, model: &str) -> Result<serde_json::Value, String> {
        let residents = self
            .llm
            .ps()
            .as_deref()
            .and_then(parse_ps)
            .ok_or("inference_unreachable: the inference engine did not answer /api/ps")?;
        let r = residents
            .iter()
            .find(|r| r.name == model)
            .ok_or_else(|| format!("not_resident: {model} holds no GPU memory now"))?;
        let _turn = wait_for_gpu(&mut |_| {});
        self.llm.unload(model)?;
        if !self.gone(model, false) {
            return Err(format!(
                "unload_unconfirmed: {model} is still listed by /api/ps"
            ));
        }
        Ok(
            serde_json::json!({ "evicted": Evicted { name: r.name.clone(), vram_gb: gb(r.vram_bytes), how: "evicted" }.to_json() }),
        )
    }
}

/// Production: the inference container's ollama, asked from inside it (the
/// enclave network is internal; the same path accel_probe uses for /api/ps).
pub struct ContainerOllama;

impl LlmEngine for ContainerOllama {
    fn ps(&self) -> Option<String> {
        let c = crate::accel_probe::resolve_inference_container()?;
        crate::accel_probe::inference_container_exec(
            &c,
            &[
                "curl",
                "-fsS",
                "--max-time",
                "2",
                "http://127.0.0.1:11434/api/ps",
            ],
        )
    }
    fn unload(&self, model: &str) -> Result<(), String> {
        let c = crate::accel_probe::resolve_inference_container()
            .ok_or("inference_unreachable: no inference container")?;
        let body = serde_json::json!({ "model": model, "keep_alive": 0 }).to_string();
        crate::accel_probe::inference_container_exec(
            &c,
            &[
                "curl",
                "-fsS",
                "--max-time",
                "30",
                "-X",
                "POST",
                "-d",
                &body,
                "http://127.0.0.1:11434/api/generate",
            ],
        )
        .map(|_| ())
        .ok_or_else(|| format!("unload_failed: ollama refused keep_alive=0 for {model}"))
    }
}

/// Production: nvidia-smi, else amdgpu's sysfs counters; `None` elsewhere.
pub struct HostVram;

impl VramMeter for HostVram {
    fn free_bytes(&self) -> Option<u64> {
        if let Ok(out) = std::process::Command::new("nvidia-smi")
            .args(["--query-gpu=memory.free", "--format=csv,noheader,nounits"])
            .output()
            && out.status.success()
            && let Some(mib) = String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|l| l.trim().parse::<u64>().ok())
                .max()
        {
            return Some(mib * 1024 * 1024);
        }
        let read = |p: &std::path::Path| -> Option<u64> {
            std::fs::read_to_string(p).ok()?.trim().parse().ok()
        };
        std::fs::read_dir("/sys/class/drm")
            .ok()?
            .flatten()
            .find_map(|card| {
                let dev = card.path().join("device");
                Some(
                    read(&dev.join("mem_info_vram_total"))?
                        .saturating_sub(read(&dev.join("mem_info_vram_used"))?),
                )
            })
    }
}

fn arbiter_seam() -> &'static Mutex<Option<Arc<Arbiter>>> {
    static SEAM: OnceLock<Mutex<Option<Arc<Arbiter>>>> = OnceLock::new();
    SEAM.get_or_init(|| Mutex::new(None))
}

#[cfg(test)]
pub fn install_arbiter(a: Option<Arbiter>) {
    *arbiter_seam().lock().unwrap_or_else(|e| e.into_inner()) = a.map(Arc::new);
}

/// The host's arbiter (a fixture's when one is installed).
pub fn arbiter() -> Arc<Arbiter> {
    if let Some(a) = arbiter_seam()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
    {
        return a;
    }
    Arc::new(Arbiter {
        llm: Arc::new(ContainerOllama),
        meter: Arc::new(HostVram),
        policy: Policy::Evict,
        settle: Duration::from_secs(10),
    })
}

/// 1957-emar: the GPU tools. The unload goes through the arbiter (and the
/// queue), never to ollama directly, so the ledger of who holds the device
/// stays single.
pub fn tool_descriptors() -> Vec<serde_json::Value> {
    vec![
        serde_json::json!({
            "name": "gpu.status",
            "description": "Who holds this host's GPU memory and how much is free: holders [{name, kind: llm|image|studio, vram_gb}] and free_vram_gb (null when the host cannot measure it). image.generate and studio.run_workflow evict a resident LLM themselves when they need the room, and say so in evicted_holders.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
        serde_json::json!({
            "name": "gpu.unload_model",
            "description": "Unload one resident LLM from the GPU now (ollama keep_alive 0), waiting its turn behind any running image job. The inference engine loads it back on its next request.",
            "inputSchema": {
                "type": "object",
                "properties": { "model": { "type": "string", "description": "A holder name from gpu.status, e.g. qwen2.5:14b" } },
                "required": ["model"]
            }
        }),
    ]
}

/// Dispatch one GPU tool; `None` when `name` is not one.
pub fn call_tool(
    name: &str,
    args: &serde_json::Value,
) -> Option<Result<serde_json::Value, String>> {
    match name {
        "gpu.status" => Some(Ok(arbiter().status())),
        "gpu.unload_model" => Some(match args.get("model").and_then(|m| m.as_str()) {
            Some(m) if !m.trim().is_empty() => arbiter().unload_model(m.trim()),
            _ => Err(
                "bad_request: gpu.unload_model needs model (a holder name from gpu.status)".into(),
            ),
        }),
        _ => None,
    }
}
/// 1957-emar: sd.cpp's out-of-memory, typed. Carries what the engine said it
/// had and needed, and who held the device at the time.
#[derive(Clone, Debug, PartialEq)]
pub struct GpuOutOfMemory {
    pub free_mb: f64,
    pub need_mb: f64,
    pub holders: Option<String>,
}

impl GpuOutOfMemory {
    /// From an engine log: "... reported free 1179 MB ... need 1343.65 MB".
    pub fn from_engine_log(log: &str, holders: Option<String>) -> Option<Self> {
        let num_after = |line: &str, key: &str| -> Option<f64> {
            let rest = &line[line.find(key)? + key.len()..];
            let n: String = rest
                .trim_start()
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect();
            n.parse().ok()
        };
        // The free figure and the need may share a line or not; the need is
        // the first "need <n>" at or after the free line.
        let at = log.find("reported free")?;
        let tail = &log[at..];
        let free_mb = num_after(tail, "reported free")?;
        let need_mb = tail
            .match_indices("need")
            .find_map(|(i, _)| num_after(&tail[i..], "need"))?;
        Some(Self {
            free_mb,
            need_mb,
            holders,
        })
    }
}

impl std::fmt::Display for GpuOutOfMemory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let who = self.holders.as_deref().map_or_else(
            || "not known (nvidia-smi could not say; an inference container such as ollama is the usual one)".to_string(),
            |h| h.replace('\n', "; "),
        );
        write!(
            f,
            "gpu_out_of_memory: the engine had {:.0} MB free and needed {:.0} MB; held by: {who}. \
             gpu.status lists the holders and gpu.unload_model frees one",
            self.free_mb, self.need_mb
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    /// The engine's VRAM refusal names who holds the device.
    #[test]
    fn a_vram_refusal_names_the_holders() {
        let log = "model manager memory on Vulkan0: reported free 180.38 MB / total 24564.00 MB\n\
                   cannot make enough memory available";
        let e = explain_engine_failure(
            &format!("engine_failed: sd-cli exited 1\n{log}"),
            Some("1234, ollama, 23900 MiB".into()),
        );
        assert!(e.starts_with("gpu_memory_busy:"), "{e}");
        assert!(e.contains("ollama"), "{e}");
        let e = explain_engine_failure("engine_failed: sd-cli exited 139", None);
        assert!(e.starts_with("engine_failed:"), "{e}");
        assert!(e.contains("crashed"), "a segfault says so: {e}");
        // ComfyUI's wording of the same failure.
        let e = explain_engine_failure(
            "engine_failed: torch.OutOfMemoryError: CUDA out of memory",
            None,
        );
        assert!(e.starts_with("gpu_memory_busy:"), "{e}");
    }

    // ---- 1957-emar: the arbiter, against a stub ollama on a real socket ----

    use std::io::{BufRead, BufReader, Read as _, Write as _};
    use std::net::{TcpListener, TcpStream};
    use std::sync::Arc;

    const GIB: u64 = 1024 * 1024 * 1024;

    /// A stub ollama: `/api/ps` lists what it holds, `POST /api/generate`
    /// with keep_alive 0 unloads a model, and any other generate loads it
    /// back (ollama's reload on demand). Every request is recorded.
    struct StubOllama {
        addr: String,
        resident: Arc<Mutex<Vec<(String, u64)>>>,
        calls: Arc<Mutex<Vec<String>>>,
    }

    impl StubOllama {
        fn start(model: &str, vram: u64) -> Self {
            Self::start_expiring(model, vram, None)
        }

        /// As [`StubOllama::start`]; with `expiry`, the model's keep_alive
        /// runs out that far from now and the stub drops it then, as ollama does.
        fn start_expiring(model: &str, vram: u64, expiry: Option<Duration>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = listener.local_addr().unwrap().to_string();
            let resident = Arc::new(Mutex::new(vec![(model.to_string(), vram)]));
            let calls = Arc::new(Mutex::new(Vec::new()));
            let expires_at = expiry.map_or_else(
                || "2099-01-01T00:00:00Z".to_string(),
                |d| (chrono::Utc::now() + chrono::Duration::from_std(d).unwrap()).to_rfc3339(),
            );
            if let Some(d) = expiry {
                let r = resident.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(d);
                    r.lock().unwrap().clear();
                });
            }
            let (r, c) = (resident.clone(), calls.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let (r, c, e) = (r.clone(), c.clone(), expires_at.clone());
                    std::thread::spawn(move || serve_stub(stream, &r, &c, &e));
                }
            });
            Self {
                addr,
                resident,
                calls,
            }
        }
        fn held(&self) -> u64 {
            self.resident.lock().unwrap().iter().map(|(_, b)| b).sum()
        }
    }

    fn serve_stub(
        stream: TcpStream,
        resident: &Mutex<Vec<(String, u64)>>,
        calls: &Mutex<Vec<String>>,
        expires_at: &str,
    ) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut head = String::new();
        reader.read_line(&mut head).unwrap();
        let mut len = 0usize;
        loop {
            let mut h = String::new();
            reader.read_line(&mut h).unwrap();
            if h.trim().is_empty() {
                break;
            }
            if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                len = v.trim().parse().unwrap();
            }
        }
        let mut body = vec![0; len];
        reader.read_exact(&mut body).unwrap();
        let body = String::from_utf8(body).unwrap();
        calls
            .lock()
            .unwrap()
            .push(format!("{} {body}", head.trim()));
        let reply = if head.starts_with("GET /api/ps") {
            let models: Vec<serde_json::Value> = resident
                .lock()
                .unwrap()
                .iter()
                .map(|(n, b)| {
                    serde_json::json!({"name": n, "model": n, "size": b, "size_vram": b,
                                                 "expires_at": expires_at})
                })
                .collect();
            serde_json::json!({ "models": models }).to_string()
        } else {
            let req: serde_json::Value = serde_json::from_str(&body).unwrap();
            let model = req["model"].as_str().unwrap().to_string();
            let mut r = resident.lock().unwrap();
            r.retain(|(n, _)| *n != model);
            if req["keep_alive"] != 0 {
                r.push((model, 22 * GIB)); // reload on demand
            }
            "{\"done\":true}".to_string()
        };
        let mut s = stream;
        let _ = write!(
            s,
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
            reply.len()
        );
    }

    fn http(addr: &str, method: &str, path: &str, body: &str) -> Option<String> {
        let mut s = TcpStream::connect(addr).ok()?;
        write!(s, "{method} {path} HTTP/1.1\r\nhost: x\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).ok()?;
        let mut out = String::new();
        s.read_to_string(&mut out).ok()?;
        Some(out.split_once("\r\n\r\n")?.1.to_string())
    }

    /// The arbiter's LLM seam over the stub's real HTTP API.
    struct HttpOllama(String);
    impl LlmEngine for HttpOllama {
        fn ps(&self) -> Option<String> {
            http(&self.0, "GET", "/api/ps", "")
        }
        fn unload(&self, model: &str) -> Result<(), String> {
            let body = serde_json::json!({ "model": model, "keep_alive": 0 }).to_string();
            http(&self.0, "POST", "/api/generate", &body)
                .map(|_| ())
                .ok_or("unreachable".into())
        }
    }

    /// A 24 GiB device: free is whatever the stub LLM does not hold.
    struct Device(Arc<Mutex<Vec<(String, u64)>>>);
    impl VramMeter for Device {
        fn free_bytes(&self) -> Option<u64> {
            Some(24 * GIB - self.0.lock().unwrap().iter().map(|(_, b)| b).sum::<u64>())
        }
    }

    /// An image engine that fails the way sd.cpp did on macuahuitl when the
    /// device is short, and draws otherwise.
    struct NeedsVram {
        device: Device,
        need: u64,
    }
    impl crate::imagegen_tool::Engine for NeedsVram {
        fn generate(
            &self,
            job: &crate::imagegen_tool::Job,
            out_dir: &std::path::Path,
            names: &[String],
            _progress: &mut dyn FnMut(crate::imagegen_tool::Progress),
        ) -> Result<crate::imagegen_tool::EngineOut, String> {
            let free = self.device.free_bytes().unwrap();
            if free < self.need {
                return Err(format!(
                    "engine_failed: sd-cli exited 139\nmodel manager memory on Vulkan0: reported free {} MB, need {} MB\ncorrupted double-linked list",
                    free / (1024 * 1024),
                    self.need / (1024 * 1024)
                ));
            }
            for n in names {
                image::RgbImage::new(job.width, job.height)
                    .save(out_dir.join(n))
                    .map_err(|e| e.to_string())?;
            }
            Ok(crate::imagegen_tool::EngineOut {
                backend: "vulkan".into(),
                first_use: false,
            })
        }
    }

    /// 1957-emar verifiable closure. Pre-fix: FAILS (nothing asked ollama to
    /// unload; the engine OOMed into exit 139 with a resident LLM).
    #[test]
    fn an_image_job_evicts_a_resident_llm_and_runs() {
        let _g = crate::imagegen_tool::SEAM_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        crate::imagegen_consent::reset_for_test();
        let ollama = StubOllama::start("qwen2.5:14b", 22 * GIB);
        install_arbiter(Some(Arbiter {
            llm: Arc::new(HttpOllama(ollama.addr.clone())),
            meter: Arc::new(Device(ollama.resident.clone())),
            policy: Policy::Evict,
            settle: Duration::from_secs(2),
        }));
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        crate::imagegen_tool::install_seam(Some(crate::imagegen_tool::Seam {
            engine: Arc::new(NeedsVram {
                device: Device(ollama.resident.clone()),
                need: 3 * GIB,
            }),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I0".into(),
        }));
        let r = crate::imagegen_tool::call(
            "emar-proj",
            "lane0",
            &serde_json::json!({"prompt": "a fox", "width": 64, "height": 64, "seed": 1}),
            &mut |_| {},
        );
        crate::imagegen_tool::install_seam(None);
        install_arbiter(None);
        let r = r.expect("the job runs once the LLM is evicted");
        let ev = &r["evicted_holders"];
        assert_eq!(ev[0]["name"], "qwen2.5:14b", "{r}");
        assert_eq!(ev[0]["kind"], "llm");
        assert_eq!(ev[0]["how"], "evicted");
        assert!(ev[0]["vram_gb"].as_f64().is_some_and(|g| g > 20.0), "{r}");
        let calls = ollama.calls.lock().unwrap().clone();
        assert!(
            calls.iter().any(|c| c.starts_with("POST /api/generate")
                && c.contains("\"keep_alive\":0")
                && c.contains("qwen2.5:14b")),
            "the arbiter asked ollama to unload: {calls:?}"
        );
        // Inference is displaced for one job, not disabled: its next request
        // reloads the model, and the arbiter left nothing that prevents it.
        assert_eq!(ollama.held(), 0);
        http(
            &ollama.addr,
            "POST",
            "/api/generate",
            r#"{"model":"qwen2.5:14b","prompt":"hi"}"#,
        )
        .unwrap();
        assert_eq!(ollama.held(), 22 * GIB, "ollama reloads on demand");
    }

    /// A job that fits, or a host that cannot measure, displaces nothing.
    #[test]
    fn the_arbiter_leaves_the_llm_alone_when_the_job_fits_or_free_is_unknown() {
        struct Unknown;
        impl VramMeter for Unknown {
            fn free_bytes(&self) -> Option<u64> {
                None
            }
        }
        let ollama = StubOllama::start("small:1b", GIB);
        let fits = Arbiter {
            llm: Arc::new(HttpOllama(ollama.addr.clone())),
            meter: Arc::new(Device(ollama.resident.clone())),
            policy: Policy::Evict,
            settle: Duration::from_secs(1),
        };
        assert!(fits.admit(3 * GIB).is_empty());
        let blind = Arbiter {
            meter: Arc::new(Unknown),
            ..fits
        };
        assert!(blind.admit(30 * GIB).is_empty());
        assert_eq!(ollama.held(), GIB);
        assert!(
            !ollama
                .calls
                .lock()
                .unwrap()
                .iter()
                .any(|c| c.starts_with("POST"))
        );
    }

    /// The wait policy: a model whose keep_alive runs out within `max` is
    /// waited for, never unloaded; one that would outlast `max` is evicted.
    #[test]
    fn the_wait_policy_waits_for_a_near_expiry_and_evicts_a_far_one() {
        let near =
            StubOllama::start_expiring("qwen2.5:14b", 22 * GIB, Some(Duration::from_millis(800)));
        let wait = Arbiter {
            llm: Arc::new(HttpOllama(near.addr.clone())),
            meter: Arc::new(Device(near.resident.clone())),
            policy: Policy::WaitForExpiry {
                max: Duration::from_secs(5),
            },
            settle: Duration::from_secs(2),
        };
        let ev = wait.admit(3 * GIB);
        assert_eq!(ev.len(), 1, "{ev:?}");
        assert_eq!(ev[0].how, "waited");
        assert!(
            !near
                .calls
                .lock()
                .unwrap()
                .iter()
                .any(|c| c.starts_with("POST")),
            "waiting never unloads"
        );

        let far = StubOllama::start("qwen2.5:14b", 22 * GIB);
        let evict = Arbiter {
            llm: Arc::new(HttpOllama(far.addr.clone())),
            meter: Arc::new(Device(far.resident.clone())),
            ..wait
        };
        let ev = evict.admit(3 * GIB);
        assert_eq!(ev.len(), 1, "{ev:?}");
        assert_eq!(ev[0].how, "evicted");
    }

    /// gpu.status names the holder; gpu.unload_model goes through the arbiter.
    #[test]
    fn gpu_status_names_holders_and_unload_goes_through_the_arbiter() {
        let ollama = StubOllama::start("qwen2.5:14b", 22 * GIB);
        let a = Arbiter {
            llm: Arc::new(HttpOllama(ollama.addr.clone())),
            meter: Arc::new(Device(ollama.resident.clone())),
            policy: Policy::Evict,
            settle: Duration::from_secs(2),
        };
        let s = a.status();
        assert_eq!(s["holders"][0]["name"], "qwen2.5:14b", "{s}");
        assert_eq!(s["holders"][0]["kind"], "llm");
        assert!(s["free_vram_gb"].as_f64().is_some_and(|g| g < 3.0), "{s}");
        assert!(
            a.unload_model("nope:1b")
                .unwrap_err()
                .starts_with("not_resident:")
        );
        let u = a.unload_model("qwen2.5:14b").unwrap();
        assert_eq!(u["evicted"]["name"], "qwen2.5:14b");
        assert_eq!(ollama.held(), 0);
    }

    /// 1957-emar verifiable closure. Pre-fix: FAILS (the transcript came back
    /// as "sd-cli exited 139 (the engine crashed ...)", untyped).
    #[test]
    fn sd_cpp_oom_surfaces_as_a_typed_error_not_a_segfault() {
        let log = "engine_failed: sd-cli exited 139\n\
                   [ERROR] model manager memory on Vulkan0: reported free 1179 MB / total 24564.00 MB, need 1343.65 MB\n\
                   corrupted double-linked list";
        let oom = GpuOutOfMemory::from_engine_log(log, Some("4321, ollama, 22200 MiB".into()))
            .expect("the OOM transcript parses as GpuOutOfMemory");
        assert_eq!(oom.free_mb, 1179.0);
        assert_eq!(oom.need_mb, 1343.65);
        let e = explain_engine_failure(log, Some("4321, ollama, 22200 MiB".into()));
        assert!(e.starts_with("gpu_out_of_memory:"), "{e}");
        assert!(
            e.contains("1179") && e.contains("1344") && e.contains("ollama"),
            "{e}"
        );
        assert!(
            !e.contains("exited 139") && !e.contains("crashed"),
            "a typed OOM, not a segfault: {e}"
        );
        // The same split over two lines, as some sd.cpp builds print it.
        let two = "reported free 900 MB\nneed 1200 MB";
        assert_eq!(
            GpuOutOfMemory::from_engine_log(two, None).map(|o| o.need_mb),
            Some(1200.0)
        );
    }
    #[test]
    fn tickets_are_served_in_order_and_a_waiter_learns_its_position() {
        let first = wait_for_gpu(&mut |_| {});
        let seen = std::sync::Arc::new(Mutex::new(Vec::new()));
        let s2 = seen.clone();
        let h = std::thread::spawn(move || {
            let _t = wait_for_gpu(&mut |p| s2.lock().unwrap().push(p));
        });
        std::thread::sleep(std::time::Duration::from_millis(30));
        assert_eq!(seen.lock().unwrap().as_slice(), &[1]);
        drop(first);
        h.join().unwrap();
    }
}
