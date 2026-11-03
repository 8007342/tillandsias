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

use crate::gpu_queue;
use crate::imagegen_consent;
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
             result says so). Runs the biggest model already on this computer unless a tier is named. The first call may build the engine and \
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
                "control_net": { "type": "string", "description": "A pinned ControlNet (e.g. openpose); needs control_image. Refused unless its licence is approved." },
                "control_image": { "type": "string", "description": format!("Path of the control PNG under {FORGE_SCRATCH}/.") },
                "init_image": { "type": "string", "description": format!("1959-xsy5: the starting PNG under {FORGE_SCRATCH}/, the job's size. Alone: image-to-image.") },
                "mask": { "type": "string", "description": "Greyscale PNG the canvas size: white repainted, black kept (byte-identical), grey blended. Needs init_image." },
                "strength": { "type": "number", "minimum": 0, "maximum": 1, "description": "How far the result may leave the init image." },
                "layout": { "type": "string", "description": "A family's reserved regions (art/families/x.json#layout) or a mask PNG; kept, and each region restored to its fill." },
                "loras": { "type": "array", "items": { "type": "object", "properties": { "name": { "type": "string" }, "weight": { "type": "number", "minimum": 0, "maximum": 2 } }, "required": ["name"] }, "description": "Pinned LoRAs; each refused unless its licence is approved." },
                "tier": { "type": "string", "enum": ["I0", "I1", "I2", "I3"], "description": "Omit to use the biggest model already on this computer (up to what it can run). Any smaller tier may be named." },
                "consent_token": { "type": "string", "description": "From a download offer (consent_required or bigger_tier_offer), only after the user said yes to its ask. Needed once per tier per computer." },
                "decline": { "type": "boolean", "description": "With the offer's consent_token, when the user said no to its ask: nothing is downloaded." }
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
    /// The lane volume the engine mounts at /out (None: bind `out_dir`).
    pub out_volume: Option<String>,
    /// Order 1954-gdi6: ControlNet and LoRA inputs, each licence-admitted.
    pub aux: Aux,
}

/// Order 1954-gdi6: optional ControlNet conditioning and LoRAs. Every file is
/// a pinned row of images/imagegen/models.tsv that the licence register admits.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Aux {
    /// The ControlNet file and the control image's path inside the engine (/out/...).
    pub control: Option<(imagegen_models::ModelFile, String)>,
    /// Each LoRA file and its weight.
    pub loras: Vec<(imagegen_models::ModelFile, f32)>,
    /// 1959-xsy5 (D11): the init image, effective mask and strength as the
    /// engine sees them (/out/in/...), staged by imagegen_init_mask.
    pub init: Option<(String, Option<String>, Option<f32>)>,
}

impl Aux {
    /// Every ControlNet and LoRA must pair with the request's base tier: an
    /// SD1.5 ControlNet on an SDXL model fails inside sd-cli, so refuse it here.
    pub fn check_base(&self, tier: &str) -> Result<(), String> {
        for m in self.files() {
            if m.base_tier() != tier {
                return Err(format!(
                    "invalid_arguments: {} pairs with tier {}, not {tier}; pass tier {} or pick a file for {tier}",
                    m.label(),
                    m.base_tier(),
                    m.base_tier()
                ));
            }
        }
        Ok(())
    }

    /// The pinned files this request adds to the tier's own.
    pub fn files(&self) -> Vec<imagegen_models::ModelFile> {
        self.control
            .iter()
            .map(|(m, _)| m.clone())
            .chain(self.loras.iter().map(|(m, _)| m.clone()))
            .collect()
    }
}

fn admitted(
    manifest: &[imagegen_models::ModelFile],
    register: &str,
    role: &str,
    name: &str,
) -> Result<imagegen_models::ModelFile, String> {
    let row = manifest
        .iter()
        .find(|m| match role {
            // A ControlNet is named by its role (`controlnet:openpose`): upstream
            // files are all called diffusion_pytorch_model*.safetensors.
            "controlnet" => m.role == format!("controlnet:{name}"),
            // A LoRA is named by its file stem, which is what sd.cpp's
            // `<lora:NAME:w>` looks up.
            _ => m.role == role && lora_stem(m) == name,
        })
        .ok_or_else(|| {
            format!(
                "model_refused: no pinned {role} named {name}; a {role} is used only when \
                 images/imagegen/models.tsv pins it and images/models/licence-register.tsv admits it \
                 (the operator approves each licence)"
            )
        })?;
    imagegen_models::register_admits(register, row)?;
    Ok(row.clone())
}

fn lora_stem(m: &imagegen_models::ModelFile) -> &str {
    m.cache_name()
        .trim_end_matches(".safetensors")
        .trim_end_matches(".gguf")
}

/// Parse `control_net`, `control_image` and `loras` against the manifest and
/// the licence register. Nothing is fetched here: a refusal downloads nothing.
pub fn parse_aux(
    args: &Value,
    manifest: &[imagegen_models::ModelFile],
    register: &str,
) -> Result<Aux, String> {
    let mut aux = Aux::default();
    let cn = args.get("control_net").and_then(Value::as_str);
    let img = args.get("control_image").and_then(Value::as_str);
    match (cn, img) {
        (None, None) => {}
        (Some(cn), Some(img)) => {
            let rel = img
                .strip_prefix(FORGE_SCRATCH)
                .and_then(|r| r.strip_prefix('/'))
                .filter(|r| {
                    !r.is_empty() && !r.split('/').any(|p| p == ".." || p == "." || p.is_empty())
                })
                .ok_or_else(|| {
                    format!(
                        "invalid_arguments: control_image must be a file under {FORGE_SCRATCH}/"
                    )
                })?;
            let row = admitted(manifest, register, "controlnet", cn)?;
            aux.control = Some((row, format!("/out/{rel}")));
        }
        _ => {
            return Err("invalid_arguments: control_net and control_image go together".into());
        }
    }
    if let Some(list) = args.get("loras").and_then(Value::as_array) {
        for l in list {
            let name = l
                .get("name")
                .and_then(Value::as_str)
                .ok_or("invalid_arguments: each lora needs a name")?;
            let weight = l.get("weight").and_then(Value::as_f64).unwrap_or(1.0) as f32;
            if !(0.0..=2.0).contains(&weight) {
                return Err(format!(
                    "invalid_arguments: lora {name} weight must be 0..=2"
                ));
            }
            aux.loras
                .push((admitted(manifest, register, "lora", name)?, weight));
        }
        let mut tiers: Vec<&str> = aux.loras.iter().map(|(m, _)| m.tier.as_str()).collect();
        tiers.dedup();
        if tiers.len() > 1 {
            return Err("invalid_arguments: every lora must share one models folder".into());
        }
    }
    Ok(aux)
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
        out_volume: None,
        aux: Aux::default(),
        tier,
    })
}

/// Progress, as the engine reports it.
#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    Building,
    Fetch(FetchEvent),
    Step {
        done: u32,
        total: u32,
    },
    /// 1955-rjv3: waiting for the host's GPU; `position` jobs are ahead.
    Queued {
        position: usize,
    },
}

/// What a generate produced.
pub struct EngineOut {
    pub backend: String,
    pub first_use: bool,
    /// 1971-3erz: the engine's own split of the call.
    pub timings: EngineTimings,
}

/// 1971-3erz: where one call's time went, from the engine's own lines.
/// MEASURED on yoga 2026-11-03 (840M, I0 SDXS 512, 1 step): a cold call is
/// ~0.1 s container start, ~3.3 s Vulkan probes + tensor load + buffer
/// sizing, ~2.0 s sampling, ~1.2 s decode. A warm call pays only the last two.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EngineTimings {
    /// The call reused a resident engine (no container start, no load).
    pub warm: bool,
    pub container_start_ms: u64,
    pub model_load_ms: u64,
    pub sample_ms: u64,
    pub decode_ms: u64,
    pub total_ms: u64,
}

impl EngineTimings {
    /// A one-shot sd-cli run: `rows` are stamped with the ms since `podman
    /// run` was spawned. Start is the first engine line; load is everything
    /// from there until sampling began.
    pub fn from_cold(rows: &[(u64, String)], total_ms: u64) -> Self {
        let container_start_ms = rows.first().map(|r| r.0).unwrap_or(0);
        let (sample_ms, sample_end) = sum_taking(rows, "sampling completed");
        let (decode_ms, _) = sum_taking(rows, "decode_first_stage completed");
        let sample_start = sample_end
            .map(|end| end.saturating_sub(sample_ms))
            .unwrap_or(container_start_ms);
        EngineTimings {
            warm: false,
            container_start_ms,
            model_load_ms: sample_start.saturating_sub(container_start_ms),
            sample_ms,
            decode_ms,
            total_ms,
        }
    }

    /// A call served by the resident engine: `rows` are the server's lines
    /// for this request only.
    pub fn from_warm(rows: &[(u64, String)], total_ms: u64) -> Self {
        EngineTimings {
            warm: true,
            container_start_ms: 0,
            model_load_ms: 0,
            sample_ms: sum_taking(rows, "sampling completed").0,
            decode_ms: sum_taking(rows, "decode_first_stage completed").0,
            total_ms,
        }
    }

    pub fn to_json(&self, warm_ttl_s: u64) -> Value {
        json!({
            "warm": self.warm,
            "container_start_ms": self.container_start_ms,
            "model_load_ms": self.model_load_ms,
            "sample_ms": self.sample_ms,
            "decode_ms": self.decode_ms,
            "total_ms": self.total_ms,
            "warm_ttl_s": warm_ttl_s,
        })
    }
}

/// Sum of sd.cpp's `<marker>, taking 2.04s` durations across `rows`, and the
/// stamp of the FIRST such row (where the first sampling pass ended).
fn sum_taking(rows: &[(u64, String)], marker: &str) -> (u64, Option<u64>) {
    let mut sum = 0u64;
    let mut first = None;
    for (at, row) in rows {
        let Some(i) = row.find(marker) else { continue };
        let Some(t) = row[i..].split("taking ").nth(1) else {
            continue;
        };
        let secs: String = t
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '.')
            .collect();
        if let Ok(s) = secs.parse::<f64>() {
            sum += (s * 1000.0).round() as u64;
            first.get_or_insert(*at);
        }
    }
    (sum, first)
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

/// The lane's scratch VOLUME: a podman named volume per forge instance,
/// created at forge launch and removed at forge teardown, mounted into the
/// forge at /work/tmp/imagegen and into the engine at /out. Never a host
/// .cache bind (the forge must not see host cache dirs).
pub fn lane_volume(project: &str, instance: &str) -> String {
    let inst = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    format!("tillandsias-imagegen-{project}-{inst}")
}

fn podman_ok(args: &[&str]) -> Result<String, String> {
    let out = crate::podman_command()
        .args(args)
        .output_bounded(std::time::Duration::from_secs(30))
        .map_err(|e| format!("podman {}: {e}", args.join(" ")))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(format!(
            "podman {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// Create the lane volume (idempotent).
pub fn ensure_lane_volume(project: &str, instance: &str) -> Result<String, String> {
    let name = lane_volume(project, instance);
    podman_ok(&["volume", "create", "--ignore", &name])?;
    Ok(name)
}

/// Forge launch: a fresh, empty volume (a leftover one from a crashed forge
/// is removed first; one in use by a live forge of this lane stays).
pub fn forge_scratch_volume(project: &str, instance: &str) -> Option<String> {
    let name = lane_volume(project, instance);
    let _ = podman_ok(&["volume", "rm", &name]);
    ensure_lane_volume(project, instance).ok()
}

/// Forge teardown: the images go with the forge.
pub fn remove_lane_volume(project: &str, instance: &str) {
    let _ = podman_ok(&["volume", "rm", "-f", &lane_volume(project, instance)]);
}

/// Where the HOST reads the lane's files (to measure them and make the
/// thumbnail): the volume's mountpoint, or the fixture seam's dir.
pub fn lane_scratch_dir(project: &str, instance: &str) -> Result<PathBuf, String> {
    if let Some(root) = seam()
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.scratch_root.clone()))
    {
        let dir = root.join(lane_volume(project, instance));
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        return Ok(dir);
    }
    let name = ensure_lane_volume(project, instance)?;
    podman_ok(&["volume", "inspect", "--format", "{{.Mountpoint}}", &name]).map(PathBuf::from)
}

/// Fixture seam: a stub engine and a scratch root.
pub struct Seam {
    pub engine: Arc<dyn Engine>,
    pub scratch_root: PathBuf,
    pub ceiling: String,
    /// Tiers whose files count as downloaded; `None` checks the real cache.
    pub present: Option<Vec<String>>,
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
/// 1971-3erz: the thumbnail's path now, the file a moment later. Decoding,
/// resizing and re-encoding the PNG ran after `elapsed_s` and before the reply
/// (measured: warm calls 2.9 s inside the tool, ~3.1 s at the client), so it
/// moves off the agent's wait onto a background thread.
fn thumbnail_later(png: &Path) -> PathBuf {
    let out = png.with_extension("thumb.png");
    let src = png.to_path_buf();
    let h = std::thread::spawn(move || {
        let _ = thumbnail(&src);
    });
    let mut pending = PENDING_THUMBNAILS.lock().unwrap_or_else(|e| e.into_inner());
    pending.retain(|p| !p.is_finished());
    pending.push(h);
    out
}

static PENDING_THUMBNAILS: std::sync::Mutex<Vec<std::thread::JoinHandle<()>>> =
    std::sync::Mutex::new(Vec::new());

/// Wait for every deferred thumbnail (tests read the file right after a call).
#[cfg(test)]
pub fn flush_thumbnails() {
    let hs = std::mem::take(&mut *PENDING_THUMBNAILS.lock().unwrap_or_else(|e| e.into_inner()));
    for h in hs {
        let _ = h.join();
    }
}

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

fn tier_index(ladder: &[TierRow], tier: &str) -> usize {
    ladder.iter().position(|t| t.tier == tier).unwrap_or(0)
}

/// The bytes still to fetch for `tier`; 0 when every pinned file is in the
/// model cache. `present` is the fixture seam's override of the cache check.
fn download_bytes(tier: &TierRow, present: Option<&[String]>) -> u64 {
    let files = imagegen_models::files_for_tier(&imagegen_models::manifest(), &tier.tier);
    if let Some(p) = present {
        return if p.contains(&tier.tier) {
            0
        } else {
            files.iter().map(|m| m.bytes).sum()
        };
    }
    let dir = imagegen_models::models_dir().join(&tier.tier);
    files
        .iter()
        .filter(|m| !dir.join(m.cache_name()).is_file())
        .map(|m| m.bytes)
        .sum()
}

/// 1957-5m8g: a tier runs with no consent when its files are pinned and either
/// already on this computer or their download was granted on this host.
/// Every tier's first download asks, I0 included (operator 2026-11-01).
fn available(tier: &TierRow, present: Option<&[String]>) -> bool {
    let pinned =
        !imagegen_models::files_for_tier(&imagegen_models::manifest(), &tier.tier).is_empty();
    pinned && (download_bytes(tier, present) == 0 || imagegen_consent::download_granted(&tier.tier))
}

/// Serialises tests that install the process-wide seam.
#[cfg(test)]
pub static SEAM_TEST_LOCK: Mutex<()> = Mutex::new(());

/// The tool call. `progress` receives each event as it happens.
pub fn call(
    project: &str,
    instance: &str,
    args: &Value,
    progress: &mut dyn FnMut(Progress),
) -> Result<Value, String> {
    let ladder = imagegen_tiers::ladder();
    let (engine, ceiling, present): (Arc<dyn Engine>, String, Option<Vec<String>>) =
        match seam().lock().ok().and_then(|s| {
            s.as_ref()
                .map(|s| (s.engine.clone(), s.ceiling.clone(), s.present.clone()))
        }) {
            Some(triple) => triple,
            None => {
                let env = crate::accel_probe::accel_envelope(&crate::accel_probe::load_or_probe(
                    crate::effective_inference_tier(),
                ));
                (
                    Arc::new(PodmanSdCli::for_this_host()),
                    imagegen_tiers::ceiling(&ladder, &env).tier.clone(),
                    None,
                )
            }
        };
    let present = present.as_deref();
    let lane = imagegen_consent::lane_key(project, instance);
    let ceil = tier_index(&ladder, &ceiling);
    // 1957-5m8g (operator ruling 2026-11-01): the highest tier within the
    // ceiling that is already here (or granted) is the default; I0 only when
    // nothing above it is.
    let top_available = (0..=ceil)
        .rev()
        .find(|&i| available(&ladder[i], present))
        .unwrap_or(0);
    let mut args = args.clone();
    if args.get("tier").is_none() {
        args["tier"] = json!(ladder[top_available].tier);
    }
    let args = &args;
    let mut job = parse_job(args, &ladder, &ceiling, false)?;
    job.aux = parse_aux(
        args,
        &imagegen_models::manifest(),
        imagegen_models::register_tsv(),
    )?;
    job.aux.check_base(&job.tier.tier)?;
    let request = imagegen_consent::request_hash(args);
    let idx = tier_index(&ladder, &job.tier.tier);
    // Any tier up to the ceiling may be asked for directly; only a download
    // asks, once per host.
    let mut granted_download = false;
    if !available(&job.tier, present) {
        let bytes = download_bytes(&job.tier, present);
        if imagegen_models::files_for_tier(&imagegen_models::manifest(), &job.tier.tier).is_empty()
        {
            return Err(format!(
                "tier_unavailable: no pinned model files for {}",
                job.tier.tier
            ));
        }
        let token = args.get("consent_token").and_then(Value::as_str);
        if args.get("decline").and_then(Value::as_bool) == Some(true) {
            imagegen_consent::decline(token);
            return Ok(json!({
                "status": "declined",
                "tier": job.tier.tier,
                "ran": false,
                "downloaded": false,
                "note": "The user declined the download. Nothing was fetched; asking again later is fine.",
            }));
        }
        if let Err(refusal) = imagegen_consent::redeem(token, &lane, &job.tier, &request) {
            let offer = imagegen_consent::offer(&lane, &request, &job.tier, bytes);
            return Ok(imagegen_consent::consent_required(offer, refusal));
        }
        granted_download = true;
    }
    let out_dir = lane_scratch_dir(project, instance)?;
    job.out_volume = Some(lane_volume(project, instance));
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let names: Vec<String> = (0..job.count)
        .map(|i| format!("img-{stamp}-{}-{i}.png", job.seed))
        .collect();
    // 1959-xsy5 (D11): stage init image, effective mask and layout before
    // the GPU turn; a bad file is refused before anything queues.
    let staged = match crate::imagegen_init_mask::parse(args)? {
        Some(req) => Some(crate::imagegen_init_mask::Staged::stage(
            project,
            instance,
            &req,
            (job.width, job.height),
            &out_dir,
            stamp,
        )?),
        None => None,
    };
    if let Some(s) = &staged {
        job.aux.init = Some(s.engine.clone());
    }
    // D3 (1956-x7xp): one GPU queue per host, shared with the studio.
    let q0 = Instant::now();
    let turn = gpu_queue::wait_for_gpu(&mut |position| progress(Progress::Queued { position }));
    // 1957-emar: with the device ours, make room: the weights plus 1 GiB of
    // activations, evicting a resident LLM when free VRAM is short.
    let need: u64 = imagegen_models::files_for_tier(&imagegen_models::manifest(), &job.tier.tier)
        .iter()
        .chain(job.aux.files().iter())
        .map(|m| m.bytes)
        .sum::<u64>()
        + (1 << 30);
    let a0 = Instant::now();
    let queue_ms = a0.duration_since(q0).as_millis() as u64;
    let evicted = gpu_queue::arbiter().admit(need);
    // 1971-3erz: the queue wait and the admit run before the engine; both are
    // on the agent's wait, so the result names them too.
    let admit_ms = a0.elapsed().as_millis() as u64;
    let t0 = Instant::now();
    let out = engine
        .generate(&job, &out_dir, &names, progress)
        .map_err(|e| gpu_queue::explain_engine_failure(&e, gpu_queue::vram_holders()));
    drop(turn);
    let out = out?;
    // 1959-xsy5 (D11): kept pixels and reserved regions are restored on
    // every output, whatever the engine did at a soft mask edge.
    if let Some(s) = &staged {
        for n in &names {
            s.composite_file(&out_dir.join(n))?;
        }
    }
    let elapsed = t0.elapsed().as_secs_f64();
    let licence = job.tier.licence.clone();
    // D5 (1956-x7xp): the same provenance schema the studio writes.
    let mut models = imagegen_models::files_for_tier(&imagegen_models::manifest(), &job.tier.tier);
    models.extend(job.aux.files());
    let control_input = job.aux.control.as_ref().and_then(|(_, img)| {
        Some(crate::provenance::Input {
            name: "control_image".into(),
            path: img.replacen("/out", FORGE_SCRATCH, 1),
            sha256: control_image_sha256(&out_dir, img)?,
        })
    });
    // 1959-xsy5 (D11 "Provenance"): the init image and the effective mask the
    // engine was given, each with its sha256.
    let d11_inputs: Vec<crate::provenance::Input> = staged
        .as_ref()
        .map(|s| {
            let mut v = vec![crate::provenance::Input {
                name: "init_image".into(),
                path: args["init_image"].as_str().unwrap_or("").to_string(),
                sha256: s.init_sha256.clone(),
            }];
            if let (Some(m), Some(sha)) = (&s.engine.1, &s.mask_sha256) {
                v.push(crate::provenance::Input {
                    name: "mask".into(),
                    path: m.replacen("/out", FORGE_SCRATCH, 1),
                    sha256: sha.clone(),
                });
            }
            v
        })
        .unwrap_or_default();
    let mut images = Vec::new();
    for (i, name) in names.iter().enumerate() {
        let host = out_dir.join(name);
        let bytes =
            std::fs::read(&host).map_err(|e| format!("engine_failed: no output {name}: {e}"))?;
        let (w, h, alpha) =
            png_facts(&bytes).ok_or_else(|| format!("engine_failed: {name} is not a PNG"))?;
        let record = crate::provenance::Record {
            engine: crate::provenance::Engine::SdCpp,
            workflow: None,
            models: models.clone(),
            inputs: control_input
                .iter()
                .cloned()
                .chain(d11_inputs.iter().cloned())
                .collect(),
            seed: job.seed + i as u64,
            prompt: job.prompt.clone(),
            negative_prompt: job.negative_prompt.clone(),
            tier: Some(job.tier.tier.clone()),
            placement: out.backend.clone(),
            family: None,
            consent: None,
            cli: None,
        };
        let prov = record.write_beside(&host)?;
        images.push(json!({
            "path": forge_path(&host),
            "width": w,
            "height": h,
            "has_alpha": alpha,
            // 1971-3erz: written after the reply, off the agent's wait.
            "thumbnail_path": forge_path(&thumbnail_later(&host)),
            "provenance_path": format!("{}.provenance.json", forge_path(&host)),
            "provenance": prov,
        }));
    }
    let first = images[0].clone();
    // The next installable tier above everything already here, as a download
    // offer; null when nothing above needs fetching (1957-8hkf).
    let above = (idx..=ceil)
        .rev()
        .find(|&i| available(&ladder[i], present))
        .unwrap_or(idx);
    let bigger =
        match imagegen_tiers::next_offerable(&ladder, above, ceil, &imagegen_models::manifest()) {
            Some(next) => {
                imagegen_consent::offer(&lane, &request, next, download_bytes(next, present))
            }
            None => Value::Null,
        };
    let grant = (granted_download || imagegen_consent::download_granted(&job.tier.tier))
        .then(|| imagegen_consent::grant_json(&job.tier.tier));
    let mut timings_json = out.timings.to_json(crate::imagegen_warm::ttl().as_secs());
    timings_json["queue_ms"] = json!(queue_ms);
    timings_json["admit_ms"] = json!(admit_ms);
    Ok(json!({
        "evicted_holders": evicted.iter().map(gpu_queue::Evicted::to_json).collect::<Vec<_>>(),
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
        "timings": timings_json,
        "size_rounded": job.rounded.map(|(a, g)| json!({
            "asked": [a.0, a.1], "got": [g.0, g.1],
            "why": "the engine draws on a 64 px grid"
        })),
        "ephemeral": true,
        "note": EPHEMERAL_NOTE,
        "bigger_tier_offer": bigger,
        "provenance": first["provenance"],
        // 1955-rjv3: part of the model ran on the CPU; slower, and a sign the
        // GPU was short of memory. Reported, never passed off as a GPU run.
        "degraded": (out.backend == "mixed").then(|| json!({
            "backend": "mixed",
            "why": "part of the model did not fit in GPU memory and ran on the CPU; \
                    the image is valid but generation was slower. Free GPU memory and retry for a full GPU run."
        })),
        "control": job.aux.control.as_ref().map(|(m, img)| json!({
            "model": m.label(), "sha256": m.sha256, "licence": m.licence,
            "image": img.replacen("/out", FORGE_SCRATCH, 1),
            "image_sha256": control_image_sha256(&out_dir, img),
        })),
        "loras": job.aux.loras.iter().map(|(m, w)| json!({
            "model": m.label(), "sha256": m.sha256, "licence": m.licence, "weight": w,
        })).collect::<Vec<_>>(),
        "grant": grant,
    }))
}

/// sha256 of the control image, read from the lane's scratch dir on the host.
fn control_image_sha256(out_dir: &Path, engine_path: &str) -> Option<String> {
    use sha2::{Digest, Sha256};
    let rel = engine_path.strip_prefix("/out/")?;
    let bytes = std::fs::read(out_dir.join(rel)).ok()?;
    Some(format!("{:x}", Sha256::digest(&bytes)))
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
        Progress::Queued { position } => (
            0.0,
            None,
            format!("waiting for the GPU: {position} job(s) ahead"),
        ),
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
        let mut a: Vec<String> = vec!["run".into(), "--rm".into()];
        a.extend(self.sandbox_args(model_bytes));
        let shader = tillandsias_core::cache_root::cache_root().join("imagegen-shader-cache");
        let _ = std::fs::create_dir_all(&shader);
        a.extend([
            "--mount".into(),
            format!(
                "type=bind,source={},target=/models,readonly=true",
                self.models_dir.display()
            ),
            "--mount".into(),
            match &job.out_volume {
                Some(v) => format!("type=volume,source={v},target=/out"),
                None => format!("type=bind,source={},target=/out", out_dir.display()),
            },
            "--mount".into(),
            format!(
                "type=bind,source={},target=/home/imagegen/.cache/nv",
                shader.display()
            ),
            "--entrypoint".into(),
            "/usr/local/bin/sd-cli".into(),
            self.image.clone(),
        ]);
        self.finish_run_args(a, job, files, names)
    }

    /// 1971-3erz: the engine's sandbox, shared by the one-shot sd-cli run and
    /// the resident sd-server (imagegen_warm.rs), so the two cannot drift.
    pub fn sandbox_args(&self, model_bytes: u64) -> Vec<String> {
        let mut a: Vec<String> = vec![
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
        // 1913-ebv8: in the forge's slice, ranked before it.
        a.extend(crate::oom_slice_args());
        if crate::nvidia_cdi_available() {
            a.extend(["--device".into(), "nvidia.com/gpu=all".into()]);
        } else if Path::new("/dev/dri").exists() {
            a.extend(["--device".into(), "/dev/dri".into()]);
        }
        a
    }

    /// The model file flags (`--model /models/...`), shared with imagegen_warm.rs.
    pub fn model_flags(&self, files: &[(String, PathBuf)]) -> Vec<String> {
        let mut a: Vec<String> = Vec::new();
        for (role, path) in files {
            // 1971-mcpu: a ControlNet's role is `controlnet:<name>`, never bare
            // `controlnet`; both aux kinds get their own flags below.
            if role.starts_with("controlnet:") || role == "controlnet" || role == "lora" {
                continue;
            }
            let rel = path.strip_prefix(&self.models_dir).unwrap_or(path);
            // The manifest's role column IS the sd-cli flag (docs/flux.md loads
            // FLUX as four files: --diffusion-model, --vae, --clip_l, --t5xxl).
            // A role the parser admits is one of these five; anything else is a
            // manifest bug and is named, not silently passed as a checkpoint.
            let flag = match role.as_str() {
                "model" => "--model",
                "diffusion_model" => "--diffusion-model",
                "vae" => "--vae",
                "clip_l" => "--clip_l",
                "t5xxl" => "--t5xxl",
                other => panic!("models.tsv role {other} has no sd-cli flag"),
            };
            a.extend([flag.into(), format!("/models/{}", rel.display())]);
        }
        a
    }

    fn finish_run_args(
        &self,
        mut a: Vec<String>,
        job: &Job,
        files: &[(String, PathBuf)],
        names: &[String],
    ) -> Vec<String> {
        a.extend(self.model_flags(files));
        if let Some((cn, image)) = &job.aux.control {
            a.extend([
                "--control-net".into(),
                format!("/models/{}/{}", cn.tier, cn.cache_name()),
                "--control-image".into(),
                image.clone(),
            ]);
        }
        // 1959-xsy5 (D11): sd-cli's image-to-image and inpaint flags
        // (examples/common/common.cpp: -i/--init-img, --mask, --strength).
        if let Some((init, mask, strength)) = &job.aux.init {
            a.extend(["--init-img".into(), init.clone()]);
            if let Some(m) = mask {
                a.extend(["--mask".into(), m.clone()]);
            }
            if let Some(s) = strength {
                a.extend(["--strength".into(), format!("{s}")]);
            }
        }
        let mut prompt = job.prompt.clone();
        if let Some((first, _)) = job.aux.loras.first() {
            a.extend(["--lora-model-dir".into(), format!("/models/{}", first.tier)]);
            for (m, w) in &job.aux.loras {
                let stem = m
                    .cache_name()
                    .trim_end_matches(".safetensors")
                    .trim_end_matches(".gguf");
                prompt.push_str(&format!(" <lora:{stem}:{w}>"));
            }
        }
        let threads = std::thread::available_parallelism().map_or(4, |n| (n.get() / 2).max(1));
        // sd-cli writes batch image i to the printf pattern; names are `<stem>-<i>.png`.
        let stem = names[0].trim_end_matches("-0.png");
        a.extend([
            "--prompt".into(),
            prompt,
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
        // 1971-3erz: a resident engine already runs this image; skip the check.
        let built = if crate::imagegen_warm::eligible(job)
            && crate::imagegen_warm::serving_image(&self.image)
        {
            false
        } else {
            self.ensure_image(progress)?
        };
        let pins = imagegen_models::files_for_tier(&imagegen_models::manifest(), &job.tier.tier);
        if pins.is_empty() {
            return Err(format!(
                "tier_unavailable: no pinned model files for {} yet",
                job.tier.tier
            ));
        }
        let mut pins = pins;
        pins.extend(job.aux.files());
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
        // 1971-3erz: a plain txt2img job reuses the resident engine.
        if crate::imagegen_warm::eligible(job) {
            let (timings, backend) =
                crate::imagegen_warm::generate(self, job, &files, out_dir, names, model_bytes)?;
            // 1972-phye: after the reply, one /api/ps look; a crowding LLM wins
            // the device. Off the critical path: the check is two podman calls
            // (~120-150 ms, measured on yoga), and releasing BEFORE this call
            // would only make the same GPU job cold.
            let _ = std::thread::Builder::new()
                .name("imagegen-warm-yield".into())
                .spawn(|| {
                    let arb = crate::gpu_queue::arbiter();
                    arb.yield_image_engine(arb.llm.ps().as_deref());
                });
            return Ok(EngineOut {
                backend,
                first_use: built || fetched,
                timings,
            });
        }
        let args = self.run_args(job, &files, out_dir, names, model_bytes);
        let mut log = String::new();
        let mut last = None;
        let t0 = std::time::Instant::now();
        let mut stamped: Vec<(u64, String)> = Vec::new();
        imagegen_models::run_streamed(&args, &mut |row| {
            stamped.push((t0.elapsed().as_millis() as u64, row.to_string()));
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
            timings: EngineTimings::from_cold(&stamped, t0.elapsed().as_millis() as u64),
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

    /// 1959-xsy5 (D11): a staged init image, mask and strength reach sd-cli
    /// as -i/--init-img, --mask and --strength, at the engine's /out paths;
    /// no init, no flags.
    #[test]
    fn imagegen_init_mask_flags_reach_sdcpp_args() {
        let args = json!({ "prompt": "ship hull" });
        let mut job = parse_job(&args, &imagegen_tiers::ladder(), "I0", false).unwrap();
        let e = PodmanSdCli {
            image: "img".into(),
            models_dir: PathBuf::from("/m"),
        };
        let run = |job: &Job| {
            e.run_args(
                job,
                &[("model".into(), PathBuf::from("/m/I0/sdxs09.safetensors"))],
                Path::new("/o"),
                &["img-1-2-0.png".into()],
                1,
            )
        };
        let plain = run(&job);
        for f in ["--init-img", "--mask", "--strength"] {
            assert!(
                !plain.contains(&f.to_string()),
                "{f} without an init image: {plain:?}"
            );
        }
        job.aux.init = Some((
            "/out/in/7-init.png".into(),
            Some("/out/in/7-mask.png".into()),
            Some(0.55),
        ));
        let a = run(&job);
        let after = |flag: &str| {
            a.iter()
                .position(|s| s == flag)
                .and_then(|i| a.get(i + 1))
                .cloned()
                .unwrap_or_else(|| panic!("{flag} missing from {a:?}"))
        };
        assert_eq!(after("--init-img"), "/out/in/7-init.png");
        assert_eq!(after("--mask"), "/out/in/7-mask.png");
        assert_eq!(after("--strength"), "0.55");
        job.aux.init = Some(("/out/in/8-init.png".into(), None, None));
        let img2img = run(&job);
        assert!(img2img.contains(&"--init-img".to_string()));
        assert!(
            !img2img.contains(&"--mask".to_string()),
            "image-to-image over the canvas: no mask"
        );
    }

    /// Order 1954-gdi6: a ControlNet image and LoRAs reach sd-cli, and a
    /// file the licence register does not admit is refused before anything runs.
    #[test]
    fn imagegen_control_image_and_lora_reach_sdcpp_args_and_licence_gate() {
        let rev = "c".repeat(40);
        let sha_cn = "a".repeat(64);
        let sha_lo = "b".repeat(64);
        let sha_un = "d".repeat(64);
        let manifest = format!(
            "I0/controlnet-openpose\tcontrolnet:openpose\tacme/cn-openpose-sdxl\t{rev}\topenpose.safetensors\t{sha_cn}\t10\tapache-2.0\n\
             I0/lora\tlora\tacme/robot-lora\t{rev}\trobot.safetensors\t{sha_lo}\t5\tmit\n\
             I0/lora\tlora\tacme/unlisted-lora\t{rev}\tunlisted.safetensors\t{sha_un}\t5\tmit\n"
        );
        let manifest = imagegen_models::parse_manifest(&manifest).unwrap();
        let register = format!(
            "cn\tacme/cn-openpose-sdxl\t{rev}\topenpose.safetensors\t{sha_cn}\tapache-2.0\tfalse\thttps://x\n\
             lo\tacme/robot-lora\t{rev}\trobot.safetensors\t{sha_lo}\tmit\tfalse\thttps://x\n"
        );
        let args = json!({
            "prompt": "a dancing robot",
            "control_net": "openpose",
            "control_image": format!("{FORGE_SCRATCH}/poses/pose-03.png"),
            "loras": [{"name": "robot", "weight": 0.8}],
        });
        let aux = parse_aux(&args, &manifest, &register).expect("registered files admitted");
        let mut job = parse_job(&args, &imagegen_tiers::ladder(), "I0", false).unwrap();
        job.aux = aux;
        let e = PodmanSdCli {
            image: "img".into(),
            models_dir: PathBuf::from("/m"),
        };
        // 1971-mcpu: generate passes run_args EVERY fetched file, the
        // ControlNet (role `controlnet:openpose`) and LoRAs included, as
        // ensure_files returns them. Passing only the base model hid a panic
        // that closed the Kumbia lane's MCP connection.
        let mut files = vec![(
            "model".to_string(),
            PathBuf::from("/m/I0/sdxs09.safetensors"),
        )];
        files.extend(
            job.aux
                .files()
                .iter()
                .map(|p| (p.role.clone(), PathBuf::from("/m/I0").join(p.cache_name()))),
        );
        let a = e.run_args(&job, &files, Path::new("/o"), &["img-1-2-0.png".into()], 1);
        let after = |flag: &str| {
            a.iter()
                .position(|s| s == flag)
                .and_then(|i| a.get(i + 1))
                .cloned()
                .unwrap_or_else(|| panic!("{flag} missing from {a:?}"))
        };
        assert_eq!(
            after("--control-net"),
            "/models/I0/controlnet-openpose/openpose.safetensors"
        );
        assert_eq!(after("--control-image"), "/out/poses/pose-03.png");
        assert_eq!(after("--lora-model-dir"), "/models/I0/lora");
        // A file pinned for another base tier is refused before sd-cli runs.
        assert!(job.aux.check_base("I0").is_ok());
        assert!(
            job.aux
                .check_base("I1")
                .unwrap_err()
                .starts_with("invalid_arguments:")
        );
        assert!(after("--prompt").ends_with("<lora:robot:0.8>"), "{a:?}");

        // A file the manifest lists but the register does not admit is refused.
        let bad = json!({"prompt": "x", "loras": [{"name": "unlisted"}]});
        let err = parse_aux(&bad, &manifest, &register).expect_err("unregistered refused");
        assert!(err.starts_with("model_refused:"), "{err}");
        // A name nothing pins is refused the same way, and downloads nothing.
        let bad = json!({"prompt": "x", "control_net": "canny",
                         "control_image": format!("{FORGE_SCRATCH}/a.png")});
        assert!(
            parse_aux(&bad, &manifest, &register)
                .unwrap_err()
                .starts_with("model_refused:")
        );
        // The control image must be a file in the lane's scratch folder.
        let bad = json!({"prompt": "x", "control_net": "openpose",
                         "control_image": "/etc/passwd"});
        assert!(
            parse_aux(&bad, &manifest, &register)
                .unwrap_err()
                .starts_with("invalid_arguments:")
        );
        let bad = json!({"prompt": "x", "control_net": "openpose",
                         "control_image": format!("{FORGE_SCRATCH}/../x.png")});
        assert!(
            parse_aux(&bad, &manifest, &register)
                .unwrap_err()
                .starts_with("invalid_arguments:")
        );
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

    /// 1959-flux: the I2 pins reach sd-cli the way docs/flux.md loads FLUX:
    /// `--diffusion-model <transformer> --vae <ae> --clip_l <clip> --t5xxl <t5>`,
    /// `--cfg-scale 1`, `--sampling-method euler`. Each flag is followed by its
    /// own file; `--model` (a full checkpoint) is not passed at all.
    #[test]
    fn flux_pins_are_passed_as_the_four_separate_sd_cpp_flags() {
        let e = PodmanSdCli {
            image: "img".into(),
            models_dir: PathBuf::from("/m"),
        };
        let job = parse_job(
            &json!({"prompt":"a fox"}),
            &imagegen_tiers::ladder(),
            "I2",
            false,
        )
        .unwrap();
        let pins = imagegen_models::files_for_tier(&imagegen_models::manifest(), "I2");
        assert!(!pins.is_empty(), "I2 has pinned files");
        let files: Vec<(String, PathBuf)> = pins
            .iter()
            .map(|p| (p.role.clone(), PathBuf::from("/m/I2").join(p.cache_name())))
            .collect();
        let a = e.run_args(&job, &files, Path::new("/o"), &["img-0.png".into()], 1);
        let after = |flag: &str| -> String {
            let i = a
                .iter()
                .position(|s| s == flag)
                .unwrap_or_else(|| panic!("{flag} missing from {a:?}"));
            a[i + 1].clone()
        };
        assert!(after("--diffusion-model").contains("flux1-schnell"));
        assert!(after("--vae").ends_with("/ae.safetensors"));
        assert!(after("--clip_l").contains("clip_l"));
        assert!(after("--t5xxl").contains("t5xxl"));
        assert!(
            !a.contains(&"--model".to_string()),
            "no full checkpoint for FLUX"
        );
        assert_eq!(after("--cfg-scale"), "1");
        assert_eq!(after("--sampling-method"), "euler");
    }

    /// Counts engine runs, so a fixture can prove a refusal ran nothing.
    struct Counting(std::sync::atomic::AtomicUsize);
    impl Engine for Counting {
        fn generate(
            &self,
            job: &Job,
            out_dir: &Path,
            names: &[String],
            _progress: &mut dyn FnMut(Progress),
        ) -> Result<EngineOut, String> {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            for n in names {
                image::RgbImage::new(job.width, job.height)
                    .save(out_dir.join(n))
                    .map_err(|e| e.to_string())?;
            }
            Ok(EngineOut {
                timings: Default::default(),
                backend: "cuda".into(),
                first_use: false,
            })
        }
    }

    /// Records how many generates are in flight at once, and reports "mixed".
    #[derive(Default)]
    struct Overlap {
        now: std::sync::atomic::AtomicUsize,
        max: std::sync::atomic::AtomicUsize,
    }
    impl Engine for Overlap {
        fn generate(
            &self,
            job: &Job,
            out_dir: &Path,
            names: &[String],
            _progress: &mut dyn FnMut(Progress),
        ) -> Result<EngineOut, String> {
            use std::sync::atomic::Ordering::SeqCst;
            let n = self.now.fetch_add(1, SeqCst) + 1;
            self.max.fetch_max(n, SeqCst);
            std::thread::sleep(std::time::Duration::from_millis(40));
            for n in names {
                image::RgbImage::new(job.width, job.height)
                    .save(out_dir.join(n))
                    .map_err(|e| e.to_string())?;
            }
            self.now.fetch_sub(1, SeqCst);
            Ok(EngineOut {
                timings: Default::default(),
                backend: "mixed".into(),
                first_use: false,
            })
        }
    }

    /// 1955-rjv3 verifiable closure. Pre-fix: FAILS (six parallel calls ran
    /// six engines on one device; "mixed" came back as plain success).
    #[test]
    fn imagegen_concurrent_calls_never_overlap_on_the_device() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        imagegen_consent::reset_for_test();
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let engine = Arc::new(Overlap::default());
        install_seam(Some(Seam {
            engine: engine.clone(),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I0".into(),
            // 1967-seam: pinned, so the test never reads the host's real
            // model cache (a host without I0 answered consent_required).
            present: Some(vec!["I0".into()]),
        }));
        let handles: Vec<_> = (0..6)
            .map(|i| {
                std::thread::spawn(move || {
                    let mut queued = Vec::new();
                    let r = call(
                        "rjv3-proj",
                        &format!("lane{i}"),
                        &json!({"prompt":"a fox","width":64,"height":64,"seed":i}),
                        &mut |p| {
                            if let Progress::Queued { position } = p {
                                queued.push(position)
                            }
                        },
                    );
                    (r, queued)
                })
            })
            .collect();
        let mut saw_queue = false;
        for h in handles {
            let (r, queued) = h.join().unwrap();
            let r = r.expect("a queued call runs, it is not refused");
            assert_eq!(r["degraded"]["backend"], "mixed", "mixed is degraded: {r}");
            assert!(r["degraded"]["why"].as_str().is_some_and(|w| !w.is_empty()));
            saw_queue |= queued.iter().any(|p| *p >= 1);
        }
        install_seam(None);
        assert_eq!(
            engine.max.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "two engines ran on the device at once"
        );
        assert!(saw_queue, "a waiting call reports its queue position");
    }

    fn seam_with(present: &[&str]) -> (Arc<Counting>, tempfile::TempDir) {
        imagegen_consent::reset_for_test();
        let scratch =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let engine = Arc::new(Counting(Default::default()));
        install_seam(Some(Seam {
            engine: engine.clone(),
            scratch_root: scratch.path().to_path_buf(),
            ceiling: "I3".into(),
            present: Some(present.iter().map(|t| t.to_string()).collect()),
        }));
        (engine, scratch)
    }

    fn small(prompt: &str, tier: Option<&str>) -> Value {
        let mut a = json!({"prompt": prompt, "width": 64, "height": 64});
        if let Some(t) = tier {
            a["tier"] = json!(t);
        }
        a
    }

    /// 1957-5m8g operator ruling 2026-11-01: a tierless call runs at the
    /// highest tier within the ceiling whose files are here. Pre-fix: FAILS
    /// (runs I0).
    #[test]
    fn tierless_call_on_an_i3_host_with_i3_present_runs_i3() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (engine, _s) = seam_with(&["I0", "I1", "I2", "I3"]);
        let mut sink = |_: Progress| {};
        let r = call("dl-a", "a", &small("a demon", None), &mut sink).unwrap();
        assert_eq!(r["tier"], "I3", "{r}");
        assert!(r["bigger_tier_offer"].is_null(), "{r}");
        // D5: image.generate speaks the same provenance schema as the studio.
        assert_eq!(r["provenance"]["schema"], "tillandsias.provenance/v1");
        assert_eq!(r["provenance"]["engine"]["name"], "sd.cpp");
        assert_eq!(
            r["provenance"]["engine"]["ref"],
            crate::provenance::SDCPP_TAG
        );
        assert_eq!(r["provenance"]["placement"], "cuda");
        assert_eq!(engine.0.load(std::sync::atomic::Ordering::SeqCst), 1);
        // Smaller tiers stay available when asked for by name.
        let r = call("dl-a", "a", &small("a demon", Some("I1")), &mut sink).unwrap();
        assert_eq!(r["tier"], "I1", "{r}");
        install_seam(None);
    }

    /// Pre-fix: FAILS (consent_required: I3 must be reached rung by rung).
    #[test]
    fn direct_i3_request_with_files_present_needs_no_token() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (engine, _s) = seam_with(&["I0", "I3"]);
        let mut sink = |_: Progress| {};
        let r = call("dl-b", "a", &small("a demon", Some("I3")), &mut sink).unwrap();
        assert_eq!(r["tier"], "I3", "no token, no ladder walk: {r}");
        assert_eq!(engine.0.load(std::sync::atomic::Ordering::SeqCst), 1);
        install_seam(None);
    }

    /// Pre-fix: FAILS (the offer is for I1, not a download of I3, and the yes
    /// does not hold for other pictures / sessions on this host).
    #[test]
    fn direct_i3_request_with_files_missing_asks_once_to_download_then_never_again() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (engine, _s) = seam_with(&["I0"]);
        let runs = || engine.0.load(std::sync::atomic::Ordering::SeqCst);
        let mut sink = |_: Progress| {};
        let r = call("dl-c", "a", &small("a demon", Some("I3")), &mut sink).unwrap();
        assert_eq!(r["status"], "consent_required", "{r}");
        let offer = &r["bigger_tier_offer"];
        assert_eq!(
            offer["tier"], "I3",
            "the download asked for is I3 itself: {r}"
        );
        let ask = offer["ask"].as_str().unwrap();
        assert!(ask.contains(" GB") && ask.contains(" min"), "{ask}");
        assert_eq!(runs(), 0);
        let mut yes = small("a demon", Some("I3"));
        yes["consent_token"] = offer["consent_token"].clone();
        let r = call("dl-c", "a", &yes, &mut sink).unwrap();
        assert_eq!(r["tier"], "I3", "{r}");
        assert_eq!(runs(), 1);
        // Never again on this host: another picture, another session, tierless.
        for (inst, args) in [
            ("a", small("a castle", Some("I3"))),
            ("b", small("a boat", Some("I3"))),
            ("c", small("a fox", None)),
        ] {
            let r = call("dl-c", inst, &args, &mut sink).unwrap();
            assert_eq!(r["tier"], "I3", "{inst}: {r}");
            assert!(r["bigger_tier_offer"].is_null(), "{inst}: {r}");
        }
        assert_eq!(runs(), 4);
        install_seam(None);
    }

    /// 1957-5m8g operator decision 2026-11-01: I0 asks too. Pre-fix: FAILS
    /// (I0 runs and fetches unasked).
    #[test]
    fn a_fresh_hosts_first_tierless_call_asks_before_any_fetch() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (engine, _s) = seam_with(&[]);
        let mut sink = |_: Progress| {};
        let r = call("dl-d", "a", &small("a demon", None), &mut sink).unwrap();
        assert_eq!(r["status"], "consent_required", "{r}");
        assert_eq!(r["bigger_tier_offer"]["tier"], "I0", "{r}");
        let ask = r["bigger_tier_offer"]["ask"].as_str().unwrap();
        assert!(ask.contains(" GB") && ask.contains(" min"), "{ask}");
        assert!(ask.contains("a while") && ask.contains("metered"), "{ask}");
        assert_eq!(
            engine.0.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "nothing fetched or run"
        );
        install_seam(None);
    }

    /// Declining a download offer runs and fetches nothing and says so.
    #[test]
    fn declining_a_download_leaves_nothing_downloaded() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (engine, _s) = seam_with(&[]);
        let mut sink = |_: Progress| {};
        let r = call("dl-e", "a", &small("a demon", None), &mut sink).unwrap();
        let mut no = small("a demon", Some("I0"));
        no["consent_token"] = r["bigger_tier_offer"]["consent_token"].clone();
        no["decline"] = json!(true);
        let r = call("dl-e", "a", &no, &mut sink).unwrap();
        assert_eq!(r["status"], "declined", "{r}");
        assert_eq!(r["downloaded"], false);
        assert_eq!(r["ran"], false);
        assert_eq!(engine.0.load(std::sync::atomic::Ordering::SeqCst), 0);
        // Declining grants nothing: the next call still asks.
        let r = call("dl-e", "a", &small("a demon", None), &mut sink).unwrap();
        assert_eq!(r["status"], "consent_required", "{r}");
        install_seam(None);
    }

    /// 1971-3erz: the cold split from sd-cli's own lines, stamped as they
    /// arrived. These are rows of the yoga run measured 2026-11-03.
    #[test]
    fn a_cold_runs_timings_come_from_the_engines_own_lines() {
        let rows: Vec<(u64, String)> = [
            (
                102,
                "[V] version: stable-diffusion.cpp version master-1015-e41fbcf",
            ),
            (
                1775,
                "[I] loading tensors completed, taking 0.20s (read: 0.03s)",
            ),
            (
                3430,
                "[I] loading tensors completed, taking 0.40s (read: 0.04s)",
            ),
            (
                5764,
                "[I] sampling completed, taking 2.04s --- image.cpp:953",
            ),
            (
                6974,
                "[I] decode_first_stage completed, taking 1.21s --- image.cpp:675",
            ),
            (7096, "[I] 1/1 images saved --- main.cpp:528"),
        ]
        .into_iter()
        .map(|(t, s)| (t, s.to_string()))
        .collect();
        let t = EngineTimings::from_cold(&rows, 7149);
        assert_eq!(
            t,
            EngineTimings {
                warm: false,
                container_start_ms: 102,
                // sampling began at 5764 - 2040 = 3724
                model_load_ms: 3724 - 102,
                sample_ms: 2040,
                decode_ms: 1210,
                total_ms: 7149,
            }
        );
        let w = EngineTimings::from_warm(&rows[3..5], 2867);
        assert!(w.warm);
        assert_eq!((w.container_start_ms, w.model_load_ms), (0, 0));
        assert_eq!((w.sample_ms, w.decode_ms, w.total_ms), (2040, 1210, 2867));
    }

    /// 1971-3erz criterion 1: the result names the engine's split. Pre-fix:
    /// FAILS (no timings key).
    #[test]
    fn the_result_carries_the_engines_timings_and_the_warm_ttl() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (_engine, _s) = seam_with(&["I0"]);
        let mut sink = |_: Progress| {};
        let r = call("dl-t", "a", &small("a demon", Some("I0")), &mut sink).unwrap();
        for k in [
            "container_start_ms",
            "model_load_ms",
            "sample_ms",
            "decode_ms",
            "total_ms",
            "warm_ttl_s",
        ] {
            assert!(r["timings"][k].is_u64(), "{k} missing: {r}");
        }
        assert!(r["timings"]["warm"].is_boolean(), "{r}");
        install_seam(None);
    }
}
