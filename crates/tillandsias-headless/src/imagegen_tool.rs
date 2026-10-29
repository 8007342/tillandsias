//! `image.generate` on the per-lane MCP socket (order 1874-kkrc).
//!
//! @trace order:1874-kkrc, spec:mcp-tool-socket (spec: openspec/changes/local-image-generation, not yet archived)
//!
//! One tool for Claude, OpenCode and Codex alike: every harness reaches the
//! lane socket through the `host-browser` bridge and sees the same schema.
//!
//! - Exact size: `width`/`height`/`steps`/`seed`/`count`/`negative_prompt`
//!   are honoured as given; sizes are rounded only to the engine's 64 px
//!   grid and the rounding is reported. Tier defaults fill omitted fields.
//! - Output: the lane's SHARED scratch dir, mounted into the forge at
//!   `/work/tmp/imagegen/` and into the engine container at `/out`. It is
//!   wiped when the lane's next forge launches; the result says it is
//!   ephemeral. Nothing is written into the project tree.
//! - Engine: a one-shot `sd-cli` sibling container (no network at all), on a
//!   cgroup budget BELOW the forge's (memory.high under the forge's, no
//!   memory.low, oom_score_adj 1000), so under pressure the kernel reclaims
//!   from, and if it must kill, kills the engine and never the forge
//!   (1911-3dqo: systemd-oomd killed a forge its unbudgeted siblings drove).
//! - Progress: MCP `notifications/progress` on the same stream, emitted from
//!   the fetch meter and sd-cli's step meter as they print. No retry_after,
//!   no polling: the call returns when the image exists.
//! - The result is files + metadata (1871-47ex): never base64.
#![cfg_attr(not(test), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use serde_json::{Value, json};

use crate::imagegen_models::{self, FetchEvent};
use crate::imagegen_tiers::{self, TierRow};

/// Where the forge sees the scratch dir.
pub const FORGE_SCRATCH: &str = "/work/tmp/imagegen";

/// Said in the description and in every result (design.md section 4).
pub const EPHEMERAL_NOTE: &str =
    "This folder is deleted when the forge shuts down. Copy or commit anything you want to keep.";

/// The engine's size grid.
const GRID: u32 = 64;
const MAX_EDGE: u32 = 2048;
const MAX_COUNT: u32 = 4;

pub fn descriptor() -> Value {
    json!({
        "name": "image.generate",
        "description": format!(
            "Generate images locally on this computer (stable-diffusion.cpp; no hosted service, no cost). \
             Returns the saved PNG path under {FORGE_SCRATCH}/ and its metadata, never image bytes. \
             width/height/steps/seed/count are honoured exactly (sizes round to a multiple of 64, and the \
             result says so). Starts on the smallest model. The first call may build the engine and \
             download the model; progress arrives as MCP progress notifications. {EPHEMERAL_NOTE}"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": { "type": "string", "description": "What to draw." },
                "negative_prompt": { "type": "string" },
                "width": { "type": "integer", "minimum": 64, "maximum": MAX_EDGE },
                "height": { "type": "integer", "minimum": 64, "maximum": MAX_EDGE },
                "steps": { "type": "integer", "minimum": 1, "maximum": 50 },
                "seed": { "type": "integer", "minimum": 0 },
                "count": { "type": "integer", "minimum": 1, "maximum": MAX_COUNT, "default": 1 },
                "tier": { "type": "string", "enum": ["I0", "I1", "I2", "I3"], "description": "Omit to use the smallest model." }
            },
            "required": ["prompt"]
        }
    })
}

/// A validated request.
#[derive(Debug, Clone, PartialEq)]
pub struct Job {
    pub prompt: String,
    pub negative_prompt: String,
    pub width: u32,
    pub height: u32,
    pub steps: u32,
    pub seed: u64,
    pub count: u32,
    pub tier: TierRow,
    /// `(asked, got)` when a size was moved onto the grid.
    pub rounded: Option<((u32, u32), (u32, u32))>,
}

fn round_to_grid(v: u32) -> u32 {
    (((v + GRID / 2) / GRID) * GRID).clamp(GRID, MAX_EDGE)
}

/// Parse `arguments` against the ladder and the host ceiling.
pub fn parse_job(
    args: &Value,
    ladder: &[TierRow],
    ceiling: &str,
    on_cpu: bool,
) -> Result<Job, String> {
    let prompt = args
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .ok_or("invalid_arguments: prompt is required")?
        .to_string();
    let tier_name = args
        .get("tier")
        .and_then(Value::as_str)
        .unwrap_or(&ladder[0].tier);
    let idx = ladder
        .iter()
        .position(|t| t.tier == tier_name)
        .ok_or_else(|| format!("invalid_arguments: unknown tier {tier_name}"))?;
    let ceil = ladder.iter().position(|t| t.tier == ceiling).unwrap_or(0);
    if idx > ceil {
        return Err(format!(
            "tier_unavailable: {tier_name} is above what this computer can run ({ceiling})"
        ));
    }
    let tier = ladder[idx].clone();
    let uint = |k: &str| args.get(k).and_then(Value::as_u64);
    let default_edge = if on_cpu { tier.cpu_size } else { tier.size };
    let asked = (
        uint("width").map_or(default_edge, |v| v as u32),
        uint("height").map_or(default_edge, |v| v as u32),
    );
    let got = (round_to_grid(asked.0), round_to_grid(asked.1));
    let count = uint("count").unwrap_or(1) as u32;
    if count == 0 || count > MAX_COUNT {
        return Err(format!("invalid_arguments: count must be 1..={MAX_COUNT}"));
    }
    let seed = uint("seed").unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64 % 4_294_967_296)
            .unwrap_or(42)
    });
    Ok(Job {
        prompt,
        negative_prompt: args
            .get("negative_prompt")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        width: got.0,
        height: got.1,
        steps: uint("steps").map_or(tier.steps, |v| (v as u32).clamp(1, 50)),
        seed,
        count,
        rounded: (asked != got).then_some((asked, got)),
        tier,
    })
}

/// Progress, as the engine reports it.
#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    Building,
    Fetch(FetchEvent),
    Step { done: u32, total: u32 },
}

/// What a generate produced.
pub struct EngineOut {
    pub backend: String,
    pub first_use: bool,
}

/// The engine behind the tool. Production is [`PodmanSdCli`]; fixtures stub it.
pub trait Engine: Send + Sync {
    /// Write `job.count` PNGs at `outputs` (host paths, in order).
    fn generate(
        &self,
        job: &Job,
        out_dir: &Path,
        names: &[String],
        progress: &mut dyn FnMut(Progress),
    ) -> Result<EngineOut, String>;
}

/// `cache_root()/imagegen-scratch/<project>-<instance>`: on disk, never tmpfs
/// (a 1024² PNG batch on tmpfs is RAM the forge loses).
pub fn lane_scratch_dir(project: &str, instance: &str) -> PathBuf {
    let inst = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    scratch_root().join(format!("{project}-{inst}"))
}

fn scratch_root() -> PathBuf {
    if let Some(root) = seam()
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.scratch_root.clone()))
    {
        return root;
    }
    tillandsias_core::cache_root::cache_root().join("imagegen-scratch")
}

/// The forge launch's mount args for the lane scratch dir. Wipes the dir
/// first: a new forge starts with an empty `/work/tmp/imagegen/`, which is
/// what "deleted when the forge shuts down" means for the next forge.
pub fn forge_scratch_mount(project: &str, instance: &str) -> Option<PathBuf> {
    let dir = lane_scratch_dir(project, instance);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Fixture seam: a stub engine and a scratch root.
pub struct Seam {
    pub engine: Arc<dyn Engine>,
    pub scratch_root: PathBuf,
    pub ceiling: String,
}

fn seam() -> &'static Mutex<Option<Seam>> {
    static SEAM: OnceLock<Mutex<Option<Seam>>> = OnceLock::new();
    SEAM.get_or_init(|| Mutex::new(None))
}

#[cfg(test)]
pub fn install_seam(s: Option<Seam>) {
    *seam().lock().unwrap() = s;
}

/// Width, height and alpha from a PNG's IHDR.
pub fn png_facts(bytes: &[u8]) -> Option<(u32, u32, bool)> {
    if bytes.len() < 29 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" || &bytes[12..16] != b"IHDR" {
        return None;
    }
    // IHDR width/height: big-endian, folded by hand (a header field, not a frame length).
    let be = |at: usize| {
        bytes[at..at + 4]
            .iter()
            .fold(0u32, |acc, b| (acc << 8) | u32::from(*b))
    };
    let (w, h) = (be(16), be(20));
    let colour = bytes[25];
    Some((w, h, colour == 4 || colour == 6))
}

/// A ≤256 px thumbnail beside `png`; `None` when it cannot be made.
fn thumbnail(png: &Path) -> Option<PathBuf> {
    let img = image::open(png).ok()?;
    let thumb = img.thumbnail(256, 256);
    let out = png.with_extension("thumb.png");
    thumb.save_with_format(&out, image::ImageFormat::Png).ok()?;
    Some(out)
}

fn forge_path(host: &Path) -> String {
    format!(
        "{FORGE_SCRATCH}/{}",
        host.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    )
}

/// The tool call. `progress` receives each event as it happens.
pub fn call(
    project: &str,
    instance: &str,
    args: &Value,
    progress: &mut dyn FnMut(Progress),
) -> Result<Value, String> {
    let ladder = imagegen_tiers::ladder();
    let (engine, ceiling): (Arc<dyn Engine>, String) = match seam()
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| (s.engine.clone(), s.ceiling.clone())))
    {
        Some(pair) => pair,
        None => {
            let env = crate::accel_probe::accel_envelope(&crate::accel_probe::load_or_probe(
                crate::effective_inference_tier(),
            ));
            (
                Arc::new(PodmanSdCli::for_this_host()),
                imagegen_tiers::ceiling(&ladder, &env).tier.clone(),
            )
        }
    };
    let job = parse_job(args, &ladder, &ceiling, false)?;
    let out_dir = lane_scratch_dir(project, instance);
    std::fs::create_dir_all(&out_dir).map_err(|e| format!("{}: {e}", out_dir.display()))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let names: Vec<String> = (0..job.count)
        .map(|i| format!("img-{stamp}-{}-{i}.png", job.seed))
        .collect();
    let t0 = Instant::now();
    let out = engine.generate(&job, &out_dir, &names, progress)?;
    let elapsed = t0.elapsed().as_secs_f64();
    let licence = job.tier.licence.clone();
    let mut images = Vec::new();
    for name in &names {
        let host = out_dir.join(name);
        let bytes =
            std::fs::read(&host).map_err(|e| format!("engine_failed: no output {name}: {e}"))?;
        let (w, h, alpha) =
            png_facts(&bytes).ok_or_else(|| format!("engine_failed: {name} is not a PNG"))?;
        images.push(json!({
            "path": forge_path(&host),
            "width": w,
            "height": h,
            "has_alpha": alpha,
            "thumbnail_path": thumbnail(&host).map(|t| forge_path(&t)),
        }));
    }
    let first = images[0].clone();
    Ok(json!({
        "path": first["path"],
        "width": first["width"],
        "height": first["height"],
        "has_alpha": first["has_alpha"],
        "thumbnail_path": first["thumbnail_path"],
        "images": images,
        "model": job.tier.model,
        "licence": licence,
        "tier": job.tier.tier,
        "backend": out.backend,
        "seed": job.seed,
        "steps": job.steps,
        "elapsed_s": (elapsed * 100.0).round() / 100.0,
        "first_use": out.first_use,
        "size_rounded": job.rounded.map(|(a, g)| json!({
            "asked": [a.0, a.1], "got": [g.0, g.1],
            "why": "the engine draws on a 64 px grid"
        })),
        "ephemeral": true,
        "note": EPHEMERAL_NOTE,
        // 1874-p8w7 fills this with the one-tier-up offer.
        "bigger_tier_offer": Value::Null,
    }))
}

/// One `notifications/progress` line for `event`, or `None` when the
/// request carried no progressToken.
pub fn progress_notification(token: &Value, seq: &mut u64, event: &Progress) -> Option<Value> {
    if token.is_null() {
        return None;
    }
    let (progress, total, message) = match event {
        Progress::Building => (
            0.0,
            None,
            "preparing the image engine (first use only)".to_string(),
        ),
        Progress::Fetch(FetchEvent::Started { .. }) => (
            0.0,
            Some(100.0),
            "downloading the model (first use only)".to_string(),
        ),
        Progress::Fetch(FetchEvent::Percent { percent, .. }) => (
            f64::from(*percent),
            Some(100.0),
            format!("downloading the model: {percent}%"),
        ),
        Progress::Fetch(FetchEvent::Verified { .. }) => {
            (100.0, Some(100.0), "model verified".to_string())
        }
        Progress::Step { done, total } => (
            f64::from(*done),
            Some(f64::from(*total)),
            format!("drawing: step {done} of {total}"),
        ),
    };
    *seq += 1;
    let mut params = json!({ "progressToken": token, "progress": progress, "message": message });
    if let Some(t) = total {
        params["total"] = json!(t);
    }
    Some(json!({ "jsonrpc": "2.0", "method": "notifications/progress", "params": params }))
}

/// sd-cli's step meter: `|=====>   | 2/4 - 5.26s/it`. The model-load meter
/// (`|####| 14/140 - 45.66MB/s`) is not a step and is skipped.
pub fn step_from_row(row: &str) -> Option<(u32, u32)> {
    if !row.contains("s/it") && !row.contains("it/s") {
        return None;
    }
    let after = row.rsplit('|').next()?.trim();
    let frac = after.split_whitespace().next()?;
    let (d, t) = frac.split_once('/')?;
    Some((d.parse().ok()?, t.parse().ok()?))
}

/// The engine container's budget: below the forge's on every axis that
/// decides who is reclaimed or killed first.
pub fn engine_budget_args(
    forge: &tillandsias_core::forge_budget::ForgeBudget,
    model_bytes: u64,
) -> Vec<String> {
    const MIB: u64 = 1024 * 1024;
    // Weights are mmap'd then copied to the device; the host side peaks near
    // the file size plus the activations. 2 GiB headroom, at most the forge's max.
    let want = model_bytes / MIB + 2048;
    let max = want.min(forge.memory_max_mib).max(1024);
    let high = (max * 85 / 100).min(forge.memory_high_mib.saturating_sub(1));
    vec![
        format!("--memory={max}m"),
        format!("--cgroup-conf=memory.high={}", high * MIB),
        format!("--cgroup-conf=memory.swap.max={}", max * MIB),
        // Raising one's own badness needs no privilege: the OOM killer picks
        // this container before the forge (which keeps the default 0).
        "--oom-score-adj=1000".into(),
        "--pids-limit=256".into(),
    ]
}

/// Production engine: a one-shot `sd-cli` container per call.
pub struct PodmanSdCli {
    pub image: String,
    pub models_dir: PathBuf,
}

impl PodmanSdCli {
    pub fn for_this_host() -> Self {
        PodmanSdCli {
            image: std::env::var("TILLANDSIAS_IMAGEGEN_IMAGE")
                .ok()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| crate::versioned_image_tag("imagegen", crate::VERSION.trim())),
            models_dir: imagegen_models::models_dir(),
        }
    }

    fn ensure_image(&self, progress: &mut dyn FnMut(Progress)) -> Result<bool, String> {
        if tillandsias_podman::image_exists_sync(&self.image) {
            return Ok(false);
        }
        progress(Progress::Building);
        let root = crate::resolve_runtime_asset_root(crate::VERSION.trim(), false)?;
        crate::ensure_image_exists(&root, "imagegen", &self.image, false)?;
        Ok(true)
    }

    pub fn run_args(
        &self,
        job: &Job,
        files: &[(String, PathBuf)],
        out_dir: &Path,
        names: &[String],
        model_bytes: u64,
    ) -> Vec<String> {
        let mut a: Vec<String> = vec![
            "run".into(),
            "--rm".into(),
            // No egress and no enclave: the weights are mounted, the output is a file.
            "--network=none".into(),
            "--userns=keep-id".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges".into(),
            "--security-opt=label=disable".into(),
        ];
        a.extend(engine_budget_args(
            &tillandsias_core::forge_budget::ForgeBudget::for_this_host(),
            model_bytes,
        ));
        if crate::nvidia_cdi_available() {
            a.extend(["--device".into(), "nvidia.com/gpu=all".into()]);
        } else if Path::new("/dev/dri").exists() {
            a.extend(["--device".into(), "/dev/dri".into()]);
        }
        let shader = tillandsias_core::cache_root::cache_root().join("imagegen-shader-cache");
        let _ = std::fs::create_dir_all(&shader);
        a.extend([
            "--mount".into(),
            format!(
                "type=bind,source={},target=/models,readonly=true",
                self.models_dir.display()
            ),
            "--mount".into(),
            format!("type=bind,source={},target=/out", out_dir.display()),
            "--mount".into(),
            format!(
                "type=bind,source={},target=/home/imagegen/.cache/nv",
                shader.display()
            ),
            "--entrypoint".into(),
            "/usr/local/bin/sd-cli".into(),
            self.image.clone(),
        ]);
        for (role, path) in files {
            let rel = path.strip_prefix(&self.models_dir).unwrap_or(path);
            let flag = match role.as_str() {
                "model" => "--model",
                "vae" => "--vae",
                "clip_l" => "--clip_l",
                "t5xxl" => "--t5xxl",
                _ => "--diffusion-model",
            };
            a.extend([flag.into(), format!("/models/{}", rel.display())]);
        }
        let threads = std::thread::available_parallelism().map_or(4, |n| (n.get() / 2).max(1));
        // sd-cli writes batch image i to the printf pattern; names are `<stem>-<i>.png`.
        let stem = names[0].trim_end_matches("-0.png");
        a.extend([
            "--prompt".into(),
            job.prompt.clone(),
            "--negative-prompt".into(),
            job.negative_prompt.clone(),
            "-W".into(),
            job.width.to_string(),
            "-H".into(),
            job.height.to_string(),
            "--steps".into(),
            job.steps.to_string(),
            "--seed".into(),
            job.seed.to_string(),
            "--cfg-scale".into(),
            "1".into(),
            "--sampling-method".into(),
            "euler".into(),
            "--batch-count".into(),
            job.count.to_string(),
            "--threads".into(),
            threads.to_string(),
            // Verbose: the placement verdict reads the per-block buffer lines
            // only this level prints (imagegen_placement.rs).
            "--verbose".into(),
            "--output-begin-idx".into(),
            "0".into(),
            "--output".into(),
            format!("/out/{stem}-%d.png"),
        ]);
        a
    }
}

impl Engine for PodmanSdCli {
    fn generate(
        &self,
        job: &Job,
        out_dir: &Path,
        names: &[String],
        progress: &mut dyn FnMut(Progress),
    ) -> Result<EngineOut, String> {
        let built = self.ensure_image(progress)?;
        let pins = imagegen_models::files_for_tier(&imagegen_models::manifest(), &job.tier.tier);
        if pins.is_empty() {
            return Err(format!(
                "tier_unavailable: no pinned model files for {} yet",
                job.tier.tier
            ));
        }
        let mut fetched = false;
        let files = imagegen_models::ensure_files(
            &self.models_dir,
            &pins,
            &imagegen_models::ProxyTransport::for_this_build(),
            &mut |e| {
                fetched = true;
                progress(Progress::Fetch(e));
            },
        )?;
        let model_bytes: u64 = pins.iter().map(|p| p.bytes).sum();
        let args = self.run_args(job, &files, out_dir, names, model_bytes);
        let mut log = String::new();
        let mut last = None;
        imagegen_models::run_streamed(&args, &mut |row| {
            if let Some(s) = step_from_row(row)
                && last != Some(s)
            {
                last = Some(s);
                progress(Progress::Step {
                    done: s.0,
                    total: s.1,
                });
            }
            log.push_str(row);
            log.push('\n');
        })
        .map_err(|e| format!("engine_failed: {e}"))?;
        let backend = crate::imagegen_placement::placement_from_log(&log)
            .backend_label()
            .to_string();
        Ok(EngineOut {
            backend,
            first_use: built || fetched,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_round_to_the_grid_and_say_so() {
        let ladder = imagegen_tiers::ladder();
        let j = parse_job(
            &json!({"prompt":"x","width":640,"height":384}),
            &ladder,
            "I0",
            false,
        )
        .unwrap();
        assert_eq!((j.width, j.height), (640, 384));
        assert!(j.rounded.is_none());
        let j = parse_job(
            &json!({"prompt":"x","width":500,"height":300}),
            &ladder,
            "I0",
            false,
        )
        .unwrap();
        assert_eq!((j.width, j.height), (512, 320));
        assert_eq!(j.rounded, Some(((500, 300), (512, 320))));
        let j = parse_job(&json!({"prompt":"x"}), &ladder, "I3", false).unwrap();
        assert_eq!(j.tier.tier, "I0", "smallest first");
        assert_eq!((j.width, j.steps), (512, 1));
        assert!(parse_job(&json!({"prompt":"x","tier":"I1"}), &ladder, "I0", false).is_err());
        assert!(parse_job(&json!({}), &ladder, "I0", false).is_err());
    }

    #[test]
    fn the_engine_budget_sits_below_the_forge() {
        use tillandsias_core::forge_budget::ForgeBudget;
        for (n, mem) in [(4, 7_800), (16, 13_811), (20, 63_897)] {
            let forge = ForgeBudget::for_host(n, mem);
            for bytes in [1_342_124_230u64, 6_938_040_682] {
                let a = engine_budget_args(&forge, bytes);
                let high: u64 = a
                    .iter()
                    .find_map(|s| s.strip_prefix("--cgroup-conf=memory.high="))
                    .unwrap()
                    .parse()
                    .unwrap();
                assert!(high < forge.memory_high_mib * 1024 * 1024, "{a:?}");
                assert!(a.contains(&"--oom-score-adj=1000".to_string()));
                assert!(
                    !a.iter().any(|s| s.starts_with("--memory-reservation")),
                    "no memory.low"
                );
            }
        }
    }

    #[test]
    fn sd_cli_step_rows_parse() {
        assert_eq!(
            step_from_row("  |============>          | 1/4 -   5.26s/it - ETA 00:15"),
            Some((1, 4))
        );
        assert_eq!(step_from_row("  |#####| 140/140 - 469.6MB/s"), None);
    }

    #[test]
    fn the_engine_runs_with_no_network() {
        let e = PodmanSdCli {
            image: "img".into(),
            models_dir: PathBuf::from("/m"),
        };
        let job = parse_job(
            &json!({"prompt":"a fox"}),
            &imagegen_tiers::ladder(),
            "I0",
            false,
        )
        .unwrap();
        let a = e.run_args(
            &job,
            &[("model".into(), PathBuf::from("/m/I0/sdxs09.safetensors"))],
            Path::new("/o"),
            &["img-1-2-0.png".into()],
            1,
        );
        assert!(a.contains(&"--network=none".to_string()));
        assert!(a.contains(&"/models/I0/sdxs09.safetensors".to_string()));
        assert!(a.contains(&"/out/img-1-2-%d.png".to_string()));
    }
}
