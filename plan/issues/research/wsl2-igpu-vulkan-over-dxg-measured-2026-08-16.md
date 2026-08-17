# iGPU acceleration from inside WSL2 over /dev/dxg: it works, and here are the numbers

- **Host**: windows/Yolanda — AMD Ryzen AI 7 350 (Zen 5, 8C/16T, AVX-512),
  Radeon 860M (RDNA 3.5, `VEN_1002 DEV_1114`, driver 32.0.31035.1003),
  15.2 GB **unified** RAM. WSL2 2.7.11.0, kernel 6.18.33.2-microsoft-standard-WSL2.
- **Guest**: distro `tillandsias-build`, Fedora Linux 44, 7.3 GiB of RAM visible.
- **Filed by**: `windows-opus5-accel-20260816`, 2026-08-16 (host local, UTC-7).
- **Order**: 793-zumy. Companions: 793-qr4t, 793-a8e7, 793-ee2g, 793-qc6q.
- **The runtime distro `tillandsias` was not touched.** The dev-inference server
  on 127.0.0.1:11434 stayed up throughout; every benchmark ran a *second* ollama
  on 127.0.0.1:11435. Verified alive before and after each phase.

## 1. The question

The existing accel probe reports `accel_class=cpu-only` on this host because it
looks for `/dev/dri`, `nvidia-smi`, and `/sys/class/accel`. On WSL2 the GPU
arrives through `/dev/dxg` instead, which that rubric cannot see. Is `cpu-only`
a *correct* verdict that happens to be reached by a blind route, or a **false
negative hiding real throughput**?

Falsifiable form: *can a process inside `tillandsias-build` run llama.cpp/ollama
on the Radeon 860M, and if so, how does tokens/sec compare to CPU-only?*

## 2. What the host actually offers the guest

```
PRESENT /dev/dxg      crw-rw-rw- 10, 258
ABSENT  /dev/dri  ABSENT /dev/accel  ABSENT /dev/kfd

/usr/lib/wsl/lib: libd3d12.so  libd3d12core.so  libdxcore.so
```

That library set is the decisive clue. It is the **D3D12** mapping layer, not
ROCm — there is no `libhsa-runtime`/`libamdhip64`, so ROCm-on-WSL is out
(consistent with AMD supporting only selected discrete cards there, and with
packet 520's never-fetched ROCm asset). `/usr/lib/wsl/drivers/amdvlk.inf_*/`
contains `amdvlk64.dll` and `vulkaninfo64.exe` — **Windows** binaries, unusable
from Linux. So the only viable guest-side compute path is Vulkan translated onto
D3D12: Mesa's `dzn` ("dozen") driver.

Fedora 44's `mesa-vulkan-drivers` ships `libvulkan_dzn.so`. That is the whole
experiment.

## 3. Exact commands (reproducible, and reversible)

Everything was installed **only** into `tillandsias-build`:

```bash
dnf install -y --setopt=install_weak_deps=False \
  vulkan-loader vulkan-tools mesa-vulkan-drivers
```

Installed, from `rpm -qa` (nothing else in the transaction is Vulkan-related):

```
vulkan-loader-1.4.341.0-1.fc44.x86_64
vulkan-tools-1.4.341.0-1.fc44.x86_64
mesa-vulkan-drivers-26.1.6-1.fc44.x86_64
mesa-filesystem-26.1.6-1.fc44.x86_64
```

**To reverse:** `dnf remove vulkan-loader vulkan-tools mesa-vulkan-drivers`
(pulled-in deps: `libdrm`, `libpciaccess`, `hwdata`, `spirv-tools-libs`,
`libwayland-client`, `libX11*`, `libxcb`, `libxshmfence`, `libdisplay-info`).
Total footprint ~32.5 MiB downloaded, ~200 MiB installed.

Device enumeration:

```bash
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json vulkaninfo --summary
```

```
GPU0:
	apiVersion    = 1.2.354
	driverVersion = 26.1.6
	vendorID      = 0x1002        <- matches host PCI VEN_1002
	deviceID      = 0x1114        <- matches host PCI DEV_1114
	deviceType    = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
	deviceName    = Microsoft Direct3D12 (AMD Radeon(TM) 860M Graphics)
	driverID      = DRIVER_ID_MESA_DOZEN
```

Benchmark invocation (the GPU arm; the CPU arm is `OLLAMA_VULKAN=0`):

```bash
OLLAMA_HOST=127.0.0.1:11435 \
OLLAMA_MODELS=/root/accel-experiment/models \
OLLAMA_VULKAN=1 OLLAMA_IGPU_ENABLE=1 \
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json \
LD_LIBRARY_PATH=/usr/lib/wsl/lib \
  /root/.local/share/tillandsias-dev-inference/bin/ollama serve

curl -s http://127.0.0.1:11435/api/generate -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:3b","prompt":"<unique ~4800-token text>","stream":false,
       "options":{"num_predict":1,"temperature":0,"num_ctx":8192}}'
```

Throughput is computed from the response's own
`prompt_eval_count / prompt_eval_duration` and `eval_count / eval_duration`.

**Methodology note that changed the answer.** A first pass reused one prompt
across repetitions and measured 76,000 prefill tok/s — ollama's prompt cache,
not the GPU. Every number below uses a **different random prompt per repetition**
(distinct RNG seeds, so no shared prefix), `num_predict=1` to isolate prefill and
a short prompt with `num_predict=256` to isolate decode. Three repetitions each;
median reported.

## 4. Results

`ollama ps` reports `100% GPU` on `Microsoft Direct3D12 (AMD Radeon(TM) 860M
Graphics)` for every GPU row — the work really is on the iGPU.

### qwen2.5:0.5b (Q4_K_M, 397 MB)

| | CPU-only | iGPU (dzn) | ratio |
|---|---|---|---|
| prefill | 407.7 / **397.5** / 395.5 t/s | 737.3 / **737.8** / 750.0 t/s | **GPU 1.86x** |
| decode | 78.56 / **78.68** / 78.69 t/s | 62.43 / **63.75** / 63.75 t/s | **CPU 1.23x** |
| llama-server RSS | 503 MB | 392 MB | |

### qwen2.5:3b (Q4_K_M, 1.9 GB)

| | CPU-only | iGPU (dzn) | ratio |
|---|---|---|---|
| prefill | 91.9 / **92.2** / 93.1 t/s | 183.9 / **188.3** / 191.3 t/s | **GPU 2.04x** |
| decode | 19.63 / **19.64** / 19.65 t/s | 26.21 / **26.96** / 27.36 t/s | **GPU 1.37x** |
| llama-server RSS | 2080 MB | 1020 MB | |

### nomic-embed-text (embedding — the "cheap expert RAG" tier)

| | CPU-only | iGPU (dzn) |
|---|---|---|
| wall per request | 8.6 / **8.7** / 9.0 ms | 10.2 / **10.2** / 11.0 ms |

**GPU is 1.16x slower.** Caveat: absolute values are small enough that HTTP and
tokenizer overhead are a meaningful share, so treat these as a *relative*
comparison only.

### The three findings that matter

1. **Prefill always wins on the iGPU** — 1.86x at 0.5B, 2.05x at 3B. Prefill is
   a batched GEMM and the 860M has the FLOPs.
2. **Decode has a crossover between 0.5B and 3B.** Decode is memory-bandwidth
   bound, and on *unified* memory the iGPU reads the same DRAM as the CPU — so it
   brings no bandwidth advantage, only compute, against a fixed per-dispatch
   cost. At 0.5B that cost dominates and the **CPU wins by 1.23x**; at 3B the
   arithmetic per token absorbs it and the GPU wins by 1.38x.
3. **Embeddings should not go to this iGPU at all.**

So "enable the GPU if one is present" would have made our own smallest models
*slower*. The routing argument is in
`plan/issues/research/accel-capability-envelope-and-routing-2026-08-16.md`.

### Memory footprint — do not read the RSS drop as a saving

GPU-side RSS is lower (1020 MB vs 2080 MB at 3B) because the weights live in a
D3D12 heap rather than in process address space. **This is the same physical
DRAM.** `dzn` advertises a single 7.58 GiB `DEVICE_LOCAL` heap, which is the
guest's RAM re-labelled, not separate VRAM. On a unified-memory node GPU and CPU
budgets must never be summed — relevant to 522 (expert-slots-vram-aware), which
would otherwise size slots against a phantom pool.

## 5. Negative results — record these so nobody re-runs them blind

- **ROCm is not available.** No `/dev/kfd`, no HIP/HSA runtime in
  `/usr/lib/wsl/lib`. Do not spend time on ROCm-in-WSL2 for this iGPU (520).
- **`/dev/dri` will never appear.** WSL2 exposes `/dev/dxg` by design; any check
  keyed on DRM nodes is permanently blind here.
- **The NPU is unreachable from WSL2** — no `/dev/accel`, no `amdxdna`, no
  passthrough. Structural; no guest-side install can fix it (793-ee2g).
- **A silent hang, once.** On the *first cold* GPU load of qwen2.5:3b, prompt
  processing stopped at 40% (2048 of 5093 tokens) and sat there >9 minutes with
  **no error, no assertion, no device-lost message**. Killed manually. A re-run
  of the same shape completed in ~25 s, and three subsequent clean repetitions
  logged zero assert/device-lost lines. Intermittent and cold-load-associated,
  not a hard limit — but it is the worst failure mode for an unattended host, so
  any enablement needs a deadline-and-fall-back-to-CPU watchdog.
- **`dzn` disclaims itself:** every run prints `WARNING: dzn is not a conformant
  Vulkan implementation, testing use only.` It exposes Vulkan 1.2, and notably
  `shaderInt8 = false`, `storageBuffer8BitAccess = false`, no cooperative-matrix
  extension. The measured throughput is achieved *without* those.
- **`lavapipe` is a trap.** With all Mesa ICDs installed, the loader also offers
  `llvmpipe`, a CPU software rasterizer that presents as a Vulkan device. Pinning
  `VK_DRIVER_FILES` to the `dzn` ICD is not a tidiness measure — without it a
  "GPU" run can silently be a slow CPU run. Any probe must reject
  `PHYSICAL_DEVICE_TYPE_CPU` / `DRIVER_ID_MESA_LLVMPIPE` devices.

## 6. Why the guest was CPU-only until today (and the one-line fix)

The already-running dev-inference server had **`OLLAMA_VULKAN:true` in its
config all along** — ollama 0.32.9 ships `lib/ollama/vulkan/libggml-vulkan.so`
and asks for Vulkan by default. It logged `inference compute id=cpu library=cpu`
purely because **no Vulkan loader was installed in the distro**. The enablement
is therefore three packages, not a code change (793-a8e7).

That cuts both ways: adding those packages to the base image would silently flip
every WSL2 host to GPU decode, *including the 0.5B case where that is a 1.23x
regression*. Enablement must be opt-in/auto-detected with a measured crossover,
never "GPU if present" (620-ca7g's floor must survive).

## 7. Networking: the direction that matters is shut

Relevant to 718-nkm2. `.wslconfig` does not exist on this host, so WSL2 is in
default **NAT** mode with localhost forwarding.

**Windows -> WSL works.** `wslrelay.exe` (PID 21260) mirrors guest listeners
into the Windows loopback; `netstat` shows `127.0.0.1:11434` and `127.0.0.1:11435`
listening on Windows, and from Windows:

```
$ curl -s http://127.0.0.1:11434/api/version
{"version":"0.32.9"}
```

**WSL -> Windows is blocked.** Two Python listeners were started on Windows
(`0.0.0.0:18080` and `127.0.0.1:18081`, both verified reachable from Windows
itself). From inside `tillandsias-build`, with the gateway derived from
`/proc/net/route` as `192.168.48.1`:

```
http://192.168.48.1:18080/  rc=28 (timeout)
http://192.168.48.1:18081/  rc=28 (timeout)
raw TCP connect 192.168.48.1:18080 -> TimeoutError
raw TCP connect 192.168.48.1:18081 -> TimeoutError
```

Timeout, not connection-refused — the packets are dropped. Cause identified:

```powershell
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore
  Name                  : {40E0AC32-46A5-438A-A0B2-2B479E8F2E90}
  DefaultInboundAction  : Block
  DefaultOutboundAction : Allow
  LoopbackEnabled       : True

Get-NetFirewallHyperVRule | ? DisplayName -match 'WSL'
  WslCore Inbound ICMPv4 / ICMPv6 / IPv4 mDNS / IPv6 mDNS  -> Allow
```

The **Hyper-V Firewall** default-blocks inbound from the WSL VM to the host; only
ICMP and mDNS are permitted. (`LoopbackEnabled: True` is why the Windows->WSL
direction works.) There are additionally two `python.exe` **Block** inbound rules
in the classic firewall, an independent second blocker for this particular test.

**Consequence.** A Windows-side NPU service (Lemonade/FastFlowLM — the only place
the NPU can be served, per 793-ee2g) is **unreachable from the enclave today**.

### 7.1 This does NOT strengthen 718-nkm2 option C — the operator already ruled

My starting hypothesis was that a Windows-side NPU forces the enclave across the
WSL boundary and therefore strengthens option C (mirrored networking) over
option B. **That is wrong, on two independent grounds.**

First, the operator settled it on 2026-08-17, before this measurement landed:

> Do **not** adopt `networkingMode=mirrored`. The sibling windows host assessed
> it as a **lower security boundary** than the current configuration. **Keep the
> enclave network isolated.**
> — The Tlatoāni, recorded in
> `plan/issues/optimization/mirrored-networking-reverted-redundant-ollama-removed-2026-08-17.md`

Mirrored mode was reverted on esmeraldinha, and the ambiguity it was meant to fix
turned out to be a self-inflicted redundant Windows ollama, not a design flaw.
So option C is not merely un-strengthened — it is **superseded by a decision on
grounds (security boundary) that my throughput data does not touch.**

Second, the measurement removes the premise. Option C was argued as the way to
resolve *endpoint ambiguity*. On this host there is no ambiguity: `wslrelay`
mirrors the single guest ollama into the Windows loopback, so both sides see the
same server — the Windows->WSL direction **already works without mirrored mode**.

What the NPU case actually needs is far narrower than mirrored networking: **one
`New-NetFirewallHyperVRule` allowing a single port inbound from the WSL VM.**
That is a scoped hole for one service, not a collapse of the network boundary,
and it is the option that should go to the operator in 793-ee2g. It remains a
host-level change and was **not made here.**

The honest summary: the acceleration decision and the networking decision *are*
coupled, but the coupling points at a single-port firewall exception, not at
mirrored networking.

## 8. Residue left on the host, and how to remove it

Confined to `tillandsias-build`:

- The three Vulkan packages of §3 (`dnf remove` to reverse).
- `/root/accel-experiment/` — logs, and an **isolated** model store containing
  `qwen2.5:3b` (~1.9 GB, pulled there deliberately so the dev-inference store was
  not modified). `rm -rf /root/accel-experiment` to reverse.
- The dev-inference model store is **unchanged**: still exactly
  `nomic-embed-text` and `qwen2.5` (verified after the run). Disk went 28G -> 30G
  of 1007G.
- No Windows-side change was made. The two test HTTP listeners were killed.
