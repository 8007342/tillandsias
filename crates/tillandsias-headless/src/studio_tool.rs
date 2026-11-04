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
//!   every `SaveImage` prefix is forced to `studio/<job>/<index>` (plus `/<node>`
//!   when there are several, 1972-stfx), so outputs
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
/// 1983-svid: the output nodes the studio forces under `studio/<job>/<i>` and
/// returns. A video node (Wan) saves through the same history as images.
pub const SAVE_CLASSES: &[&str] = &[
    "SaveImage",
    "SaveVideo",
    "SaveWEBM",
    "SaveAnimatedWEBP",
    "SaveAnimatedPNG",
];

fn is_save_class(class: &str) -> bool {
    SAVE_CLASSES.contains(&class)
}

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

/// 1972-stfx: loader inputs whose name is too generic to read on every node
/// (`model` is a link on most nodes), keyed by class. BiRefNet_ll's loader
/// names its weights in `model`, so they were never checked or fetched and
/// ComfyUI refused "model.safetensors not in []".
pub const CLASS_MODEL_INPUTS: &[(&str, &str)] = &[("LoadRembgByBiRefNetModel", "model")];

/// 1986-snpx: nodes that pick their weights by a CONFIG value, not a file
/// name: (class, input, value, folder, pinned file). LayerDiffuse at the
/// pinned commit: Apply's `config` names the injection weights, Decode's
/// `sd_version` the transparent VAE decoder. Before this, these weights were
/// never validated, fetched or recorded in provenance (kumbia forge: layer_model
/// was empty). A config value of these classes not listed here is refused.
pub const CONFIG_MODELS: &[(&str, &str, &str, &str, &str)] = &[
    (
        "LayeredDiffusionApply",
        "config",
        "SDXL, Attention Injection",
        "I1/layer_model",
        "layer_xl_transparent_attn.safetensors",
    ),
    (
        "LayeredDiffusionApply",
        "config",
        "SDXL, Conv Injection",
        "I1/layer_model",
        "layer_xl_transparent_conv.safetensors",
    ),
    (
        "LayeredDiffusionDecode",
        "sd_version",
        "SDXL",
        "I1/layer_model",
        "vae_transparent_decoder.safetensors",
    ),
];

/// The pinned rows a config-selected node uses, or a refusal naming the
/// accepted values. `None` when the class picks no weights by config.
fn config_models<'a>(
    manifest: &'a [ModelFile],
    class: &str,
    inputs: &serde_json::Map<String, Value>,
) -> Option<Result<Vec<&'a ModelFile>, String>> {
    let rows: Vec<_> = CONFIG_MODELS.iter().filter(|r| r.0 == class).collect();
    if rows.is_empty() {
        return None;
    }
    let input = rows[0].1;
    let value = inputs.get(input).and_then(Value::as_str).unwrap_or("");
    let hit: Vec<_> = rows.iter().filter(|r| r.2 == value).collect();
    if hit.is_empty() {
        let accepted: Vec<&str> = rows.iter().map(|r| r.2).collect();
        return Some(Err(format!(
            "model_refused: {class} {input}={value:?} selects weights that are not pinned; accepted: {}",
            accepted.join(" | ")
        )));
    }
    Some(
        hit.iter()
            .map(|r| {
                manifest
                    .iter()
                    .find(|m| m.tier == r.3 && m.cache_name() == r.4)
                    .ok_or_else(|| {
                        format!(
                            "model_refused: {class} needs {}/{} but models.tsv does not pin it",
                            r.3, r.4
                        )
                    })
            })
            .collect(),
    )
}

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
                "verbose": { "type": "boolean", "default": false,
                             "description": "Return each output's full provenance inline. By default it is only in the sidecar file at provenance_path." },
                "family": { "type": "string", "description": "Optional family spec path in the checkout (studio.validate_family runs first)." },
                "init_image": { "type": "string", "description": format!("1959-xsy5 (D11): bound to a LoadImage whose image is \"$init_image\"; under {FORGE_SCRATCH}/.") },
                "mask": { "type": "string", "description": "Bound to a LoadImage whose image is \"$mask\" (white repainted, black kept)." },
                "layout_mask": { "type": "string", "description": "Bound to a LoadImage whose image is \"$layout_mask\"." },
                "strength": { "type": "number", "minimum": 0, "maximum": 1, "description": "The denoise of the KSampler titled $strength. A workflow without the node is refused workflow_has_no_input:<name>." }
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

#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub workflow: String,
    pub inputs: BTreeMap<String, String>,
    pub overrides: Overrides,
    pub count: u32,
    pub tier: Option<String>,
    pub family: Option<String>,
    /// 1959-xsy5 (D11): the image keys this request binds (init_image, mask,
    /// layout_mask), each also present in `inputs` under the same name. A
    /// workflow with no `$<name>` LoadImage for one is refused.
    pub d11_keys: Vec<String>,
    /// 1959-xsy5 (D11): bound to the KSampler titled `$strength`.
    pub strength: Option<f32>,
}

/// D11's image keys, in the order they are checked.
const D11_IMAGE_KEYS: &[&str] = &["init_image", "mask", "layout_mask"];

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
    // 1959-xsy5 (D11): the same keys image.generate takes, as named inputs.
    let mut d11_keys = Vec::new();
    for key in D11_IMAGE_KEYS {
        if let Some(p) = args.get(*key).and_then(Value::as_str) {
            if inputs.contains_key(*key) {
                return Err(format!(
                    "invalid_arguments: {key} is given both as a key and in inputs; pass it once"
                ));
            }
            inputs.insert((*key).to_string(), p.to_string());
            d11_keys.push((*key).to_string());
        }
    }
    let strength = match args.get("strength") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_f64()
                .filter(|s| (0.0..=1.0).contains(s))
                .ok_or("invalid_arguments: strength must be a number 0..=1")? as f32,
        ),
    };
    Ok(Request {
        d11_keys,
        strength,
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
        // 1991-dovl: a dev build appends overlay rows (read per call); a
        // class from an unpinned package still admits nothing.
        let rows = crate::dev_overlay::append(
            NODE_CLASSES_TSV,
            crate::dev_overlay::read(crate::dev_overlay::NODE_CLASSES),
        );
        Self::parse(&rows, CUSTOM_NODES_TOML)
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
    /// 1986-snpx: every loader input resolved to a pinned file:
    /// (node, class, input, the name as written, the row).
    pub loader_inputs: Vec<(String, String, String, String, ModelFile)>,
}

/// 1986-snpx: what a refusal says about the table it read: the build of
/// this tray and the digest of the models.tsv compiled into it.
fn table_note() -> String {
    format!(
        "(this tray: build {}, models.tsv {}; a pin newer than this tray needs a tray rebuild)",
        crate::mcp_socket::build_identity(),
        imagegen_models::manifest_digest()
    )
}

fn title_of(node: &Value) -> Option<&str> {
    node.get("_meta")?.get("title")?.as_str()
}

/// 1986-snpx: the studio's ComfyUI folder map (extra_model_paths.yaml):
/// category -> the tier folders under /models it scans.
const EXTRA_MODEL_PATHS: &str =
    include_str!("../../../images/imagegen-studio/extra_model_paths.yaml");

/// `category: |` followed by indented folder lines, per category.
fn model_folders(category: &str) -> Vec<String> {
    let head = format!("  {category}: |");
    let mut out = Vec::new();
    let mut inside = false;
    // 1991-dovl: a dev overlay map replaces the compiled one.
    let paths = crate::dev_overlay::read(crate::dev_overlay::MODEL_PATHS)
        .unwrap_or_else(|| EXTRA_MODEL_PATHS.to_string());
    for line in paths.lines() {
        if line.trim_end() == head {
            inside = true;
            continue;
        }
        if inside {
            match line.strip_prefix("    ") {
                Some(v) if !v.trim().is_empty() && !v.trim_start().starts_with('#') => {
                    out.push(v.trim().to_string())
                }
                _ => break,
            }
        }
    }
    out
}

/// 1986-snpx: the ComfyUI folder categories a loader input reads from. A
/// name is resolved only among the rows in those folders, so two pinned
/// files with one basename (I1/clip_vision and I1/birefnet model.safetensors)
/// never resolve to each other.
fn input_categories(class: &str, key: &str) -> &'static [&'static str] {
    match (class, key) {
        ("LoadRembgByBiRefNetModel", "model") => &["birefnet"],
        // Before the generic clip_name arm: this loader's clip_name reads
        // clip_vision, not the text encoders.
        ("CLIPVisionLoader", "clip_name") => &["clip_vision"],
        (_, "ckpt_name") => &["checkpoints"],
        (_, "unet_name") => &["diffusion_models", "unet"],
        (_, "vae_name") => &["vae"],
        (_, "lora_name") => &["loras"],
        (_, "control_net_name") => &["controlnet"],
        (_, "ipadapter_file") => &["ipadapter"],
        (_, "clip_name" | "clip_name1" | "clip_name2" | "clip_name3" | "clip_name4") => {
            &["text_encoders", "clip"]
        }
        (_, "clip_vision" | "clip_vision_name" | "image_encoder") => &["clip_vision"],
        _ => &[],
    }
}

/// Every name ComfyUI may list `m` under for these folders: a file under a
/// scanned folder F is listed by its path relative to F (ComfyUI walks F
/// recursively), so I1/sdxl-full/x under the `I1` root is `sdxl-full/x`.
/// The bare basename and `<tier>/<file>` are accepted too.
fn listed_names(m: &ModelFile, folders: &[String]) -> Vec<String> {
    let mut names = vec![
        m.cache_name().to_string(),
        format!("{}/{}", m.tier, m.cache_name()),
    ];
    for f in folders {
        if let Some(rest) = m.tier.strip_prefix(&format!("{f}/")) {
            names.push(format!("{rest}/{}", m.cache_name()));
        }
    }
    names
}

/// `pinned_model`, limited to the rows in `categories`' folders when given.
fn pinned_model_in<'a>(
    manifest: &'a [ModelFile],
    named: &str,
    categories: Option<&[&str]>,
) -> Option<&'a ModelFile> {
    let folders: Vec<String> = categories
        .unwrap_or(&[])
        .iter()
        .flat_map(|c| model_folders(c))
        .collect();
    // A row is in scope only when its OWN folder is one of the category's:
    // the `I1` checkpoints root also walks into I1/lora, but a lora is not a
    // checkpoint (I1/sdxl-full is listed under checkpoints in its own right).
    let in_scope =
        |m: &ModelFile| categories.is_none_or(|c| c.is_empty()) || folders.contains(&m.tier);
    manifest
        .iter()
        .filter(|m| in_scope(m))
        .find(|m| listed_names(m, &folders).iter().any(|n| n == named))
}

/// A forge path under `FORGE_SCRATCH/` → its path relative to the volume.
pub(crate) fn scratch_relative(forge_path: &str) -> Result<&str, String> {
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
    if !classes.iter().any(|(_, c)| is_save_class(c)) {
        return Err(format!(
            "invalid_workflow: no output node ({}), so the run would produce nothing",
            SAVE_CLASSES.join(", ")
        ));
    }
    // 3. Every model file is a pinned, admitted row.
    let mut models: Vec<ModelFile> = Vec::new();
    let mut loader_inputs: Vec<(String, String, String, String, ModelFile)> = Vec::new();
    for (id, node) in nodes {
        let inputs = node["inputs"].as_object().expect("checked above");
        let class = node["class_type"].as_str().unwrap_or("");
        let keys = MODEL_INPUTS.iter().copied().chain(
            CLASS_MODEL_INPUTS
                .iter()
                .filter(|(c, _)| *c == class)
                .map(|(_, k)| *k),
        );
        // 1986-snpx: weights a node picks by a config value.
        if let Some(rows) = config_models(manifest, class, inputs) {
            for row in rows.map_err(|e| format!("{e} (node {id})"))? {
                imagegen_models::register_admits(register, row)?;
                // A config value names no file a loader lists: disk check only.
                loader_inputs.push((
                    id.clone(),
                    String::new(),
                    "config".into(),
                    row.cache_name().to_string(),
                    row.clone(),
                ));
                if !models.contains(row) {
                    models.push(row.clone());
                }
            }
        }
        for key in keys {
            if let Some(named) = inputs.get(key).and_then(Value::as_str) {
                let cats = input_categories(class, key);
                let row = pinned_model_in(manifest, named, Some(cats)).ok_or_else(|| {
                    let folders: Vec<String> = cats.iter().flat_map(|c| model_folders(c)).collect();
                    let accepted: Vec<String> = manifest
                        .iter()
                        .filter(|m| folders.contains(&m.tier))
                        .flat_map(|m| listed_names(m, &folders).into_iter().take(1))
                        .collect();
                    format!(
                        "model_refused: node {id} {key}={named:?} is not a pinned file in its folders ({}); \
                         accepted here: {}. A model runs only when images/imagegen/models.tsv pins it and \
                         images/models/licence-register.tsv admits it (the operator approves each licence) {}",
                        cats.join("/"),
                        if accepted.is_empty() { "none".to_string() } else { accepted.join(", ") },
                        table_note()
                    )
                })?;
                imagegen_models::register_admits(register, row)?;
                loader_inputs.push((
                    id.clone(),
                    class.to_string(),
                    key.to_string(),
                    named.to_string(),
                    row.clone(),
                ));
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
    let mut placeholders: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut strength_bound = false;
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
            placeholders.insert(name.to_string());
            let rel = scratch_relative(&bound.forge_path)?;
            obj.insert((*key).to_string(), json!(format!("{rel} [output]")));
        }
        // 1959-xsy5 (D11): strength is the denoise of the sampler titled
        // $strength; a KSamplerAdvanced (no denoise input) starts that far in.
        if title_of(node) == Some("$strength")
            && let Some(s) = req.strength
        {
            let class = node["class_type"].as_str().unwrap_or("").to_string();
            let obj = node["inputs"].as_object_mut().expect("object");
            match class.as_str() {
                "KSampler" => {
                    obj.insert("denoise".into(), json!(s));
                    strength_bound = true;
                }
                "KSamplerAdvanced" => {
                    let steps = obj.get("steps").and_then(Value::as_u64).unwrap_or(20);
                    let start = (steps as f64 * (1.0 - s as f64)).round() as u64;
                    obj.insert("start_at_step".into(), json!(start));
                    strength_bound = true;
                }
                _ => {}
            }
        }
    }
    // D11: a requested key the workflow has no node for is refused here,
    // before anything queues, naming the knob the workflow does not open.
    for key in &req.d11_keys {
        if !placeholders.contains(key.as_str()) {
            return Err(format!(
                "workflow_has_no_input:{key}: no LoadImage in {} has image \"${key}\"",
                req.workflow
            ));
        }
    }
    if req.strength.is_some() && !strength_bound {
        return Err(format!(
            "workflow_has_no_input:strength: no KSampler or KSamplerAdvanced in {} is titled $strength",
            req.workflow
        ));
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
        loader_inputs,
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
/// 1983-svid: what one output file is.
enum OutputKind {
    Image { w: u32, h: u32, alpha: bool },
    Video,
}

/// A PNG is an image (its IHDR read); mp4, webm, an animated webp or gif is
/// a video. Anything else is named, never silently accepted or dropped.
fn output_kind(file: &str, bytes: &[u8]) -> Result<OutputKind, String> {
    let ext = file.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "png" => crate::imagegen_tool::png_facts(bytes)
            .map(|(w, h, alpha)| OutputKind::Image { w, h, alpha })
            .ok_or_else(|| format!("engine_failed: {file} is not a PNG")),
        "mp4" | "webm" | "webp" | "gif" | "mov" | "mkv" => {
            if bytes.is_empty() {
                Err(format!("engine_failed: {file} is empty"))
            } else {
                Ok(OutputKind::Video)
            }
        }
        other => Err(format!(
            "engine_failed: {file} is an unexpected output type ({other}); the studio returns png images and mp4/webm/webp/gif videos"
        )),
    }
}

/// 1973-prvc: the record shared by every output, said once. `verbose` keeps
/// the full first record (the pre-1973 shape); otherwise only the fields an
/// agent reads to know what ran: workflow, models, tier, placement.
fn provenance_summary(first: &Value, verbose: bool) -> Value {
    if verbose {
        return first.clone();
    }
    json!({
        "schema": first["schema"],
        "workflow": first["workflow"]["path"],
        "models": first["models"]
            .as_array()
            .map(|m| m.iter().map(|x| x["file"].clone()).collect::<Vec<_>>()),
        "tier": first["tier"],
        "placement": first["placement"],
        "full": "each output's provenance_path (verbose: true returns it inline)",
    })
}

pub fn prompt_for(plan: &Plan, job: &str, i: u32) -> Value {
    let mut p = plan.workflow.clone();
    // 1972-stfx: with more than one SaveImage, each writes under its own node
    // id, so no two nodes share a prefix and every node's images come back.
    let saves = p
        .as_object()
        .expect("object")
        .values()
        .filter(|n| n["class_type"].as_str().is_some_and(is_save_class))
        .count();
    for (id, node) in p.as_object_mut().expect("object").iter_mut() {
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
        if is_save_class(&class) {
            inputs.insert(
                "filename_prefix".into(),
                json!(if saves > 1 {
                    format!("studio/{job}/{i:04}/{id}")
                } else {
                    format!("studio/{job}/{i:04}")
                }),
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

    /// 1986-snpx: the names ComfyUI's loader `class` offers for `input`
    /// (`/object_info/<class>`). `None`: this engine cannot say (a fixture),
    /// so the check is skipped, never failed.
    fn loader_options(&self, _class: &str, _input: &str) -> Option<Result<Vec<String>, String>> {
        None
    }

    /// 1986-snpx: where this engine's pinned files live (`None` for a
    /// fixture, which skips the on-disk check).
    fn models_dir(&self) -> Option<PathBuf> {
        None
    }
}

/// 1986-snpx: the loaders `studio.models` asks ComfyUI about.
const LISTED_LOADERS: &[(&str, &str)] = &[
    ("CheckpointLoaderSimple", "ckpt_name"),
    ("UNETLoader", "unet_name"),
    ("VAELoader", "vae_name"),
    ("CLIPLoader", "clip_name"),
    ("CLIPVisionLoader", "clip_name"),
    ("LoraLoader", "lora_name"),
    ("ControlNetLoader", "control_net_name"),
    ("LoadRembgByBiRefNetModel", "model"),
];

/// `studio.models {}`, read-only: every pinned studio-reachable row and
/// whether it is on disk, this tray's table (build and models.tsv digest, to
/// compare with the checkout's images/imagegen/models.tsv), and, when the
/// studio runs, what each of ComfyUI's loaders lists.
pub fn models_listing(models_dir: &Path, engine: Option<&dyn StudioEngine>) -> Value {
    let rows: Vec<Value> = imagegen_models::manifest()
        .iter()
        .filter(|m| m.tier.starts_with("I1") || m.role.starts_with("studio:"))
        .map(|m| {
            json!({
                "folder": m.tier,
                "file": m.cache_name(),
                "role": m.role,
                "licence": m.licence,
                "on_disk": models_dir.join(&m.tier).join(m.cache_name()).is_file(),
            })
        })
        .collect();
    let comfyui = engine.map(|e| {
        let mut m = serde_json::Map::new();
        for (class, input) in LISTED_LOADERS {
            let v = match e.loader_options(class, input) {
                Some(Ok(list)) => json!(list),
                Some(Err(err)) => json!({ "error": err }),
                None => Value::Null,
            };
            m.insert(format!("{class}.{input}"), v);
        }
        Value::Object(m)
    });
    json!({
        "tray_build": crate::mcp_socket::build_identity(),
        "models_tsv": imagegen_models::manifest_digest(),
        "compare": "sha256 (first 12) of the checkout's images/imagegen/models.tsv against models_tsv: a difference means this tray predates the pins (rebuild it)",
        "rows": rows,
        "comfyui": comfyui.unwrap_or(Value::Null),
    })
}

/// The `studio.models` descriptor.
pub fn models_descriptor() -> Value {
    json!({
        "name": "studio.models",
        "description": "Read-only: the studio-reachable pinned model files (folder, file, licence, on disk), this tray's model table (build and models.tsv digest), and, when the studio runs, what each ComfyUI loader lists. Use it when a workflow is refused or a loader says 'not in []'.",
        "inputSchema": { "type": "object", "properties": {} },
    })
}

/// 1986-snpx: before anything queues, every resolved file is on disk and
/// ComfyUI's loader lists it. Before this a pinned-but-unfetched file reached
/// ComfyUI and failed there as "<file> not in []" (kumbia forge).
pub fn precheck_models(engine: &dyn StudioEngine, plan: &Plan) -> Result<(), String> {
    let models_dir = engine.models_dir();
    for (node, class, input, named, row) in &plan.loader_inputs {
        let on_disk = models_dir
            .as_ref()
            .map(|d| d.join(&row.tier).join(row.cache_name()));
        if let Some(on_disk) = on_disk.filter(|p| !p.is_file()) {
            return Err(format!(
                "model_missing: node {node} {input}={named:?} is pinned ({}/{}) but not on disk at {} after the fetch",
                row.tier,
                row.cache_name(),
                on_disk.display()
            ));
        }
        if class.is_empty() {
            continue;
        }
        if let Some(listed) = engine.loader_options(class, input) {
            let listed = listed?;
            if !listed.iter().any(|l| l == named) {
                let shown: Vec<&str> = listed.iter().take(8).map(String::as_str).collect();
                return Err(format!(
                    "model_not_visible: node {node} {class}.{input}={named:?} is on disk, but the studio's loader lists [{}]{}; \
                     restart the studio (its folder map is read at start) or write the name as listed",
                    shown.join(", "),
                    if listed.len() > 8 { ", ..." } else { "" }
                ));
            }
        }
    }
    Ok(())
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
pub(crate) fn scratch_dir(project: &str, instance: &str) -> Result<PathBuf, String> {
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
    // 1986-snpx: fail before queueing, never inside ComfyUI.
    precheck_models(engine.as_ref(), &plan)?;

    let job = job_id();
    let t0 = Instant::now();
    // D3: one GPU queue per host; the turn covers the prompts, then /free.
    let turn = gpu_queue::wait_for_gpu(&mut |position| progress(Progress::Queued { position }));
    // 1971-3erz: a studio job takes the device; the resident image engine yields.
    #[cfg(feature = "host-services")]
    crate::imagegen_warm::release("a studio job takes the GPU");
    // 1957-emar: room for the workflow's weights plus 1 GiB, evicting a
    // resident LLM when free VRAM is short.
    let need: u64 = plan.models.iter().map(|m| m.bytes).sum::<u64>() + (1 << 30);
    let evicted = gpu_queue::arbiter().admit(need);
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
        return Err(
            "engine_failed: the workflow finished but produced no output file (image or video)"
                .into(),
        );
    }

    let verbose = args.get("verbose").and_then(Value::as_bool) == Some(true);
    let mut summary: Option<Value> = None;
    let mut outputs = Vec::new();
    for (i, sub, file) in &produced {
        let host = scratch.join(sub).join(file);
        let bytes = std::fs::read(&host)
            .map_err(|e| format!("engine_failed: no output {sub}/{file}: {e}"))?;
        // 1983-svid: a video output (Wan SaveVideo/SaveWEBM, an animated WEBP)
        // is returned like an image, never dropped and never a "not a PNG" failure.
        let kind = output_kind(file, &bytes)?;
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
        let mut out = json!({
            "path": forge,
            "seed": plan.seed + u64::from(*i),
            "provenance_path": format!("{forge}.provenance.json"),
        });
        match kind {
            OutputKind::Image { w, h, alpha } => {
                out["kind"] = json!("image");
                out["width"] = json!(w);
                out["height"] = json!(h);
                out["has_alpha"] = json!(alpha);
            }
            OutputKind::Video => {
                out["kind"] = json!("video");
                out["bytes"] = json!(bytes.len());
            }
        }
        outputs.push(out);
        // 1973-prvc: the full record lives in the sidecar; inline only on ask.
        if verbose {
            outputs.last_mut().expect("pushed")["provenance"] = prov.clone();
        }
        summary.get_or_insert(prov);
    }
    Ok(json!({
        "job": job,
        "evicted_holders": evicted.iter().map(gpu_queue::Evicted::to_json).collect::<Vec<_>>(),
        "outputs": outputs,
        "provenance": provenance_summary(summary.as_ref().expect("an output"), verbose),
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
                "studio_unavailable: {container} is not running; call studio.start {{}} first (no relaunch needed), then retry"
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

    fn models_dir(&self) -> Option<PathBuf> {
        Some(self.models_dir.clone())
    }

    /// `/object_info/<class>`: the option list of `input` (required or
    /// optional), ComfyUI's own view of what the loader can load.
    fn loader_options(&self, class: &str, input: &str) -> Option<Result<Vec<String>, String>> {
        let info = match self.json("GET", &format!("/object_info/{class}"), None) {
            Ok(v) => v,
            Err(e) => return Some(Err(e)),
        };
        let spec = &info[class]["input"];
        let list = spec["required"][input][0]
            .as_array()
            .or_else(|| spec["optional"][input][0].as_array())?;
        Some(Ok(list
            .iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect()))
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
        let mut two = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        two["11"] =
            json!({"class_type":"SaveImage","inputs":{"filename_prefix":"b","images":["8",0]}});
        std::fs::write(wf.join("two_saves.api.json"), two.to_string()).unwrap();
        // 1986-snpx: LayerDiffuse picks its weights by config value.
        let mut layer = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        layer["14"] = json!({"class_type":"LayeredDiffusionApply","inputs":{"model":["1",0],"config":"SDXL, Conv Injection","weight":1.0}});
        layer["15"] = json!({"class_type":"LayeredDiffusionDecode","inputs":{"samples":["5",0],"images":["8",0],"sd_version":"SDXL","sub_batch_size":16}});
        std::fs::write(wf.join("layer.api.json"), layer.to_string()).unwrap();
        let mut layer_bad = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        layer_bad["14"] = json!({"class_type":"LayeredDiffusionApply","inputs":{"model":["1",0],"config":"SD15, Attention Injection","weight":1.0}});
        std::fs::write(wf.join("layer_bad.api.json"), layer_bad.to_string()).unwrap();
        // 1983-svid: a video-only workflow, and one with an image and a video.
        let mut video = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        video["9"] = json!({"class_type":"SaveWEBM","inputs":{"filename_prefix":"v","images":["8",0],"codec":"vp9","fps":16.0,"crf":32.0}});
        std::fs::write(wf.join("video_only.api.json"), video.to_string()).unwrap();
        let mut mixed = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        mixed["13"] = json!({"class_type":"SaveWEBM","inputs":{"filename_prefix":"v","images":["8",0],"codec":"vp9","fps":16.0,"crf":32.0}});
        std::fs::write(wf.join("mixed.api.json"), mixed.to_string()).unwrap();
        let mut rembg = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        rembg["12"] = json!({"class_type":"LoadRembgByBiRefNetModel",
                             "inputs":{"model":"model.safetensors","device":"AUTO"}});
        std::fs::write(wf.join("rembg.api.json"), rembg.to_string()).unwrap();
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
            // Every SaveImage node saves, as ComfyUI does; one prefix shared
            // by two nodes writes the same file twice here (1972-stfx).
            let mut images = Vec::new();
            for node in prompt.as_object().unwrap().values() {
                let class = node["class_type"].as_str().unwrap_or("");
                if !is_save_class(class) {
                    continue;
                }
                let prefix = node["inputs"]["filename_prefix"].as_str().unwrap();
                let (sub, stem) = prefix.rsplit_once('/').unwrap();
                let dir = out_dir.join(sub);
                std::fs::create_dir_all(&dir).unwrap();
                // 1983-svid: a video node writes a .webm, as ComfyUI does.
                let name = if class == "SaveImage" {
                    let n = format!("{stem}_00001_.png");
                    image::RgbaImage::new(64, 64)
                        .save(dir.join(&n))
                        .map_err(|e| e.to_string())?;
                    n
                } else {
                    let n = format!("{stem}_00001_.webm");
                    std::fs::write(dir.join(&n), b"\x1aE\xdf\xa3 webm bytes")
                        .map_err(|e| e.to_string())?;
                    n
                };
                images.push((sub.to_string(), name));
            }
            Ok(RunOut {
                images,
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

    /// 1972-stfx: a workflow with two SaveImage nodes returns both nodes'
    /// images, each at its own path. Pre-fix: FAILS, both nodes shared
    /// studio/<job>/<i> and the second overwrote the first.
    #[test]
    fn every_save_image_node_returns_its_own_output() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("stfx-two", "a");
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone());
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let r = call(
            "stfx-two",
            "a",
            &json!({"workflow":"tool/art/workflows/two_saves.api.json","inputs":{"pose":pose}}),
            &mut |_| {},
        );
        install_seam(None);
        let r = r.expect("runs");
        let paths: Vec<&str> = r["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["path"].as_str().unwrap())
            .collect();
        assert_eq!(paths.len(), 2, "{r}");
        assert_ne!(paths[0], paths[1], "each node has its own path: {paths:?}");
    }

    /// 1973-prvc: a count=4 result stays small (the forge pays for every
    /// token) and still names every output's path, seed and sidecar. The
    /// MCP reply carries it twice (text + structuredContent), so the budget
    /// here is half of ~2k tokens at ~4 bytes each. Pre-fix: FAILS, the full
    /// record was inline per output and again at the top level.
    #[test]
    fn a_count_four_result_is_compact_and_keeps_every_path_seed_and_sidecar() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("prvc-proj", "a");
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone());
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let r = call(
            "prvc-proj",
            "a",
            &json!({"workflow":"tool/art/workflows/ok.api.json","inputs":{"pose":pose},
                    "overrides":{"seed":5,"prompt":"a gatekeeper, pixel art, full body"},
                    "count":4,"tier":"I1"}),
            &mut |_| {},
        );
        install_seam(None);
        let r = r.unwrap_or_else(|e| panic!("{e}"));
        let bytes = r.to_string().len();
        assert!(bytes < 4000, "{bytes} bytes: {r}");
        let outs = r["outputs"].as_array().unwrap();
        assert_eq!(outs.len(), 4);
        for (i, o) in outs.iter().enumerate() {
            assert!(
                o["path"].is_string() && o["provenance_path"].is_string(),
                "{o}"
            );
            assert_eq!(o["seed"], 5 + i as u64);
            assert!(
                o["provenance"].is_null(),
                "no inline record by default: {o}"
            );
            let side = fx.lane_dir.join(
                o["provenance_path"]
                    .as_str()
                    .unwrap()
                    .strip_prefix(&format!("{FORGE_SCRATCH}/"))
                    .unwrap(),
            );
            assert!(side.is_file(), "{}", side.display());
        }
    }

    /// ORDER 1986-snpx: a name resolves only among the rows in its input's
    /// folders. Pre-fix: FAILS, BiRefNet's model.safetensors resolved to the
    /// FIRST row with that basename (I1/clip_vision, line 46), so the BiRefNet
    /// weights were never fetched (kumbia forge, "not in []").
    #[test]
    fn a_shared_basename_resolves_to_the_row_in_the_inputs_folder() {
        let manifest = imagegen_models::manifest();
        let birefnet = pinned_model_in(
            &manifest,
            "model.safetensors",
            Some(input_categories("LoadRembgByBiRefNetModel", "model")),
        )
        .expect("birefnet resolves");
        assert_eq!(birefnet.tier, "I1/birefnet");
        // CLIPVisionLoader's clip_name reads clip_vision; every other loader's
        // clip_name reads text encoders, where no model.safetensors is pinned.
        let clip_vision = pinned_model_in(
            &manifest,
            "model.safetensors",
            Some(input_categories("CLIPVisionLoader", "clip_name")),
        )
        .expect("CLIPVisionLoader resolves");
        assert_eq!(clip_vision.tier, "I1/clip_vision");
        let text_encoder = pinned_model_in(
            &manifest,
            "model.safetensors",
            Some(input_categories("CLIPLoader", "clip_name")),
        )
        .map(|m| m.tier.clone());
        assert_eq!(text_encoder, None);
        let vision = pinned_model_in(
            &manifest,
            "model.safetensors",
            Some(input_categories("IPAdapterUnifiedLoader", "clip_vision")),
        )
        .expect("clip_vision resolves");
        assert_eq!(vision.tier, "I1/clip_vision");
    }

    /// ORDER 1986-snpx: ComfyUI lists a file under a scanned root by its path
    /// relative to that root (the `I1` checkpoints root walks into
    /// sdxl-full/), so that listed form is accepted.
    #[test]
    fn comfyuis_listed_subfolder_form_is_accepted() {
        let manifest = imagegen_models::manifest();
        let cats = Some(input_categories("CheckpointLoaderSimple", "ckpt_name"));
        if let Some(row) = manifest.iter().find(|m| m.tier == "I1/sdxl-full") {
            let listed = format!("sdxl-full/{}", row.cache_name());
            assert_eq!(
                pinned_model_in(&manifest, &listed, cats).map(|m| m.tier.as_str()),
                Some("I1/sdxl-full")
            );
        }
        // The base I1 checkpoint keeps its bare name.
        assert!(pinned_model_in(&manifest, "sdxl_lightning_4step.safetensors", cats).is_some());
        // A lora is not a checkpoint, even though the I1 root walks into I1/lora.
        assert!(pinned_model_in(&manifest, "lora/pixel-art-xl.safetensors", cats).is_none());
    }

    /// ORDER 1986-snpx: a LayerDiffuse workflow fetches the weights its config
    /// values select and records them in provenance; an unpinned config is
    /// refused. Pre-fix: FAILS, config-selected weights were never seen.
    #[test]
    fn config_selected_layerdiffuse_weights_are_fetched_and_recorded() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("snpx-layer", "a");
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone());
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let run = |wf: &str| {
            call(
                "snpx-layer",
                "a",
                &json!({"workflow":format!("tool/art/workflows/{wf}"),"inputs":{"pose":pose},"verbose":true}),
                &mut |_| {},
            )
        };
        let ok = run("layer.api.json");
        let bad = run("layer_bad.api.json");
        install_seam(None);
        let ok = ok.unwrap_or_else(|e| panic!("{e}"));
        let fetched = engine.fetched.lock().unwrap().clone();
        for f in [
            "layer_xl_transparent_conv.safetensors",
            "vae_transparent_decoder.safetensors",
        ] {
            assert!(fetched.iter().any(|x| x == f), "{f} fetched: {fetched:?}");
        }
        let models = ok["outputs"][0]["provenance"]["models"].to_string();
        assert!(
            models.contains("layer_xl_transparent_conv")
                && models.contains("vae_transparent_decoder"),
            "{models}"
        );
        let e = bad.unwrap_err();
        assert!(
            e.starts_with("model_refused:") && e.contains("SDXL, Conv Injection"),
            "{e}"
        );
    }

    /// 1983-svid: a video output is returned like an image (kind video, its
    /// path and sidecar), and a run whose only output is a video succeeds
    /// WITH it. Pre-fix: FAILS, a workflow with no SaveImage was refused
    /// (invalid_workflow), and a video file failed the run as "not a PNG".
    #[test]
    fn a_video_output_is_returned_and_a_video_only_run_is_not_empty() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("svid-proj", "a");
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone());
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let run = |wf: &str| {
            call(
                "svid-proj",
                "a",
                &json!({"workflow":format!("tool/art/workflows/{wf}"),"inputs":{"pose":pose}}),
                &mut |_| {},
            )
        };
        let only = run("video_only.api.json");
        let mixed = run("mixed.api.json");
        install_seam(None);

        let only = only.unwrap_or_else(|e| panic!("video-only: {e}"));
        let outs = only["outputs"].as_array().unwrap();
        assert_eq!(outs.len(), 1, "{only}");
        assert_eq!(outs[0]["kind"], "video");
        let p = outs[0]["path"].as_str().unwrap();
        assert!(p.ends_with(".webm") && p.contains("/studio/"), "{p}");
        assert!(outs[0]["bytes"].as_u64().unwrap() > 0);
        assert!(outs[0]["provenance_path"].is_string());

        let mixed = mixed.unwrap_or_else(|e| panic!("mixed: {e}"));
        let kinds: Vec<&str> = mixed["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["kind"].as_str().unwrap())
            .collect();
        assert!(
            kinds.contains(&"image") && kinds.contains(&"video"),
            "{kinds:?}"
        );
    }

    /// An unexpected output type is named, never accepted or dropped.
    #[test]
    fn an_unexpected_output_type_fails_by_name() {
        assert!(matches!(output_kind("a.png", b"not a png"), Err(e) if e.contains("not a PNG")));
        assert!(matches!(output_kind("a.webm", b""), Err(e) if e.contains("empty")));
        assert!(
            matches!(output_kind("a.exr", b"x"), Err(e) if e.contains("unexpected output type (exr)"))
        );
        assert!(matches!(output_kind("a.mp4", b"x"), Ok(OutputKind::Video)));
    }

    /// An engine that reports a models dir and a fixed loader list.
    struct Picky {
        inner: Stub,
        dir: PathBuf,
        listed: Vec<String>,
    }
    impl StudioEngine for Picky {
        fn ensure_models(
            &self,
            f: &[ModelFile],
            p: &mut dyn FnMut(Progress),
        ) -> Result<(), String> {
            self.inner.ensure_models(f, p)
        }
        fn run(
            &self,
            prompt: &Value,
            out: &Path,
            p: &mut dyn FnMut(Progress),
        ) -> Result<RunOut, String> {
            self.inner.run(prompt, out, p)
        }
        fn free(&self) -> Result<(), String> {
            self.inner.free()
        }
        fn models_dir(&self) -> Option<PathBuf> {
            Some(self.dir.clone())
        }
        fn loader_options(&self, _c: &str, _i: &str) -> Option<Result<Vec<String>, String>> {
            Some(Ok(self.listed.clone()))
        }
    }

    /// ORDER 1986-snpx (kumbia): a pinned file that is not on disk, or that the
    /// studio's loader does not list, fails BEFORE anything queues, by name.
    /// Pre-fix: FAILS, the workflow reached ComfyUI ("<file> not in []").
    #[test]
    fn a_pinned_file_absent_or_unlisted_fails_before_queueing() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("snp2-pre", "a");
        let models = tempfile::tempdir_in(fx.scratch_root.parent().unwrap()).unwrap();
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let args = json!({"workflow":"tool/art/workflows/ok.api.json","inputs":{"pose":pose}});
        let row = imagegen_models::manifest()
            .into_iter()
            .find(|m| m.cache_name() == I1_CKPT)
            .unwrap();
        let go = |listed: Vec<String>| {
            let engine = Arc::new(Picky {
                inner: Stub::default(),
                dir: models.path().to_path_buf(),
                listed,
            });
            install(&fx, engine.clone());
            let r = call("snp2-pre", "a", &args, &mut |_| {});
            (r, engine.inner.runs.load(SeqCst))
        };
        // Not on disk: refused, nothing ran.
        let (r, runs) = go(vec![I1_CKPT.to_string()]);
        let e = r.unwrap_err();
        assert!(
            e.starts_with("model_missing:") && e.contains(I1_CKPT),
            "{e}"
        );
        assert_eq!(runs, 0);
        // On disk, but the loader does not list it: refused, nothing ran.
        std::fs::create_dir_all(models.path().join(&row.tier)).unwrap();
        std::fs::write(models.path().join(&row.tier).join(row.cache_name()), b"w").unwrap();
        let (r, runs) = go(vec!["something_else.safetensors".into()]);
        let e = r.unwrap_err();
        assert!(
            e.starts_with("model_not_visible:") && e.contains("something_else"),
            "{e}"
        );
        assert_eq!(runs, 0);
        // Both: it runs.
        let (r, runs) = go(vec![I1_CKPT.to_string()]);
        install_seam(None);
        r.unwrap_or_else(|e| panic!("{e}"));
        assert!(runs > 0);
    }

    /// ORDER 1986-snpx: studio.models lists pinned rows with their on-disk
    /// state, this tray's table, and what the studio's loaders list.
    #[test]
    fn studio_models_lists_pins_disk_state_and_loader_views() {
        let dir = tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let row = imagegen_models::manifest()
            .into_iter()
            .find(|m| m.cache_name() == I1_CKPT)
            .unwrap();
        std::fs::create_dir_all(dir.path().join(&row.tier)).unwrap();
        std::fs::write(dir.path().join(&row.tier).join(row.cache_name()), b"w").unwrap();
        let engine = Picky {
            inner: Stub::default(),
            dir: dir.path().to_path_buf(),
            listed: vec![I1_CKPT.into()],
        };
        let v = models_listing(dir.path(), Some(&engine));
        assert_eq!(v["models_tsv"], imagegen_models::manifest_digest());
        let rows = v["rows"].as_array().unwrap();
        let ckpt = rows
            .iter()
            .find(|r| r["file"] == I1_CKPT)
            .expect("the I1 checkpoint is listed");
        assert_eq!(ckpt["on_disk"], true);
        assert!(
            rows.iter().any(|r| r["on_disk"] == false),
            "absent files say so"
        );
        assert_eq!(v["comfyui"]["CheckpointLoaderSimple.ckpt_name"][0], I1_CKPT);
        // Without a running studio there is no loader view.
        assert!(models_listing(dir.path(), None)["comfyui"].is_null());
    }

    /// ORDER 1986-snpx: a refusal names this tray's build and table digest, so
    /// a stale tray does not read as a licence refusal.
    #[test]
    fn a_model_refusal_names_the_trays_table() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("snp2-note", "a");
        install(&fx, Arc::new(Stub::default()));
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let e = call(
            "snp2-note",
            "a",
            &json!({"workflow":"tool/art/workflows/unregistered.api.json","inputs":{"pose":pose}}),
            &mut |_| {},
        )
        .unwrap_err();
        install_seam(None);
        assert!(
            e.contains(&imagegen_models::manifest_digest()) && e.contains("tray rebuild"),
            "{e}"
        );
    }

    /// ORDER 1991-dovl: a node class added through the dev overlay is admitted
    /// on the NEXT call, no restart. Pre-fix: FAILS, the allowlist was only
    /// the compiled table.
    #[test]
    fn a_dev_overlay_node_class_takes_effect_on_the_next_call() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("dovl-node", "a");
        install(&fx, Arc::new(Stub::default()));
        let overlay = tempfile::tempdir_in(fx.scratch_root.parent().unwrap()).unwrap();
        crate::dev_overlay::set_test_dir(Some(overlay.path().to_path_buf()));
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let wf = fx
            .project
            .path()
            .join("tool/art/workflows/overlay.api.json");
        let mut w = serde_json::from_str::<Value>(&workflow(I1_CKPT, None)).unwrap();
        w["16"] = json!({"class_type":"MyNewCoreNode","inputs":{}});
        std::fs::write(&wf, w.to_string()).unwrap();
        let args = json!({"workflow":"tool/art/workflows/overlay.api.json","inputs":{"pose":pose}});
        let before = call("dovl-node", "a", &args, &mut |_| {});
        std::fs::write(
            overlay.path().join(crate::dev_overlay::NODE_CLASSES),
            "comfyui-core\tMyNewCoreNode\n",
        )
        .unwrap();
        let after = call("dovl-node", "a", &args, &mut |_| {});
        crate::dev_overlay::set_test_dir(None);
        install_seam(None);
        assert!(before.unwrap_err().starts_with("node_not_pinned:"));
        after.unwrap_or_else(|e| panic!("the overlay class was not admitted: {e}"));
    }

    /// ORDER 1991-dovl: an overlay can never admit a licence by itself: a
    /// model pinned only through the overlay is still refused, because the
    /// compiled-in licence register does not admit it.
    #[test]
    fn a_dev_overlay_model_pin_cannot_admit_its_own_licence() {
        let overlay =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        crate::dev_overlay::set_test_dir(Some(overlay.path().to_path_buf()));
        let sha = "c".repeat(64);
        std::fs::write(
            overlay.path().join(crate::dev_overlay::MODELS),
            format!("I1/sdxl-full\tstudio:checkpoint\tacme/overlay-only\t{}\toverlay_only.safetensors\t{sha}\t10\tapache-2.0\n", "a".repeat(40)),
        )
        .unwrap();
        let manifest = imagegen_models::manifest();
        let row = manifest
            .iter()
            .find(|m| m.cache_name() == "overlay_only.safetensors")
            .cloned();
        let admitted = row
            .as_ref()
            .map(|r| imagegen_models::register_admits(imagegen_models::register_tsv(), r));
        crate::dev_overlay::set_test_dir(None);
        let row = row.expect("the overlay pin is read");
        assert_eq!(row.tier, "I1/sdxl-full");
        assert!(
            admitted.unwrap().is_err(),
            "the register, not the overlay, admits a licence"
        );
    }

    /// 1972-stfx: BiRefNet_ll's loader names its weights in `model`; the
    /// pinned file is admitted and fetched before the run. Pre-fix: FAILS,
    /// `model` was not read, nothing was fetched, and ComfyUI refused it.
    #[test]
    fn the_birefnet_loader_model_is_checked_and_fetched() {
        let _g = SEAM_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let fx = fixture("stfx-rembg", "a");
        let engine = Arc::new(Stub::default());
        install(&fx, engine.clone());
        let pose = format!("{FORGE_SCRATCH}/in/gk/left_hand.png");
        let r = call(
            "stfx-rembg",
            "a",
            &json!({"workflow":"tool/art/workflows/rembg.api.json","inputs":{"pose":pose}}),
            &mut |_| {},
        );
        install_seam(None);
        r.expect("runs");
        assert!(
            engine
                .fetched
                .lock()
                .unwrap()
                .iter()
                .any(|f| f == "model.safetensors"),
            "{:?}",
            engine.fetched.lock().unwrap()
        );
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
                    "count":2,"tier":"I1","verbose":true}),
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

    /// 1959-xsy5 (D11): run_workflow binds init_image / mask / layout_mask to
    /// LoadImage nodes whose image is "$<name>", strength to the sampler
    /// titled $strength (denoise; start_at_step for KSamplerAdvanced), and a
    /// workflow that lacks the node is refused workflow_has_no_input:<name>
    /// before anything queues.
    #[test]
    fn imagegen_init_mask_run_workflow_binds_d11_keys_or_names_the_missing_input() {
        let fx = fixture("xsy5-wf", "a");
        std::fs::write(fx.lane_dir.join("in/gk/init.png"), b"\x89PNG init").unwrap();
        std::fs::write(fx.lane_dir.join("in/gk/mask.png"), b"\x89PNG mask").unwrap();
        let mut w: Value = serde_json::from_str(&workflow(I1_CKPT, None)).unwrap();
        w["11"] = json!({"class_type":"LoadImage","inputs":{"image":"$init_image"}});
        w["12"] = json!({"class_type":"LoadImage","inputs":{"image":"$mask"}});
        w["5"]["_meta"]["title"] = json!("$strength");
        let with_nodes = serde_json::to_string(&w).unwrap();
        let args = json!({
            "workflow":"tool/art/workflows/ok.api.json",
            "inputs":{"pose":format!("{FORGE_SCRATCH}/in/gk/left_hand.png")},
            "init_image": format!("{FORGE_SCRATCH}/in/gk/init.png"),
            "mask": format!("{FORGE_SCRATCH}/in/gk/mask.png"),
            "strength": 0.55,
        });
        let req = parse_request(&args).unwrap();
        assert_eq!(req.d11_keys, ["init_image", "mask"]);
        let run = |wf: &str| {
            validate(
                &req,
                wf,
                &Allowlist::shipped(),
                &crate::imagegen_models::manifest(),
                crate::imagegen_models::register_tsv(),
                &fx.lane_dir,
            )
        };
        let plan = run(&with_nodes).unwrap_or_else(|e| panic!("{e}"));
        let p = prompt_for(&plan, "st-1", 0);
        assert!(
            p["11"]["inputs"]["image"]
                .as_str()
                .unwrap()
                .contains("in/gk/init.png")
        );
        assert!(
            p["12"]["inputs"]["image"]
                .as_str()
                .unwrap()
                .contains("in/gk/mask.png")
        );
        assert_eq!(
            p["5"]["inputs"]["denoise"]
                .as_f64()
                .map(|d| (d * 100.0).round()),
            Some(55.0)
        );

        // The plain fixture workflow opens none of these knobs.
        let err = run(&workflow(I1_CKPT, None)).unwrap_err();
        assert!(
            err.starts_with("workflow_has_no_input:init_image:"),
            "{err}"
        );
        let only_strength = parse_request(&json!({
            "workflow":"tool/art/workflows/ok.api.json",
            "inputs":{"pose":format!("{FORGE_SCRATCH}/in/gk/left_hand.png")},
            "strength": 0.3,
        }))
        .unwrap();
        let err = validate(
            &only_strength,
            &workflow(I1_CKPT, None),
            &Allowlist::shipped(),
            &crate::imagegen_models::manifest(),
            crate::imagegen_models::register_tsv(),
            &fx.lane_dir,
        )
        .unwrap_err();
        assert!(err.starts_with("workflow_has_no_input:strength:"), "{err}");

        // KSamplerAdvanced has no denoise: strength 0.55 of 4 steps starts at
        // round(4 * 0.45) = 2.
        let mut adv = w.clone();
        adv["5"]["class_type"] = json!("KSamplerAdvanced");
        let plan = run(&serde_json::to_string(&adv).unwrap()).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            prompt_for(&plan, "st-1", 0)["5"]["inputs"]["start_at_step"],
            2
        );

        // The same key both ways is refused.
        let both = json!({ "workflow":"tool/art/workflows/ok.api.json",
            "inputs":{"init_image":format!("{FORGE_SCRATCH}/in/gk/init.png")},
            "init_image": format!("{FORGE_SCRATCH}/in/gk/init.png") });
        assert!(
            parse_request(&both)
                .unwrap_err()
                .contains("both as a key and in inputs")
        );
        assert!(parse_request(&json!({"workflow":"w.json","strength":2})).is_err());
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
                    timings: Default::default(),
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
            present: None,
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
