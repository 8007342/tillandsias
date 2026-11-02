//! `studio.run_workflow` on the per-lane MCP socket (order 1956-x7xp).
//!
//! @trace order:1956-x7xp, spec:imagegen-studio (spec: openspec/changes/studio-asset-pipeline, not yet archived)
//!
//! A forge agent runs a COMMITTED, API-format ComfyUI workflow headlessly in
//! the studio container (imagegen_studio.rs) and gets output paths plus one
//! provenance record per output, never bytes. Design rulings this follows:
//!
//! - D1: the tray validates before anything is queued. Every `class_type`
//!   must be a row of images/imagegen-studio/node-classes.tsv whose package
//!   is ComfyUI core or a package custom-nodes.toml pins (`node_not_pinned`);
//!   every model filename in a loader input must be a models.tsv row the
//!   licence register admits (`model_refused`, and nothing is fetched); every
//!   bound input must exist under /work/tmp/imagegen/. `$name` placeholders
//!   bind inputs; overrides reach only nodes titled `$seed`, `$prompt` or
//!   `$negative_prompt`.
//! - D2: files cross through the lane scratch volume, which the forge sees at
//!   /work/tmp/imagegen and the studio at /out. ComfyUI runs with
//!   `--output-directory /out`, so a bound input `/work/tmp/imagegen/in/X` is
//!   handed to `LoadImage` as `"in/X [output]"` (ComfyUI's annotated-path
//!   form that reads from the output directory; no copy, no second mount) and
//!   every `SaveImage` prefix is forced to `studio/<job>/<index>`, so outputs
//!   land at /work/tmp/imagegen/studio/<job>/ as D2 names them.
//! - D3: one GPU queue per host (gpu_queue.rs). The turn is held only while
//!   the prompts execute; then `POST /free {unload_models, free_memory}`.
//! - D5: `<output>.provenance.json` beside each output, also in the result.
//!
//! HTTP: ComfyUI's API is a handful of JSON routes (`/prompt`, `/history/<id>`,
//! `/system_stats`, `/free`). The crate's `reqwest` is async-only (no
//! `blocking` feature) and this tool runs synchronously inside the socket's
//! dispatcher, so a sixty-line HTTP/1.1 client over `std::net::TcpStream`
//! (`Connection: close`, chunked decoding) is used instead of pulling in a
//! runtime hop or a new dependency. Rootless podman does not route host
//! traffic to enclave-network container addresses, so production reaches the
//! studio through a published port when there is one and otherwise through
//! `podman exec <studio> python3` (urllib, same routes); both are
//! [`Transport`]s and the engine never knows which.
#![cfg_attr(not(test), allow(dead_code))]

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::gpu_queue;
use crate::imagegen_models::{self, ModelFile};
use crate::imagegen_tool::{EPHEMERAL_NOTE, FORGE_SCRATCH, Progress};
use crate::provenance;

/// The node-class allowlist (D1 step 2), data beside custom-nodes.toml.
pub const NODE_CLASSES_TSV: &str = include_str!("../../../images/imagegen-studio/node-classes.tsv");
/// The pinned custom-node packages the studio image holds (1921-7aa5).
pub const CUSTOM_NODES_TOML: &str =
    include_str!("../../../images/imagegen-studio/custom-nodes.toml");

const MAX_COUNT: u32 = 16;

/// Loader inputs whose value names a model file (D1 step 3).
pub const MODEL_INPUTS: &[&str] = &[
    "ckpt_name",
    "unet_name",
    "vae_name",
    "lora_name",
    "control_net_name",
    "ipadapter_file",
    "clip_name",
    "clip_name1",
    "clip_name2",
    "clip_name3",
    "clip_name4",
    "clip_vision",
    "clip_vision_name",
    "image_encoder",
    "style_model_name",
    "gligen_name",
    "model_name",
    "upscale_model_name",
];

/// Inputs that carry a `$name` placeholder bound from `inputs`.
const BINDABLE_INPUTS: &[&str] = &["image", "mask"];

pub fn descriptor() -> Value {
    json!({
        "name": "studio.run_workflow",
        "description": format!(
            "Run a committed ComfyUI workflow (API format) headlessly in this project's studio \
             container and return output paths under {FORGE_SCRATCH}/studio/<job>/ with a provenance \
             record beside each, never image bytes. Before anything is queued every node class must \
             be pinned (node_not_pinned otherwise) and every model file licence-admitted \
             (model_refused otherwise; nothing is fetched). `inputs` binds names to files under \
             {FORGE_SCRATCH}/ for LoadImage nodes whose image is \"$name\"; `overrides` reach only \
             nodes titled $seed, $prompt or $negative_prompt. Shares the host's GPU queue with \
             image.generate; progress arrives as MCP progress notifications. {EPHEMERAL_NOTE}"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workflow": { "type": "string", "description": "Path in the project checkout of an API-format ComfyUI workflow JSON." },
                "inputs": { "type": "object", "additionalProperties": { "type": "string" },
                            "description": format!("name -> file path under {FORGE_SCRATCH}/, bound to LoadImage nodes whose image is \"$name\".") },
                "overrides": { "type": "object", "properties": {
                    "seed": { "type": "integer", "minimum": 0 },
                    "prompt": { "type": "string" },
                    "negative_prompt": { "type": "string" }
                } },
                "count": { "type": "integer", "minimum": 1, "maximum": MAX_COUNT, "default": 1,
                           "description": "Batch size; items run consecutively with seed, seed+1, ..." },
                "tier": { "type": "string", "enum": ["I0", "I1", "I2", "I3"] },
                "family": { "type": "string", "description": "Optional family spec path in the checkout (studio.validate_family runs first)." }
            },
            "required": ["workflow"]
        }
    })
}

// ─── Request ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Overrides {
    pub seed: Option<u64>,
    pub prompt: Option<String>,
    pub negative_prompt: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub workflow: String,
    pub inputs: BTreeMap<String, String>,
    pub overrides: Overrides,
    pub count: u32,
    pub tier: Option<String>,
    pub family: Option<String>,
}

/// A relative path that stays inside the checkout: no root, no `..`, no
/// empty component.
fn checkout_relative(p: &str) -> Result<&str, String> {
    let ok = !p.is_empty()
        && !p.starts_with('/')
        && !p.contains('\\')
        && !p.split('/').any(|c| c.is_empty() || c == "." || c == "..");
    ok.then_some(p).ok_or_else(|| {
        format!("invalid_arguments: {p:?} must be a relative path inside the project checkout")
    })
}

pub fn parse_request(args: &Value) -> Result<Request, String> {
    let workflow = args
        .get("workflow")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|w| !w.is_empty())
        .ok_or("invalid_arguments: workflow is required")?;
    checkout_relative(workflow)?;
    let mut inputs = BTreeMap::new();
    if let Some(map) = args.get("inputs") {
        let map = map
            .as_object()
            .ok_or("invalid_arguments: inputs must be an object of name -> path")?;
        for (k, v) in map {
            let v = v
                .as_str()
                .ok_or_else(|| format!("invalid_arguments: inputs.{k} must be a path"))?;
            inputs.insert(k.clone(), v.to_string());
        }
    }
    let ov = args.get("overrides").cloned().unwrap_or(json!({}));
    if !ov.is_object() {
        return Err("invalid_arguments: overrides must be an object".into());
    }
    let count = args.get("count").and_then(Value::as_u64).unwrap_or(1);
    if count == 0 || count > u64::from(MAX_COUNT) {
        return Err(format!("invalid_arguments: count must be 1..={MAX_COUNT}"));
    }
    let family = args
        .get("family")
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(f) = &family {
        checkout_relative(f)?;
    }
    Ok(Request {
        workflow: workflow.to_string(),
        inputs,
        overrides: Overrides {
            seed: ov.get("seed").and_then(Value::as_u64),
            prompt: ov.get("prompt").and_then(Value::as_str).map(str::to_string),
            negative_prompt: ov
                .get("negative_prompt")
                .and_then(Value::as_str)
                .map(str::to_string),
        },
        count: count as u32,
        tier: args.get("tier").and_then(Value::as_str).map(str::to_string),
        family,
    })
}

// ─── Node-class allowlist (D1 step 2) ────────────────────────────────────────

/// `class_type -> package`, plus the packages custom-nodes.toml pins.
pub struct Allowlist {
    classes: HashMap<String, String>,
    pinned: HashMap<String, String>,
}

/// `(name, commit)` of every `[[node]]` in custom-nodes.toml. A flat scan: the
/// file is a list of tables with string keys and no nesting.
pub fn pinned_packages(toml: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let (mut name, mut commit) = (None::<String>, None::<String>);
    let flush = |name: &mut Option<String>, commit: &mut Option<String>, out: &mut Vec<_>| {
        if let (Some(n), Some(c)) = (name.take(), commit.take()) {
            out.push((n, c));
        }
    };
    for line in toml.lines() {
        let line = line.trim();
        if line == "[[node]]" {
            flush(&mut name, &mut commit, &mut out);
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let v = v.trim().trim_matches('"').to_string();
            match k.trim() {
                "name" => name = Some(v),
                "commit" => commit = Some(v),
                _ => {}
            }
        }
    }
    flush(&mut name, &mut commit, &mut out);
    out
}

impl Allowlist {
    pub fn parse(tsv: &str, custom_nodes_toml: &str) -> Allowlist {
        let classes = tsv
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .filter_map(|l| l.split_once('\t'))
            .map(|(pkg, class)| (class.trim().to_string(), pkg.trim().to_string()))
            .collect();
        Allowlist {
            classes,
            pinned: pinned_packages(custom_nodes_toml).into_iter().collect(),
        }
    }

    pub fn shipped() -> Allowlist {
        Self::parse(NODE_CLASSES_TSV, CUSTOM_NODES_TOML)
    }

    pub fn admits(&self, class: &str) -> Result<(), String> {
        match self.classes.get(class).map(String::as_str) {
            Some("comfyui-core") => Ok(()),
            Some(pkg) if self.pinned.contains_key(pkg) => Ok(()),
            Some(pkg) => Err(format!(
                "node_not_pinned: {class} comes from {pkg}, which images/imagegen-studio/custom-nodes.toml \
                 does not pin yet; the workflow runs once that package is pinned and the studio image rebuilt"
            )),
            None => Err(format!(
                "node_not_pinned: {class} is not a ComfyUI core node nor one of a pinned custom-node package \
                 (images/imagegen-studio/node-classes.tsv); the studio runs only pinned nodes"
            )),
        }
    }

    /// The pinned packages, sorted by name, for the provenance record.
    pub fn pinned(&self) -> Vec<(String, String)> {
        let mut v: Vec<_> = self
            .pinned
            .iter()
            .map(|(n, c)| (n.clone(), c.clone()))
            .collect();
        v.sort();
        v
    }
}

// ─── Validation (D1 steps 1-4) ───────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoundInput {
    pub name: String,
    pub forge_path: String,
    pub host_path: PathBuf,
    pub sha256: String,
}

/// A validated workflow ready to queue.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    /// The API-format map, inputs bound (`$name` replaced by its studio path).
    pub workflow: Value,
    pub workflow_path: String,
    pub workflow_sha256: String,
    pub models: Vec<ModelFile>,
    pub inputs: Vec<BoundInput>,
    pub seed: u64,
    pub prompt: Option<String>,
    pub negative_prompt: Option<String>,
    pub count: u32,
    pub tier: Option<String>,
    pub family: Option<(String, String)>,
}

fn title_of(node: &Value) -> Option<&str> {
    node.get("_meta")?.get("title")?.as_str()
}

/// A model filename as a loader input names it: the cache name, or
/// `<tier>/<cache name>` (extra_model_paths.yaml lists one dir per tier).
fn pinned_model<'a>(manifest: &'a [ModelFile], named: &str) -> Option<&'a ModelFile> {
    manifest
        .iter()
        .find(|m| named == m.cache_name() || named == format!("{}/{}", m.tier, m.cache_name()))
}

/// A forge path under `FORGE_SCRATCH/` → its path relative to the volume.
fn scratch_relative(forge_path: &str) -> Result<&str, String> {
    forge_path
        .strip_prefix(FORGE_SCRATCH)
        .and_then(|r| r.strip_prefix('/'))
        .filter(|r| !r.is_empty() && !r.split('/').any(|c| c.is_empty() || c == "." || c == ".."))
        .ok_or_else(|| {
            format!("invalid_arguments: {forge_path:?} must be a file under {FORGE_SCRATCH}/")
        })
}

/// Validate `req` against the workflow text, the allowlist, the manifest and
/// the register, with inputs read from `scratch` (the lane's volume on the
/// host). Nothing is queued or fetched here.
pub fn validate(
    req: &Request,
    workflow_json: &str,
    allow: &Allowlist,
    manifest: &[ModelFile],
    register: &str,
    scratch: &Path,
) -> Result<Plan, String> {
    // 1. It parses, and it is the API format: a map of node id -> {class_type, inputs}.
    let mut wf: Value = serde_json::from_str(workflow_json)
        .map_err(|e| format!("invalid_workflow: {} does not parse: {e}", req.workflow))?;
    let nodes = wf
        .as_object()
        .ok_or_else(|| format!("invalid_workflow: {} is not an object", req.workflow))?;
    if nodes.contains_key("nodes") && nodes.contains_key("links") {
        return Err(format!(
            "invalid_workflow: {} is the UI graph format; export it with \"Save (API format)\"",
            req.workflow
        ));
    }
    if nodes.is_empty() {
        return Err(format!("invalid_workflow: {} has no nodes", req.workflow));
    }
    let mut classes = Vec::new();
    for (id, node) in nodes {
        let class = node
            .get("class_type")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("invalid_workflow: node {id} has no class_type"))?;
        if !node.get("inputs").is_some_and(Value::is_object) {
            return Err(format!("invalid_workflow: node {id} has no inputs object"));
        }
        classes.push((id.clone(), class.to_string()));
    }
    // 2. Every class is pinned.
    for (_, class) in &classes {
        allow.admits(class)?;
    }
    if !classes.iter().any(|(_, c)| c == "SaveImage") {
        return Err("invalid_workflow: no SaveImage node, so the run would produce nothing".into());
    }
    // 3. Every model file is a pinned, admitted row.
    let mut models: Vec<ModelFile> = Vec::new();
    for (id, node) in nodes {
        let inputs = node["inputs"].as_object().expect("checked above");
        for key in MODEL_INPUTS {
            if let Some(named) = inputs.get(*key).and_then(Value::as_str) {
                let row = pinned_model(manifest, named).ok_or_else(|| {
                    format!(
                        "model_refused: node {id} {key}={named:?} is not a row of images/imagegen/models.tsv; \
                         a model runs only when it is pinned there and images/models/licence-register.tsv \
                         admits it (the operator approves each licence)"
                    )
                })?;
                imagegen_models::register_admits(register, row)?;
                if !models.contains(row) {
                    models.push(row.clone());
                }
            }
        }
    }
    // 4. Every bound input exists; placeholders bind and are rewritten to the
    // studio's view of the volume (D2).
    let mut inputs = Vec::new();
    for (name, forge_path) in &req.inputs {
        let rel = scratch_relative(forge_path)?;
        let host = scratch.join(rel);
        if !host.is_file() {
            return Err(format!(
                "invalid_arguments: inputs.{name} = {forge_path:?} does not exist (copy the file under {FORGE_SCRATCH}/in/ first)"
            ));
        }
        inputs.push(BoundInput {
            name: name.clone(),
            forge_path: forge_path.clone(),
            host_path: host.clone(),
            sha256: provenance::sha256_file(&host)?,
        });
    }
    let mut seed_nodes = 0;
    let mut prompt_nodes = 0;
    let mut negative_nodes = 0;
    let mut base_seed = None;
    for (id, node) in wf.as_object_mut().expect("object") {
        match title_of(node) {
            Some("$seed") => {
                seed_nodes += 1;
                let inp = &node["inputs"];
                base_seed = base_seed.or_else(|| {
                    inp.get("seed")
                        .or_else(|| inp.get("noise_seed"))
                        .and_then(Value::as_u64)
                });
            }
            Some("$prompt") => prompt_nodes += 1,
            Some("$negative_prompt") => negative_nodes += 1,
            _ => {}
        }
        let obj = node["inputs"].as_object_mut().expect("object");
        for key in BINDABLE_INPUTS {
            let Some(ph) = obj.get(*key).and_then(Value::as_str) else {
                continue;
            };
            let Some(name) = ph.strip_prefix('$') else {
                continue;
            };
            let bound = inputs.iter().find(|b| b.name == name).ok_or_else(|| {
                format!("invalid_arguments: node {id} {key} wants input ${name}, which `inputs` does not bind")
            })?;
            let rel = scratch_relative(&bound.forge_path)?;
            obj.insert((*key).to_string(), json!(format!("{rel} [output]")));
        }
    }
    if req.overrides.prompt.is_some() && prompt_nodes == 0 {
        return Err(
            "invalid_arguments: overrides.prompt given, but no node is titled $prompt".into(),
        );
    }
    if req.overrides.negative_prompt.is_some() && negative_nodes == 0 {
        return Err(
            "invalid_arguments: overrides.negative_prompt given, but no node is titled $negative_prompt"
                .into(),
        );
    }
    if req.overrides.seed.is_some() && seed_nodes == 0 {
        return Err("invalid_arguments: overrides.seed given, but no node is titled $seed".into());
    }
    let seed = req.overrides.seed.or(base_seed).unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64 % 4_294_967_296)
            .unwrap_or(42)
    });
    Ok(Plan {
        workflow: wf,
        workflow_path: req.workflow.clone(),
        workflow_sha256: provenance::sha256_hex(workflow_json.as_bytes()),
        models,
        inputs,
        seed,
        prompt: req.overrides.prompt.clone(),
        negative_prompt: req.overrides.negative_prompt.clone(),
        count: req.count,
        tier: req.tier.clone(),
        family: None,
    })
}

fn set_text(inputs: &mut serde_json::Map<String, Value>, text: &str) {
    if inputs.contains_key("text") {
        inputs.insert("text".into(), json!(text));
    } else {
        for k in ["text_g", "text_l"] {
            if inputs.contains_key(k) {
                inputs.insert(k.into(), json!(text));
            }
        }
    }
}

/// Batch item `i` of `job`: overrides applied to the titled nodes only, seed
/// `plan.seed + i`, and every SaveImage prefixed `studio/<job>/<i>` (D2).
pub fn prompt_for(plan: &Plan, job: &str, i: u32) -> Value {
    let mut p = plan.workflow.clone();
    for node in p.as_object_mut().expect("object").values_mut() {
        let title = title_of(node).map(str::to_string);
        let class = node["class_type"].as_str().unwrap_or("").to_string();
        let inputs = node["inputs"].as_object_mut().expect("object");
        match title.as_deref() {
            Some("$seed") => {
                let key = if inputs.contains_key("noise_seed") {
                    "noise_seed"
                } else {
                    "seed"
                };
                inputs.insert(key.into(), json!(plan.seed + u64::from(i)));
            }
            Some("$prompt") => {
                if let Some(t) = &plan.prompt {
                    set_text(inputs, t);
                }
            }
            Some("$negative_prompt") => {
                if let Some(t) = &plan.negative_prompt {
                    set_text(inputs, t);
                }
            }
            _ => {}
        }
        if class == "SaveImage" {
            inputs.insert(
                "filename_prefix".into(),
                json!(format!("studio/{job}/{i:04}")),
            );
        }
    }
    p
}

// ─── Engine ──────────────────────────────────────────────────────────────────

/// What one prompt produced: `(subfolder, filename)` under /out per image,
/// and where the model ran.
pub struct RunOut {
    pub images: Vec<(String, String)>,
    pub placement: String,
}

/// The studio behind the tool. Production is [`HttpStudio`]; fixtures stub it.
pub trait StudioEngine: Send + Sync {
    /// Fetch admitted files the cache lacks (through the existing path, with progress).
    fn ensure_models(
        &self,
        files: &[ModelFile],
        progress: &mut dyn FnMut(Progress),
    ) -> Result<(), String>;
    /// Queue one prompt and wait for its outputs. Runs under the GPU turn.
    fn run(
        &self,
        prompt: &Value,
        out_dir: &Path,
        progress: &mut dyn FnMut(Progress),
    ) -> Result<RunOut, String>;
    /// D3: unload the models so the next job, of either engine, starts empty.
    fn free(&self) -> Result<(), String>;
}

/// Fixture seam: a stub engine, a scratch root and a project checkout.
pub struct Seam {
    pub engine: Arc<dyn StudioEngine>,
    pub scratch_root: PathBuf,
    pub project_root: PathBuf,
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

/// The lane's scratch volume on the host (the studio seam's root when one
/// is installed, else the shared lane volume image.generate uses).
fn scratch_dir(project: &str, instance: &str) -> Result<PathBuf, String> {
    if let Some(root) = seam()
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.scratch_root.clone()))
    {
        let dir = root.join(crate::imagegen_tool::lane_volume(project, instance));
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        return Ok(dir);
    }
    crate::imagegen_tool::lane_scratch_dir(project, instance)
}

/// Read `rel` from the project's checkout. In production the checkout lives
/// in the live forge of this lane (studio.rs `checkout_dir`), so the read
/// goes through `podman exec` there after `realpath` proves the resolved file
/// stays under the checkout; the seam reads from a directory.
pub(crate) fn read_checkout_file(
    project: &str,
    instance: &str,
    rel: &str,
) -> Result<String, String> {
    let rel = checkout_relative(rel)?;
    if let Some(root) = seam()
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.project_root.clone()))
    {
        let root = root
            .canonicalize()
            .map_err(|e| format!("{}: {e}", root.display()))?;
        let path = root.join(rel);
        let real = path
            .canonicalize()
            .map_err(|e| format!("invalid_arguments: {rel}: {e}"))?;
        if !real.starts_with(&root) {
            return Err(format!(
                "invalid_arguments: {rel} escapes the project checkout"
            ));
        }
        return std::fs::read_to_string(&real)
            .map_err(|e| format!("invalid_arguments: {rel}: {e}"));
    }
    let lane = crate::local_web_preview::resolve_live_source(project, instance)?;
    let dir = crate::studio::checkout_dir(project);
    let guest = format!("{dir}/{rel}");
    let exec = |args: &[&str]| -> Result<String, String> {
        let mut cmd = tillandsias_podman::podman_cmd_sync();
        cmd.args(["exec", &lane.forge_id]).args(args);
        let out = cmd
            .output_bounded(Duration::from_secs(15))
            .map_err(|e| format!("studio: reading {rel} in the forge failed: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "invalid_arguments: {rel}: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let real = exec(&["realpath", "-e", "--", &guest])?;
    if !real.trim().starts_with(&format!("{dir}/")) {
        return Err(format!(
            "invalid_arguments: {rel} escapes the project checkout"
        ));
    }
    exec(&["cat", "--", real.trim()])
}

/// D1: a `family` spec runs `studio.validate_family` first (order 1956-26qh)
/// and the run is refused, with nothing queued, on any static failure.
fn family_admits(project: &str, instance: &str, family: &str) -> Result<(), String> {
    let v = crate::mcp_socket::validate_family_in_lane(
        project,
        instance,
        &serde_json::json!({ "spec": family }),
    )?;
    if v["ok"].as_bool() == Some(true) {
        return Ok(());
    }
    let lines: Vec<&str> = v["verdicts"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    Err(format!(
        "family_refused: {family} fails the family contract; nothing was queued. {}",
        lines.join("; ")
    ))
}

/// A ≤256 px thumbnail is not made here: studio outputs can be sprite
/// atlases; the forge's own tools review them.
fn job_id() -> String {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    static SEQ: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("st-{stamp}-{n}")
}

/// The tool call. `progress` receives each event as it happens.
pub fn call(
    project: &str,
    instance: &str,
    args: &Value,
    progress: &mut dyn FnMut(Progress),
) -> Result<Value, String> {
    let req = parse_request(args)?;
    let engine: Arc<dyn StudioEngine> = match seam()
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.engine.clone()))
    {
        Some(e) => e,
        None => Arc::new(HttpStudio::for_this_host(project)?),
    };
    let scratch = scratch_dir(project, instance)?;
    let workflow_json = read_checkout_file(project, instance, &req.workflow)?;
    let allow = Allowlist::shipped();
    let mut plan = validate(
        &req,
        &workflow_json,
        &allow,
        &imagegen_models::manifest(),
        imagegen_models::register_tsv(),
        &scratch,
    )?;
    if let Some(fam) = &req.family {
        family_admits(project, instance, fam)?;
        let spec = read_checkout_file(project, instance, fam)?;
        plan.family = Some((fam.clone(), provenance::sha256_hex(spec.as_bytes())));
    }
    // Admitted files the cache lacks are fetched now, before the GPU turn.
    engine.ensure_models(&plan.models, progress)?;

    let job = job_id();
    let t0 = Instant::now();
    // D3: one GPU queue per host; the turn covers the prompts, then /free.
    let turn = gpu_queue::wait_for_gpu(&mut |position| progress(Progress::Queued { position }));
    let mut produced: Vec<(u32, String, String)> = Vec::new();
    let mut placement = String::from("unknown");
    let mut failure = None;
    for i in 0..plan.count {
        let prompt = prompt_for(&plan, &job, i);
        match engine.run(&prompt, &scratch, progress) {
            Ok(out) => {
                placement = out.placement;
                produced.extend(out.images.into_iter().map(|(s, f)| (i, s, f)));
            }
            Err(e) => {
                failure = Some(gpu_queue::explain_engine_failure(
                    &e,
                    gpu_queue::vram_holders(),
                ));
                break;
            }
        }
    }
    let freed = engine.free();
    drop(turn);
    if let Some(e) = failure {
        return Err(e);
    }
    if let Err(e) = freed {
        eprintln!("[tillandsias] studio /free after {job} failed: {e}");
    }
    let elapsed = t0.elapsed().as_secs_f64();
    if produced.is_empty() {
        return Err("engine_failed: the workflow finished but produced no output image".into());
    }

    let mut outputs = Vec::new();
    for (i, sub, file) in &produced {
        let host = scratch.join(sub).join(file);
        let bytes = std::fs::read(&host)
            .map_err(|e| format!("engine_failed: no output {sub}/{file}: {e}"))?;
        let (w, h, alpha) = crate::imagegen_tool::png_facts(&bytes)
            .ok_or_else(|| format!("engine_failed: {file} is not a PNG"))?;
        let record = provenance::Record {
            engine: provenance::Engine::ComfyUi {
                nodes: allow.pinned(),
            },
            workflow: Some((plan.workflow_path.clone(), plan.workflow_sha256.clone())),
            models: plan.models.clone(),
            inputs: plan
                .inputs
                .iter()
                .map(|b| provenance::Input {
                    name: b.name.clone(),
                    path: b.forge_path.clone(),
                    sha256: b.sha256.clone(),
                })
                .collect(),
            seed: plan.seed + u64::from(*i),
            prompt: plan.prompt.clone().unwrap_or_default(),
            negative_prompt: plan.negative_prompt.clone().unwrap_or_default(),
            tier: plan.tier.clone(),
            placement: placement.clone(),
            family: plan.family.clone(),
            consent: None,
            cli: None,
        };
        let prov = record.write_beside(&host)?;
        let forge = format!("{FORGE_SCRATCH}/{sub}/{file}");
        outputs.push(json!({
            "path": forge,
            "width": w,
            "height": h,
            "has_alpha": alpha,
            "seed": plan.seed + u64::from(*i),
            "provenance_path": format!("{forge}.provenance.json"),
            "provenance": prov,
        }));
    }
    Ok(json!({
        "job": job,
        "outputs": outputs,
        "provenance": outputs[0]["provenance"],
        "placement": placement,
        "degraded": (placement == "cpu" || placement == "mixed").then(|| json!({
            "backend": placement,
            "why": "the studio ran the model on the CPU (or partly): the GPU was absent or short of memory; \
                    the output is valid but slow. Free GPU memory and retry for a full GPU run."
        })),
        "seed": plan.seed,
        "count": plan.count,
        "tier": plan.tier,
        "elapsed_s": (elapsed * 100.0).round() / 100.0,
        "ephemeral": true,
        "note": EPHEMERAL_NOTE,
    }))
}

// ─── HTTP engine ─────────────────────────────────────────────────────────────

/// One HTTP exchange with the studio: `(status, body)`.
pub trait Transport: Send + Sync {
    fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> Result<(u16, String), String>;
}

/// HTTP/1.1 over a TCP socket: `Connection: close`, body read to EOF,
/// chunked framing decoded. Enough for ComfyUI's JSON routes.
pub struct TcpTransport {
    pub addr: String,
}

fn decode_chunked(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < raw.len() {
        let Some(nl) = raw[at..].windows(2).position(|w| w == b"\r\n") else {
            break;
        };
        let size_line = String::from_utf8_lossy(&raw[at..at + nl]);
        let size = usize::from_str_radix(size_line.split(';').next().unwrap_or("0").trim(), 16)
            .unwrap_or(0);
        at += nl + 2;
        if size == 0 {
            break;
        }
        out.extend_from_slice(&raw[at..(at + size).min(raw.len())]);
        at += size + 2;
    }
    out
}

/// Split a raw HTTP/1.1 response into `(status, body)`.
pub fn parse_http_response(raw: &[u8]) -> Result<(u16, String), String> {
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("studio: malformed HTTP response (no header end)")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| format!("studio: malformed HTTP status line: {head:?}"))?;
    let chunked = head.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    let body = &raw[split + 4..];
    let body = if chunked {
        decode_chunked(body)
    } else {
        body.to_vec()
    };
    Ok((status, String::from_utf8_lossy(&body).into_owned()))
}

impl Transport for TcpTransport {
    fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> Result<(u16, String), String> {
        use std::io::{Read, Write};
        use std::net::ToSocketAddrs;
        let addr = self
            .addr
            .to_socket_addrs()
            .map_err(|e| format!("studio_unavailable: {}: {e}", self.addr))?
            .next()
            .ok_or_else(|| format!("studio_unavailable: {} resolves to nothing", self.addr))?;
        let mut s = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(10))
            .map_err(|e| format!("studio_unavailable: {}: {e}", self.addr))?;
        let _ = s.set_read_timeout(Some(Duration::from_secs(120)));
        let _ = s.set_write_timeout(Some(Duration::from_secs(30)));
        let body = body.unwrap_or("");
        let req = format!(
            "{method} {path} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            self.addr,
            body.len()
        );
        s.write_all(req.as_bytes())
            .map_err(|e| format!("studio: {method} {path}: {e}"))?;
        let mut raw = Vec::new();
        s.read_to_end(&mut raw)
            .map_err(|e| format!("studio: {method} {path}: {e}"))?;
        parse_http_response(&raw)
    }
}

/// The same routes through `podman exec <studio> python3` (urllib), for a
/// studio with no published port: rootless podman does not route the host to
/// enclave-network addresses.
pub struct PodmanExecTransport {
    pub container: String,
}

const EXEC_SCRIPT: &str = r#"
import sys, urllib.request, urllib.error
method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://127.0.0.1:8188" + path, data=body.encode() if method == "POST" else None, method=method, headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        sys.stdout.write(str(r.status) + "\n" + r.read().decode("utf-8", "replace"))
except urllib.error.HTTPError as e:
    sys.stdout.write(str(e.code) + "\n" + e.read().decode("utf-8", "replace"))
"#;

impl Transport for PodmanExecTransport {
    fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> Result<(u16, String), String> {
        let mut cmd = tillandsias_podman::podman_cmd_sync();
        cmd.args([
            "exec",
            &self.container,
            "python3",
            "-c",
            EXEC_SCRIPT,
            method,
            path,
            body.unwrap_or(""),
        ]);
        let out = cmd
            .output_bounded(Duration::from_secs(150))
            .map_err(|e| format!("studio_unavailable: exec into {}: {e}", self.container))?;
        if !out.status.success() {
            return Err(format!(
                "studio_unavailable: {method} {path} in {}: {}",
                self.container,
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let (status, body) = text.split_once('\n').unwrap_or((text.trim(), ""));
        Ok((status.trim().parse().unwrap_or(0), body.to_string()))
    }
}

/// Production engine: ComfyUI's HTTP API in the project's studio container.
pub struct HttpStudio {
    pub transport: Box<dyn Transport>,
    pub models_dir: PathBuf,
    /// How often `/history/<id>` is polled.
    pub poll: Duration,
}

impl HttpStudio {
    /// The studio of `project`, if it is running: through
    /// `TILLANDSIAS_STUDIO_ADDR` (host:port), a published 8188 port, or exec.
    pub fn for_this_host(project: &str) -> Result<Self, String> {
        let container = crate::imagegen_studio::container_name(project);
        let models_dir = imagegen_models::models_dir();
        if let Ok(addr) = std::env::var("TILLANDSIAS_STUDIO_ADDR")
            && !addr.trim().is_empty()
        {
            return Ok(Self::with_transport(
                Box::new(TcpTransport {
                    addr: addr.trim().into(),
                }),
                models_dir,
            ));
        }
        let mut cmd = tillandsias_podman::podman_cmd_sync();
        cmd.args(["inspect", "--format", "{{.State.Running}}", &container]);
        let running = cmd
            .output_bounded(Duration::from_secs(15))
            .ok()
            .filter(|o| o.status.success())
            .is_some_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "true");
        if !running {
            return Err(format!(
                "studio_unavailable: {container} is not running; set `[imagegen] studio = true` in the \
                 project's tillandsias.toml and relaunch the forge"
            ));
        }
        let mut cmd = tillandsias_podman::podman_cmd_sync();
        cmd.args(["port", &container, "8188/tcp"]);
        let published = cmd
            .output_bounded(Duration::from_secs(15))
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty());
        let transport: Box<dyn Transport> = match published {
            Some(addr) => Box::new(TcpTransport {
                addr: addr
                    .lines()
                    .next()
                    .unwrap_or("")
                    .replace("0.0.0.0", "127.0.0.1"),
            }),
            None => Box::new(PodmanExecTransport { container }),
        };
        Ok(Self::with_transport(transport, models_dir))
    }

    pub fn with_transport(transport: Box<dyn Transport>, models_dir: PathBuf) -> Self {
        HttpStudio {
            transport,
            models_dir,
            poll: Duration::from_millis(500),
        }
    }

    fn json(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Value, String> {
        let body_s = body.map(Value::to_string);
        let (status, text) = self.transport.request(method, path, body_s.as_deref())?;
        if !(200..300).contains(&status) {
            return Err(format!(
                "engine_failed: studio {method} {path} returned {status}: {}",
                text.chars().take(600).collect::<String>()
            ));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text)
            .map_err(|e| format!("engine_failed: studio {method} {path}: not JSON ({e})"))
    }

    fn placement(&self) -> String {
        self.json("GET", "/system_stats", None)
            .ok()
            .and_then(|v| v["devices"][0]["type"].as_str().map(str::to_string))
            .unwrap_or_else(|| "unknown".into())
    }
}

impl StudioEngine for HttpStudio {
    fn ensure_models(
        &self,
        files: &[ModelFile],
        progress: &mut dyn FnMut(Progress),
    ) -> Result<(), String> {
        if files.is_empty() {
            return Ok(());
        }
        imagegen_models::ensure_files(
            &self.models_dir,
            files,
            &imagegen_models::ProxyTransport::for_this_build(),
            &mut |e| progress(Progress::Fetch(e)),
        )
        .map(|_| ())
    }

    fn run(
        &self,
        prompt: &Value,
        _out_dir: &Path,
        progress: &mut dyn FnMut(Progress),
    ) -> Result<RunOut, String> {
        let queued = self.json(
            "POST",
            "/prompt",
            Some(&json!({ "prompt": prompt, "client_id": "tillandsias-studio-tool" })),
        )?;
        let id = queued["prompt_id"]
            .as_str()
            .ok_or_else(|| format!("engine_failed: studio rejected the workflow: {queued}"))?
            .to_string();
        let total = prompt.as_object().map_or(1, |o| o.len() as u32).max(1);
        let started = Instant::now();
        loop {
            let hist = self.json("GET", &format!("/history/{id}"), None)?;
            if let Some(entry) = hist.get(&id) {
                let status = &entry["status"];
                if status["status_str"] == "error" {
                    let why = status["messages"]
                        .as_array()
                        .map(|m| {
                            m.iter()
                                .filter(|x| x[0] == "execution_error")
                                .map(|x| {
                                    format!(
                                        "{} in {}: {}",
                                        x[1]["exception_type"].as_str().unwrap_or("error"),
                                        x[1]["node_type"].as_str().unwrap_or("?"),
                                        x[1]["exception_message"].as_str().unwrap_or("")
                                    )
                                })
                                .collect::<Vec<_>>()
                                .join("; ")
                        })
                        .unwrap_or_default();
                    return Err(format!("engine_failed: studio execution failed: {why}"));
                }
                let mut images = Vec::new();
                if let Some(outs) = entry["outputs"].as_object() {
                    for node in outs.values() {
                        for img in node["images"].as_array().into_iter().flatten() {
                            if img["type"] == "output"
                                && let (Some(f), Some(s)) =
                                    (img["filename"].as_str(), img["subfolder"].as_str())
                            {
                                images.push((s.to_string(), f.to_string()));
                            }
                        }
                    }
                }
                progress(Progress::Step { done: total, total });
                let placement = self.placement();
                return Ok(RunOut { images, placement });
            }
            // Not finished: a coarse meter from the elapsed time against the
            // node count, so a long sampler still shows movement.
            let done = (started.elapsed().as_secs() as u32).min(total.saturating_sub(1));
            progress(Progress::Step { done, total });
            std::thread::sleep(self.poll);
        }
    }

    fn free(&self) -> Result<(), String> {
        self.json(
            "POST",
            "/free",
            Some(&json!({ "unload_models": true, "free_memory": true })),
        )
        .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};

    const I1_CKPT: &str = "sdxl_lightning_4step.safetensors";

    fn workflow(ckpt: &str, extra_class: Option<&str>) -> String {
        let mut w = json!({
            "1": {"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":ckpt}},
            "2": {"class_type":"CLIPTextEncode","inputs":{"text":"placeholder","clip":["1",1]},"_meta":{"title":"$prompt"}},
            "3": {"class_type":"CLIPTextEncode","inputs":{"text":"","clip":["1",1]},"_meta":{"title":"$negative_prompt"}},
            "4": {"class_type":"LoadImage","inputs":{"image":"$pose"}},
            "5": {"class_type":"KSampler","inputs":{"seed":1,"steps":4,"cfg":1.0,"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["7",0]},"_meta":{"title":"$seed"}},
            "6": {"class_type":"CLIPTextEncode","inputs":{"text":"untouched","clip":["1",1]},"_meta":{"title":"a style note"}},
            "7": {"class_type":"EmptyLatentImage","inputs":{"width":64,"height":64,"batch_size":1}},
            "8": {"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},
            "9": {"class_type":"SaveImage","inputs":{"filename_prefix":"whatever","images":["8",0]}}
        });
        if let Some(c) = extra_class {
            w["10"] = json!({"class_type": c, "inputs": {}});
        }
        serde_json::to_string_pretty(&w).unwrap()
    }

    struct Fixture {
        _scratch: tempfile::TempDir,
        scratch_root: PathBuf,
        project: tempfile::TempDir,
        lane_dir: PathBuf,
    }

    fn fixture(project: &str, instance: &str) -> Fixture {
        let here = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();
        let scratch = tempfile::tempdir_in(&here).unwrap();
        let proj = tempfile::tempdir_in(&here).unwrap();
        let lane_dir = scratch
            .path()
            .join(crate::imagegen_tool::lane_volume(project, instance));
        std::fs::create_dir_all(lane_dir.join("in/gk")).unwrap();
        std::fs::write(lane_dir.join("in/gk/left_hand.png"), b"\x89PNG pose bytes").unwrap();
        let wf = proj.path().join("tool/art/workflows");
        std::fs::create_dir_all(&wf).unwrap();
        std::fs::write(wf.join("ok.api.json"), workflow(I1_CKPT, None)).unwrap();
        std::fs::write(
            wf.join("unpinned.api.json"),
            workflow(I1_CKPT, Some("WidgetFromTheInternet")),
        )
        .unwrap();
        std::fs::write(
            wf.join("unregistered.api.json"),
            workflow("mystery_merge_v9.safetensors", None),
        )
        .unwrap();
        Fixture {
            scratch_root: scratch.path().to_path_buf(),
            _scratch: scratch,
            project: proj,
            lane_dir,
        }
    }

    /// Writes real PNGs where ComfyUI would, counts runs and `/free` calls.
    #[derive(Default)]
    struct Stub {
        runs: AtomicUsize,
        frees: AtomicUsize,
        fetched: Mutex<Vec<String>>,
        prompts: Mutex<Vec<Value>>,
    }
    impl StudioEngine for Stub {
        fn ensure_models(
            &self,
            f: &[ModelFile],
            _p: &mut dyn FnMut(Progress),
        ) -> Result<(), String> {
            self.fetched
                .lock()
                .unwrap()
                .extend(f.iter().map(|m| m.cache_name().to_string()));
            Ok(())
        }
        fn run(
            &self,
            prompt: &Value,
            out_dir: &Path,
            progress: &mut dyn FnMut(Progress),
        ) -> Result<RunOut, String> {
            self.runs.fetch_add(1, SeqCst);
            self.prompts.lock().unwrap().push(prompt.clone());
            progress(Progress::Step { done: 1, total: 1 });
            let prefix = prompt["9"]["inputs"]["filename_prefix"]
                .as_str()
                .unwrap()
                .to_string();
            let (sub, stem) = prefix.rsplit_once('/').unwrap();
            let dir = out_dir.join(sub);
            std::fs::create_dir_all(&dir).unwrap();
            let name = format!("{stem}_00001_.png");
            image::RgbaImage::new(64, 64)
                .save(dir.join(&name))
                .map_err(|e| e.to_string())?;
            Ok(RunOut {
                images: vec![(sub.to_string(), name)],
                placement: "cuda".into(),
            })
        }
        fn free(&self) -> Result<(), String> {
            self.frees.fetch_add(1, SeqCst);
            Ok(())
        }
    }

    fn install(fx: &Fixture, engine: Arc<dyn StudioEngine>) {
        install_seam(Some(Seam {
            engine,
            scratch_root: fx.scratch_root.clone(),
            project_root: fx.project.path().to_path_buf(),
        }));
    }

    /// 1956-x7xp verifiable closure (design D1 steps 2-4, D5). Pre-fix: FAILS,
    /// studio.run_workflow does not exist.
    #[test]
    fn studio_run_workflow_refuses_unpinned_node_and_returns_provenance() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("x7xp-proj", "a");
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone());
        let mut sink = |_: Progress| {};
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");

        // An unpinned class is refused and nothing is queued or fetched.
        let err = call(
            "x7xp-proj",
            "a",
            &json!({"workflow":"tool/art/workflows/unpinned.api.json","inputs":{"pose":pose}}),
            &mut sink,
        )
        .unwrap_err();
        assert!(
            err.starts_with("node_not_pinned:") && err.contains("WidgetFromTheInternet"),
            "{err}"
        );
        assert_eq!(engine.runs.load(SeqCst), 0);
        assert!(
            engine.fetched.lock().unwrap().is_empty(),
            "a refusal fetches nothing"
        );

        // A checkpoint the register does not admit: model_refused, nothing fetched.
        let err = call(
            "x7xp-proj",
            "a",
            &json!({"workflow":"tool/art/workflows/unregistered.api.json","inputs":{"pose":pose}}),
            &mut sink,
        )
        .unwrap_err();
        assert!(
            err.starts_with("model_refused:") && err.contains("mystery_merge_v9"),
            "{err}"
        );
        assert!(engine.fetched.lock().unwrap().is_empty());

        // A path outside the checkout is refused.
        let err = call(
            "x7xp-proj",
            "a",
            &json!({"workflow":"../../etc/passwd","inputs":{"pose":pose}}),
            &mut sink,
        )
        .unwrap_err();
        assert!(err.starts_with("invalid_arguments:"), "{err}");

        // A missing input file is refused before anything runs.
        let err = call(
            "x7xp-proj",
            "a",
            &json!({"workflow":"tool/art/workflows/ok.api.json",
                    "inputs":{"pose":format!("{FORGE_SCRATCH}/in/nope.png")}}),
            &mut sink,
        )
        .unwrap_err();
        assert!(
            err.starts_with("invalid_arguments:") && err.contains("nope.png"),
            "{err}"
        );
        assert_eq!(engine.runs.load(SeqCst), 0);

        // The valid workflow runs `count` items and writes provenance beside each.
        let mut queued = Vec::new();
        let r = call(
            "x7xp-proj",
            "a",
            &json!({"workflow":"tool/art/workflows/ok.api.json","inputs":{"pose":pose},
                    "overrides":{"seed":930001,"prompt":"a gatekeeper","negative_prompt":"blurry"},
                    "count":2,"tier":"I1"}),
            &mut |p| {
                if let Progress::Queued { position } = p {
                    queued.push(position)
                }
            },
        )
        .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(engine.runs.load(SeqCst), 2, "count items run consecutively");
        assert_eq!(
            engine.frees.load(SeqCst),
            1,
            "/free once after the job (D3)"
        );
        assert_eq!(
            engine.fetched.lock().unwrap().as_slice(),
            &[I1_CKPT.to_string()]
        );
        let outs = r["outputs"].as_array().expect("outputs");
        assert_eq!(outs.len(), 2);
        let job = r["job"].as_str().unwrap();
        assert!(job.starts_with("st-"), "{job}");
        for (i, o) in outs.iter().enumerate() {
            let p = o["path"].as_str().unwrap();
            assert!(
                p.starts_with(&format!("{FORGE_SCRATCH}/studio/{job}/")),
                "{p}"
            );
            let host = fx
                .lane_dir
                .join(p.strip_prefix(&format!("{FORGE_SCRATCH}/")).unwrap());
            assert!(host.is_file(), "{}", host.display());
            assert_eq!(o["has_alpha"], true);
            let side = crate::provenance::sidecar_path(&host);
            assert!(side.is_file(), "{}", side.display());
            let on_disk: Value = serde_json::from_slice(&std::fs::read(&side).unwrap()).unwrap();
            assert_eq!(
                on_disk, o["provenance"],
                "the result carries the same record"
            );
            assert_eq!(on_disk["schema"], "tillandsias.provenance/v1");
            assert_eq!(on_disk["engine"]["name"], "comfyui");
            assert_eq!(on_disk["engine"]["sha"], crate::provenance::COMFYUI_SHA);
            assert_eq!(on_disk["pipelineVersion"], crate::VERSION.trim());
            assert_eq!(on_disk["seed"], 930001 + i as u64);
            assert_eq!(on_disk["prompt"], "a gatekeeper");
            assert_eq!(on_disk["negative_prompt"], "blurry");
            assert_eq!(on_disk["tier"], "I1");
            assert_eq!(on_disk["placement"], "cuda");
            let m = &on_disk["models"][0];
            assert_eq!(m["file"], I1_CKPT);
            assert_eq!(
                m["sha256"],
                "e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490"
            );
            assert_eq!(m["licence"], "openrail++");
            assert_eq!(m["repo"], "ByteDance/SDXL-Lightning");
            let inp = &on_disk["inputs"][0];
            assert_eq!(inp["name"], "pose");
            assert_eq!(inp["path"], pose);
            assert_eq!(
                inp["sha256"],
                crate::provenance::sha256_hex(b"\x89PNG pose bytes")
            );
            let wsha = on_disk["workflow"]["sha256"].as_str().unwrap();
            assert_eq!(
                wsha,
                crate::provenance::sha256_hex(workflow(I1_CKPT, None).as_bytes())
            );
        }
        assert_eq!(r["provenance"], outs[0]["provenance"]);
        assert!(r["degraded"].is_null());
        assert_eq!(r["ephemeral"], true);
        // The pose crossed as /out/in/... inside the studio (D2).
        let prompts = engine.prompts.lock().unwrap();
        let bound = prompts[0]["4"]["inputs"]["image"].as_str().unwrap();
        assert_eq!(bound, "in/gk/left_hand.png [output]", "{bound}");
        assert_eq!(prompts[1]["5"]["inputs"]["seed"], 930002);
        drop(prompts);
        install_seam(None);
    }

    /// D1: overrides reach only nodes titled $seed, $prompt, $negative_prompt.
    #[test]
    fn studio_overrides_reach_only_titled_nodes() {
        let fx = fixture("x7xp-ov", "a");
        let req = parse_request(&json!({
            "workflow":"tool/art/workflows/ok.api.json",
            "inputs":{"pose":format!("{FORGE_SCRATCH}/in/gk/left_hand.png")},
            "overrides":{"seed":5,"prompt":"P","negative_prompt":"N"},
            "count":3
        }))
        .unwrap();
        assert_eq!(req.count, 3);
        let plan = validate(
            &req,
            &workflow(I1_CKPT, None),
            &Allowlist::shipped(),
            &crate::imagegen_models::manifest(),
            crate::imagegen_models::register_tsv(),
            &fx.lane_dir,
        )
        .unwrap_or_else(|e| panic!("{e}"));
        let p = prompt_for(&plan, "st-1", 2);
        assert_eq!(p["2"]["inputs"]["text"], "P");
        assert_eq!(p["3"]["inputs"]["text"], "N");
        assert_eq!(
            p["6"]["inputs"]["text"], "untouched",
            "an untitled node keeps its text"
        );
        assert_eq!(p["5"]["inputs"]["seed"], 7, "seed + i");
        assert_eq!(p["9"]["inputs"]["filename_prefix"], "studio/st-1/0002");
        assert!(
            p["4"]["inputs"]["image"]
                .as_str()
                .unwrap()
                .ends_with(" [output]")
        );
        // Without an override the workflow's own seed is the base.
        let req = parse_request(&json!({
            "workflow":"tool/art/workflows/ok.api.json",
            "inputs":{"pose":format!("{FORGE_SCRATCH}/in/gk/left_hand.png")}
        }))
        .unwrap();
        let plan = validate(
            &req,
            &workflow(I1_CKPT, None),
            &Allowlist::shipped(),
            &crate::imagegen_models::manifest(),
            crate::imagegen_models::register_tsv(),
            &fx.lane_dir,
        )
        .unwrap();
        assert_eq!(plan.seed, 1);
        assert_eq!(
            prompt_for(&plan, "st-2", 0)["2"]["inputs"]["text"],
            "placeholder"
        );
        // An override the workflow does not open is refused.
        let req =
            parse_request(&json!({"workflow":"w.api.json","overrides":{"prompt":"P"}})).unwrap();
        let only_seed = json!({
            "1": {"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":I1_CKPT}},
            "9": {"class_type":"SaveImage","inputs":{"filename_prefix":"x","images":["1",0]}}
        })
        .to_string();
        let err = validate(
            &req,
            &only_seed,
            &Allowlist::shipped(),
            &crate::imagegen_models::manifest(),
            crate::imagegen_models::register_tsv(),
            &fx.lane_dir,
        )
        .unwrap_err();
        assert!(
            err.starts_with("invalid_arguments:") && err.contains("$prompt"),
            "{err}"
        );
    }

    /// The allowlist: core classes pass, a class of an unpinned package does
    /// not, and the shipped TSV only names packages custom-nodes.toml can pin.
    #[test]
    fn studio_allowlist_is_data_and_admits_only_pinned_packages() {
        let toml = "[[node]]\nname = \"ComfyUI-GGUF\"\nrepo = \"x\"\ncommit = \"abc\"\n";
        let tsv = "#package\tclass\ncomfyui-core\tKSampler\nComfyUI-GGUF\tUnetLoaderGGUF\nComfyUI-layerdiffuse\tLayeredDiffusionApply\n";
        let a = Allowlist::parse(tsv, toml);
        assert!(a.admits("KSampler").is_ok());
        assert!(a.admits("UnetLoaderGGUF").is_ok());
        let e = a.admits("LayeredDiffusionApply").unwrap_err();
        assert!(
            e.starts_with("node_not_pinned:") && e.contains("ComfyUI-layerdiffuse"),
            "{e}"
        );
        assert!(
            a.admits("Nope")
                .unwrap_err()
                .starts_with("node_not_pinned:")
        );
        assert_eq!(
            a.pinned(),
            vec![("ComfyUI-GGUF".to_string(), "abc".to_string())]
        );
        let shipped = Allowlist::shipped();
        assert!(shipped.admits("SaveImage").is_ok());
        assert!(shipped.admits("UnetLoaderGGUF").is_ok());
        assert!(shipped.admits("ComfyUI-Manager").is_err());
        assert!(!shipped.pinned().is_empty());
    }

    /// Design D3: studio jobs and image.generate share one GPU queue.
    #[test]
    fn studio_and_imagegen_calls_never_overlap_on_the_device() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _g2 = crate::imagegen_tool::SEAM_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        crate::imagegen_consent::reset_for_test();
        #[derive(Default)]
        struct Busy {
            now: AtomicUsize,
            max: AtomicUsize,
        }
        impl Busy {
            fn enter(&self) {
                let n = self.now.fetch_add(1, SeqCst) + 1;
                self.max.fetch_max(n, SeqCst);
                std::thread::sleep(std::time::Duration::from_millis(40));
            }
            fn leave(&self) {
                self.now.fetch_sub(1, SeqCst);
            }
        }
        struct StudioBusy(Arc<Busy>, Stub);
        impl StudioEngine for StudioBusy {
            fn ensure_models(
                &self,
                f: &[ModelFile],
                p: &mut dyn FnMut(Progress),
            ) -> Result<(), String> {
                self.1.ensure_models(f, p)
            }
            fn run(
                &self,
                pr: &Value,
                o: &Path,
                p: &mut dyn FnMut(Progress),
            ) -> Result<RunOut, String> {
                self.0.enter();
                let r = self.1.run(pr, o, p);
                self.0.leave();
                r
            }
            fn free(&self) -> Result<(), String> {
                assert_eq!(
                    self.0.now.load(SeqCst),
                    0,
                    "/free runs after the turn's work"
                );
                self.1.free()
            }
        }
        struct ImgBusy(Arc<Busy>);
        impl crate::imagegen_tool::Engine for ImgBusy {
            fn generate(
                &self,
                job: &crate::imagegen_tool::Job,
                out_dir: &Path,
                names: &[String],
                _p: &mut dyn FnMut(Progress),
            ) -> Result<crate::imagegen_tool::EngineOut, String> {
                self.0.enter();
                for n in names {
                    image::RgbImage::new(job.width, job.height)
                        .save(out_dir.join(n))
                        .map_err(|e| e.to_string())?;
                }
                self.0.leave();
                Ok(crate::imagegen_tool::EngineOut {
                    backend: "cuda".into(),
                    first_use: false,
                })
            }
        }
        let busy = Arc::new(Busy::default());
        let fx = fixture("x7xp-q", "a");
        install(&fx, Arc::new(StudioBusy(busy.clone(), Stub::default())));
        crate::imagegen_tool::install_seam(Some(crate::imagegen_tool::Seam {
            engine: Arc::new(ImgBusy(busy.clone())),
            scratch_root: fx.scratch_root.clone(),
            ceiling: "I0".into(),
        }));
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let mut handles = Vec::new();
        for _ in 0..2 {
            let pose = pose.clone();
            handles.push(std::thread::spawn(move || {
                call(
                    "x7xp-q",
                    "a",
                    &json!({"workflow":"tool/art/workflows/ok.api.json","inputs":{"pose":pose},"count":2}),
                    &mut |_| {},
                )
                .map(|_| ())
            }));
        }
        handles.push(std::thread::spawn(|| {
            crate::imagegen_tool::call(
                "x7xp-q",
                "a",
                &json!({"prompt":"a fox","width":64,"height":64}),
                &mut |_| {},
            )
            .map(|_| ())
        }));
        for h in handles {
            h.join().unwrap().unwrap_or_else(|e| panic!("{e}"));
        }
        install_seam(None);
        crate::imagegen_tool::install_seam(None);
        assert_eq!(
            busy.max.load(SeqCst),
            1,
            "two engines on the device at once"
        );
    }

    /// The HTTP engine: POST /prompt, poll /history/<id>, GET /system_stats
    /// for the placement, then POST /free with the models unloaded (D3).
    #[test]
    fn studio_http_engine_runs_prompt_history_free_against_a_stub() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let log = Arc::new(Mutex::new(Vec::<String>::new()));
        let log2 = log.clone();
        let server = std::thread::spawn(move || {
            let mut history_polls = 0;
            loop {
                let (mut s, _) = listener.accept().unwrap();
                let mut buf = Vec::new();
                let mut tmp = [0u8; 4096];
                // Read headers, then the announced body.
                loop {
                    let n = s.read(&mut tmp).unwrap();
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..pos]).to_string();
                        let len: usize = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")
                                    .map(|v| v.trim().parse().unwrap())
                            })
                            .unwrap_or(0);
                        while buf.len() < pos + 4 + len {
                            let n = s.read(&mut tmp).unwrap();
                            if n == 0 {
                                break;
                            }
                            buf.extend_from_slice(&tmp[..n]);
                        }
                        break;
                    }
                }
                let text = String::from_utf8_lossy(&buf).to_string();
                let line = text.lines().next().unwrap_or("").to_string();
                let body_at = text.find("\r\n\r\n").map(|p| p + 4).unwrap_or(text.len());
                let body = text[body_at..].to_string();
                log2.lock().unwrap().push(format!("{line} {body}"));
                let (status, reply) = if line.starts_with("POST /prompt ") {
                    let v: Value = serde_json::from_str(&body).unwrap();
                    assert!(v["prompt"]["9"]["class_type"] == "SaveImage");
                    (200, json!({"prompt_id":"abc","number":1}).to_string())
                } else if line.starts_with("GET /history/abc ") {
                    history_polls += 1;
                    if history_polls < 2 {
                        (200, "{}".to_string())
                    } else {
                        (200, json!({"abc":{"outputs":{"9":{"images":[{"filename":"0000_00001_.png","subfolder":"studio/st-9","type":"output"}]}},
                                     "status":{"status_str":"success","completed":true}}}).to_string())
                    }
                } else if line.starts_with("GET /system_stats ") {
                    (
                        200,
                        json!({"devices":[{"name":"cuda:0","type":"cuda"}]}).to_string(),
                    )
                } else if line.starts_with("POST /free ") {
                    let v: Value = serde_json::from_str(&body).unwrap();
                    assert_eq!(v["unload_models"], true);
                    assert_eq!(v["free_memory"], true);
                    (200, String::new())
                } else {
                    (404, String::new())
                };
                // Chunked for one route, so the client decodes both framings.
                if line.starts_with("GET /system_stats ") {
                    let _ = write!(
                        s,
                        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{reply}\r\n0\r\n\r\n",
                        reply.len()
                    );
                } else {
                    let _ = write!(
                        s,
                        "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                        reply.len()
                    );
                }
                let _ = s.flush();
                if line.starts_with("POST /free ") {
                    break;
                }
            }
        });
        let engine = HttpStudio {
            transport: Box::new(TcpTransport {
                addr: addr.to_string(),
            }),
            models_dir: PathBuf::from("/nonexistent"),
            poll: std::time::Duration::from_millis(5),
        };
        let prompt: Value = serde_json::from_str(&workflow(I1_CKPT, None)).unwrap();
        let mut steps = Vec::new();
        let out = engine
            .run(&prompt, Path::new("/unused"), &mut |p| steps.push(p))
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            out.images,
            vec![("studio/st-9".to_string(), "0000_00001_.png".to_string())]
        );
        assert_eq!(out.placement, "cuda");
        engine.free().unwrap();
        server.join().unwrap();
        let log = log.lock().unwrap();
        let routes: Vec<&str> = log
            .iter()
            .map(|l| l.split(' ').take(2).collect::<Vec<_>>().join(" "))
            .map(|s| Box::leak(s.into_boxed_str()) as &str)
            .collect();
        assert_eq!(routes[0], "POST /prompt");
        assert_eq!(routes[1], "GET /history/abc");
        assert_eq!(routes[2], "GET /history/abc");
        assert_eq!(routes[3], "GET /system_stats");
        assert_eq!(routes[4], "POST /free");
        assert_eq!(routes.len(), 5);
    }

    /// `family` is accepted now and validated by studio_contract.rs (1956-26qh) later.
    #[test]
    fn studio_request_parses_as_design_d1_shows() {
        let r = parse_request(&json!({
            "workflow": "tool/art/workflows/character-pose-sdxl.api.json",
            "inputs": { "pose": "/work/tmp/imagegen/in/gk/left_hand.peak.pose.png" },
            "overrides": { "seed": 930001, "prompt": "...", "negative_prompt": "..." },
            "count": 4,
            "family": "art/families/gatekeeper-v3.json",
            "tier": "I1"
        }))
        .unwrap();
        assert_eq!(r.count, 4);
        assert_eq!(r.overrides.seed, Some(930001));
        assert_eq!(r.family.as_deref(), Some("art/families/gatekeeper-v3.json"));
        assert_eq!(r.tier.as_deref(), Some("I1"));
        assert!(parse_request(&json!({"workflow":"w","count":17})).is_err());
        assert!(parse_request(&json!({"workflow":"w","count":0})).is_err());
        assert!(parse_request(&json!({})).is_err());
        let d = descriptor();
        assert_eq!(d["name"], "studio.run_workflow");
        assert_eq!(d["inputSchema"]["required"][0], "workflow");
    }
}
