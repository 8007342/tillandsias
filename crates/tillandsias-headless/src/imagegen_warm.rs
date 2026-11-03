//! 1971-3erz — a resident image engine, so a second call within minutes does
//! not start a container and reload the model.
//!
//! MEASURED on yoga 2026-11-03 (840M, vulkan, I0 SDXS 512, 1 step): a cold
//! one-shot `sd-cli` call is ~7.1 s, of which ~3.3 s is per-process setup
//! (Vulkan probes, tensor load, buffer sizing) and ~3.2 s is sampling plus
//! decode. A resident `sd-server` in the SAME sandbox answered calls 2-4 in
//! 2.9-3.0 s, within sample + decode + 0.5 s.
//!
//! The server keeps the engine's sandbox: `--network=none`, so it listens on
//! the container's own loopback and is reached with `podman exec <c> curl`.
//! Only plain text-to-image jobs are served warm; ControlNet, LoRA, init
//! image and mask jobs keep the one-shot path. One resident engine per host:
//! a call for other model files replaces it; it exits after
//! [`ttl`] unused, and [`release`] stops it before any other GPU job.

use crate::imagegen_tool::{EngineTimings, Job, PodmanSdCli};
use base64::Engine as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The label every resident engine carries, so a tray restart finds and
/// removes the previous tray's.
pub const WARM_LABEL: &str = "tillandsias.imagegen-warm=1";
const PORT: u16 = 1234;

struct Warm {
    name: String,
    /// The k8s-file log the server writes (read directly: no podman call).
    log: PathBuf,
    key: String,
    backend: String,
    /// The model files it holds (their names under /models) and their size.
    model: String,
    model_bytes: u64,
    last_used: Instant,
    /// One long-lived `podman exec -i <c> /bin/sh` the requests are written
    /// to; a fresh `podman exec` cost ~110 ms per call (measured on yoga).
    session: Option<Session>,
}

struct Session {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    out: std::io::BufReader<std::process::ChildStdout>,
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn open_session(name: &str) -> Option<Session> {
    let mut child = crate::podman_command()
        .args(["exec", "-i", name, "/bin/sh"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn_caller_owned_lifetime()
        .ok()?;
    let stdin = child.stdin.take()?;
    let out = std::io::BufReader::new(child.stdout.take()?);
    Some(Session { child, stdin, out })
}

/// The shell text for one request: the body in a quoted heredoc (a JSON
/// document is one line and never the delimiter), then an end marker
/// carrying curl's exit status. curl's own --max-time bounds every read.
pub fn session_request(body: &str) -> String {
    format!(
        "curl -sS --max-time 900 -X POST http://127.0.0.1:{PORT}/sdapi/v1/txt2img -H 'Content-Type: application/json' --data-binary @- <<'__TILL_BODY__'\n{body}\n__TILL_BODY__\necho; echo \"__TILL_END__ $?\"\n"
    )
}

/// Send one request on the session; `Some(reply)` when curl exited 0.
fn session_call(s: &mut Session, body: &str) -> Option<String> {
    use std::io::{BufRead, Write};
    s.stdin.write_all(session_request(body).as_bytes()).ok()?;
    s.stdin.flush().ok()?;
    let mut reply = String::new();
    loop {
        let mut line = String::new();
        if s.out.read_line(&mut line).ok()? == 0 {
            return None;
        }
        if let Some(rc) = line.strip_prefix("__TILL_END__ ") {
            return (rc.trim() == "0").then_some(reply);
        }
        reply.push_str(&line);
    }
}

static WARM: Mutex<Option<Warm>> = Mutex::new(None);

/// How long an unused resident engine stays up. `TILLANDSIAS_IMAGEGEN_WARM_TTL_S`
/// overrides; 0 turns the resident engine off (every call is one-shot).
pub fn ttl() -> Duration {
    let s = std::env::var("TILLANDSIAS_IMAGEGEN_WARM_TTL_S")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(300);
    Duration::from_secs(s)
}

/// A plain text-to-image job: the only kind the server takes warm.
pub fn eligible(job: &Job) -> bool {
    !ttl().is_zero()
        && job.aux.control.is_none()
        && job.aux.loras.is_empty()
        && job.aux.init.is_none()
}

/// Stop the resident engine, if any (another GPU job needs the device, or the
/// TTL ran out). `sd-server` ignores SIGTERM (measured: podman fell back to
/// SIGKILL after 10 s), so the stop does not wait for it.
pub fn release(why: &str) {
    let taken = WARM.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(w) = taken {
        tracing::info!(spec = "local-image-generation", name = %w.name, why, "stopping the resident image engine");
        stop(&w.name);
        let _ = std::fs::remove_file(&w.log);
    }
}

/// 1972-phye: the resident engine as a gpu.status holder. `vram_gb` is null:
/// no meter here attributes VRAM to one process (amdgpu's counters are
/// device-wide), so the model files' size is reported apart as an estimate.
pub fn holder() -> Option<serde_json::Value> {
    let guard = WARM.lock().unwrap_or_else(|e| e.into_inner());
    guard.as_ref().map(|w| holder_json(w, ttl()))
}

fn holder_json(w: &Warm, ttl: Duration) -> serde_json::Value {
    let gb = |b: u64| (b as f64 / 1e9 * 100.0).round() / 100.0;
    serde_json::json!({
        "name": w.name,
        "kind": "image",
        "model": w.model,
        "backend": w.backend,
        "vram_gb": null,
        "model_files_gb": gb(w.model_bytes),
        "idle_s": w.last_used.elapsed().as_secs(),
        "exits_after_idle_s": ttl.as_secs(),
    })
}

fn stop(name: &str) {
    let _ = crate::podman_command()
        .args(["rm", "-f", "-t", "0", name])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status_bounded(Duration::from_secs(30));
}

/// Remove any resident engine a previous tray left (by label). Called once
/// when the first warm call starts one.
fn reap_strays() {
    let out = crate::podman_command()
        .args(["ps", "-aq", "--filter", &format!("label={WARM_LABEL}")])
        .stdin(std::process::Stdio::null())
        .output_bounded(Duration::from_secs(30));
    if let Ok(o) = out {
        for id in String::from_utf8_lossy(&o.stdout).split_whitespace() {
            stop(id);
        }
    }
}

/// The request body for sd-server's txt2img endpoint: the same sampler, cfg
/// and seed rule (seed + i per image) as the one-shot run.
pub fn request_body(job: &Job) -> serde_json::Value {
    serde_json::json!({
        "prompt": job.prompt,
        "negative_prompt": job.negative_prompt,
        "width": job.width,
        "height": job.height,
        "steps": job.steps,
        "seed": job.seed,
        "cfg_scale": 1,
        "sampler_name": "euler",
        "batch_size": job.count,
    })
}

/// Decode the server's `{"images":["<base64 png>", ...]}` into `names` under
/// `out_dir`. Exactly `names.len()` images, or an error naming the count.
pub fn write_images(body: &str, out_dir: &Path, names: &[String]) -> Result<(), String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("engine_failed: resident engine answered non-JSON: {e}"))?;
    let imgs = v["images"].as_array().cloned().unwrap_or_default();
    if imgs.len() != names.len() {
        return Err(format!(
            "engine_failed: resident engine returned {} image(s), {} asked",
            imgs.len(),
            names.len()
        ));
    }
    for (img, name) in imgs.iter().zip(names) {
        let b64 = img.as_str().unwrap_or_default();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| format!("engine_failed: image {name} is not base64: {e}"))?;
        std::fs::write(out_dir.join(name), bytes)
            .map_err(|e| format!("engine_failed: cannot write {name}: {e}"))?;
    }
    Ok(())
}

fn log_lines(name: &str, tail: Option<u32>) -> Vec<String> {
    let mut args = vec!["logs".to_string()];
    if let Some(n) = tail {
        args.extend(["--tail".into(), n.to_string()]);
    }
    args.push(name.to_string());
    crate::podman_command()
        .args(&args)
        .stdin(std::process::Stdio::null())
        .output_bounded(Duration::from_secs(30))
        .map(|o| {
            let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            s.lines().map(str::to_string).collect()
        })
        .unwrap_or_default()
}

/// The last `max` bytes of `path`, as lines (a k8s-file log line carries a
/// timestamp and stream prefix; the markers are matched by `contains`).
fn file_tail(path: &Path, max: u64) -> Vec<String> {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(path) else {
        return Vec::new();
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let _ = f.seek(SeekFrom::Start(len.saturating_sub(max)));
    let mut s = String::new();
    let _ = f.read_to_string(&mut s);
    s.lines().map(str::to_string).collect()
}

/// The resident engine runs `image` now (no podman call): the caller may skip
/// its own image check.
pub fn serving_image(image: &str) -> bool {
    WARM.lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_some_and(|w| w.key.starts_with(&format!("{image}|")))
}

/// The server's lines for the LAST request only: everything after the
/// previous request's `generate_image completed` line.
pub fn last_request_rows(lines: &[String]) -> Vec<(u64, String)> {
    let ends: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.contains("generate_image completed"))
        .map(|(i, _)| i)
        .collect();
    let from = if ends.len() >= 2 {
        ends[ends.len() - 2] + 1
    } else {
        0
    };
    lines[from..].iter().map(|l| (0, l.clone())).collect()
}

fn running(name: &str) -> bool {
    crate::podman_command()
        .args(["inspect", "--format", "{{.State.Running}}", name])
        .stdin(std::process::Stdio::null())
        .output_bounded(Duration::from_secs(30))
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "true")
        .unwrap_or(false)
}

/// A started resident engine: its name, placement, and how long `podman run`
/// took to come back (the container start; the rest until it listens is load).
struct Started {
    name: String,
    log: PathBuf,
    backend: String,
    run_ms: u64,
}

/// Start the resident engine for `files`, returning once it listens. Bounded:
/// a server that never listens is removed and named.
fn start(
    engine: &PodmanSdCli,
    files: &[(String, PathBuf)],
    model_bytes: u64,
) -> Result<Started, String> {
    reap_strays();
    let t0 = Instant::now();
    let name = format!("tillandsias-imagegen-warm-{}", std::process::id());
    let shader = tillandsias_core::cache_root::cache_root().join("imagegen-shader-cache");
    let _ = std::fs::create_dir_all(&shader);
    // 1971-3erz: a file log, read by the tool directly after each call;
    // `podman logs` cost ~65 ms on every warm call (measured on yoga).
    let log = tillandsias_core::cache_root::cache_root().join(format!("{name}.log"));
    let _ = std::fs::remove_file(&log);
    let mut a: Vec<String> = vec![
        "run".into(),
        "-d".into(),
        "--rm".into(),
        "--name".into(),
        name.clone(),
        "--label".into(),
        WARM_LABEL.into(),
        "--log-driver=k8s-file".into(),
        format!("--log-opt=path={}", log.display()),
    ];
    a.extend(engine.sandbox_args(model_bytes));
    a.extend([
        "--mount".into(),
        format!(
            "type=bind,source={},target=/models,readonly=true",
            engine.models_dir.display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/home/imagegen/.cache/nv",
            shader.display()
        ),
        "--entrypoint".into(),
        "/usr/local/bin/sd-server".into(),
        engine.image.clone(),
    ]);
    a.extend(engine.model_flags(files));
    a.extend([
        "--listen-port".into(),
        PORT.to_string(),
        // Verbose: the placement verdict reads the per-block buffer lines.
        "--verbose".into(),
    ]);
    let out = crate::podman_command()
        .args(&a)
        .stdin(std::process::Stdio::null())
        .output_bounded(Duration::from_secs(120))
        .map_err(|e| format!("engine_failed: resident engine did not start: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "engine_failed: resident engine did not start: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let run_ms = t0.elapsed().as_millis() as u64;
    let deadline = Instant::now() + Duration::from_secs(180);
    loop {
        let lines = log_lines(&name, None);
        if lines.iter().any(|l| l.contains("listening on")) {
            let text = lines.join("\n");
            let backend = crate::imagegen_placement::placement_from_log(&text)
                .backend_label()
                .to_string();
            return Ok(Started {
                name,
                log,
                backend,
                run_ms,
            });
        }
        if !running(&name) || Instant::now() > deadline {
            let tail = lines
                .iter()
                .rev()
                .take(5)
                .rev()
                .cloned()
                .collect::<Vec<_>>()
                .join(" | ");
            stop(&name);
            return Err(format!(
                "engine_failed: resident engine never listened: {tail}"
            ));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn call(name: &str, body: &str) -> std::io::Result<std::process::Output> {
    crate::podman_command()
        .args([
            "exec",
            name,
            "curl",
            "-sS",
            "--max-time",
            "900",
            "-X",
            "POST",
            &format!("http://127.0.0.1:{PORT}/sdapi/v1/txt2img"),
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            body,
        ])
        .stdin(std::process::Stdio::null())
        .output_bounded(Duration::from_secs(960))
}

/// Serve `job` on the resident engine, starting it if absent or loaded with
/// other files. A reused engine reports warm with zero start and load; a call
/// that started it reports `podman run` as the start and the wait until the
/// server listened as the load.
pub fn generate(
    engine: &PodmanSdCli,
    job: &Job,
    files: &[(String, PathBuf)],
    out_dir: &Path,
    names: &[String],
    model_bytes: u64,
) -> Result<(EngineTimings, String), String> {
    let t0 = Instant::now();
    let key = format!(
        "{}|{}",
        engine.image,
        files
            .iter()
            .map(|(r, p)| format!("{r}={}", p.display()))
            .collect::<Vec<_>>()
            .join(",")
    );
    let body = request_body(job).to_string();
    let mut guard = WARM.lock().unwrap_or_else(|e| e.into_inner());
    // No inspect on the warm path: a vanished engine shows as a failed exec,
    // which restarts it once below.
    let mut started: Option<(u64, u64)> = None; // (run_ms, listen_ms)
    let mut attempt = 0;
    let out = loop {
        attempt += 1;
        if guard.as_ref().is_none_or(|w| w.key != key) {
            if let Some(old) = guard.take() {
                stop(&old.name);
            }
            let s0 = Instant::now();
            let s = start(engine, files, model_bytes)?;
            started = Some((s.run_ms, s0.elapsed().as_millis() as u64));
            *guard = Some(Warm {
                name: s.name,
                log: s.log,
                key: key.clone(),
                backend: s.backend,
                model: files
                    .iter()
                    .filter_map(|(_, p)| p.file_name())
                    .map(|n| n.to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join(","),
                model_bytes,
                last_used: Instant::now(),
                session: None,
            });
            spawn_reaper();
        }
        let w = guard.as_mut().expect("resident engine present");
        if w.session.is_none() {
            w.session = open_session(&w.name);
        }
        if let Some(s) = w.session.as_mut() {
            if let Some(reply) = session_call(s, &body) {
                break reply;
            }
            // A broken session (EOF or a failed curl) falls back to one exec.
            w.session = None;
        }
        let name = w.name.clone();
        let out = call(&name, &body)
            .map_err(|e| format!("engine_failed: resident engine call failed: {e}"))?;
        if out.status.success() {
            break String::from_utf8_lossy(&out.stdout).into_owned();
        }
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if let Some(w) = guard.take() {
            stop(&w.name);
        }
        if attempt >= 2 || started.is_some() {
            return Err(format!("engine_failed: resident engine call failed: {err}"));
        }
    };
    write_images(&out, out_dir, names)?;
    let w = guard.as_mut().expect("resident engine present");
    let rows = last_request_rows(&file_tail(&w.log, 64 * 1024));
    w.last_used = Instant::now();
    let backend = w.backend.clone();
    let total_ms = t0.elapsed().as_millis() as u64;
    let mut timings = EngineTimings::from_warm(&rows, total_ms);
    if let Some((run_ms, listen_ms)) = started {
        // This call started the engine: cold, with its own start and load.
        timings.warm = false;
        timings.container_start_ms = run_ms;
        timings.model_load_ms = listen_ms.saturating_sub(run_ms);
    }
    Ok((timings, backend))
}
/// One background thread per tray that stops the resident engine once it has
/// been unused for [`ttl`].
fn spawn_reaper() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        let _ = std::thread::Builder::new()
            .name("imagegen-warm-reaper".into())
            .spawn(|| {
                loop {
                    std::thread::sleep(Duration::from_secs(15));
                    let idle = WARM
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .as_ref()
                        .map(|w| w.last_used.elapsed());
                    if idle.is_some_and(|d| d >= ttl()) {
                        release("unused past its TTL");
                    }
                }
            });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1972-phye criterion 2: the resident engine is a named image holder.
    #[test]
    fn the_resident_engine_is_a_gpu_status_holder_naming_its_model() {
        let w = Warm {
            name: "tillandsias-imagegen-warm-7".into(),
            log: PathBuf::from("/nonexistent"),
            key: String::new(),
            backend: "vulkan".into(),
            model: "sdxs-512.safetensors".into(),
            model_bytes: 2_340_000_000,
            last_used: Instant::now(),
            session: None,
        };
        let h = holder_json(&w, Duration::from_secs(300));
        assert_eq!(h["name"], "tillandsias-imagegen-warm-7", "{h}");
        assert_eq!(h["kind"], "image");
        assert_eq!(h["model"], "sdxs-512.safetensors");
        assert!(
            h["vram_gb"].is_null(),
            "unmeasured VRAM must not be invented: {h}"
        );
        assert_eq!(h["model_files_gb"], 2.34);
        assert_eq!(h["exits_after_idle_s"], 300);
    }

    #[test]
    fn the_request_carries_the_one_shot_runs_sampler_cfg_and_batch() {
        let job = crate::imagegen_tool::parse_job(
            &serde_json::json!({"prompt":"a plant","width":512,"height":512,"steps":1,"seed":7,"count":2}),
            &crate::imagegen_tiers::ladder(),
            "I0",
            false,
        )
        .unwrap();
        let b = request_body(&job);
        assert_eq!(b["sampler_name"], "euler");
        assert_eq!(b["cfg_scale"], 1);
        assert_eq!(b["batch_size"], 2);
        assert_eq!(b["seed"], 7);
        assert_eq!(
            (b["width"].as_u64(), b["height"].as_u64()),
            (Some(512), Some(512))
        );
    }

    /// The session text reads the body from stdin (`@-`) through a quoted
    /// heredoc and ends with a marker carrying curl's status. Found live: a
    /// build that posted a FILE (`--data-binary 1438`) got a JSON error back
    /// and every warm call failed with "returned 0 image(s)".
    #[test]
    fn a_session_request_posts_the_body_from_stdin_and_ends_with_a_marker() {
        let r = session_request(r#"{"prompt":"a plant"}"#);
        assert!(
            r.contains(
                " --data-binary @- <<'__TILL_BODY__'\n{\"prompt\":\"a plant\"}\n__TILL_BODY__\n"
            ),
            "{r}"
        );
        assert!(r.ends_with("echo; echo \"__TILL_END__ $?\"\n"), "{r}");
        assert!(r.contains("http://127.0.0.1:1234/sdapi/v1/txt2img"), "{r}");
    }

    #[test]
    fn only_the_last_requests_server_lines_are_its_timings() {
        let lines: Vec<String> = [
            "[I] sampling completed, taking 1.68s",
            "[I] decode_first_stage completed, taking 1.20s",
            "[I] generate_image completed in 2.88s",
            "[I] sampling completed, taking 1.67s",
            "[I] decode_first_stage completed, taking 0.99s",
            "[I] generate_image completed in 2.67s",
        ]
        .map(str::to_string)
        .to_vec();
        let t = EngineTimings::from_warm(&last_request_rows(&lines), 2867);
        assert_eq!((t.sample_ms, t.decode_ms), (1670, 990));
        // A server that has served one request: all of its lines.
        let t = EngineTimings::from_warm(&last_request_rows(&lines[..3]), 1);
        assert_eq!((t.sample_ms, t.decode_ms), (1680, 1200));
    }

    #[test]
    fn server_images_are_written_under_their_names_and_a_short_answer_is_named() {
        let dir = tempfile::tempdir().unwrap();
        let png = base64::engine::general_purpose::STANDARD.encode(b"\x89PNG-bytes");
        let names = vec!["a-0.png".to_string()];
        write_images(&format!("{{\"images\":[\"{png}\"]}}"), dir.path(), &names).unwrap();
        assert_eq!(
            std::fs::read(dir.path().join("a-0.png")).unwrap(),
            b"\x89PNG-bytes"
        );
        let two = vec!["a-0.png".to_string(), "a-1.png".to_string()];
        let e = write_images(&format!("{{\"images\":[\"{png}\"]}}"), dir.path(), &two).unwrap_err();
        assert!(e.contains("returned 1 image(s), 2 asked"), "{e}");
    }
}
