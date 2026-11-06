# Fedora 45 and AMD NPU/iGPU runtimes: the claim checked, which images move, which model runs where

- classification: research
- filed: 2026-11-06 (linux/lenovinha-silverblue, delegated research, reviewed)
- status: research record for operator review; nothing built
- related packets: 2014-f45n (this), 1980-tkfj (the Fedora 45 image bump), 2014-slpw (local models select work and wake)

@trace order:2014-f45n, order:1980-tkfj

## Which images change, and what each tier runs

- **Images on Fedora 44 today** (grep 2026-11-06): `images/default/Containerfile.base`, `images/inference/Containerfile`, `images/imagegen/Containerfile` (two stages), `images/chromium/Containerfile.core`, `images/builder/Containerfile`. All move under 1980-tkfj; that row holds the full 53-site scope.
- **What F45 itself gives them:** nothing new for AMD accelerators inside the image. The driver and firmware are host-side and already present; the userspace the NPU needs (XRT) is not in F45. A move to F45 is for currency, not for the NPU.
- **Low tier, CPU:** llama.cpp or ollama CPU, no device passthrough. Baseline. [unmeasured]
- **Mid tier, iGPU:** Vulkan (RADV) needs only `renderD*` and the Vulkan loader + ICD in the image (the inference image notes that gap). ROCm/HIP needs `/dev/kfd` too, and its iGPU targets lean on Fedora patches. [unmeasured]
- **Mid tier, NPU:** not a Fedora path. Only FastFlowLM/Lemonade (third-party, XDNA2-only, its own RPM), and it needs XRT plus an unlimited memlock limit raised on the host first. [unmeasured]
- **Measurement:** this host (lenovinha, F44) has no NPU. yoga runs F45 with `/dev/accel/accel0` and CDI specs (1980-tkfj), so the one mid-tier measurement belongs there: a 1–3B model, tokens/s on CPU, Vulkan, and (if installed) FastFlowLM.

## Claim check: Claim check: "Fedora 45 bakes AMD iGPU and NPU drivers into the kernel and images, giving local agents a more reliable NPU runtime" (checked 2026-11-06)

### VERDICT: PARTLY HOLDS. The kernel and firmware half is true. The "more reliable NPU runtime" half does not hold.
- True: Fedora's kernel builds the amdxdna module (=m), and the NPU firmware ships in Fedora's linux-firmware split. Both were already true in F42 to F44, so neither is new in F45.
- False: F45 has no Change for AMD NPU, iGPU, ROCm, Mesa or Vulkan. XRT, the NPU userspace, is packaged in rawhide (fc46) only, not in F45. No LLM runtime that runs on the NPU is packaged in Fedora. "Bakes into images" is [unproven] for anything beyond the stock kernel and firmware.

### 1. Release, kernel, Changes
- Released 2026-11-03 after two NO-GO slips from 2026-10-20. Ships Linux 7.2, with 7.3 to follow as an update. Third-party sources only (Phoronix "Fedora 45 Released", linuxiac). I did not confirm this on fedoraproject.org [official confirmation: unproven].
- Official: https://fedoraproject.org/wiki/Releases/45/ChangeSet. Fetching it found no Change mentioning AMD, NPU, XDNA, XRT, ROCm, amdgpu, Mesa, Vulkan, Intel NPU or OpenVINO. The kernel-adjacent Changes are ptrace restriction, kmscon, CRYPTO_USER_API disable and the DRM panic frontend. LLVM 23 is the only toolchain item near this topic.

### 2. amdxdna: kernel, firmware, userspace
- Upstream since Linux 6.14 (merge window Jan 2025, rc1 2025-02-02). Source: Phoronix "Linux 6.14 Features"; kernel.org confirmation of the exact commit is [unproven].
- Kernel docs (https://docs.kernel.org/accel/amdxdna/amdnpu.html) cover Phoenix and Hawk Point ("4x5 topology") and Strix Point ("4x8 topology"). Firmware is "securely load[ed] signed NPU FW" via the PSP. Userspace is "XRT ... An XRT shim for the NPU is hosted in AMD's xdna-driver repository." The page does not mention Strix Halo or Krackan [unproven for those].
- Fedora kernel config. Local evidence: Fedora kernel 7.2.13-200.fc44, the same 7.2 line that F45 ships, `/usr/lib/modules/.../config`: `CONFIG_DRM_ACCEL=y`, `CONFIG_DRM_ACCEL_AMDXDNA=m`, `CONFIG_DRM_ACCEL_IVPU=m`, `CONFIG_HSA_AMD=y`. Applying this to the fc45 build is an inference [unproven for the fc45 build specifically].
- Firmware: `/usr/lib/firmware/amdnpu/{1502_00,17f0_10,17f0_11}`. On this host these files belong to package `amd-gpu-firmware-20261019-1.fc44`. Bugzilla 2445615 records an amdxdna probe failure from a firmware protocol mismatch, fixed in linux-firmware 20260309 for F42, F43 and F44. Reliability problems have therefore existed with the in-tree bits.
- XRT: mdapi shows `xrt 2.25.0-2.fc46` in **rawhide only**. f45 returns no package, and src.fedoraproject.org/rpms/xrt/raw/f45 returns 404. The rawhide spec deletes `xdna/xdna-driver/src/drivers`, so it builds the shim against the in-tree driver. This host has no F45 or F46 amdxdna plugin package to check; the plugin's packaging status is [unproven]. Out-of-Fedora option: COPR xanderlent/amd-npu-driver ("experimental").
- Intel, for comparison: `intel-npu-driver 1.32.0-2.fc45` and `openvino 2026.0.0-16.fc45` are in F45. Intel's NPU userspace is packaged and AMD's is not.

### 3. ROCm in F45 (mdapi f45)
- rocm-runtime 7.2.1-4.fc45, rocm-hip 7.2.2-4.fc45, rocblas 7.2.0-9.fc45, onnxruntime 1.26.0-13.fc45, llama-cpp b9840-2.fc45, mesa-vulkan-drivers 26.2.3-1.fc45.
- rocm-rpm-macros (f45) `%rocm_gpu_list_default` includes `gfx1035;gfx1036;...gfx1103;gfx1150;gfx1151;gfx1152;gfx1153`, which covers the Rembrandt, Raphael, Phoenix/Hawk, Strix, Strix Halo and Krackan iGPUs. hipBLASLt covers fewer: "gfx1100;gfx1101;gfx1151;gfx1200;gfx1201". The rocblas spec carries Fedora patches: "Add support for Fedora-specific GPU architectures (gfx1035, gfx1150-1152)" and gfx1153/gfx1036 Tensile patches. These are not AMD-official targets [AMD support status: unproven].
- F45 llama-cpp spec: x86_64 builds with ROCm/HIP (`%bcond_without rocm`), and **Vulkan is disabled**: `%bcond_with vulkan` with the comment "# broken on stx halo b9781 / # Needs a maintainer".

### 4. Rootless podman access
- iGPU: `--device /dev/dri/renderD128` (label `dri_device_t`) and, for ROCm, `--device /dev/kfd` (label `hsa_device_t`). Add `--group-add keep-groups` so the container keeps the host's render/video group membership. On this host `/dev/kfd` is `crw-rw-rw- root render`.
- SELinux booleans on this host: `container_use_dri_devices --> on`, `container_use_devices --> on`. I did not check Fedora's shipped defaults; they may have been set locally [unproven]. `--security-opt label=disable` is the common fallback [third-party].
- NPU: `--device /dev/accel/accel0`, which appears only once amdxdna binds. It is absent on this host, which has no NPU. Its SELinux label is [unproven]; `container_use_devices` is likely required.
- memlock: AMD xdna-driver docs recommend `/etc/security/limits.d/99-amdxdna.conf` with `memlock unlimited`, otherwise large BO allocation fails. Podman usage (flm-portable, lemonade-npu-toolbox, third-party) is `--ulimit memlock=-1:-1`, "without it the NPU driver will crash". Rootless podman cannot raise a limit above the host hard limit. This host's limit is `ulimit -l` = 8192 KB, so the host limits.d change is required first. That ordering is inferred from rlimit semantics.

### 5. Still unsupported or fragile
- No AMD Linux NPU LLM path is in Fedora. The working path is FastFlowLM, a third-party mostly-proprietary runtime, Linux since 0.9.35 (2026-03-11), usually used through Lemonade 10.x, which offers an RPM from upstream rather than Fedora. It needs kernel 7.0 or later (or backports) and current firmware plus XRT. Per Phoronix it targets Ryzen AI 300/400 (XDNA2). XDNA1 (Phoenix/Hawk, 7040/8040) LLM support on the NPU is not a working route (securitylab.ru, third-party).
- Ryzen AI Software (Vitis AI EP for ONNX Runtime) on Linux: Fedora's onnxruntime is not built with that EP [inferred; unproven].
- Reported field issues: the driver reports 0 compute units without the right kernel flags (Reddit, Lemonade v10); the amdxdna probe failure breaks s2idle (BZ 2445615 and 2447225).

### 6. Realistic runtime per tier for 0.5 to 4B work-selection models
- CPU: llama.cpp (Fedora `llama-cpp` package or upstream). This tier is the most reliable and has no device plumbing. I gathered no benchmarks.
- iGPU: llama.cpp HIP from F45 packages for gfx1103/1150/1151 (Fedora-patched targets), or upstream llama.cpp Vulkan/RADV, which Fedora does not build. Vulkan needs only renderD*, which makes it the simpler container story. Benchmarks are [not gathered].
- NPU: only FastFlowLM/Lemonade (non-Fedora, XDNA2 only), with a curated model list (Llama 3.2 1B/3B, Qwen3 and similar; list [unproven]). Third-party LinuxLinks numbers, HX 470 on Ubuntu 26.04: about 11.5 tok/s decode at 1K context and about 6 tok/s at 32K. The same article also quotes 61.58 tok/s, which is internally inconsistent [unproven]. None of this is a "Fedora-provided" NPU runtime.

### Sources
- https://fedoraproject.org/wiki/Releases/45/ChangeSet
- https://docs.kernel.org/accel/amdxdna/amdnpu.html
- https://mdapi.fedoraproject.org/{f45,rawhide}/pkg/<name>; https://src.fedoraproject.org/rpms/{xrt,rocblas,rocm-rpm-macros,llama-cpp}
- https://bugzilla.redhat.com/show_bug.cgi?id=2445615 , https://bugzilla.redhat.com/show_bug.cgi?id=2447225
- https://copr.fedorainfracloud.org/coprs/xanderlent/amd-npu-driver
- https://phoronix.com/news/Fedora-45-Released ; https://www.phoronix.com/review/linux-614-features ; https://www.phoronix.com/news/AMD-Ryzen-AI-NPUs-Linux-LLMs ; https://phoronix.com/news/lemonade-10.1-released
- https://github.com/amd/xdna-driver (memlock) ; https://github.com/abn/flm-portable ; https://github.com/oresk/lemonade-npu-toolbox
- https://www.linuxlinks.com/bosgame-vta-439-running-llms-ryzen-ai-9-hx-470-npu/
- Local host probes: Fedora 44, kernel 7.2.13-200.fc44.
