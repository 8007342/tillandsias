---
title: GPU Tier Detection — VRAM and Capability Classification
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [gpu, nvidia, amd, intel, vram, cuda, tier-detection]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# GPU Tier Detection — VRAM and Capability Classification

@trace spec:zen-default-with-ollama-analysis-pool

**Version baseline**: NVIDIA Driver 535+, AMD AMDGPU-PRO 23.30+, Intel i915 (any recent kernel)  
**Use when**: Determining which LLM models to pre-pull or lazy-load based on GPU VRAM, selecting GPU passthrough strategies, detecting hardware capabilities at runtime.

## Provenance

- https://developer.nvidia.com/cuda/gpus — NVIDIA GPU compute capability database and VRAM specs
- https://docs.nvidia.com/deploy/cuda-compatibility/ — NVIDIA CUDA compute capability and driver compatibility
- https://docs.nvidia.com/deploy/cuda-gpus/ — CUDA capability levels and memory bandwidth tables
- https://www.kernel.org/doc/html/latest/gpu/amdgpu/index.html — AMD GPU in Linux kernel (AMDGPU driver)
- https://01.org/linuxgraphics — Intel Linux Graphics (i915, Iris, UHD drivers)
- **Last updated:** 2026-05-03

## Quick reference: GPU Tier Mapping

| Tier | VRAM Range | Example GPUs | T0/T1 Models | T2-T5 Lazy-Pull |
|------|------------|--------------|--------------|-----------------|
| **None** | 0 GB (CPU only) | N/A | qwen2.5:0.5b | None |
| **Low** | ≤ 4 GB | RTX 4050, GTX 1050 | qwen2.5:0.5b, llama3.2:3b | None |
| **Mid** | 4–8 GB | RTX 4060, RTX 3060, A2000 | qwen2.5:0.5b, llama3.2:3b | qwen2.5-coder:7b |
| **High** | 8–12 GB | RTX 3080, RTX 4070, A5000 | qwen2.5:0.5b, llama3.2:3b | qwen2.5-coder:7b, qwen2.5-coder:14b |
| **Ultra** | ≥ 12 GB | RTX 4090, A100, H100 | qwen2.5:0.5b, llama3.2:3b | qwen2.5-coder:7b, qwen2.5-coder:14b, qwen2.5-coder:32b |

**Model memory footprint (loaded in VRAM):**
| Model | VRAM Required |
|-------|---------------|
| qwen2.5:0.5b | 0.35 GB |
| llama3.2:3b | 1.8 GB |
| qwen2.5-coder:7b | 4.5 GB |
| qwen2.5-coder:14b | 9 GB |
| qwen2.5-coder:32b | 20 GB |

## Detection: NVIDIA GPUs

### Query VRAM and Compute Capability

```bash
# List all NVIDIA GPUs with VRAM and compute capability
nvidia-smi --query-gpu=index,name,memory.total,compute_cap --format=csv,noheader

# Example output:
# 0, NVIDIA RTX 4080, 16000 MiB, 8.9
# 1, NVIDIA A100 80GB, 81920 MiB, 8.0

# Parse VRAM (in MiB)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
VRAM_GB=$((VRAM_MB / 1024))

# Parse compute capability
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
```

### Compute Capability → GPU Generation

| Compute Capability | Generation | Release | Typical VRAM |
|--------------------|------------|---------|--------------|
| 3.0–3.5 | Kepler | 2012–2014 | 2–4 GB |
| 5.0–5.3 | Maxwell | 2014–2016 | 2–8 GB |
| 6.0–6.2 | Pascal | 2016–2017 | 4–12 GB |
| 7.0–7.5 | Volta/Turing | 2017–2020 | 8–32 GB |
| 8.0–8.9 | Ampere/Ada | 2020–2024 | 16–80 GB |
| 9.0+ | Hopper | 2023+ | 24–80+ GB |

### Driver → Max CUDA Compatibility

| NVIDIA Driver | Max CUDA | Released |
|---------------|----------|----------|
| 535 | 11.8 | 2022 |
| 545 | 12.0 | 2023 |
| 555 | 12.1 | 2024 |

**Rule**: Container CUDA version MUST be ≤ host driver CUDA version.

## Detection: AMD GPUs

### Query VRAM and RDNA Generation

```bash
# List AMD GPUs
rocminfo | grep -E "gfx[0-9]+"

# Example: gfx1030 (RDNA 2), gfx1100 (RDNA 3)

# Query VRAM via lspci (for discrete GPUs)
lspci -k -s $(lspci | grep -i "VGA.*AMD" | cut -d: -f1) | grep "Memory"

# Or use rocm-smi (if installed)
rocm-smi --showproductname --showmeminfo
```

### RDNA Generation → Performance

| Generation | GFX Code | Release | Example GPU | Typical VRAM |
|-----------|----------|---------|-------------|--------------|
| RDNA 1 | gfx90c | 2020 | RX 5700 XT | 8 GB |
| RDNA 2 | gfx1030 | 2021 | RX 6700 XT | 12 GB |
| RDNA 3 | gfx1100 | 2023 | RX 7900 XT | 24 GB |

## Detection: Intel GPUs

### Query VRAM and GPU Architecture

```bash
# List Intel GPUs (integrated or discrete)
lspci | grep -i "VGA.*Intel"

# Example: Intel UHD Graphics 770 (integrated)
#          Intel Arc A770 (discrete)

# For Arc discrete GPUs: check kernel logs
dmesg | grep -i "i915\|arc"

# Query available VRAM (Intel integrated uses system RAM; discrete has dedicated VRAM)
# For discrete Arc GPUs, memory is enumerated via /proc/driver/
cat /proc/driver/i915/gt_prob_pe_control  # Intel's perf/energy interface
```

### Intel GPU Tier

- **Integrated (UHD/Iris/Xe)**: Shares system RAM; no discrete VRAM pool
  - Tier: Based on system RAM (treat as Low if < 8GB, Mid if 8-16GB)
- **Discrete (Arc A-series)**: Dedicated VRAM
  - Arc A380: 6 GB → Low
  - Arc A750: 8 GB → Mid
  - Arc A770: 16 GB → High

## Implementation: Rust GPU Tier Detection

```rust
// @trace spec:zen-default-with-ollama-analysis-pool

use std::process::Command;

#[derive(Debug, Clone, Copy)]
pub enum GpuTier {
    None,
    Low,
    Mid,
    High,
    Ultra,
}

impl GpuTier {
    pub fn models_to_pull(&self) -> Vec<&'static str> {
        match self {
            GpuTier::None | GpuTier::Low => vec![],
            GpuTier::Mid => vec!["qwen2.5-coder:7b"],
            GpuTier::High => vec!["qwen2.5-coder:7b", "qwen2.5-coder:14b"],
            GpuTier::Ultra => vec![
                "qwen2.5-coder:7b",
                "qwen2.5-coder:14b",
                "qwen2.5-coder:32b",
            ],
        }
    }
}

pub fn detect_gpu_tier() -> Result<GpuTier> {
    // Try NVIDIA first
    if let Ok(vram_gb) = detect_nvidia_vram() {
        return Ok(classify_vram_nvidia(vram_gb));
    }

    // Try AMD
    if let Ok(vram_gb) = detect_amd_vram() {
        return Ok(classify_vram_amd(vram_gb));
    }

    // Try Intel
    if let Ok(vram_gb) = detect_intel_vram() {
        return Ok(classify_vram_intel(vram_gb));
    }

    // CPU-only
    Ok(GpuTier::None)
}

fn detect_nvidia_vram() -> Result<u32> {
    let output = Command::new("nvidia-smi")
        .args(&["--query-gpu=memory.total", "--format=csv,noheader,nounits"])
        .output()?;

    let vram_mb: u32 = String::from_utf8(output.stdout)?
        .lines()
        .next()
        .ok_or("no GPU")?
        .trim()
        .parse()?;

    Ok(vram_mb / 1024)  // Convert MiB → GiB
}

fn classify_vram_nvidia(vram_gb: u32) -> GpuTier {
    match vram_gb {
        0..=4 => GpuTier::Low,
        5..=8 => GpuTier::Mid,
        9..=12 => GpuTier::High,
        _ => GpuTier::Ultra,
    }
}

fn detect_amd_vram() -> Result<u32> {
    let output = Command::new("rocm-smi")
        .args(&["--showmeminfo", "HIP"])
        .output()?;

    let output_str = String::from_utf8(output.stdout)?;
    // Parse rocm-smi output for total memory
    // Example: "GPU[0] : Total Memory: 12000M"
    for line in output_str.lines() {
        if line.contains("Total Memory") {
            // Extract numeric value
            if let Some(pos) = line.find(':') {
                let mem_str = &line[pos + 1..];
                if let Ok(mem_mb) = mem_str.trim().trim_end_matches('M').parse::<u32>() {
                    return Ok(mem_mb / 1024);
                }
            }
        }
    }
    Err("Could not parse rocm-smi output".into())
}

fn classify_vram_amd(vram_gb: u32) -> GpuTier {
    // AMD RDNA scales similarly to NVIDIA
    classify_vram_nvidia(vram_gb)
}

fn detect_intel_vram() -> Result<u32> {
    // Intel discrete Arc GPUs: parse kernel logs or /sys/
    // Integrated GPUs: use system RAM
    // For simplicity: check /proc/meminfo for system RAM
    // (Integrated GPUs don't have discrete VRAM)

    let output = Command::new("cat")
        .arg("/proc/meminfo")
        .output()?;

    let meminfo = String::from_utf8(output.stdout)?;
    for line in meminfo.lines() {
        if line.starts_with("MemTotal:") {
            if let Some(kb_str) = line.split_whitespace().nth(1) {
                if let Ok(kb) = kb_str.parse::<u64>() {
                    return Ok((kb / 1024 / 1024) as u32);  // KB → GB
                }
            }
        }
    }
    Err("Could not parse /proc/meminfo".into())
}

fn classify_vram_intel(vram_gb: u32) -> GpuTier {
    // Intel integrated: classify based on available system RAM
    classify_vram_nvidia(vram_gb)
}
```

## Detection: Fallback (CPU-only)

If no GPU is detected:

```bash
# Check if nvidia-smi exists
if ! command -v nvidia-smi &>/dev/null; then
    echo "No NVIDIA GPU detected"
fi

# Check if rocm-smi exists
if ! command -v rocm-smi &>/dev/null; then
    echo "No AMD GPU detected"
fi

# If neither, assume CPU-only
echo "Tier: None (CPU-only)"
```

## Tillandsias integration

**Inference launcher** (`zen-default-with-ollama-analysis-pool`):

1. At startup, call `gpu::detect_gpu_tier()`
2. T0/T1 models (qwen2.5:0.5b, llama3.2:3b) are baked into forge image
3. Based on tier, spawn background task to pull T2-T5 models:
   ```bash
   case $TIER in
       Mid) ollama pull qwen2.5-coder:7b ;;
       High) ollama pull qwen2.5-coder:7b qwen2.5-coder:14b ;;
       Ultra) ollama pull qwen2.5-coder:7b qwen2.5-coder:14b qwen2.5-coder:32b ;;
   esac
   ```
4. Log: `info!("GPU tier: {:?}; pulling models: {:?}", tier, tier.models_to_pull())`
5. If pulls fail, log `DEGRADED` and continue (no forge impact)

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `nvidia-smi: command not found` | NVIDIA driver not installed | Install NVIDIA driver or assume CPU-only |
| Reported VRAM is wrong | Shared/virtual GPU or container override | Use `--gpus all` in container to see host GPU |
| Model pull OOM despite high VRAM | Other process consuming VRAM | Check `nvidia-smi dmon -s pucvmet` |
| Intel GPU not detected in container | GPU not passed through to container | Use `--device /dev/dri/renderD128` |
| AMD GPU in container reports 0 VRAM | ROCm not installed in container | Add `rocminfo` to container image |

## See also

- `runtime/container-gpu.md` — GPU passthrough methods for containers
- `runtime/ollama-model-management.md` — Model pulling and caching semantics
- `runtime/inference-container.md` (DRAFT) — Inference container setup with multi-model support
