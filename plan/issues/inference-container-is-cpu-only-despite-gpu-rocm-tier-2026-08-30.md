# The inference container claims tier `gpu-rocm` while running CPU-only

Filed 2026-08-30 by yoga (linux, Fedora Silverblue) during 937-68n4 measurement
setup. Found before any number was taken, which is the only reason the numbers
would not have been mislabelled.

## What was observed

The running inference container on yoga:

    container: tillandsias-dev-inference
    image:     localhost/tillandsias-inference:v0.4.260826.1
    env:       TILLANDSIAS_INFERENCE_TIER=gpu-rocm
    status:    Up 3 days (healthy)

Inside it:

    ls /dev/kfd  -> No such file or directory
    ls /dev/dri  -> No such file or directory

And from the host:

    podman inspect tillandsias-dev-inference --format '{{json .HostConfig.Devices}}'
    -> []

No device is passed into the container at all. Confirmed at the runtime level,
not inferred from the device nodes:

    GET /api/ps -> nomic-embed-text: size_vram=0
                   qwen2.5:0.5b:     size_vram=0

`size_vram=0` for every loaded model is the runtime saying it placed nothing on
a GPU.

Meanwhile the HOST has a working ROCm path, and the capability document agrees:

    accel_class=workstation-gpu accel_gpu=usable
    accel_gpu_name=Krackan_Radeon_840M_860M_Graphics accel_reason=engine-missing
    /dev/kfd present, /dev/dri/renderD128 present

## Why this matters beyond one host

The host-level verdict `accel_gpu=usable` does not survive into the container
lane, and nothing in the artifacts says so. A reader of the capability document
sees a usable GPU; the workload that actually runs sees a CPU. The tier label
`gpu-rocm` is carried on the container as an environment variable that describes
an intention, not a measured state — so the one place where the discrepancy
could have been caught is instead where it is asserted away.

This is the same shape as the Windows finding yolanda measured today
(`/dev/dxg` present, no Vulkan ICD, CPU-only in practice) and it means the two
hosts are closer than the fleet believed: on the model workload, BOTH are
currently CPU-only. The difference is that on Windows the substrate cannot
deliver the GPU, while here the GPU is deliverable and simply is not delivered.

## Consequence for 937-68n4

The regime label "L-native, ROCm live" is wrong for anything measured through
this container. Every row taken here must read `gpu_path=none` with the reason
recorded verbatim, or it claims an accelerator that took no part in the work.
A tier recommendation built on rows labelled GPU that were computed on CPU is
worse than no recommendation: it would tell an operator their machine class
needs a GPU it never used.

## What is NOT claimed here

Whether passing `/dev/kfd` and `/dev/dri` into the container would make ROCm
work end to end is UNMEASURED. The host has the device nodes; that is not the
same as a working userspace inside this image. `accel_reason=engine-missing` on
the host's own NPU line is a reminder that a present device and a usable lane
are different questions.

## Suggested remedies, in preference order

1. Make the container's tier label a MEASURED field rather than an asserted one:
   have the container report what the runtime actually placed (`size_vram`, or
   the device nodes it can see) and let the tier be derived from that. An
   environment variable that says `gpu-rocm` while `HostConfig.Devices` is empty
   is a claim no one checked.
2. If the GPU lane is intended for this container, pass the devices and then
   verify placement rather than assuming it followed.
3. Either way, surface the container-lane verdict next to the host-lane verdict
   in the capability document, so `accel_gpu=usable` cannot be read as "usable
   by the workload" when it means "usable by the host".

Related: 805-r98w (the fingerprint keys rows on hardware; this is the substrate
half of the same key), 793-zumy / 793-a8e7 (the Windows engine-missing lane),
935-jhh5 (accel/inference image, owned by lenovinha — this packet deliberately
does not touch accel_probe.rs or the inference image).
