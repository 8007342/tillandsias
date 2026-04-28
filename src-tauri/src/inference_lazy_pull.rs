//! Host-side lazy model pulling for the inference container.
//!
//! After the inference container reports ready, this module spawns a background task
//! that detects the available VRAM tier and automatically pulls higher-tier LLM models.
//! Downloads bypass the proxy and land in `~/.cache/tillandsias/models/`, which the
//! inference container bind-mounts and reads via `ollama /api/tags`.
//!
//! @trace spec:inference-host-side-pull

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;

use tracing::{debug, info, warn};

use crate::gpu::GpuTier;

/// Model tier mappings: GPU tier -> list of models to lazy-pull.
/// T0/T1 are baked into the inference image; T2-T5 are pulled host-side.
///
/// @trace spec:inference-host-side-pull
fn model_tier_map() -> HashMap<GpuTier, Vec<&'static str>> {
    let mut map = HashMap::new();
    // T0/T1 baked in image — no pull needed
    map.insert(GpuTier::None, vec![]);
    map.insert(GpuTier::Low, vec![]);

    // T2-T5 models pulled for higher-tier GPUs
    map.insert(GpuTier::Mid, vec!["qwen2.5-coder:7b"]);
    map.insert(GpuTier::High, vec!["qwen2.5-coder:7b", "qwen2.5-coder:14b"]);
    map.insert(GpuTier::Ultra, vec![
        "qwen2.5-coder:7b",
        "qwen2.5-coder:14b",
        "qwen2.5-coder:32b",
    ]);
    map
}

/// Check if an ollama model is already cached locally.
///
/// Ollama stores manifests under `~/.ollama/models/manifests/registry.ollama.ai/library/`.
/// This function checks if the manifest for `model_name` (e.g., "qwen2.5-coder:7b") exists.
///
/// @trace spec:inference-host-side-pull
fn is_model_cached(model_name: &str) -> bool {
    let home = match std::env::var("HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => {
            warn!(spec = "inference-host-side-pull", "HOME env var not set");
            return false;
        }
    };

    let parts: Vec<&str> = model_name.split(':').collect();
    if parts.len() != 2 {
        warn!(
            spec = "inference-host-side-pull",
            model = model_name,
            "Invalid model name format (expected 'name:tag')"
        );
        return false;
    }

    let (name, tag) = (parts[0], parts[1]);
    let manifest_path = home
        .join(".ollama")
        .join("models")
        .join("manifests")
        .join("registry.ollama.ai")
        .join("library")
        .join(name)
        .join(tag);

    manifest_path.exists()
}

/// Spawn a background task to pull higher-tier models based on GPU.
///
/// Detects the GPU tier, determines which models are needed, and pulls any
/// that aren't already cached. All pulls happen via the host-side `ollama`
/// binary (not in-container), bypassing the proxy.
///
/// Returns immediately (fire-and-forget). Errors are logged but not returned.
///
/// @trace spec:inference-host-side-pull
pub fn spawn_model_pull_task(tier: GpuTier) {
    tokio::spawn(async move {
        run_model_pull(tier).await;
    });
}

/// Internal: execute the model pull sequence.
async fn run_model_pull(tier: GpuTier) {
    let models_to_pull = model_tier_map()
        .get(&tier)
        .cloned()
        .unwrap_or_default();

    if models_to_pull.is_empty() {
        debug!(
            spec = "inference-host-side-pull",
            tier = %tier,
            "No models to pull for this tier"
        );
        return;
    }

    info!(
        spec = "inference-host-side-pull",
        tier = %tier,
        model_count = models_to_pull.len(),
        "Starting lazy model pull task"
    );

    for model in models_to_pull {
        if is_model_cached(model) {
            debug!(
                spec = "inference-host-side-pull",
                model = model,
                "Model already cached — skipping"
            );
            continue;
        }

        pull_model_host_side(model).await;
    }

    info!(
        spec = "inference-host-side-pull",
        tier = %tier,
        "Model pull task completed"
    );
}

/// Pull a single model via host-side `ollama` binary.
///
/// Spawns a blocking task to run `ollama pull` synchronously.
/// @trace spec:inference-host-side-pull
async fn pull_model_host_side(model: &str) {
    info!(
        spec = "inference-host-side-pull",
        model = model,
        "Starting model pull from ollama registry"
    );

    let model = model.to_string();

    // Spawn a blocking task so we don't block the async event loop
    tokio::task::spawn_blocking(move || {
        // Check if ollama is available on the host
        let ollama_check = Command::new("which")
            .arg("ollama")
            .output();

        if !ollama_check.map(|o| o.status.success()).unwrap_or(false) {
            warn!(
                spec = "inference-host-side-pull",
                category = "capability",
                safety = "DEGRADED: host-side ollama not found",
                model = %model,
                "ollama binary not found on host — cannot pull models"
            );
            return;
        }

        // Spawn ollama pull as a child process
        let start = std::time::Instant::now();
        match Command::new("ollama")
            .arg("pull")
            .arg(&model)
            .output()
        {
            Ok(output) => {
                let elapsed = start.elapsed();
                if output.status.success() {
                    info!(
                        spec = "inference-host-side-pull",
                        model = %model,
                        elapsed_secs = elapsed.as_secs(),
                        "Model pull completed successfully"
                    );
                } else {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    warn!(
                        spec = "inference-host-side-pull",
                        model = %model,
                        error = %stderr,
                        elapsed_secs = elapsed.as_secs(),
                        "Model pull failed"
                    );
                }
            }
            Err(e) => {
                warn!(
                    spec = "inference-host-side-pull",
                    model = %model,
                    error = %e,
                    "Failed to spawn ollama pull process"
                );
            }
        }
    }).await.ok();
}
