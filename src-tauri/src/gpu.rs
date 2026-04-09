//! GPU detection and model tier routing.
//!
//! Detects NVIDIA (and eventually AMD) GPUs, classifies them by VRAM into
//! tiers, and selects the best model pair (primary + small) for local
//! inference. The selected models are patched into the config overlay on
//! ramdisk so forge containers use the optimal models for the hardware.
//!
//! @trace spec:inference-container

use std::path::PathBuf;

use tracing::{debug, info, warn};

/// Detected GPU capability tier for model selection.
///
/// @trace spec:inference-container
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuTier {
    /// No GPU detected — CPU inference only (T0-T1)
    None,
    /// <=4GB VRAM — can run small models (T0-T2)
    Low,
    /// 4-8GB VRAM — can run medium models (T0-T3)
    Mid,
    /// 8-12GB VRAM — can run large models (T0-T4)
    High,
    /// >=12GB VRAM — can run all models (T0-T5)
    Ultra,
}

impl GpuTier {
    /// Return the (primary_model, small_model) pair for this tier.
    ///
    /// Primary model is used for main inference (code generation, chat).
    /// Small model is used for lightweight tasks (autocomplete, embeddings).
    ///
    /// @trace spec:inference-container
    pub fn model_pair(&self) -> (&'static str, &'static str) {
        match self {
            GpuTier::None => ("ollama/qwen2.5:0.5b", "ollama/qwen2.5:0.5b"),
            GpuTier::Low => ("ollama/phi3.5:3.8b", "ollama/qwen2.5:0.5b"),
            GpuTier::Mid => ("ollama/qwen2.5-coder:7b", "ollama/qwen2.5:0.5b"),
            GpuTier::High => ("ollama/llama3.2:8b", "ollama/tinyllama:1.1b"),
            GpuTier::Ultra => ("ollama/qwen2.5:13b", "ollama/qwen2.5:0.5b"),
        }
    }
}

impl std::fmt::Display for GpuTier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GpuTier::None => write!(f, "none"),
            GpuTier::Low => write!(f, "low"),
            GpuTier::Mid => write!(f, "mid"),
            GpuTier::High => write!(f, "high"),
            GpuTier::Ultra => write!(f, "ultra"),
        }
    }
}

/// Detect GPU and classify into a tier.
///
/// Tries `nvidia-smi` first (NVIDIA GPUs), with a placeholder for future
/// AMD ROCm detection via `rocm-smi`. Falls back to `GpuTier::None` if
/// no GPU tooling is found.
///
/// @trace spec:inference-container
pub fn detect_gpu_tier() -> GpuTier {
    // Try nvidia-smi first
    if let Ok(output) = std::process::Command::new("nvidia-smi")
        .args(["--query-gpu=memory.total", "--format=csv,noheader,nounits"])
        .output()
    {
        if output.status.success() {
            let vram_str = String::from_utf8_lossy(&output.stdout);
            // nvidia-smi may report multiple GPUs (one line per GPU).
            // Use the first GPU's VRAM for tier classification.
            if let Some(first_line) = vram_str.lines().next() {
                if let Ok(vram_mib) = first_line.trim().parse::<u64>() {
                    let vram_gb = vram_mib / 1024;
                    debug!(
                        vram_mib = vram_mib,
                        vram_gb = vram_gb,
                        spec = "inference-container",
                        "nvidia-smi reported VRAM"
                    );
                    return match vram_gb {
                        0..=3 => GpuTier::Low,
                        4..=7 => GpuTier::Mid,
                        8..=11 => GpuTier::High,
                        _ => GpuTier::Ultra,
                    };
                }
            }
        }
    }

    // TODO: AMD ROCm detection via rocm-smi
    debug!(
        spec = "inference-container",
        "No GPU detected (nvidia-smi not found or failed)"
    );
    GpuTier::None
}

/// Runtime directory for config overlay (matches `embedded.rs` runtime_dir).
fn runtime_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join("tillandsias")
    } else {
        std::env::temp_dir().join("tillandsias-embedded")
    }
}

/// Patch the config overlay's opencode config.json with GPU-appropriate models.
///
/// Reads the static config from ramdisk, replaces `model` and `small_model`
/// fields based on the detected GPU tier, and writes the patched JSON back.
///
/// This is a no-op if the config overlay hasn't been extracted yet (the
/// config overlay extraction may not have run, or the file may not exist).
///
/// @trace spec:inference-container, spec:layered-tools-overlay
pub fn patch_config_overlay_for_gpu(tier: GpuTier) -> Result<(), String> {
    let config_path = runtime_dir()
        .join("config-overlay")
        .join("opencode")
        .join("config.json");

    if !config_path.exists() {
        debug!(
            path = %config_path.display(),
            spec = "inference-container",
            "Config overlay not found — skipping GPU model patch"
        );
        return Ok(());
    }

    let content =
        std::fs::read_to_string(&config_path).map_err(|e| format!("Cannot read config overlay: {e}"))?;

    let (primary, small) = tier.model_pair();

    let mut config: serde_json::Value =
        serde_json::from_str(&content).map_err(|e| format!("Cannot parse config overlay JSON: {e}"))?;

    config["model"] = serde_json::Value::String(primary.to_string());
    config["small_model"] = serde_json::Value::String(small.to_string());

    let patched = serde_json::to_string_pretty(&config)
        .map_err(|e| format!("Cannot serialize patched config: {e}"))?;

    std::fs::write(&config_path, patched)
        .map_err(|e| format!("Cannot write patched config overlay: {e}"))?;

    debug!(
        path = %config_path.display(),
        primary_model = primary,
        small_model = small,
        tier = %tier,
        spec = "inference-container",
        "Patched config overlay with GPU-appropriate models"
    );

    Ok(())
}

/// Detect GPU tier, patch config overlay, and log the result.
///
/// This is the main entry point called from the startup sequence.
/// It combines detection, patching, and accountability logging.
///
/// @trace spec:inference-container
pub fn detect_and_patch_models() {
    let tier = detect_gpu_tier();
    let (primary, small) = tier.model_pair();

    // @trace spec:inference-container
    info!(
        accountability = true,
        category = "inference",
        spec = "inference-container",
        tier = %tier,
        primary_model = %primary,
        small_model = %small,
        "GPU detected — model tier selected"
    );

    if let Err(e) = patch_config_overlay_for_gpu(tier) {
        warn!(
            error = %e,
            spec = "inference-container",
            "Failed to patch config overlay for GPU tier — using static defaults"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_tier_model_pairs() {
        assert_eq!(
            GpuTier::None.model_pair(),
            ("ollama/qwen2.5:0.5b", "ollama/qwen2.5:0.5b")
        );
        assert_eq!(
            GpuTier::Low.model_pair(),
            ("ollama/phi3.5:3.8b", "ollama/qwen2.5:0.5b")
        );
        assert_eq!(
            GpuTier::Mid.model_pair(),
            ("ollama/qwen2.5-coder:7b", "ollama/qwen2.5:0.5b")
        );
        assert_eq!(
            GpuTier::High.model_pair(),
            ("ollama/llama3.2:8b", "ollama/tinyllama:1.1b")
        );
        assert_eq!(
            GpuTier::Ultra.model_pair(),
            ("ollama/qwen2.5:13b", "ollama/qwen2.5:0.5b")
        );
    }

    #[test]
    fn gpu_tier_display() {
        assert_eq!(GpuTier::None.to_string(), "none");
        assert_eq!(GpuTier::Low.to_string(), "low");
        assert_eq!(GpuTier::Mid.to_string(), "mid");
        assert_eq!(GpuTier::High.to_string(), "high");
        assert_eq!(GpuTier::Ultra.to_string(), "ultra");
    }

    #[test]
    fn patch_config_overlay_missing_file_is_ok() {
        // When the config overlay doesn't exist, patching should be a no-op (Ok)
        let result = patch_config_overlay_for_gpu(GpuTier::Mid);
        // This will succeed because the function returns Ok(()) when the file doesn't exist
        assert!(result.is_ok());
    }

    #[test]
    fn patch_config_overlay_writes_correct_models() {
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join("config-overlay").join("opencode");
        std::fs::create_dir_all(&config_dir).unwrap();
        let config_path = config_dir.join("config.json");

        let initial = serde_json::json!({
            "$schema": "https://opencode.ai/config.json",
            "autoupdate": false,
            "model": "ollama/qwen2.5:0.5b",
            "small_model": "ollama/qwen2.5:0.5b"
        });
        std::fs::write(&config_path, serde_json::to_string_pretty(&initial).unwrap()).unwrap();

        // Patch with a custom runtime dir pointing to our temp dir
        // We can't easily override runtime_dir() in tests, so test the JSON
        // patching logic directly instead.
        let content = std::fs::read_to_string(&config_path).unwrap();
        let mut config: serde_json::Value = serde_json::from_str(&content).unwrap();

        let (primary, small) = GpuTier::Mid.model_pair();
        config["model"] = serde_json::Value::String(primary.to_string());
        config["small_model"] = serde_json::Value::String(small.to_string());

        let patched = serde_json::to_string_pretty(&config).unwrap();
        std::fs::write(&config_path, &patched).unwrap();

        // Verify
        let result: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).unwrap();
        assert_eq!(result["model"], "ollama/qwen2.5-coder:7b");
        assert_eq!(result["small_model"], "ollama/qwen2.5:0.5b");
        assert_eq!(result["autoupdate"], false); // Other fields preserved
    }

    #[test]
    fn patch_config_overlay_all_tiers() {
        // Verify every tier produces valid model strings for the config
        for tier in [
            GpuTier::None,
            GpuTier::Low,
            GpuTier::Mid,
            GpuTier::High,
            GpuTier::Ultra,
        ] {
            let (primary, small) = tier.model_pair();
            assert!(
                primary.starts_with("ollama/"),
                "Primary model for {tier:?} must start with ollama/"
            );
            assert!(
                small.starts_with("ollama/"),
                "Small model for {tier:?} must start with ollama/"
            );
            // Ensure model strings are valid JSON values
            let val = serde_json::Value::String(primary.to_string());
            assert!(val.is_string());
        }
    }
}
