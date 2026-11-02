//! Provenance v1: one record per generated output (studio-asset-pipeline
//! design D5). `image.generate` (engine sd.cpp) and `studio.run_workflow`
//! (engine comfyui) write the same schema, `<output>.provenance.json`
//! beside each file, and return the same object in the result.
//! @trace order:1956-x7xp (spec: openspec/changes/studio-asset-pipeline, not yet archived)
#![cfg_attr(not(test), allow(dead_code))]

use std::path::Path;

use serde_json::{Value, json};

use crate::imagegen_models::ModelFile;

pub const SCHEMA: &str = "tillandsias.provenance/v1";

/// The studio's ComfyUI pin. A test keeps these equal to the Containerfile's
/// `ARG COMFYUI_REF` / `ARG COMFYUI_SHA` (images/imagegen-studio/Containerfile).
pub const COMFYUI_REF: &str = "v0.40.0";
pub const COMFYUI_SHA: &str = "3541246a9c997f4b8c32f9f88f3c985d02021c79";

/// The sd.cpp pin, `ARG SDCPP_TAG` in images/imagegen/Containerfile.
pub const SDCPP_TAG: &str = "master-1015-e41fbcf";

/// Which engine drew the output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Engine {
    /// sd.cpp at its Containerfile tag.
    SdCpp,
    /// ComfyUI at the pinned ref, with the custom-node packages (name, commit).
    ComfyUi { nodes: Vec<(String, String)> },
}

impl Engine {
    fn to_json(&self) -> Value {
        match self {
            Engine::SdCpp => {
                json!({ "name": "sd.cpp", "ref": SDCPP_TAG, "sha": null, "nodes": [] })
            }
            Engine::ComfyUi { nodes } => json!({
                "name": "comfyui", "ref": COMFYUI_REF, "sha": COMFYUI_SHA,
                "nodes": nodes.iter().map(|(n, c)| json!({ "name": n, "commit": c })).collect::<Vec<_>>(),
            }),
        }
    }
}

/// One named input file and its digest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Input {
    pub name: String,
    /// The path as the forge sees it.
    pub path: String,
    pub sha256: String,
}

/// Everything a record carries besides the output itself.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub engine: Engine,
    /// `(path, sha256)` of the workflow; `None` for sd.cpp.
    pub workflow: Option<(String, String)>,
    pub models: Vec<ModelFile>,
    pub inputs: Vec<Input>,
    pub seed: u64,
    pub prompt: String,
    pub negative_prompt: String,
    pub tier: Option<String>,
    /// `cuda`, `cpu`, `vulkan`, `mixed`, ...
    pub placement: String,
    /// `(path, sha256)` of the family spec, when one was given.
    pub family: Option<(String, String)>,
}

impl Record {
    pub fn to_json(&self) -> Value {
        json!({
            "schema": SCHEMA,
            "pipelineVersion": crate::VERSION.trim(),
            "engine": self.engine.to_json(),
            "workflow": self.workflow.as_ref().map(|(p, s)| json!({ "path": p, "sha256": s })),
            "models": self.models.iter().map(|m| json!({
                "file": m.cache_name(), "repo": m.repo, "revision": m.revision,
                "sha256": m.sha256, "licence": m.licence, "consent": null,
            })).collect::<Vec<_>>(),
            "inputs": self.inputs.iter().map(|i| json!({
                "name": i.name, "path": i.path, "sha256": i.sha256,
            })).collect::<Vec<_>>(),
            "seed": self.seed,
            "prompt": self.prompt,
            "negative_prompt": self.negative_prompt,
            "tier": self.tier,
            "placement": self.placement,
            "family": self.family.as_ref().map(|(p, s)| json!({
                "path": p, "sha256": s, "contract": "1935-k2ib/v1",
            })),
        })
    }

    /// Write `<output>.provenance.json` beside `output` (a host path) and
    /// return the record. The sidecar's name keeps the output's extension:
    /// `0000.png` → `0000.png.provenance.json`.
    pub fn write_beside(&self, output: &Path) -> Result<Value, String> {
        let v = self.to_json();
        let side = sidecar_path(output);
        std::fs::write(&side, serde_json::to_vec_pretty(&v).unwrap_or_default())
            .map_err(|e| format!("engine_failed: {}: {e}", side.display()))?;
        Ok(v)
    }
}

/// `<output>.provenance.json`.
pub fn sidecar_path(output: &Path) -> std::path::PathBuf {
    let mut name = output
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".provenance.json");
    output.with_file_name(name)
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}

pub fn sha256_file(path: &Path) -> Result<String, String> {
    std::fs::read(path)
        .map(|b| sha256_hex(&b))
        .map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn containerfile_arg(rel: &str, arg: &str) -> String {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let text = std::fs::read_to_string(root.join(rel)).unwrap();
        text.lines()
            .find_map(|l| l.trim().strip_prefix(&format!("ARG {arg}=")))
            .unwrap_or_else(|| panic!("{rel} has no ARG {arg}"))
            .trim()
            .to_string()
    }

    /// D5: the engine pins in the record are the Containerfiles' pins.
    #[test]
    fn provenance_engine_pins_match_the_containerfiles() {
        assert_eq!(
            containerfile_arg("images/imagegen-studio/Containerfile", "COMFYUI_SHA"),
            COMFYUI_SHA
        );
        assert_eq!(
            containerfile_arg("images/imagegen-studio/Containerfile", "COMFYUI_REF"),
            COMFYUI_REF
        );
        assert_eq!(
            containerfile_arg("images/imagegen/Containerfile", "SDCPP_TAG"),
            SDCPP_TAG
        );
    }

    #[test]
    fn a_record_is_written_beside_its_output_with_the_crate_version() {
        let dir = tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let out = dir.path().join("0000.png");
        std::fs::write(&out, b"png").unwrap();
        let rec = Record {
            engine: Engine::SdCpp,
            workflow: None,
            models: vec![],
            inputs: vec![],
            seed: 7,
            prompt: "a fox".into(),
            negative_prompt: String::new(),
            tier: Some("I0".into()),
            placement: "cuda".into(),
            family: None,
        };
        let v = rec.write_beside(&out).unwrap();
        assert_eq!(v["schema"], SCHEMA);
        assert_eq!(v["pipelineVersion"], crate::VERSION.trim());
        assert_eq!(v["engine"]["name"], "sd.cpp");
        assert_eq!(v["engine"]["ref"], SDCPP_TAG);
        let side = dir.path().join("0000.png.provenance.json");
        let on_disk: Value = serde_json::from_slice(&std::fs::read(side).unwrap()).unwrap();
        assert_eq!(on_disk, v);
    }
}
