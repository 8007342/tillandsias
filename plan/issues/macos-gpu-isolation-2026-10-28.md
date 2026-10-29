# macOS GPU access from isolated Linux workloads (order 1921-xkhw)

Filed 2026-10-28 by tlatoanis-macbook-air (Claude). Part B is web research.
Part A is a partial spike: the guest-device check is MEASURED, and the
per-image timings are NOT YET RUN. Labels: **[measured]** = run on this host,
**[primary]** = Apple docs / project repo / issue text, **[comment]** = an
unofficial user comment, **[inferred]** = my reasoning.

## A. Spike: can our VZ guest reach a GPU?

**[measured]** I ran a read-only probe in the Tillandsias VZ guest via
`tillandsias-tray --exec-guest` (v56.10.20.1, Fedora 44, kernel 6.19.10,
8 vCPU, 8 GB):

- no `/dev/dri`, and nothing under `/sys/class/drm`;
- PCI shows only virtio net, console, blk, fs, vsock, rng and balloon. There
  is **no virtio-gpu device (0x1050)**;
- no Vulkan ICDs and no `vulkaninfo`.

So the Venus → MoltenVK path is unreachable from our VZ VM. VZ exposes no
3D virtio-gpu to Linux guests, and VZ is closed source, so no device can be
added ([primary] https://sinrega.org/2024-03-06-enabling-containers-gpu-macos/).
Reaching Vulkan would need **the libkrun provider**: a different VMM, built on
Hypervisor.framework rather than VZ ([primary] same URL;
https://github.com/containers/krunkit).

Not yet done:
- SDXS / SD1.5 512px time per image on CPU in this guest. It needs sd.cpp and
  a model downloaded inside the guest; that waits for story 1921 (#704) to land.
- Any Vulkan number. It cannot be measured on VZ, and krunkit needs a host
  install, which the operator ruling forbids.
- Wakeups and memory for both runs.

## B. What Apple offers today

### Containerization framework / `container` CLI
- **[primary]** Runs Linux containers as lightweight VMs on Apple silicon.
  It supports **macOS 26 only**; macOS 15 is listed as unsupported.
  https://github.com/apple/container
- **[primary]** It has **no GPU support**. Requests #57, #163, #185, #213 and
  #281 were all closed. **[inferred]** PR #1314 ("--gpu flag for Metal/MLX")
  was closed in March 2026; the listing doesn't show whether it merged, and I
  am assuming it didn't. **[primary]** #1511 (`--gpus`) is open with no
  maintainer response. https://github.com/apple/container/issues/1511
- **[comment]** A commenter on #1511 says macOS 27 adds a public
  `VZCustomVirtioDevice`, which might allow a third-party virtio-gpu.
  Unverified.

### Virtualization.framework
- **[inferred]** `VZVirtioGraphicsDeviceConfiguration` is scanout (display)
  only for Linux guests; no 3D, Venus, virgl or compute is documented. The doc
  page body did not load, so this rests on the Red Hat post above.
- **[inferred]** The paravirtualized Metal GPU is for macOS guests only; I did
  not re-verify this in this pass.

### libkrun / krunkit (not Apple)
- **[primary]** An open-source VMM on Hypervisor.framework. Guest Mesa Venus
  sends Vulkan over virtio-gpu, and MoltenVK on the host runs it as Metal.
  krunkit needs macOS 14 or newer and installs via `brew install krunkit`.
  Podman 5.2+ has a libkrun provider. Lima marks krunkit experimental.
  https://github.com/containers/krunkit,
  https://blog.podman.io/2024/07/podman-and-libkrun/,
  https://lima-vm.io/docs/config/vmtype/krunkit/
- **[primary]** Proxy performance from llama.cpp on an M2 Max, as reported by
  the author of discussion #12985 (one user's measurements, not project docs).
  https://github.com/ggml-org/llama.cpp/discussions/12985

  | Setup | pp512 (tokens/s) | tg128 (tokens/s) |
  |---|---|---|
  | Native Metal | 746 | 71.4 |
  | krunkit Vulkan | 428 | 35.9 |
  | CPU container | 135 | 28.6 |

- No published SD1.5 or SDXS per-image numbers for krunkit exist.

### ComfyUI (PyTorch MPS) isolated?
- **[primary]** No. MPS and MLX need Metal, and Linux has no Metal, so no
  Linux VM or container gets them.
  https://github.com/ml-explore/mlx/issues/1945
- **[inferred]** A GPU route inside a guest is sd.cpp with Vulkan, under
  krunkit only. Check its output: one report shows Vulkan images differing
  from CPU on an AMD iGPU.
  https://github.com/leejet/stable-diffusion.cpp/issues/563

## Bottom line

1. **[measured + primary]** Today, no Apple-provided isolation gives a Linux
   workload a GPU. That covers our VZ VM and `container` on macOS 26 alike.
2. **[primary]** The only isolated GPU path is libkrun/krunkit with
   Venus/MoltenVK, at roughly 0.6× native Metal and about 3× CPU on the
   compute-bound llama.cpp prompt benchmark. It needs a host component, which
   is a native install unless libkrun is bundled in the Tillandsias app. That
   is an operator decision, and I have not pursued it.
3. **[primary]** ComfyUI with MPS cannot run isolated. Under the current
   ruling it stays off the table.
4. **[inferred]** Until 2 is decided, image generation on macOS is CPU sd.cpp
   with SDXS or few-step SD1.5. The CPU timing is the next measurement, once
   #704 lands.
5. **Watch:** the macOS 27 `VZCustomVirtioDevice` comment and
   apple/container#1511.
