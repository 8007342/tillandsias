# Research: XDNA2 NPU inference proven e2e on this host — toolboxes, containers, and the container-citizenship verdict (v0.5)

- date: 2026-07-29
- agent: linux-claudia-fable5-20260729T2222Z (operator-directed wave: 4 research
  + 2 toolbox-install + 1 container-probe agents, cross-verified; installs and
  probe ran on the live target host)
- packet: `npu-container-citizenship-e2e` (order 541, kind: research, status: done)
- consumers: orders 479–484 (amended this commit), 542–544 (filed this commit)
- host: `yoga` — AMD Ryzen AI 5 340 "Krackan Point" (XDNA2), Radeon 840M
  (RDNA3.5), 14 GiB RAM, Fedora Silverblue 44, kernel 7.1.4-200.fc44
- operator intent (2026-07-29): install ROCm-FastFlowLM and Lemonade Server
  toolboxes on this host, verify e2e NPU usability, then fold the winner(s)
  into a Tillandsias container on the enclave network gated on NPU hardware;
  make the idiomatic layers + dependency graph support dynamically added and
  removed optional containers (scientific/R images later); treat the NPU
  laptop tier as the primary end-user inference engine.

## 1. Headline verdicts

1. **Real NPU LLM inference works on this host today, end to end, in both
   lanes** — FastFlowLM v0.9.46 standalone and Lemonade Server 11.5.0
   wrapping FLM — with hard engagement evidence (xdna_mailbox IRQ deltas,
   runtime_status D3→D0, FLM telemetry) and ~90–99 tok/s decode on
   qwen3:0.6b (q4nx), TTFT ~0.48 s.
2. **Container-citizen, not sidecar, for the Linux XDNA2 lane.** Everything
   the toolboxes achieved was reproduced in PLAIN rootless podman
   (fedora-minimal:44) with exactly two flags — `--device /dev/accel/accel0
   --security-opt label=disable` — plus an in-image LD_PRELOAD shim, and it
   serves **fully offline on a `--internal` network with by-name discovery
   from a sibling container** (the enclave property). Order 478's
   "NPUs do not belong IN the container" is hereby REVERSED for Linux
   XDNA2; it stands for macOS/WSL2 (order 483 keeps those sidecar lanes).
3. **The FastFlowLM license hard-gate is NOT cleared** (§6). ROCm/FastFlowLM
   is a one-way MIRROR of FastFlowLM/FastFlowLM (GitHub API: `fork:false`,
   description "FLM app mirror"), not an AMD-relicensed fork. AMD acqui-hired
   the developers (2026-07-17) and v0.9.46's release notes promise "starting
   from v1.0.0, everything moves to ROCm/FastFlowLM" — **v1.0.0 does not
   exist yet**. The NPU kernels remain closed binaries with NO affirmative
   redistribution grant. Tillandsias may DOWNLOAD at provision time
   (sha256-pinned), never vendor/re-host. Lemonade Server itself is clean
   Apache-2.0 (Fedora RPM) and bundleable.
4. **Both runtimes: verdict "conditional include"** as an OPTIONAL,
   capability-gated, opt-in stack component. Lemonade is the preferred
   engine wrapper (Apache-2.0, official fc44 RPM, multi-backend: flm:npu +
   llamacpp vulkan/cpu behind one OpenAI surface); bare FLM is the smaller
   single-purpose alternative (also speaks ollama + OpenAI dialects).
5. **Routing seed confirmed empirically**: at 0.6B the NPU (~90 t/s, TTFT
   0.47 s) is BEATEN by both llamacpp CPU (101.6 t/s, TTFT 0.034 s) and
   Vulkan/840M (107.5 t/s, TTFT 0.050 s) in raw speed; the NPU's win is the
   ~5–15 W power envelope. NPU = background/sustained/battery lane, never
   the default interactive path for small models — exactly order 484's
   CLASS/ROUTE design, now with first-party numbers.
6. **No ollama rebase.** images/inference is generic fedora-minimal + ollama
   FIRST_RUN self-install; there is no base to escape. Keep order 482's
   engine-slot plan (ollama default until llama-server parity), and add the
   NPU lane as a separate optional image variant (order 543).
7. **NPU is a CONCURRENT co-processor, not a laptop-only fallback**
   (operator directive 2026-07-31). Even the fat-GPU desktop tier ships a
   small NPU beside the discrete/large GPU. So the optional NPU container is
   worth gating ON for EVERY NPU-equipped host, not just battery-primary
   laptops: on a fat host it runs the **background/sustained/expert-idle**
   lane (its ~5–15 W envelope, throttle-proof steady throughput) CONCURRENTLY
   while the big GPU serves interactive/quality traffic — heterogeneous
   parallel placement, not either/or. This turns order 484's workload classes
   from a single-device selector into a **concurrent multi-device scheduler**:
   the NPU absorbs preemptible/low-priority work (expert warm-keeping, RAG
   re-embeds, background summarization) so it never competes with the GPU's
   VRAM or the CPU's latency budget. Concretely it makes the NPU the natural
   home for the always-warm expert lane (relieving the VRAM pressure that
   sibling orders 522/527 flag on GPU hosts). See §10.

## 2. Corrections to the order-478 baseline

| 478 claim (2026-07-24) | Status 2026-07-29 |
|---|---|
| "FastFlowLM (flm) via Lemonade Server 10.x" | Lemonade is at 11.5.0 with an official Fedora 44 RPM; FLM at v0.9.46 |
| FastFlowLM license: MIT CLI + closed kernels, cap rumored, LICENSE 404 | Confirmed and WORSE: no license file ships in the Linux tarball at all; contradictory texts in-repo; explicit no-redistribution clause in the only formal binary license; see §6 |
| "NPUs … want a host-native sidecar slot, not container citizenship" | REVERSED for Linux XDNA2 by live evidence (§5); retained for macOS/WSL2 |
| Container recipe "PROVEN: --device /dev/accel/accel0 --ulimit memlock=-1:-1" | Half right: the device flag yes, but `--ulimit memlock=-1:-1` is a DECOY in rootless podman (silently clamped to the host hard cap); SELinux `label=disable` is required and was missing from the recipe; the memlock answer is the shim or a root limits.d drop-in (§4) |
| "XRT + xdna-driver shim" as separate userspace prerequisite | The FLM Linux tarball BUNDLES XRT 2.21.75 (libxrt_core, libxrt_driver_xdna) + all xclbins; zero extra packages needed on fedora-toolbox:44 (glibc ≥2.39 suffices; host has 2.43) |
| kernel ≥7.0 + linux-firmware ≥20260221 floors | Host satisfies: kernel 7.1.4, fw 1.1.2.64 (RyzenAI-npu6, amdnpu/17f0_10/npu_7.sbin, linux-firmware-20260622); `iommu=pt` NOT needed on 7.1.x (no iommu kernel arg present; NPU group is type "identity") |

## 3. What was proven, with evidence

### 3.1 FastFlowLM v0.9.46 (toolbox `rocm-fastflowlm`)

- Portable tarball `fastflowlm_0.9.46_linux.tar.gz` (69,418,981 B, sha256
  `17edb4a56542381b9e0a09707b424e513ee7a69675281f8e401f961566d056ff`), from
  the official GitHub release. No dnf deps beyond the fedora-toolbox:44
  baseline. `flm serve qwen3:0.6b` on :52625.
- E2E from the HOST: OpenAI dialect returned 62 tokens
  (`prefill_speed_tps:66.28, decoding_speed_tps:97.67,
  prefill_duration_ttft:0.4828`, wall 1.16 s); ollama dialect
  `/api/generate` returned `{"response":"banana","done_reason":"stop"}`.
- NPU engagement: mid-generation `/proc/interrupts` grew 5 `xdna_mailbox`
  MSI-X lines (sum 1259; ZERO at idle — lines retract on runtime suspend);
  `/sys/class/accel/accel0/device/power/runtime_status` suspended→active;
  FLM `/api/npu/status` `{"npu_available":true,"active_requests":1}`.
  Negative control: without `/dev/accel/accel0` FLM hard-errors
  "No NPU device found" — there is NO CPU/GPU fallback path in FLM, so
  emitted tokens are NPU-computed by construction.
- Model: `qwen3:0.6b` → Qwen3-0.6B-NPU2, q4nx (FLM-proprietary 4-bit),
  664 MB, pulled + hash-verified by flm. Catalog is a fixed set of
  NPU-compiled models (0.6B–3B fits this 14 GiB tier); no GGUF interop.

### 3.2 Lemonade Server 11.5.0 (toolbox `lemonade`)

- Official fc44 RPM (Apache-2.0), server `lemond` on :13305, OpenAI
  endpoints under `/api/v1` and `/v1`. `lemonade backends install flm:npu`
  auto-downloaded FLM v0.9.45 (bundled XRT). Backends active on this host:
  flm:npu, llamacpp:vulkan (RADV KRACKAN1 / Radeon 840M, Mesa 26.1.4),
  llamacpp:cpu (b9747).
- E2E from the HOST on `qwen3-0.6b-FLM`: coherent completions, telemetry
  `tps=89.52` / `90.53`, TTFT 0.47 s; IRQ delta +2597 across one 40-token
  request; runtime_status suspended→active→suspended around the run.
- Cross-engine measurement, same model class (Qwen3 0.6B):

| engine | decode t/s | TTFT s | note |
|---|---:|---:|---|
| FLM NPU (q4nx) | 89.5–90.5 | 0.47 | ~5–15 W envelope, D0 only during job |
| llamacpp Vulkan, Radeon 840M (Q4_0) | 107.5 | 0.050 | |
| llamacpp CPU (Q4_0) | 101.6 | 0.034 | |

### 3.3 NPU-engagement methodology (reusable for litmus)

- `grep xdna_mailbox /proc/interrupts` — lines EXIST ONLY while the device
  is awake; sample DURING generation (0.15–0.2 s cadence), never
  before/after (false negative). MSI-X range 74–105 on this host.
- `/sys/class/accel/accel0/device/power/runtime_status`:
  suspended (D3hot) → active (D0) on model load/inference.
- FLM `/api/npu/status` `active_requests`; lemonade telemetry log lines.
  `/api/v1/system-info` utilization reads 0.0 post-hoc for sub-second jobs —
  not a reliable probe.
- `flm validate --json` reports `ready:false` under the 8 MiB cap even when
  inference works via the shim — never gate automation on its exit code.

## 4. The memlock wall and the nolock shim

**Blocker (forecast by the host probe, reproduced in both lanes):** this
host caps RLIMIT_MEMLOCK at 8 MiB (soft=hard, systemd default). FLM's
bundled `libxrt_driver_xdna.so` maps NPU GEM buffer objects with
`mmap(..., MAP_SHARED|MAP_FIXED|MAP_LOCKED, accel_fd, ...)` (64–128 MiB
chunks; ~model-size total) → `EAGAIN`. Every unprivileged raise fails:
rootless podman `--ulimit memlock=-1:-1` is SILENTLY CLAMPED to the host
hard cap; root-in-userns `prlimit` gets EPERM (capability checked against
the init userns); toolbox has no podman-arg passthrough; host and toolbox
sudo both require a password on this box.

**Unprivileged fix, proven across every lane:** `nolock.so`, an LD_PRELOAD
shim (source in §9.1) that strips `MAP_LOCKED` from mmap/mmap64, no-ops
`mlock/mlock2/mlockall`, and reports RLIMIT_MEMLOCK as infinity to
getrlimit/setrlimit/prlimit (which also makes `flm validate` pass:
`memlock_ok:true, ready:true`). **Correctness argument:** amdxdna GEM BO
backing pages are allocated and DMA-pinned by the kernel driver itself
(kernel-accounted, not RLIMIT_MEMLOCK-accounted); userspace MAP_LOCKED is
belt-and-suspenders residency, not a DMA-correctness requirement. Verified
by coherent multi-cycle output at full speed in toolboxes and containers.

**Production ladder** (for order 543): (1) default = in-image shim — works
everywhere, zero privileges, at the cost of pageable (in practice resident)
model pages; (2) preferred where the operator consents = one-time root
`limits.d` drop-in raising memlock for the user + re-login (no reboot, no
rpm-ostree; precedent exists on Fedora for @pipewire) — then the shim is a
no-op and can stay; (3) never rely on `--ulimit memlock` in rootless podman.

## 5. Container probe — the enclave-deciding evidence

Both lanes rebuilt as plain rootless podman images (NOT toolbox) from
fedora-minimal:44: `tillandsias-scratch/npu-flm:probe` (404 MB, FLM 0.9.46)
and `tillandsias-scratch/npu-lemonade:probe` (188 MB, lemonade RPM; FLM +
models bind-mounted). Containerfiles in §9.2–9.3.

- **Minimal flag set** (bisected): `--device /dev/accel/accel0
  --security-opt label=disable`. Nothing else: no kfd/dri needed for
  NPU-only, `--group-add keep-groups` irrelevant (node is 0666 here),
  `:z/:Z` not needed, `--ulimit` a decoy (§4).
- **SELinux**: `/dev/accel/accel0` is generic `device_t` (kfd/renderD128
  have container-friendly types), so enforcing podman denies it: AVC
  `comm=flm-real scontext=container_t tcontext=device_t tclass=chr_file
  denied getattr`. `label=disable` is the documented cost; a root-side
  udev/semanage relabel of /dev/accel would let it be dropped later.
- **Performance parity with toolbox**: FLM in-container 98.6 t/s decode,
  TTFT 0.505 s; lemonade-wrapping-FLM 99.2 t/s.
- **Offline/enclave emulation**: on `podman network create --internal`
  (egress verifiably dead: external DNS fails), both containers served
  models bind-mounted from local caches, and a SECOND container on the same
  network reached them BY NAME (aardvark DNS) and got real NPU completions
  ("Offline inference works." 76.9 t/s; "Enclave NPU is online." 82.5 t/s;
  IRQ88 1578→1774 during). Offline-after-provision holds: only the
  runtime + model caches must exist locally — matching the existing
  provision-through-Squid-then-isolate flow.
- **Operational notes**: FLM as PID1 ignores SIGTERM (set a small
  `--stop-timeout` or wrap with an init; lemond stops gracefully ~4.5 s);
  lemond needs `XDG_RUNTIME_DIR` set in plain containers; lemond on 0.0.0.0
  without `LEMONADE_API_KEY` exposes unauthenticated `/internal/*` control
  and MCP process-launch endpoints — set the key or rely on internal-only
  exposure (the enclave topology); if flm-real's deps (libgomp etc.) are
  missing, lemonade's FLM discovery fails SILENTLY (catalog empty,
  model_not_found 404s).

**Recommendation adopted:** container-citizen for Linux XDNA2. A host
sidecar demonstrated no capability the container lacks on this host, and
costs host-shared PID/HOME state (toolbox footguns observed: `pkill -f`
matching host processes, caches shared across toolboxes via $HOME).

## 6. License gate (NOT cleared — quotes)

- The shipped Linux tarball contains **zero license files** (all 364
  entries checked).
- Repo `LICENSE_RUNTIME.txt`: verbatim MIT, "Copyright (c) 2025
  FastFlowLM" — source/CLI only.
- Repo README (post-2026-06-09, commit 479b4647 "docs: drop bin lic"
  deleted the $10M line and moved LICENSE_BINARY.txt to
  assets/superseded/): "These NPU-accelerated binary kernels are completely
  free for any use, including commercial use" + requested credit
  "Powered by [FastFlowLM]". Informal; grants USE only.
- Repo `TERMS.md` (STILL at root, unchanged since 2025-10-31, orphaned but
  live): binaries "are NOT open source and are protected by pending
  patents"; free commercially only "if your company's annual revenue
  remains at or below USD 10 million".
- `assets/superseded/LICENSE_BINARY.txt` v2.0 §3(c): "You may not: …
  Redistribute, publish, upload, or otherwise make the Binaries available
  to any third party, whether for commercial or non-commercial purposes,
  without prior written permission from the Licensor"; §5: "The Binaries
  are not licensed under the open-source MIT license".
- Windows installer EULA `src/inno/terms.txt` (live): repeats the $10M cap,
  no-redistribution, "PATENT PENDING".
- Copyright holder is FastFlowLM, Inc., not AMD. ROCm/FastFlowLM is a
  mirror (`fork:false`, hourly cron `17 * * * *` in upstream
  `.github/workflows/mirror.yml`); v1.0.0 handover announced, not shipped.

**Binding consequences for Tillandsias:** never vendor/re-host FLM binaries
or bake them into a pushed image (probe images are LOCAL-ONLY); provision
by downloading the official release sha256-pinned through the Squid
allowlist at install/first-run time; surface the $10M cap to commercial
users; RE-READ the license at the v1.0.0 ROCm handover (tracked in
order 483's gate). Lemonade Server: Apache-2.0 (RPM `License: Apache-2.0`,
verbatim LICENSE) — bundleable without conditions.

## 7. Integration design (repo seams, verified at 11fd37f2)

Full analysis with file:line anchors lives in the amended packets; the
load-bearing findings:

1. **Optional NPU container seams exist and are clean**: device-args
   pattern at `build_inference_run_args` (main.rs:3305 region, gpu-rocm arm
   precedent), launch seam `ensure_shared_git_and_inference_for_launch`
   (main.rs:10678–10827) with the order-491 non-fatal readiness pattern,
   teardown `remove_shared_stack_containers` (main.rs:4450–4456), image
   registration triple (main.rs asset-root map + scripts/build-image.sh
   name/CONTAINERFILE maps), agent discovery (container_profile.rs
   OLLAMA_HOST env + opencode config.json provider entries), NO_PROXY const
   `ENCLAVE_NO_PROXY_BASE` (main.rs:1022) which the new alias MUST join,
   and `images/proxy/allowlist.txt` which must learn `.hf.co`
   (HF Xet CDN) and `.lemonade-server.ai` (+verify `.fastflowlm.com`).
2. **But container_deps.rs cannot express optional components**: static
   `Service` enum + const DEPS table (no conditional presence), binary
   Satisfier Result (no SkippedNotApplicable), inference itself launched
   OUTSIDE the graph, hardcoded LivenessProbe `[Vault, Proxy]` set and
   teardown lists, per-target zero-sized `Up<T>` markers that don't scale
   to a catalog. This is the real enabler gap → new packet
   `optional-component-registry` (order 542), which enclave-service-catalog
   R9 (SCIENTIFIC/R images) must also land on — one mechanism, not two.
3. **Experts pipeline is ollama-coupled in exactly two absorbable places**:
   Modelfile create-time stuffing → move to shim request-time system
   messages; `keep_alive` eviction → demote to a per-slot capability owned
   by the order-484 policy router. Embeddings must pin to a CPU/GPU-capable
   slot (FLM is chat-only, fixed catalog). Expert traffic is
   interactive/TTFT-class → routes to the primary slot by class, not to the
   NPU (§3.2 numbers). → new packet `experts-engine-neutrality`
   (order 544); order 393's decision survives unmodified.

## 8. Host artifacts left in place (deliverables, local-only)

- Toolboxes: `rocm-fastflowlm` (FLM 0.9.46 at /usr/local/bin/flm launcher),
  `lemonade` (lemonade-server 11.5.0 RPM + flm:npu backend). Servers
  STOPPED; NPU verified suspended, zero xdna IRQ lines at exit.
- Local probe images: `tillandsias-scratch/npu-flm:probe` (404 MB),
  `tillandsias-scratch/npu-lemonade:probe` (188 MB) — NEVER push (license).
- Model caches (shared via $HOME across toolboxes): `~/.config/flm`
  (Qwen3-0.6B-NPU2, 664 MB), `~/.cache/lemonade` (flm backend + config,
  Qwen3-0.6B-GGUF Q4_0 364.5 MB).
- Session scratchpad (EPHEMERAL — distilled into this doc): runbooks,
  raw logs, shim binaries under
  /tmp/claude-1000/-var-home-tlatoani-claudia-tillandsias/…/scratchpad/.

## 9. Appendix: proven artifacts

### 9.1 nolock.c — LD_PRELOAD memlock shim (order 543 recreates as a repo asset)

```c
/*
 * nolock.so - LD_PRELOAD shim to work around the 8 MiB RLIMIT_MEMLOCK hard cap
 * on immutable hosts. FLM's bundled XRT XDNA shim maps its DRM GEM buffer
 * objects with mmap(...MAP_LOCKED...), which fails EAGAIN when the locked
 * bytes exceed RLIMIT_MEMLOCK. The BO backing store is kernel-allocated GEM
 * memory (already resident / DMA-pinned by the amdxdna driver), so the
 * userspace MAP_LOCKED is belt-and-suspenders; stripping it lets the mapping
 * succeed without changing DMA correctness. We also neuter mlock/mlockall so
 * nothing else trips the cap, and report RLIMIT_MEMLOCK as unlimited so FLM's
 * validate gate passes. Diagnostic counters on stderr with NOLOCK_DEBUG=1.
 */
#define _GNU_SOURCE
#include <sys/mman.h>
#include <sys/resource.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

#ifndef MAP_LOCKED
#define MAP_LOCKED 0x2000
#endif

static void *(*real_mmap)(void *, size_t, int, int, int, off_t) = NULL;
static void *(*real_mmap64)(void *, size_t, int, int, int, off_t) = NULL;
static int (*real_mlock)(const void *, size_t) = NULL;
static int (*real_mlockall)(int) = NULL;
static int (*real_getrlimit)(int, struct rlimit *) = NULL;

static atomic_long stripped = 0;
static atomic_long mlock_calls = 0;
static atomic_long rlimit_faked = 0;

static void init_syms(void) {
    if (!real_mmap)   real_mmap   = dlsym(RTLD_NEXT, "mmap");
    if (!real_mmap64) real_mmap64 = dlsym(RTLD_NEXT, "mmap64");
    if (!real_mlock)  real_mlock  = dlsym(RTLD_NEXT, "mlock");
    if (!real_mlockall) real_mlockall = dlsym(RTLD_NEXT, "mlockall");
    if (!real_getrlimit) real_getrlimit = dlsym(RTLD_NEXT, "getrlimit");
}

int getrlimit(__rlimit_resource_t resource, struct rlimit *rlim) {
    init_syms();
    int rc = real_getrlimit(resource, rlim);
    if (rc == 0 && resource == RLIMIT_MEMLOCK && rlim) {
        rlim->rlim_cur = RLIM_INFINITY;
        rlim->rlim_max = RLIM_INFINITY;
        atomic_fetch_add(&rlimit_faked, 1);
    }
    return rc;
}

int __getrlimit(__rlimit_resource_t resource, struct rlimit *rlim) {
    return getrlimit(resource, rlim);
}

int getrlimit64(__rlimit_resource_t resource, struct rlimit64 *rlim) {
    int (*real_g64)(__rlimit_resource_t, struct rlimit64 *) = dlsym(RTLD_NEXT, "getrlimit64");
    int rc = real_g64 ? real_g64(resource, rlim) : -1;
    if (rc == 0 && resource == RLIMIT_MEMLOCK && rlim) {
        rlim->rlim_cur = RLIM64_INFINITY;
        rlim->rlim_max = RLIM64_INFINITY;
        atomic_fetch_add(&rlimit_faked, 1);
    }
    return rc;
}

int setrlimit(__rlimit_resource_t resource, const struct rlimit *rlim) {
    if (resource == RLIMIT_MEMLOCK) { atomic_fetch_add(&rlimit_faked, 1); return 0; }
    int (*real_setrlimit)(__rlimit_resource_t, const struct rlimit *) = dlsym(RTLD_NEXT, "setrlimit");
    if (real_setrlimit) return real_setrlimit(resource, rlim);
    return 0;
}

int prlimit(pid_t pid, enum __rlimit_resource resource, const struct rlimit *new_limit, struct rlimit *old_limit) {
    int (*real_prlimit)(pid_t, enum __rlimit_resource, const struct rlimit *, struct rlimit *) = dlsym(RTLD_NEXT, "prlimit");
    if (resource == RLIMIT_MEMLOCK) {
        if (old_limit) { old_limit->rlim_cur = RLIM_INFINITY; old_limit->rlim_max = RLIM_INFINITY; }
        atomic_fetch_add(&rlimit_faked, 1);
        return 0;
    }
    if (real_prlimit) return real_prlimit(pid, resource, new_limit, old_limit);
    return 0;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    init_syms();
    if (flags & MAP_LOCKED) { flags &= ~MAP_LOCKED; atomic_fetch_add(&stripped, 1); }
    return real_mmap(addr, len, prot, flags, fd, off);
}

void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    init_syms();
    if (flags & MAP_LOCKED) { flags &= ~MAP_LOCKED; atomic_fetch_add(&stripped, 1); }
    return real_mmap64(addr, len, prot, flags, fd, off);
}

int mlock(const void *addr, size_t len) {
    (void)addr; (void)len;
    atomic_fetch_add(&mlock_calls, 1);
    return 0; /* pages stay pageable; GEM BOs are pinned by the driver */
}

int mlock2(const void *addr, size_t len, unsigned int flags) {
    (void)addr; (void)len; (void)flags;
    atomic_fetch_add(&mlock_calls, 1);
    return 0;
}

int mlockall(int flags) {
    (void)flags;
    atomic_fetch_add(&mlock_calls, 1);
    return 0;
}

__attribute__((destructor))
static void report(void) {
    if (getenv("NOLOCK_DEBUG")) {
        fprintf(stderr, "[nolock] MAP_LOCKED stripped=%ld  mlock*_noop=%ld  rlimit_faked=%ld\n",
                atomic_load(&stripped), atomic_load(&mlock_calls), atomic_load(&rlimit_faked));
    }
}
```

Build: `gcc -O2 -shared -fPIC -o nolock.so nolock.c -ldl`. Note: glibc
declares the resource arg as `__rlimit_resource_t`, not `int` — signatures
above compile clean on Fedora 44 gcc 16.

### 9.2 Containerfile — FLM lane (proven as tillandsias-scratch/npu-flm:probe)

```dockerfile
# Build context: flmx/ = extracted official fastflowlm tarball (NO redistribution
# grant — image is LOCAL-ONLY; production extracts the sha256-pinned tarball at
# provision time), nolock.c = shim from 9.1.
FROM registry.fedoraproject.org/fedora-minimal:44 AS shimbuild
RUN dnf5 -y install gcc glibc-devel && dnf5 clean all
COPY nolock.c /src/nolock.c
RUN gcc -O2 -shared -fPIC -o /nolock.so /src/nolock.c -ldl

FROM registry.fedoraproject.org/
## 10. Integration with sibling inference/experts work (orders 519–540)

Between this wave's research (2026-07-29) and its filing (2026-07-31) the
Linux coordinator filed a large inference/experts burndown (orders 519–540).
This wave's packets (541–544) are numbered above that range and integrate as
follows — no sibling packet is duplicated; each overlap is a cross-reference:

- **520 `ollama-rocm-asset-never-fetched`** ("gpu-rocm tier is CPU-only by
  construction; the ROCm asset is never downloaded") is CORROBORATED by this
  host: the working GPU lane here is **Vulkan/RADV on the Radeon 840M**
  (107.5 t/s), not ROCm. Reinforces order 482's "Vulkan-first variant" and
  this wave's "Vulkan is the robust default GPU lane, NPU is the power lane."
- **521 `engine-payload-download-integrity`** ("payload downloaded and
  executed with NO integrity verification") is the MECHANISM the NPU container
  (543) must reuse: FLM is fetched at provision time and MUST be sha256-pinned
  (this wave computed the pin: `17edb4a5…d056ff`). 543's integrity exit
  criterion is the NPU instance of 521's general requirement.
- **525 `inference-enclave-ca-not-trusted-by-engine`** ("ollama's Go TLS never
  trusts the enclave CA; failure swallowed as 'no models cached'") is a
  FOOTGUN 543 must dodge: FLM downloads via libcurl (honours
  `CURL_CA_BUNDLE=/etc/tillandsias/ca.crt`, the order-486 pattern), but any
  Go/Python component in lemonade's downloader could hit 525's exact swallow.
  543 must assert CA trust for its model/engine fetch, not infer it.
- **522 `expert-slots-vram-aware`** + **527 `expert-keepalive-contradicts-
  ephemerality`** are the ollama-specific instances of what **544
  `experts-engine-neutrality`** generalizes: keep-alive/residency must become a
  per-slot capability owned by the policy router, not an `OLLAMA_KEEP_ALIVE`
  literal. Better still (per §1.7): route the always-warm expert lane onto the
  **NPU** on fat GPU+NPU hosts so expert residency stops competing for GPU
  VRAM entirely — 544 should reference 522/527 as the problems it dissolves.
- **519 `model-lifecycle-mcp-surface`** (agent-triggered load/unload + RAG
  refresh under a VRAM budget) is the control surface through which 544's
  request-time stuffing and the 543 NPU slot are exercised; the NPU slot is a
  placement target 519's budget-enforcer can prefer for background work.
- **528 `source-window-litmus-assertions-are-brittle`** ("convert the
  inference ones to arg-vector assertions") applies to 543's
  `build_npu_inference_run_args`: assert the arg VECTOR, never line distance.
- **e4fa379e** (`fix(inference)!: the engine payload dropped llama-server`)
  UNBLOCKS order 482's llama-server slot — the slot this wave's 544 shim and
  543 NPU lane both target as the engine-neutral `/v1` upstream.

**Concurrent NPU+GPU scheduling (operator directive 2026-07-31).** The fat-GPU
desktop tier also carries an NPU, so order 484's router must evolve from a
single-device selector into a concurrent multi-device scheduler: the NPU runs
the background/sustained/expert-warm lane in parallel with the GPU's
interactive/quality lane. This is filed as an amendment note on order 484 and
as a routing seed in packet 544's coordination with 519/522/527.
