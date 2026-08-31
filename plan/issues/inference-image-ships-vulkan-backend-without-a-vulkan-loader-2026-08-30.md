# The inference image selects the Vulkan backend and ships no Vulkan userspace

Filed 2026-08-30 by yoga while taking the Linux GPU lane (917-zkge / accel work).
This is the THIRD and final layer of the gpu-rocm lane failure on this host, and
it is the one that actually stops inference.

## The three layers, in the order they were found

1. **No devices in the container.** `dev-inference-ensure.sh` set `--device` only
   for `gpu-cuda`, so a `gpu-rocm` host launched with an empty device list while
   the script still passed `TILLANDSIAS_INFERENCE_TIER=gpu-rocm` in. Fixed
   2026-08-30; `/dev/kfd` and `/dev/dri` now reach the container.
2. **No ROCm runtime in the image.** Filed separately. Deliberate, per
   `_engine_wanted_backends()`: "This ollama release ships no rocm backend dir;
   Vulkan is the working AMD lane (RamaLama's proven pattern, order 482)." So
   `gpu-rocm` is mapped to the `vulkan` backend by design.
3. **THIS ONE — the Vulkan backend has no Vulkan userspace to load.** Measured in
   the image itself, not inferred:

       podman run --rm --entrypoint sh localhost/tillandsias-inference:v0.4.260826.1 \
         -c 'ls /usr/lib64/libvulkan.so*; ls /usr/share/vulkan/icd.d/'
       -> NO libvulkan loader in image
       -> NO Vulkan ICD dir in image

   ollama's own `lib/ollama/vulkan/` backend directory IS installed (the engine
   manifest records `core+vulkan`), and the container's startup log reports
   `OLLAMA_LIBRARY_PATH="[.../lib/ollama .../lib/ollama/vulkan]"` — and then
   `inference compute id=cpu library=cpu`, because a Vulkan backend cannot
   enumerate a device without a loader (`libvulkan.so.1`) and an ICD
   (`/usr/share/vulkan/icd.d/*.json` — for AMD, Mesa's radv).

## Why this is the same defect the fleet has been finding all night

The engine-selection code has a guard for exactly this class and it fires
correctly: "a wanted backend the release does not ship is a REAL mismatch: say so
rather than silently installing a CPU-only payload on a GPU host." That guard
checks whether the BACKEND DIRECTORY is present. It cannot check whether the
backend can LOAD — so the backend is installed, the manifest records
`core+vulkan`, every artifact says the GPU lane is configured, and the workload
runs on the CPU.

A backend directory is a proxy for a working lane. Placement is not:
`/api/ps` reports `size_vram=0` for every model, and decode is unchanged at
12.18 -> 12.22 tok/s across the device-passthrough fix.

Note the exact mirror on Windows: yolanda's WSL2 lane is `engine-missing:no-vulkan-icd`
— the same missing ICD, reached from the other substrate. The Linux container and
the WSL2 guest fail identically for identical reasons.

## What the host proves is available

yoga's HOST is fully equipped and the container is not:

    rocminfo          gfx1152, AMD Radeon 840M Graphics (rocm-runtime 7.1.1)
    /dev/kfd          present        /dev/dri/renderD128  present
    lspci             1002:1114 Krackan [Radeon 840M / 860M]

So this is not a hardware or driver question on this tier. yolanda independently
proved gfx1152 does real inference on this silicon from the Windows userspace
(0.08 of 16 cores while generating), so the target is known-good.

## Two candidate fixes, both unmeasured here

(a) **Ship the Vulkan userspace**: `vulkan-loader` + `mesa-vulkan-drivers` in the
    image, keeping the existing `gpu-rocm -> vulkan` mapping. Smaller, matches
    the documented RamaLama pattern, and would fix the WSL2 lane by the same
    change if that guest uses this image.
(b) **Fetch the ROCm bundle**: ollama publishes
    `ollama-linux-amd64-rocm.tar.zst` as a SEPARATE release asset — verified
    fetchable today (HTTP 206 on a range request). The self-install currently
    pulls only the base tarball, which is why no `rocm` backend dir exists to
    install. This would make the `gpu-rocm` tier literally true.

(a) is the smaller change and (b) is the more honest one. Neither is claimed to
work until `size_vram > 0` is observed with a model resident — every signal short
of placement already says this lane works.

## What is NOT claimed

That either fix makes gfx1152 usable through ollama. RDNA3.5 integrated graphics
support is uneven in both stacks, and `HSA_OVERRIDE_GFX_VERSION` exists because of
it. The measurement is `size_vram > 0`, not a successful image build.

Related: `plan/issues/inference-container-is-cpu-only-despite-gpu-rocm-tier-2026-08-30.md`,
`plan/issues/rocm-lane-needs-userspace-not-just-devices-2026-08-30.md`, 793-zumy
(proof-by-placement), 482 (the Vulkan-for-AMD decision), 917-zkge.
