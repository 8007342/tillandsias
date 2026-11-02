//! `studio.key_footage` on the per-lane MCP socket (order 1956-ucix, implements
//! 1954-xy5m): CorridorKey 2.0 as a PROOF OF CONCEPT studio job.
//!
//! @trace order:1956-ucix, order:1954-xy5m (spec: openspec/changes/studio-asset-pipeline, design D9, not yet archived)
//!
//! A forge agent keys green- or blue-screen footage (a video file or a frame
//! directory under /work/tmp/imagegen/) with upstream's `infer.py`, run from a
//! pinned commit in a separate CUDA image (images/imagegen-corridorkey) that
//! is built on first use. Outputs land under /work/tmp/imagegen/studio/<job>/
//! with a provenance record beside each. Design rulings this follows:
//!
//! - D9: the weights and the three foundation models come from the RESTRICTED
//!   register, behind D6. Nothing here fetches them: the user's machine does,
//!   after consent, into `<models_dir>/corridorkey/`, which the container sees
//!   read-only as /models/corridorkey. The gate is ONE call,
//!   [`crate::licence_consent::admits_restricted`]; a refusal names the
//!   artefact and nothing is queued. (Until order 1956-ecpb lands that module
//!   is a shim refusing everything.)
//! - Opt-in only: the tool is listed, and the call admitted, only for a
//!   project with `[imagegen] corridorkey = true`. No automatic wiring ships
//!   to other users until Corridor has seen the demo (operator ruling on
//!   1954-xy5m, clause 2d).
//! - CUDA only (RTX 30 series or newer per upstream): a host without a
//!   container-reachable NVIDIA card is refused by name, `corridorkey_needs_cuda`.
//! - D3: the job takes the one GPU turn per host (gpu_queue.rs) and holds it
//!   only while the container runs; a one-shot container leaves the device
//!   empty, so there is no `/free` to call.
//! - D5: provenance v1 beside each output: engine corridorkey at the pinned
//!   commit, every weight with sha256 and licence, the input hashes and the
//!   CLI arguments.
#![cfg_attr(not(test), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::gpu_queue;
use crate::imagegen_models::ModelFile;
use crate::imagegen_tool::{EPHEMERAL_NOTE, FORGE_SCRATCH, Progress};
use crate::licence_consent::{self, RestrictedArtefact};
use crate::provenance;

/// The image name `image_specs` and `runtime_assets` resolve.
pub const IMAGE: &str = "imagegen-corridorkey";
/// The upstream repository and the pinned commit (`ARG CORRIDORKEY_SHA` in the
/// Containerfile; a test keeps them equal).
pub const UPSTREAM: &str = "github.com/nikopueringer/CorridorKey2.0";
pub const COMMIT: &str = "485f5e9ab759ead6138cc990776184b59d6ea971";
/// The licence id of the CorridorKey weights (CORRIDOR KEY LICENCE v2.0, a
/// CC BY-NC-SA 4.0 variant): restricted, never on the permissive list.
pub const CORRIDOR_LICENCE: &str = "corridor-key-licence-2.0";
/// The weight manifest, data beside the Containerfile.
pub const WEIGHTS_TSV: &str = include_str!("../../../images/imagegen-corridorkey/weights.tsv");
/// Where the weights live under the shared model cache, and under /models.
pub const CACHE_SUBDIR: &str = "corridorkey";
/// infer.py's `--outputs` vocabulary, and the D9 default set.
pub const OUTPUTS: &[&str] = &["alpha", "fg", "checker", "cutout"];
const DEFAULT_OUTPUTS: &[&str] = &["alpha", "fg", "cutout"];
/// A keying run is bounded; upstream keys 4K in minutes, long clips in tens.
const RUN_TIMEOUT: Duration = Duration::from_secs(4 * 3600);

pub fn descriptor() -> Value {
    json!({
        "name": "studio.key_footage",
        "description": format!(
            "This is a proof of concept (order 1956-ucix): key green- or blue-screen footage with CorridorKey 2.0 \
             (infer.py at upstream commit {short}) in a separate CUDA container built on first use, and \
             return output paths under {FORGE_SCRATCH}/studio/<job>/ with a provenance record beside each. \
             Runs only for a project with `[imagegen] corridorkey = true`, only on an NVIDIA CUDA host \
             (corridorkey_needs_cuda otherwise), and only when the licence consent gate admits the \
             CorridorKey weights and their three foundation models (consent_required otherwise; nothing \
             is fetched or queued). The weights are never bundled: they come from the user's own model \
             cache, read-only. The CorridorKey licence is a CC BY-NC-SA 4.0 variant: attribution \
             \"CorridorKey\", share-alike on modifications, no resale or paid API, seats above the revenue \
             threshold, and Corridor's written agreement for commercial integration. Corridor sees this \
             demo before any wider release; no automatic wiring ships to other users until then. Shares \
             the host's GPU queue with image.generate; progress arrives as MCP progress notifications. \
             {EPHEMERAL_NOTE}",
            short = &COMMIT[..12]
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "input": { "type": "string",
                           "description": format!("A video file or a directory of frames under {FORGE_SCRATCH}/.") },
                "outputs": { "type": "array", "items": { "type": "string", "enum": OUTPUTS },
                             "default": DEFAULT_OUTPUTS,
                             "description": "Which outputs infer.py writes: alpha, fg, checker, cutout." },
                "low_vram": { "type": "boolean", "default": false,
                              "description": "Staged low-memory inference (4 GB cards, long clips)." }
            },
            "required": ["input"]
        }
    })
}

// ─── Request ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    /// The forge path, `/work/tmp/imagegen/<rel>`.
    pub input: String,
    pub outputs: Vec<String>,
    pub low_vram: bool,
}

impl Request {
    /// `<rel>` of the input under the lane scratch.
    pub fn input_rel(&self) -> &str {
        self.input
            .strip_prefix(&format!("{FORGE_SCRATCH}/"))
            .unwrap_or(&self.input)
    }
}

pub fn parse_request(args: &Value) -> Result<Request, String> {
    let input = args["input"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "invalid_arguments: input (a path under /work/tmp/imagegen/) is required".to_string())?;
    let rel = input.strip_prefix(&format!("{FORGE_SCRATCH}/")).ok_or_else(|| {
        format!("invalid_arguments: input {input:?} must be under {FORGE_SCRATCH}/ (the lane's scratch volume)")
    })?;
    if rel.is_empty()
        || rel.contains('\\')
        || rel.split('/').any(|c| c.is_empty() || c == "." || c == "..")
    {
        return Err(format!(
            "invalid_arguments: input {input:?} must name a file or directory inside {FORGE_SCRATCH}/"
        ));
    }
    let outputs: Vec<String> = match args.get("outputs") {
        None | Some(Value::Null) => DEFAULT_OUTPUTS.iter().map(|s| s.to_string()).collect(),
        Some(Value::Array(items)) => {
            let mut out = Vec::new();
            for item in items {
                let s = item
                    .as_str()
                    .map(|s| s.trim().to_ascii_lowercase())
                    .ok_or_else(|| "invalid_arguments: outputs must be strings".to_string())?;
                if !OUTPUTS.contains(&s.as_str()) {
                    return Err(format!(
                        "invalid_arguments: outputs: {s:?} is not one of {}",
                        OUTPUTS.join(", ")
                    ));
                }
                if !out.contains(&s) {
                    out.push(s);
                }
            }
            if out.is_empty() {
                return Err("invalid_arguments: outputs must name at least one output".into());
            }
            out
        }
        Some(_) => return Err("invalid_arguments: outputs must be an array of strings".into()),
    };
    let low_vram = match args.get("low_vram") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err("invalid_arguments: low_vram must be a boolean".into()),
    };
    Ok(Request {
        input: input.to_string(),
        outputs,
        low_vram,
    })
}

// ─── Weights ─────────────────────────────────────────────────────────────────

/// Parse weights.tsv: `role repo revision file sha256 bytes licence source`.
/// `file` is the path under /models/corridorkey/, which is upstream's
/// package-relative path, so it begins with `weights/` or `vfms/`.
pub fn parse_weights(body: &str) -> Result<Vec<ModelFile>, String> {
    let mut rows = Vec::new();
    for (n, line) in body.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != 8 {
            return Err(format!(
                "weights.tsv line {}: {} columns, want 8",
                n + 1,
                c.len()
            ));
        }
        let row = ModelFile {
            tier: CACHE_SUBDIR.to_string(),
            role: c[0].to_string(),
            repo: c[1].to_string(),
            revision: c[2].to_string(),
            file: c[3].to_string(),
            sha256: c[4].to_ascii_lowercase(),
            bytes: c[5]
                .parse()
                .map_err(|e| format!("weights.tsv line {}: bytes: {e}", n + 1))?,
            licence: c[6].to_string(),
        };
        if row.sha256.len() != 64 || !row.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("weights.tsv line {}: sha256 is not 64 hex", n + 1));
        }
        if !(row.file.starts_with("weights/") || row.file.starts_with("vfms/"))
            || row.file.split('/').any(|p| p.is_empty() || p == "..")
        {
            return Err(format!(
                "weights.tsv line {}: {} is not a package-relative weights/ or vfms/ path",
                n + 1,
                row.file
            ));
        }
        if row.licence.is_empty() || c[7].is_empty() {
            return Err(format!("weights.tsv line {}: licence and source are required", n + 1));
        }
        rows.push(row);
    }
    if !rows.iter().any(|r| r.licence == CORRIDOR_LICENCE) {
        return Err("weights.tsv: no CorridorKey row".into());
    }
    Ok(rows)
}

/// The shipped manifest (a test keeps it parseable).
pub fn weights() -> Vec<ModelFile> {
    parse_weights(WEIGHTS_TSV).unwrap_or_default()
}

/// Every weight as the consent gate names it. All rows go through the gate,
/// not only the restricted one: the operator's acknowledgement covers the
/// set D9 names, and a permissive row simply has a permissive licence.
pub fn artefacts(rows: &[ModelFile]) -> Vec<RestrictedArtefact> {
    rows.iter()
        .map(|m| RestrictedArtefact {
            licence: m.licence.clone(),
            repo: m.repo.clone(),
            revision: m.revision.clone(),
            file: m.file.clone(),
            sha256: m.sha256.clone(),
        })
        .collect()
}

/// The weights the cache lacks (by presence and size; the sha256 was checked
/// at fetch time by the gate and is recorded in the provenance).
fn missing_weights(models_dir: &Path, rows: &[ModelFile]) -> Vec<String> {
    rows.iter()
        .filter(|m| {
            let p = models_dir.join(CACHE_SUBDIR).join(&m.file);
            !std::fs::metadata(&p).is_ok_and(|md| md.is_file() && md.len() == m.bytes)
        })
        .map(|m| format!("{} ({}@{})", m.file, m.repo, m.revision))
        .collect()
}

// ─── Engine and seam ─────────────────────────────────────────────────────────

/// The engine behind the tool. Production is [`PodmanKey`]; fixtures stub it.
pub trait KeyEngine: Send + Sync {
    /// Build the image on first use (never INIT).
    fn ensure_image(&self, progress: &mut dyn FnMut(Progress)) -> Result<(), String>;
    /// Run the one-shot container with the full podman argv. Under the GPU turn.
    fn run(&self, argv: &[String], progress: &mut dyn FnMut(Progress)) -> Result<(), String>;
}

/// Fixture seam: a stub engine, a scratch root, a project checkout, a model
/// cache and whether the host counts as CUDA.
pub struct Seam {
    pub engine: Arc<dyn KeyEngine>,
    pub scratch_root: PathBuf,
    pub project_root: PathBuf,
    pub models_dir: PathBuf,
    pub cuda: bool,
}

fn seam() -> &'static Mutex<Option<Seam>> {
    static SEAM: OnceLock<Mutex<Option<Seam>>> = OnceLock::new();
    SEAM.get_or_init(|| Mutex::new(None))
}

#[cfg(test)]
pub fn install_seam(s: Option<Seam>) {
    *seam().lock().unwrap() = s;
}

/// Serialises tests that install the process-wide seam.
#[cfg(test)]
pub static SEAM_TEST_LOCK: Mutex<()> = Mutex::new(());

fn with_seam<T>(f: impl FnOnce(&Seam) -> T) -> Option<T> {
    seam().lock().ok().and_then(|s| s.as_ref().map(f))
}

fn scratch_dir(project: &str, instance: &str) -> Result<PathBuf, String> {
    if let Some(root) = with_seam(|s| s.scratch_root.clone()) {
        let dir = root.join(crate::imagegen_tool::lane_volume(project, instance));
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        return Ok(dir);
    }
    crate::imagegen_tool::lane_scratch_dir(project, instance)
}

fn models_dir() -> PathBuf {
    with_seam(|s| s.models_dir.clone()).unwrap_or_else(crate::imagegen_models::models_dir)
}

/// Whether this host's containers can reach an NVIDIA card through CDI.
fn host_has_cuda() -> bool {
    with_seam(|s| s.cuda).unwrap_or_else(crate::nvidia_cdi_available)
}

/// The project's `.tillandsias/config.toml`, read from the lane's checkout
/// (the seam's directory, else through the live forge as studio_tool does).
fn project_config(project: &str, instance: &str) -> Option<tillandsias_core::config::ProjectConfig> {
    const REL: &str = ".tillandsias/config.toml";
    let text = match with_seam(|s| s.project_root.clone()) {
        Some(root) => std::fs::read_to_string(root.join(REL)).ok()?,
        None => crate::studio_tool::read_checkout_file(project, instance, REL).ok()?,
    };
    toml::from_str(&text).ok()
}

/// `[imagegen] corridorkey = true` in the project's config: the only way the
/// tool is listed or admitted.
pub fn enabled(project: &str, instance: &str) -> bool {
    project_config(project, instance)
        .and_then(|c| c.imagegen)
        .is_some_and(|c| c.corridorkey)
}

// ─── The podman argv ─────────────────────────────────────────────────────────

/// The full `podman run` argv for one job: a one-shot container with no
/// network, the shared cache read-only at /models, the lane volume at /out,
/// the CDI GPU, then infer.py's own flags.
pub fn run_args(
    req: &Request,
    job: &str,
    models_dir: &Path,
    lane_volume: &str,
    image: &str,
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
        "--oom-score-adj=1000".into(),
        "--pids-limit=256".into(),
        "--label".into(),
        format!("tillandsias.studio.job={job}"),
    ];
    a.extend(crate::oom_slice_args());
    a.extend(["--device".into(), "nvidia.com/gpu=all".into()]);
    a.extend([
        "--mount".into(),
        format!(
            "type=bind,source={},target=/models,readonly=true",
            models_dir.display()
        ),
        "--mount".into(),
        format!("type=volume,source={lane_volume},target=/out"),
        image.to_string(),
        "--input".into(),
        format!("/out/{}", req.input_rel()),
        "--output_dir".into(),
        format!("/out/studio/{job}"),
        "--outputs".into(),
    ]);
    a.extend(req.outputs.iter().cloned());
    if req.low_vram {
        a.push("--low_vram".into());
    }
    a
}

/// The CLI the provenance records: everything after the image name.
fn cli_of(argv: &[String], image: &str) -> Vec<String> {
    match argv.iter().position(|a| a == image) {
        Some(i) => argv[i + 1..].to_vec(),
        None => argv.to_vec(),
    }
}

// ─── Hashing and provenance ──────────────────────────────────────────────────

/// The input's digest(s): one for a file, one per regular file (sorted) for
/// a frame directory. `forge_path` is how the record names it.
pub fn hash_inputs(host: &Path, forge_path: &str) -> Result<Vec<provenance::Input>, String> {
    let md = std::fs::metadata(host)
        .map_err(|e| format!("invalid_arguments: {forge_path}: {e}"))?;
    if md.is_file() {
        return Ok(vec![provenance::Input {
            name: "input".into(),
            path: forge_path.to_string(),
            sha256: provenance::sha256_file(host)?,
        }]);
    }
    if !md.is_dir() {
        return Err(format!(
            "invalid_arguments: {forge_path} is neither a file nor a directory"
        ));
    }
    let mut names: Vec<String> = std::fs::read_dir(host)
        .map_err(|e| format!("invalid_arguments: {forge_path}: {e}"))?
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    if names.is_empty() {
        return Err(format!("invalid_arguments: {forge_path} holds no frames"));
    }
    names
        .iter()
        .map(|n| {
            Ok(provenance::Input {
                name: format!("frame:{n}"),
                path: format!("{forge_path}/{n}"),
                sha256: provenance::sha256_file(&host.join(n))?,
            })
        })
        .collect()
}

/// D5: the record every output of a job carries. `cli` is infer.py's argv,
/// which already carries the request's outputs and low_vram.
pub fn provenance_record(
    _req: &Request,
    inputs: &[provenance::Input],
    placement: &str,
    cli: &[String],
) -> provenance::Record {
    provenance::Record {
        engine: provenance::Engine::CorridorKey {
            upstream: UPSTREAM,
            commit: COMMIT,
        },
        workflow: None,
        models: weights(),
        inputs: inputs.to_vec(),
        seed: 0,
        prompt: String::new(),
        negative_prompt: String::new(),
        tier: None,
        placement: placement.to_string(),
        family: None,
        consent: None,
        cli: Some(cli.to_vec()),
    }
}

fn job_id() -> String {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    static SEQ: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("ck-{stamp}-{n}")
}

// ─── The call ────────────────────────────────────────────────────────────────

/// The tool call. Refusals, in order and each by name, before anything is
/// queued: `invalid_arguments`, `corridorkey_not_enabled`,
/// `corridorkey_needs_cuda`, `consent_required`, `weights_missing`.
pub fn call(
    project: &str,
    instance: &str,
    args: &Value,
    progress: &mut dyn FnMut(Progress),
) -> Result<Value, String> {
    let req = parse_request(args)?;
    if !enabled(project, instance) {
        return Err(format!(
            "corridorkey_not_enabled: {project} has not opted in; set `[imagegen] corridorkey = true` \
             in .tillandsias/config.toml. This is a proof of concept: no automatic wiring ships to \
             other users until Corridor has seen the demo."
        ));
    }
    if !host_has_cuda() {
        return Err(
            "corridorkey_needs_cuda: CorridorKey 2.0 runs only on an NVIDIA CUDA GPU (RTX 30 series \
             or newer, 4-6 GB VRAM) reachable by containers through CDI; this host has none. Nothing \
             was queued."
                .into(),
        );
    }
    let rows = weights();
    // D6/D9: ONE gate, one call. A refusal names the artefact; nothing is fetched or queued.
    let consent = licence_consent::admits_restricted(project, &artefacts(&rows))?;

    let scratch = scratch_dir(project, instance)?;
    let host_input = scratch.join(req.input_rel());
    let inputs = hash_inputs(&host_input, &req.input)?;
    let models = models_dir();
    let missing = missing_weights(&models, &rows);
    if !missing.is_empty() {
        return Err(format!(
            "weights_missing: {} file(s) are not in the model cache at {}/{CACHE_SUBDIR}: {}. They are \
             fetched on this machine by the consent-gated fetch (order 1956-ecpb), never bundled. \
             Nothing was queued.",
            missing.len(),
            models.display(),
            missing.join("; ")
        ));
    }

    let engine: Arc<dyn KeyEngine> = match with_seam(|s| s.engine.clone()) {
        Some(e) => e,
        None => Arc::new(PodmanKey::for_this_host()),
    };
    engine.ensure_image(progress)?;

    let job = job_id();
    let image = with_seam(|_| format!("{IMAGE}:seam"))
        .unwrap_or_else(|| crate::versioned_image_tag(IMAGE, crate::VERSION.trim()));
    let lane_volume = crate::imagegen_tool::lane_volume(project, instance);
    let argv = run_args(&req, &job, &models, &lane_volume, &image);
    let out_dir = scratch.join("studio").join(&job);
    std::fs::create_dir_all(&out_dir).map_err(|e| format!("{}: {e}", out_dir.display()))?;

    let t0 = Instant::now();
    // D3: one GPU queue per host; the turn covers the container's life.
    let turn = gpu_queue::wait_for_gpu(&mut |position| progress(Progress::Queued { position }));
    let ran = engine.run(&argv, progress);
    drop(turn);
    if let Err(e) = ran {
        return Err(gpu_queue::explain_engine_failure(
            &e,
            gpu_queue::vram_holders(),
        ));
    }
    let elapsed = t0.elapsed().as_secs_f64();

    // One record per top-level output (a file, or an EXR sequence directory).
    let mut record = provenance_record(&req, &inputs, "cuda", &cli_of(&argv, &image));
    record.consent = Some(consent);
    let mut names: Vec<String> = std::fs::read_dir(&out_dir)
        .map_err(|e| format!("engine_failed: {}: {e}", out_dir.display()))?
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.ends_with(".provenance.json"))
        .collect();
    names.sort();
    if names.is_empty() {
        return Err("engine_failed: infer.py finished but wrote no output".into());
    }
    let mut outputs = Vec::new();
    for name in &names {
        let host = out_dir.join(name);
        let prov = record.write_beside(&host)?;
        let forge = format!("{FORGE_SCRATCH}/studio/{job}/{name}");
        outputs.push(json!({
            "path": forge,
            "kind": OUTPUTS.iter().find(|k| name.contains(*k)).copied(),
            "is_dir": host.is_dir(),
            "provenance_path": format!("{forge}.provenance.json"),
            "provenance": prov,
        }));
    }
    Ok(json!({
        "job": job,
        "engine": { "name": "corridorkey", "commit": COMMIT, "status": "proof-of-concept" },
        "outputs": outputs,
        "provenance": outputs[0]["provenance"],
        "placement": "cuda",
        "elapsed_s": (elapsed * 100.0).round() / 100.0,
        "ephemeral": true,
        "note": EPHEMERAL_NOTE,
    }))
}

// ─── Production engine ───────────────────────────────────────────────────────

/// A one-shot `podman run` of the imagegen-corridorkey image per job.
pub struct PodmanKey {
    pub image: String,
}

impl PodmanKey {
    pub fn for_this_host() -> Self {
        PodmanKey {
            image: crate::versioned_image_tag(IMAGE, crate::VERSION.trim()),
        }
    }
}

impl KeyEngine for PodmanKey {
    fn ensure_image(&self, progress: &mut dyn FnMut(Progress)) -> Result<(), String> {
        if tillandsias_podman::image_exists_sync(&self.image) {
            return Ok(());
        }
        progress(Progress::Building);
        let root = crate::resolve_runtime_asset_root(crate::VERSION.trim(), false)?;
        crate::ensure_image_exists(&root, IMAGE, &self.image, false)
    }

    fn run(&self, argv: &[String], progress: &mut dyn FnMut(Progress)) -> Result<(), String> {
        progress(Progress::Step { done: 0, total: 1 });
        let mut cmd = tillandsias_podman::podman_cmd_sync();
        cmd.args(argv);
        let out = cmd
            .output_bounded(RUN_TIMEOUT)
            .map_err(|e| format!("engine_failed: podman run: {e}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            let tail: Vec<&str> = err.lines().rev().take(12).collect::<Vec<_>>().into_iter().rev().collect();
            return Err(format!(
                "engine_failed: infer.py exited {}: {}",
                out.status.code().unwrap_or(-1),
                tail.join("\n")
            ));
        }
        progress(Progress::Step { done: 1, total: 1 });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};

    const LANE_VOLUME: &str = "tillandsias-imagegen-ucix-proj-a";

    struct Fixture {
        _scratch: tempfile::TempDir,
        scratch_root: PathBuf,
        project: tempfile::TempDir,
        models: tempfile::TempDir,
        lane_dir: PathBuf,
    }

    fn fixture(opt_in: bool) -> Fixture {
        let here = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();
        let scratch = tempfile::tempdir_in(&here).unwrap();
        let proj = tempfile::tempdir_in(&here).unwrap();
        let models = tempfile::tempdir_in(&here).unwrap();
        let lane_dir = scratch.path().join(LANE_VOLUME);
        std::fs::create_dir_all(lane_dir.join("in")).unwrap();
        std::fs::write(lane_dir.join("in/clip.mp4"), b"not really an mp4").unwrap();
        if opt_in {
            let cfg = proj.path().join(".tillandsias");
            std::fs::create_dir_all(&cfg).unwrap();
            std::fs::write(
                cfg.join("config.toml"),
                "[imagegen]\nstudio = true\ncorridorkey = true\n",
            )
            .unwrap();
        }
        Fixture {
            scratch_root: scratch.path().to_path_buf(),
            _scratch: scratch,
            project: proj,
            models,
            lane_dir,
        }
    }

    #[derive(Default)]
    struct Stub {
        runs: AtomicUsize,
    }
    impl KeyEngine for Stub {
        fn ensure_image(&self, _p: &mut dyn FnMut(Progress)) -> Result<(), String> {
            Ok(())
        }
        fn run(&self, _argv: &[String], _p: &mut dyn FnMut(Progress)) -> Result<(), String> {
            self.runs.fetch_add(1, SeqCst);
            Ok(())
        }
    }

    fn install(fx: &Fixture, engine: Arc<dyn KeyEngine>, cuda: bool) {
        install_seam(Some(Seam {
            engine,
            scratch_root: fx.scratch_root.clone(),
            project_root: fx.project.path().to_path_buf(),
            models_dir: fx.models.path().to_path_buf(),
            cuda,
        }));
    }

    /// 1956-ucix verifiable closure (design D9, D3, D5). Pre-fix: FAILS,
    /// studio.key_footage does not exist.
    #[test]
    fn corridorkey_key_footage_builds_argv_and_refuses_without_consent() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let fx = fixture(true);
        let mut sink = |_: Progress| {};

        // The request: a file under the lane scratch, the three outputs, low_vram.
        let req = parse_request(&json!({
            "input": "/work/tmp/imagegen/in/clip.mp4",
            "outputs": ["alpha", "fg", "cutout"],
            "low_vram": true
        }))
        .unwrap();
        assert_eq!(req.outputs, vec!["alpha", "fg", "cutout"]);
        let bad = parse_request(&json!({"input": "/etc/passwd"})).unwrap_err();
        assert!(bad.starts_with("invalid_arguments:"), "{bad}");
        let bad = parse_request(&json!({"input": "/work/tmp/imagegen/in/x.mp4", "outputs": ["depth"]}))
            .unwrap_err();
        assert!(bad.starts_with("invalid_arguments:") && bad.contains("depth"), "{bad}");

        // The argv: one-shot container, no network, /models read-only, the
        // lane volume at /out, the CDI GPU, infer.py's own flags.
        let argv = run_args(&req, "ck-1", fx.models.path(), LANE_VOLUME, "imagegen-corridorkey:v1");
        let s = |x: &str| argv.iter().any(|a| a == x);
        assert!(s("run") && s("--rm") && s("--network=none"), "{argv:?}");
        assert!(s("--cap-drop=ALL") && s("--security-opt=no-new-privileges"), "{argv:?}");
        assert!(
            s(&format!(
                "type=bind,source={},target=/models,readonly=true",
                fx.models.path().display()
            )),
            "{argv:?}"
        );
        assert!(s(&format!("type=volume,source={LANE_VOLUME},target=/out")), "{argv:?}");
        assert!(s("nvidia.com/gpu=all"), "{argv:?}");
        assert!(!argv.iter().any(|a| a.to_ascii_lowercase().contains("proxy")), "{argv:?}");
        assert!(!s("--network=tillandsias-enclave"), "{argv:?}");
        let image_at = argv.iter().position(|a| a == "imagegen-corridorkey:v1").unwrap();
        let tail: Vec<&str> = argv[image_at + 1..].iter().map(String::as_str).collect();
        assert_eq!(
            tail,
            vec![
                "--input", "/out/in/clip.mp4",
                "--output_dir", "/out/studio/ck-1",
                "--outputs", "alpha", "fg", "cutout",
                "--low_vram",
            ],
            "{tail:?}"
        );
        let no_low = parse_request(&json!({"input": "/work/tmp/imagegen/in/clip.mp4"})).unwrap();
        let argv2 = run_args(&no_low, "ck-2", fx.models.path(), LANE_VOLUME, "img");
        assert!(!argv2.iter().any(|a| a == "--low_vram"), "{argv2:?}");
        assert_eq!(no_low.outputs, vec!["alpha", "fg", "cutout"], "the D9 default set");

        // Refusal without consent: the gate says no, nothing is queued or run.
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone(), true);
        let err = call(
            "ucix-proj",
            "a",
            &json!({"input": "/work/tmp/imagegen/in/clip.mp4"}),
            &mut sink,
        )
        .unwrap_err();
        assert!(err.starts_with("consent_required:"), "{err}");
        assert!(err.contains("corridor-key-licence-2.0"), "{err}");
        assert_eq!(engine.runs.load(SeqCst), 0);
        assert!(!fx.lane_dir.join("studio").exists(), "nothing was queued");

        // Refusal on a host without CUDA, by name, before the gate is asked.
        install(&fx, engine.clone(), false);
        let err = call(
            "ucix-proj",
            "a",
            &json!({"input": "/work/tmp/imagegen/in/clip.mp4"}),
            &mut sink,
        )
        .unwrap_err();
        assert!(err.starts_with("corridorkey_needs_cuda:"), "{err}");
        assert_eq!(engine.runs.load(SeqCst), 0);

        // No automatic wiring: a project that did not opt in has no tool.
        let plain = fixture(false);
        install(&plain, engine.clone(), true);
        assert!(!enabled("ucix-proj", "a"));
        let err = call(
            "ucix-proj",
            "a",
            &json!({"input": "/work/tmp/imagegen/in/clip.mp4"}),
            &mut sink,
        )
        .unwrap_err();
        assert!(err.starts_with("corridorkey_not_enabled:"), "{err}");
        install(&fx, engine.clone(), true);
        assert!(enabled("ucix-proj", "a"));

        // The provenance record (D5): engine corridorkey at the pinned commit,
        // every weight with sha256 and licence, the input hash, the CLI args.
        let inputs = hash_inputs(&fx.lane_dir.join("in/clip.mp4"), &req.input).unwrap();
        assert_eq!(inputs.len(), 1);
        assert_eq!(inputs[0].sha256, provenance::sha256_hex(b"not really an mp4"));
        assert_eq!(inputs[0].path, "/work/tmp/imagegen/in/clip.mp4");
        let rec = provenance_record(&req, &inputs, "cuda", &argv[image_at + 1..]).to_json();
        assert_eq!(rec["schema"], provenance::SCHEMA);
        assert_eq!(rec["engine"]["name"], "corridorkey");
        assert_eq!(rec["engine"]["sha"], COMMIT);
        assert_eq!(rec["engine"]["ref"], UPSTREAM);
        let models = rec["models"].as_array().unwrap();
        assert_eq!(models.len(), weights().len());
        assert!(models.len() >= 5, "corridorkey + stats + three foundation models");
        for m in models {
            assert_eq!(m["sha256"].as_str().unwrap().len(), 64, "{m}");
            assert!(!m["licence"].as_str().unwrap().is_empty(), "{m}");
        }
        assert!(
            models.iter().any(|m| m["file"] == "corridorkey_v2.safetensors"
                && m["licence"] == CORRIDOR_LICENCE
                && m["repo"] == "nikopueringer/CorridorKey2.0"),
            "{models:?}"
        );
        assert!(models.iter().any(|m| m["licence"] == "nvidia-open-model-license"));
        assert!(models.iter().any(|m| m["licence"] == "mit"));
        assert!(models.iter().any(|m| m["licence"] == "cc-by-4.0"));
        assert_eq!(rec["inputs"][0]["sha256"], inputs[0].sha256);
        assert_eq!(rec["cli"][0], "--input");
        assert_eq!(rec["cli"].as_array().unwrap().last().unwrap(), "--low_vram");
        assert_eq!(rec["placement"], "cuda");

        // The tool description records the proof-of-concept status.
        let d = descriptor();
        assert_eq!(d["name"], "studio.key_footage");
        let text = d["description"].as_str().unwrap();
        assert!(text.contains("proof of concept"), "{text}");
        assert!(text.contains("Corridor"), "{text}");
        assert_eq!(d["inputSchema"]["required"][0], "input");

        // The image: known to image_specs, never INIT, pinned, no weights, non-root.
        let (cf, ctx) = crate::image_specs(&root, IMAGE).expect("imagegen-corridorkey is known");
        assert!(ctx.ends_with("images/imagegen-corridorkey") && cf.is_file());
        assert!(!crate::INIT_IMAGES.contains(&IMAGE));
        let containerfile = std::fs::read_to_string(&cf).unwrap();
        assert!(containerfile.contains(&format!("CORRIDORKEY_SHA={COMMIT}")), "pinned commit");
        assert!(containerfile.contains("TORCH_VERSION=2.9.1+cu128"), "pinned torch cu128");
        assert!(containerfile.contains("useradd"), "non-root");
        assert!(containerfile.contains("USER "), "non-root");
        assert!(!containerfile.contains("download_weights.py"), "no weights baked in");
        assert!(!containerfile.contains("huggingface.co/nikopueringer"), "no weights baked in");
        assert!(containerfile.contains("ln -s /models/corridorkey/weights"), "weights shim");
        assert!(containerfile.contains("ln -s /models/corridorkey/vfms"), "vfms shim");
        // Every weight row names a destination the runtime's shim resolves.
        for w in weights() {
            assert!(
                w.file.starts_with("weights/") || w.file.starts_with("vfms/"),
                "{}",
                w.file
            );
        }
        install_seam(None);
    }
}
