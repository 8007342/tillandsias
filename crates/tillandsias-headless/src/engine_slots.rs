// @trace spec:inference-engine-slots
//! Engine slot abstraction and backend pinning per spec:inference-engine-slots.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
// @trace spec:inference-engine-slots
pub enum EngineKind {
    Ollama,
    LlamaServer,
    HostNativeSidecar,
}

impl EngineKind {
    // @trace spec:inference-engine-slots
    pub fn as_str(&self) -> &'static str {
        match self {
            EngineKind::Ollama => "ollama",
            EngineKind::LlamaServer => "llama-server",
            EngineKind::HostNativeSidecar => "host-native-sidecar",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
// @trace spec:inference-engine-slots
pub struct EngineSlotDescriptor {
    pub slot_id: String,
    pub engine_kind: EngineKind,
    pub bound_device_class: String,
    pub lane: String, // "container" | "host-native"
    pub endpoint_url: String,
    pub readiness_url: String,
}

// @trace spec:inference-engine-slots
pub fn default_engine_kind() -> EngineKind {
    // SLOT-3: Ollama MUST remain the default engine until llama-server lane records smoke evidence
    EngineKind::Ollama
}

// @trace spec:inference-engine-slots
pub fn validate_slot_registration(
    engine_kind: EngineKind,
    device_class: &str,
    usable: bool,
) -> Result<(), String> {
    if !usable {
        return Err(format!(
            "refused slot registration: device class '{}' is unusable",
            device_class
        ));
    }
    // SLOT-3: An NPU lane MUST NOT be added to the ollama engine kind
    if engine_kind == EngineKind::Ollama && device_class.eq_ignore_ascii_case("npu") {
        return Err("refused slot registration: NPU backends are prohibited on the ollama engine kind (SLOT-3)".to_string());
    }
    Ok(())
}

/// Parse the CUDA UMD major from `nvidia-smi -q`. The driver is backward
/// compatible, so an unparseable version deterministically selects cuda_v12
/// rather than leaving both shipped CUDA runners eligible.
// @trace spec:inference-engine-slots
pub fn parse_cuda_major(nvidia_smi_query: &str) -> Option<u32> {
    nvidia_smi_query.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        if !matches!(key.trim(), "CUDA UMD Version" | "CUDA Version") {
            return None;
        }
        value
            .split(|character: char| !character.is_ascii_digit())
            .find(|part| !part.is_empty())
            .and_then(|major| major.parse().ok())
    })
}

// @trace spec:inference-engine-slots
pub fn pin_backend_environment(
    effective_tier: &str,
    cuda_major: Option<u32>,
) -> Vec<(String, String)> {
    let mut envs = Vec::new();
    // SLOT-4 & Determinism: OLLAMA_VULKAN defaults to TRUE, so when vulkan and a cuda dir are present,
    // explicitly pin the backend variables to ensure deterministic execution.
    match effective_tier {
        "gpu-cuda" => {
            envs.push(("OLLAMA_VULKAN".to_string(), "0".to_string()));
            let library = if cuda_major.is_some_and(|major| major >= 13) {
                "cuda_v13"
            } else {
                // NVIDIA drivers are backward compatible. cuda_v12 is the
                // deterministic safe fallback when nvidia-smi cannot report
                // the UMD major and the payload carries both CUDA runners.
                "cuda_v12"
            };
            envs.push(("OLLAMA_LLM_LIBRARY".to_string(), library.to_string()));
        }
        "vulkan" | "gpu-vulkan" | "gpu-rocm" => {
            envs.push(("OLLAMA_VULKAN".to_string(), "1".to_string()));
            envs.push(("OLLAMA_LLM_LIBRARY".to_string(), "vulkan".to_string()));
            // ORDER 793-a8e7: the WSL2 opt-in lane's device is ALWAYS integrated
            // (Dozen over /dev/dxg), and ollama drops integrated GPUs unless told
            // otherwise. Measured on yolanda 2026-10-12, ollama v0.34.0 with the
            // vulkan backend installed: "dropping integrated GPU; to enable, set
            // OLLAMA_IGPU_ENABLE=1 ... Microsoft Direct3D12 (AMD Radeon(TM) 860M
            // Graphics)", then `inference compute id=cpu`. With it set: library=
            // Vulkan type=iGPU, and qwen2.5:0.5b fully resident in VRAM. Scoped
            // to the opt-in tier: the other vulkan tiers keep their behaviour.
            if effective_tier == "gpu-vulkan" {
                envs.push(("OLLAMA_IGPU_ENABLE".to_string(), "1".to_string()));
                // ORDER 1648-gy9z (793-a8e7 S4): bound a stalled MODEL LOAD on
                // the opt-in lane (ollama's default is 5m). Cold loads measured
                // 3-8 s on yolanda 2026-10-12. A stall AFTER the load is the
                // in-container gpu-stall watchdog's job.
                envs.push(("OLLAMA_LOAD_TIMEOUT".to_string(), "2m".to_string()));
            }
        }
        _ => {}
    }
    envs
}

/// Order 482b: the engine the operator selected with TILLANDSIAS_INFERENCE_ENGINE.
/// Unset is the default (SLOT-3: ollama). A value that names no container engine
/// falls back to the default WITH the reason, never to a guess.
// @trace spec:inference-engine-slots
pub fn selected_engine_kind(requested: Option<&str>) -> (EngineKind, Option<String>) {
    match requested.map(str::trim) {
        None | Some("") => (default_engine_kind(), None),
        Some("ollama") => (EngineKind::Ollama, None),
        Some("llama-server") => (EngineKind::LlamaServer, None),
        Some(other) => (
            default_engine_kind(),
            Some(format!(
                "TILLANDSIAS_INFERENCE_ENGINE='{other}' names no container engine (ollama | llama-server); using {}",
                default_engine_kind().as_str()
            )),
        ),
    }
}

/// Order 482b (SLOT-4/SLOT-5): render nodes under `dri` that THIS user can open
/// read-write, sorted. A node that exists but is not accessible is skipped and
/// named in the second list, never chmod-ed or escalated (SLOT-5).
// @trace spec:inference-engine-slots
pub fn usable_render_nodes(
    dri: &std::path::Path,
) -> (Vec<std::path::PathBuf>, Vec<std::path::PathBuf>) {
    let mut usable = Vec::new();
    let mut unusable = Vec::new();
    let Ok(entries) = std::fs::read_dir(dri) else {
        return (usable, unusable);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let is_render = path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("renderD"));
        if !is_render {
            continue;
        }
        if read_write_accessible(&path) {
            usable.push(path);
        } else {
            unusable.push(path);
        }
    }
    usable.sort();
    unusable.sort();
    (usable, unusable)
}

#[cfg(unix)]
fn read_write_accessible(path: &std::path::Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(c_path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: access(2) reads a NUL-terminated path and touches nothing else.
    unsafe { libc::access(c_path.as_ptr(), libc::R_OK | libc::W_OK) == 0 }
}

#[cfg(not(unix))]
fn read_write_accessible(_path: &std::path::Path) -> bool {
    false
}

/// Order 482b: the inference run args the llama-server slot adds. Pure, so the
/// selection is testable without a host. `engine` and `backend` are the raw
/// operator env values; `tier` is the EFFECTIVE tier; `usable` are the render
/// nodes this user can open. The container makes the final, exactly-one backend
/// choice (llama-server-lane.sh); the launcher only delivers what is usable.
// @trace spec:inference-engine-slots
pub fn llama_server_run_args(
    engine: EngineKind,
    backend: Option<&str>,
    tier: &str,
    usable: &[std::path::PathBuf],
) -> Vec<String> {
    let mut args = vec![
        "--env".to_string(),
        format!("TILLANDSIAS_INFERENCE_ENGINE={}", engine.as_str()),
    ];
    if engine != EngineKind::LlamaServer {
        return args;
    }
    if let Some(backend) =
        backend.filter(|b| matches!(*b, "auto" | "vulkan" | "cpu" | "cuda" | "rocm"))
    {
        args.extend([
            "--env".to_string(),
            format!("TILLANDSIAS_INFERENCE_LLAMA_BACKEND={backend}"),
        ]);
    }
    // gpu-rocm already delivers the whole /dev/dri (order 392); never twice.
    if tier != "gpu-rocm" && !usable.is_empty() {
        for node in usable {
            args.extend(["--device".to_string(), node.display().to_string()]);
        }
        // A 0660 root:render node is usable on the host only through the user's
        // render group; keep it inside the user namespace instead of chmod-ing.
        args.extend(["--group-add".to_string(), "keep-groups".to_string()]);
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    // @trace spec:inference-engine-slots
    fn test_engine_selection_defaults_to_ollama_and_names_a_bad_value() {
        assert_eq!(selected_engine_kind(None), (EngineKind::Ollama, None));
        assert_eq!(selected_engine_kind(Some("")), (EngineKind::Ollama, None));
        assert_eq!(
            selected_engine_kind(Some("llama-server")),
            (EngineKind::LlamaServer, None)
        );
        let (kind, why) = selected_engine_kind(Some("vllm"));
        assert_eq!(kind, EngineKind::Ollama);
        assert!(why.unwrap().contains("'vllm' names no container engine"));
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_llama_server_run_args_deliver_usable_render_nodes_only() {
        let nodes = vec![std::path::PathBuf::from("/dev/dri/renderD128")];
        // ollama: the engine is named and nothing else changes.
        assert_eq!(
            llama_server_run_args(EngineKind::Ollama, Some("vulkan"), "gpu-cuda", &nodes),
            vec!["--env", "TILLANDSIAS_INFERENCE_ENGINE=ollama"]
        );
        // llama-server on a CUDA-tier host still gets the iGPU's render node:
        // the vulkan lane needs no vendor stack (SLOT-4).
        let args = llama_server_run_args(EngineKind::LlamaServer, None, "gpu-cuda", &nodes);
        assert_eq!(
            args,
            vec![
                "--env",
                "TILLANDSIAS_INFERENCE_ENGINE=llama-server",
                "--device",
                "/dev/dri/renderD128",
                "--group-add",
                "keep-groups",
            ]
        );
        // No usable node: CPU lane, no device args, launch proceeds (SLOT-4).
        assert_eq!(
            llama_server_run_args(EngineKind::LlamaServer, Some("cpu"), "cpu", &[]),
            vec![
                "--env",
                "TILLANDSIAS_INFERENCE_ENGINE=llama-server",
                "--env",
                "TILLANDSIAS_INFERENCE_LLAMA_BACKEND=cpu",
            ]
        );
        // gpu-rocm already passes /dev/dri; an unknown backend request is dropped.
        let rocm =
            llama_server_run_args(EngineKind::LlamaServer, Some("metal"), "gpu-rocm", &nodes);
        assert!(
            !rocm
                .iter()
                .any(|a| a == "--device" || a.contains("LLAMA_BACKEND"))
        );
    }

    #[cfg(unix)]
    #[test]
    // @trace spec:inference-engine-slots
    fn test_usable_render_nodes_skip_inaccessible_and_non_render_nodes() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let open = dir.path().join("renderD128");
        let locked = dir.path().join("renderD129");
        let card = dir.path().join("card0");
        for p in [&open, &locked, &card] {
            std::fs::write(p, b"").unwrap();
        }
        std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o666)).unwrap();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        let (usable, unusable) = usable_render_nodes(dir.path());
        if unsafe { libc::geteuid() } == 0 {
            // root bypasses mode bits; only the card0 exclusion is meaningful.
            assert!(!usable.contains(&card));
            return;
        }
        assert_eq!(usable, vec![open]);
        assert_eq!(unusable, vec![locked]);
        assert_eq!(
            usable_render_nodes(&dir.path().join("absent")),
            (vec![], vec![])
        );
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_default_engine_is_ollama() {
        assert_eq!(default_engine_kind(), EngineKind::Ollama);
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_npu_refused_on_ollama() {
        let res = validate_slot_registration(EngineKind::Ollama, "npu", true);
        assert!(res.is_err());
        assert!(res.unwrap_err().contains("NPU backends are prohibited"));
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_npu_allowed_on_llama_server() {
        let res = validate_slot_registration(EngineKind::LlamaServer, "npu", true);
        assert!(res.is_ok());
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_unusable_device_refused() {
        let res = validate_slot_registration(EngineKind::LlamaServer, "gpu", false);
        assert!(res.is_err());
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_backend_env_pinning() {
        let cuda_env = pin_backend_environment("gpu-cuda", Some(13));
        assert!(cuda_env.contains(&("OLLAMA_VULKAN".to_string(), "0".to_string())));
        assert!(cuda_env.contains(&("OLLAMA_LLM_LIBRARY".to_string(), "cuda_v13".to_string())));
        let cuda_12_env = pin_backend_environment("gpu-cuda", Some(12));
        assert!(cuda_12_env.contains(&("OLLAMA_LLM_LIBRARY".to_string(), "cuda_v12".to_string())));
        let unknown_cuda_env = pin_backend_environment("gpu-cuda", None);
        assert!(
            unknown_cuda_env.contains(&("OLLAMA_LLM_LIBRARY".to_string(), "cuda_v12".to_string()))
        );
        let vulkan_env = pin_backend_environment("vulkan", None);
        assert!(vulkan_env.contains(&("OLLAMA_VULKAN".to_string(), "1".to_string())));
        assert!(vulkan_env.contains(&("OLLAMA_LLM_LIBRARY".to_string(), "vulkan".to_string())));
        // 793-a8e7: only the WSL2 opt-in tier enables integrated GPUs.
        let igpu = ("OLLAMA_IGPU_ENABLE".to_string(), "1".to_string());
        assert!(pin_backend_environment("gpu-vulkan", None).contains(&igpu));
        // 1648-gy9z: and only it bounds a stalled load.
        let load = ("OLLAMA_LOAD_TIMEOUT".to_string(), "2m".to_string());
        assert!(pin_backend_environment("gpu-vulkan", None).contains(&load));
        for tier in ["vulkan", "gpu-rocm", "gpu-cuda", "cpu"] {
            assert!(
                !pin_backend_environment(tier, None).contains(&load),
                "{tier}"
            );
        }
        for tier in ["vulkan", "gpu-rocm", "gpu-cuda", "cpu"] {
            assert!(
                !pin_backend_environment(tier, None).contains(&igpu),
                "{tier}"
            );
        }
    }

    #[test]
    // @trace spec:inference-engine-slots
    fn test_cuda_major_parser() {
        assert_eq!(
            parse_cuda_major("CUDA UMD Version                  : 13.3\n"),
            Some(13)
        );
        assert_eq!(
            parse_cuda_major("CUDA Version                      : 12.8\n"),
            Some(12)
        );
        assert_eq!(parse_cuda_major("CUDA Version : N/A\n"), None);
    }
}
