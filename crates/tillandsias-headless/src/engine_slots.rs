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
        }
        _ => {}
    }
    envs
}

#[cfg(test)]
mod tests {
    use super::*;

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
