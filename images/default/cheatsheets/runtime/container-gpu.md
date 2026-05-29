---
title: GPU Acceleration in Containers (Podman/Docker)
since: "2026-04-28"
last_verified: "2026-04-28"
tags: [gpu, container, podman, docker, cuda, dri, nvidia]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# GPU Acceleration in Containers

**Use when**: Running GPU-accelerated workloads (Chromium rendering, CUDA inference, WebGL), choosing GPU passthrough strategies, detecting host GPU capabilities.

## Provenance

- https://docs.docker.com/desktop/features/gpu/ — Docker GPU support (vendor-agnostic)
- https://podman-desktop.io/docs/podman/gpu — Podman GPU via CDI and raw device mounts
- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/ — NVIDIA Container Toolkit (primary for NVIDIA GPUs)
- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/1.14.2/cdi-support.html — NVIDIA CDI (Container Device Interface)
- https://developer.nvidia.com/cuda/gpus — NVIDIA GPU compute capability reference
- https://oneuptime.com/blog/post/2026-03-18-use-gpu-passthrough-podman/view — Podman GPU passthrough patterns
- https://developer.nvidia.com/blog/gpu-containers-runtime/ — NVIDIA Blog on container GPU architecture
- **Last updated:** 2026-04-28

## Quick reference

### GPU Passthrough Methods by Vendor

#### NVIDIA GPUs

**Option 1: Docker `--gpus` flag (Docker 19.03+)**
```bash
docker run --gpus all <image>
docker run --gpus '"device=0,1"' <image>  # Specific GPUs
```

**Option 2: Podman CDI (Podman 4.1.0+, recommended)**
```bash
# Setup (once):
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Usage:
podman run --device nvidia.com/gpu=all <image>
podman run --device nvidia.com/gpu=0 <image>
```

**Option 3: Raw device mounts (Podman < 4.1, Docker fallback)**
```bash
podman run \
  --device /dev/nvidia0 \
  --device /dev/nvidiactl \
  --device /dev/nvidia-uvm \
  -e NVIDIA_VISIBLE_DEVICES=all \
  <image>
```

**Requirements**:
- NVIDIA driver 470.42+ on host
- NVIDIA Container Toolkit installed (provides `nvidia-ctk` + libnvidia-container)
- CUDA 11.0+ in container (matches host driver version)

#### AMD/Intel GPUs (DRI/GBM)

AMD RDNA and Intel integrated GPUs use **DRI (Direct Rendering Infrastructure)** and **GBM (Generic Buffer Management)**:

```bash
# Minimal passthrough:
podman run --device /dev/dri/renderD128 <image>

# Full feature (with compute for AMD):
podman run \
  --device /dev/dri/renderD128 \
  --device /dev/kfd \
  <image>
```

**Environment**:
```bash
export LIBVA_DRIVER_NAME=i965         # Intel legacy
export LIBVA_DRIVER_NAME=iHD          # Intel modern
export LIBVA_DRIVER_NAME=radeonsi     # AMD
```

**Requirements**:
- Host GPU drivers (Mesa, AMDGPU-PRO)
- `/dev/dri/renderD128` accessible (default for non-NVIDIA)
- `/dev/kfd` accessible (AMD ROCm compute)

### GPU Tier Detection

**Query host GPU VRAM & capability**:

```bash
# NVIDIA
nvidia-smi --query-gpu=memory.total,compute_cap --format=csv,noheader
# Output: 8192 MiB, 7.0

# Intel/AMD (via lspci + driver queries)
lspci | grep -i gpu
```

**NVIDIA Compute Capability mapping**:
| Compute Capability | GPU Generation | VRAM Typical |
|-------------------|-----------------|--------------|
| 5.0-5.3 | Maxwell | 2-8GB |
| 6.0-6.2 | Pascal | 4-12GB |
| 7.0-7.5 | Volta/Turing | 8-32GB |
| 8.0-8.9 | Ampere/Ada | 16-80GB |

**Container tier logic**:
```python
if vram >= 32: tier = "Ultra"
elif vram >= 12: tier = "High"
elif vram >= 8: tier = "Mid"
elif vram >= 4: tier = "Low"
else: tier = "None"
```

### Container Driver Compatibility

**Critical**: Container CUDA version MUST match or be older than host driver.

| Host Driver | Max CUDA in Container |
|-------------|----------------------|
| 535 (2022) | 11.8 |
| 545 (2023) | 12.0 |
| 555 (2024) | 12.1+ |

Mismatch causes:
```
NVIDIA Container Toolkit: libcuda.so not found in LD_LIBRARY_PATH
CUDA Runtime API initialization failed
```

### CDI (Container Device Interface) — Best Practice

**Advantages**:
- Container-runtime agnostic (works with Podman, Docker, Kubernetes)
- Abstraction layer (vendor-neutral syntax)
- Supported by NVIDIA Container Toolkit 1.13.0+

**Setup**:
```bash
# Generate CDI spec (NVIDIA only)
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Result: ~/.config/containers/cdi/nvidia.yaml (or /etc/cdi/nvidia.yaml)
```

**Usage**:
```bash
podman run --device nvidia.com/gpu=all <image>
```

**For Intel/AMD**: CDI spec can be hand-written (lower priority than NVIDIA support).

### Fallback: Software Rendering (SwiftShader)

When GPU unavailable, Chromium can use **SwiftShader** software renderer:

```bash
chromium-browser --headless=new --disable-gpu
```

**Performance**: ~10x slower than GPU, high CPU/memory overhead (not recommended for production).

## Container recipe

```dockerfile
FROM nvidia/cuda:12.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y chromium

# GPU detection script (optional)
RUN cat > /check-gpu.sh << 'EOF'
#!/bin/bash
if nvidia-smi &>/dev/null; then
  echo "✓ GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
else
  echo "! GPU not available; using software rendering (--disable-gpu)"
fi
EOF

ENTRYPOINT ["/check-gpu.sh"]
```

Run with:
```bash
# NVIDIA GPU
podman run --device nvidia.com/gpu=all <image>

# AMD/Intel GPU
podman run --device /dev/dri/renderD128 --device /dev/kfd <image>

# CPU-only fallback
podman run <image>  # Will use --disable-gpu
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `NVIDIA: no such device` | Driver not loaded | `modprobe nvidia` on host |
| `CUDA version mismatch` | Container CUDA > host driver | Downgrade container CUDA or upgrade host driver |
| `libcuda.so not found` | nvidia-container-toolkit not installed | Install NVIDIA Container Toolkit |
| `Permission denied /dev/nvidiactl` | Container user not in group | Use `podman --group-add` or run as root |
| `WebGL context lost` | GPU evicted or driver crash | Check dmesg, restart GPU-using container |

## References

- `cheatsheets/runtime/chromium-headless.md` — Headless rendering options
- `cheatsheets/runtime/container-security.md` — Cap-drop and seccomp for GPU containers
- NVIDIA Container Toolkit docs — Official NVIDIA setup guide
- Podman GPU documentation — CDI reference
