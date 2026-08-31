# The ROCm lane needs a runtime in the image, not just the device nodes

Filed 2026-08-30 by yoga, immediately after fixing the device-passthrough half
(scripts/dev-inference-ensure.sh). This is the SECOND half, and the first fix is
worthless without it.

## What was done and what happened

`scripts/dev-inference-ensure.sh` only set `--device` for `gpu-cuda`, so the
fleet's gpu-rocm host launched its inference container with no devices while the
script still passed `TILLANDSIAS_INFERENCE_TIER=gpu-rocm` into it. Fixed: the
gpu-rocm branch now passes `/dev/kfd` and `/dev/dri`.

Verified from where the work happens, not from the host:

    podman exec tillandsias-dev-inference ls /dev/kfd /dev/dri
    -> /dev/kfd, /dev/dri/card1, /dev/dri/renderD128     (present, were absent)

And the lane still does not engage:

    GET /api/ps  -> qwen2.5:7b  size=5.19GB  size_vram=0.00GB
    decode        12.22 tok/s   (before the fix: 12.18 tok/s — unchanged)

The container's own log says why, plainly:

    msg="discovering available GPUs..."
    OLLAMA_LIBRARY_PATH="[.../lib/ollama .../lib/ollama/vulkan]"
    msg="inference compute" id=cpu library=cpu name=cpu total="14.8 GiB"

and the library directory contains only CPU backends:

    libggml-cpu-{alderlake,haswell,zen4,...}.so, libggml.so, libllama.so, vulkan/

No ROCm/HIP backend is shipped, and there is no `/opt/rocm` or `libhsa*` in the
image. So the runtime enumerates the CPU as its only compute device — correctly,
given what it was given.

## The finding

A GPU lane needs THREE things, and the fleet has been tracking one:

    1. the hardware                 yoga: yes
    2. the device nodes in the container   yoga: NOW yes (this fix)
    3. a runtime that can drive them       yoga: NO

The tier label `gpu-rocm` asserted all three. The passthrough fix supplies (2).
Nothing supplies (3), and (3) is invisible from outside the container — the host
has the devices, the container has the devices, and the workload still runs on
the CPU.

Note this is exactly the state `accel_reason=engine-missing` already names on
this host's NPU line. The same condition on the GPU had no such marker, because
the GPU's verdict came from a label rather than from placement.

## What this is worth to the probe redesign

This is the case a label-based probe gets wrong most confidently: a host that
enumerates a real GPU, in a container that can stat its device nodes, whose lane
still cannot run. Every signal short of actual placement says yes.
`size_vram == 0` with the model resident is the only one that says no, and it is
the only one that is true.

## What is NOT claimed

Whether adding a ROCm runtime to `images/inference/` would work on this part is
UNMEASURED. gfx1150-class integrated graphics has its own ROCm support story
(`HSA_OVERRIDE_GFX_VERSION` exists precisely because that support is uneven),
and the ollama build here also carries a `vulkan/` backend directory that is
present but produced no device — whether the Vulkan path is a cheaper route than
ROCm on this hardware is likewise unmeasured. Both are worth trying; neither is
claimed here.

## Consequence for 937-68n4 right now

Every yoga measurement stays `gpu_path=none`. The passthrough fix is kept
because it is correct wiring and costs nothing (decode unchanged, 12.18 ->
12.22 tok/s, within noise), but it does not change a single number and must not
be reported as though it did.

Related: `plan/issues/inference-container-is-cpu-only-despite-gpu-rocm-tier-2026-08-30.md`
(the wiring half), 793-zumy (the enumeration redesign — this is its fourth test
case, and the useful one), 935-jhh5.
