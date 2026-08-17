# The NPU is not reachable from WSL2, and the reason is upstream of WSL

- **Host**: windows/Yolanda — AMD Ryzen AI 7 350 (Zen 5, 8C/16T, AVX-512),
  Radeon 860M (RDNA 3.5, `VEN_1002 DEV_1114`), XDNA2 NPU
  (`PCI\VEN_1022&DEV_17F0`, driver 32.0.20102.3930, `Status OK`), 15.2 GB
  **unified** RAM. WSL2 2.7.11.0, kernel 6.18.33.2-microsoft-standard-WSL2.
- **Guest**: distro `tillandsias-build`, Fedora Linux 44.
- **Filed by**: `windows-opus5-npu-20260817`, 2026-08-17.
- **Orders**: 794-kmqe (shared Windows-lane measurement), 793-ee2g, 718-nkm2.
- **The runtime distro `tillandsias`, the tray and the enclave were not touched.**
  The dev-inference ollama on 127.0.0.1:11434 stayed up throughout.

## 1. The question, in its sharp form

The operator asked, half-joking, "what if FastFlowLM is just a linux distro
inside WSL?" The serious question underneath it is precise and worth settling:

> The GPU is not exposed as `/dev/dri`. It arrives as `/dev/dxg` plus
> `/usr/lib/wsl/lib/{libd3d12.so,libd3d12core.so,libdxcore.so}`, and Mesa's
> `dzn` turns that into a usable Vulkan device. **Does DXCore inside WSL
> enumerate the NPU the same way** — as a D3D12 Core Compute or GENERIC_ML
> adapter — so that a Linux-side runtime could reach it through `/dev/dxg`?

An earlier filing answered "no /dev/accel, therefore no". That is true but it is
the weak form of the answer: it reports a missing device node without saying
whether the paravirtualisation path could ever carry the device. This settles
the strong form, at three independent layers.

## 2. Verdict: NOT REACHABLE

### Layer 1 — the WSL2 kernel cannot host the driver

`amdxdna`, the Linux driver for XDNA NPUs, lives under `drivers/accel/` and
depends on `CONFIG_DRM_ACCEL`. In the running WSL2 kernel:

```
$ zcat /proc/config.gz | grep -i -E "XDNA|DRM_ACCEL"
# CONFIG_DRM_ACCEL is not set
(no CONFIG_AMDXDNA symbol exists at all)
```

The compute-accelerator subsystem is compiled out. There is no configuration of
userspace that produces a `/dev/accel/accel0` on this kernel — the node is not
merely absent, it is unbuildable. Confirmed absent alongside it: `/dev/dri`,
`/dev/accel`, `/dev/kfd`. Present: `/dev/dxg` (`crw-rw-rw- 10, 258`).

### Layer 2 — DXCore inside the guest carries the GPU and nothing else

`libdxcore.so` in `/usr/lib/wsl/lib` really does export
`DXCoreCreateAdapterFactory`, so the question is answerable directly rather than
by inference. A DXCore enumerator was compiled **inside the guest** against
Microsoft's own `DirectX-Headers` and linked to the WSL library, and asked for
every adapter class including `D3D12_CORE_COMPUTE` and `D3D12_GENERIC_ML`:

```
DXCoreCreateAdapterFactory OK (inside WSL2 guest)
FILTER D3D11_GRAPHICS       -> 1 adapter(s)
FILTER D3D12_GRAPHICS       -> 1 adapter(s)
FILTER D3D12_CORE_COMPUTE   -> 1 adapter(s)
FILTER D3D12_GENERIC_ML     -> 1 adapter(s)
FILTER D3D12_GENERIC_MEDIA  -> 0 adapter(s)
  [adapter 0]
    DriverDescription : AMD Radeon(TM) 860M Graphics
    HardwareID        : vendor=0x1002 device=0x1114 subsys=0x380317AA rev=0xC2
    InstanceLuid      : 0x00000000_0x34835E06
    IsHardware        : true   IsIntegrated : true
    attributes        : D3D11_GRAPHICS D3D12_GRAPHICS D3D12_CORE_COMPUTE
                        D3D12_GENERIC_ML HW_GPU
```

One adapter, the iGPU, tagged `HW_GPU`. No adapter carries
`HW_NPU` or `HW_COMPUTE_ACCELERATOR`. Note the LUID is **remapped**
(`0x34835E06` in-guest vs `0x00010153` on the host) — this is a paravirtualised
handle, not a passed-through device, which is exactly why the set of adapters is
a policy decision rather than a hardware fact.

### Layer 3 — the decisive one: the NPU is not a DXCore adapter *on Windows either*

The same enumerator, compiled with MSVC against the Windows 11 SDK
(10.0.26100.0) and run natively on the host, sees:

```
FILTER D3D12_CORE_COMPUTE   -> 2 adapter(s)
FILTER D3D12_GENERIC_ML     -> 2 adapter(s)
  [adapter 0] AMD Radeon(TM) 860M Graphics   vendor=0x1002 device=0x1114  HW_GPU
  [adapter 1] Microsoft Basic Render Driver  vendor=0x1414 device=0x008C  HW_GPU
```

**Two adapters, neither of them the NPU** — even though `DXCORE_HARDWARE_TYPE_
ATTRIBUTE_NPU` is a defined attribute in that SDK and the NPU is healthy:

```
FriendlyName : NPU Compute Accelerator Device
InstanceId   : PCI\VEN_1022&DEV_17F0&SUBSYS_382317AA&REV_20\...
Status       : OK
Class        : ComputeAccelerator  ClassGuid : {f01a9d53-...-c8a7004be10c}
```

Corroborating: there is no `NPU Engine` performance-counter set on this host, and
the three `GPU Engine` adapter LUIDs contain no NPU.

This reframes the whole question. The XDNA2 NPU is a `ComputeAccelerator`-class
PnP device served by AMD's XRT stack; it is **outside the DXGI/DXCore world
entirely**. GPU-PV forwards DXCore adapters. There is no DXCore adapter to
forward. So this is not a gap in WSL's paravirtualisation that a future WSL
release closes by exposing more — there is nothing on the Windows side for it to
expose. It also means **ONNX Runtime's DirectML EP cannot reach this NPU on
Windows either**, let alone in WSL; the NPU's routes are AMD's own (VitisAI /
Ryzen AI) or FastFlowLM's XRT path.

**Consequence for the fleet: NPU work must live on the Windows side. It cannot
live in our WSL architecture, and no future WSL update is likely to change that.**

## 3. What FastFlowLM actually is, and whether the WSL hypothesis holds

FastFlowLM (`github.com/ROCm/FastFlowLM`, "flm") is a **native LLM runtime for
XDNA2 NPUs**, not a distro and not a wrapper.

- **Both Windows and Linux.** Linux support landed 2026-03-11, so the operator's
  instinct that there is a Linux story was right.
- **But the Linux build requires bare metal.** Its own install guide requires
  *"Kernel 7.0+ with `amdxdna`, or `amdxdna-dkms`"*, AMD's XRT stack, NPU
  firmware >= 1.1.0.0, and it validates against **`/dev/accel/accel0`**. WSL is
  mentioned nowhere. Every one of those prerequisites is exactly what section 2
  shows WSL2 cannot provide.
- **So the hypothesis does not hold.** "FastFlowLM as a Linux distro inside WSL"
  fails not on packaging but on the kernel: `CONFIG_DRM_ACCEL` is off and the PCI
  function is not in the VM. A FastFlowLM Linux lane would need a second,
  bare-metal Linux install — not a WSL distro.
- Lemonade's installer confirms the shape in practice: `lemonade backends
  install flm:npu` fetched **`fastflowlm_0.9.46_windows_amd64.zip`**.
- It serves an OpenAI-compatible endpoint (`flm serve`, default port 52625;
  under Lemonade it is served through Lemonade's own port).
- **It does run embeddings on the NPU** — `embed-gemma-300m-FLM` is a registered
  Lemonade model with recipe `flm` and label `embeddings`, and it returns real
  768-dimension vectors. See section 5 for why that is not yet useful.

Execution provider **verified, not assumed**: the `flm` process has
`xrt_core.dll` and `xrt_coreutil.dll` (AMD XRT) loaded alongside a family of
per-architecture kernels — `qwen3_npu.dll`, `llama_npu.dll`, `gemma_npu.dll`,
`q4_npu_eXpress.dll` and others. That is the XRT/XDNA path, not DirectML and not
ONNX Runtime. Triangulated by load: during sustained generation host CPU sits at
**12.8-21.7%** of 16 threads, which no CPU fallback at 92 tok/s could do.

## 4. Numbers — three lanes on one host

All medians of 3 reps, a **unique nonce at the head of every prompt** so ollama's
prefix cache cannot serve any of it. Prefill measured with a ~2700-token prompt
and one output token; decode with a short prompt and 256 output tokens.

| lane | model | prefill tok/s | decode tok/s |
|---|---|---|---|
| CPU (Zen 5, Vulkan backend **absent**) | qwen2.5:0.5b | **455.9** | **76.5** |
| iGPU (Mesa `dzn` over `/dev/dxg`) | qwen2.5:0.5b | 737.8 | 63.8 |
| **NPU** (FLM 0.9.46 / XRT) | qwen3-0.6b | **1938.1** | **91.9** |
| **NPU** (FLM 0.9.46 / XRT) | llama3.2-1b | **2084.2** | 63.1 |

Caveat stated up front: the NPU rows are a different model family and
quantisation (FLM's `q4nx`) from the ollama rows, so treat the comparison as
order-of-magnitude, not a controlled A/B. Within that limit the NPU wins **both**
axes at the ~0.5-1B scale — 4.3x CPU prefill, 2.6x iGPU prefill, and it is the
only lane that beats CPU decode below the ~1.5B crossover.

**Sustained behaviour, which is what "cheap expert RAG running continuously"
actually needs.** Fifteen consecutive 256-token generations, back to back:

```
run 1: decode_tok_s= 93.24 ttft_s=0.506 cpu_pct=17.7
run 8: decode_tok_s= 93.75 ttft_s=0.511 cpu_pct=14.1
run15: decode_tok_s= 92.08 ttft_s=0.506 cpu_pct=21.7
```

Range 92.08-94.28 tok/s, **no decay**; TTFT flat at 0.50-0.53 s; ACPI thermal
zone 43.1 C throughout. The NPU does not throttle under continuous load, which
is precisely the property the CPU and iGPU lanes lack.

## 5. The catch: NPU embeddings work, and are not usable

`embed-gemma-300m-FLM` returns correct 768-dim vectors on the NPU. Its latency,
against the same 2000-char chunk `bench-inference-floor.sh` uses:

```
nomic-embed-text, CPU, 10 sequential round trips :   295.5 ms/chunk
embed-gemma-300m-FLM, NPU, 10 sequential         : 18019.5 ms/chunk
```

A sweep shows the cost is **not** input-bound, which is the tell that this is a
defect rather than a speed limit:

```
input_chars=   40  ms= 11 892      input_chars= 1000  ms= 22 381
input_chars=  200  ms=  2 348      input_chars= 2000  ms= 12 266
input_chars=  500  ms= 13 833
```

Two orders of magnitude of variance, uncorrelated with input size. Projected
full-corpus re-embed (1592 chunks): **~8 hours on the NPU vs ~8 minutes on the
CPU.** Verdict: FastFlowLM is the only NPU embeddings route that exists, it is
functional, and it is **not adoptable** at 0.9.46. Worth re-testing on a later
release; not worth designing around today.

## 6. Cross-boundary: WSL2 guest -> Windows NPU endpoint. It works.

This is the path an enclave-side expert tier would need, and the earlier filing
recorded it as blocked. It is now **open and measured**, and the earlier
diagnosis of *why* it was blocked was wrong.

**The address the guest must use is the default gateway, `192.168.48.1`** — the
Windows host's `vEthernet (WSL (Hyper-V firewall))` address under NAT. Read it
from `/proc/net/route`, not from `ip route`: **`ip` is absent in this guest**,
another instance of the shared missing-tools trap.

```
$ curl http://192.168.48.1:8000/api/v1/models        -> http=200 in 5.6 ms
$ curl http://192.168.48.1:8000/api/v1/chat/completions ...
{"choices":[{"message":{"content":"NPU reached from WSL2 guest."}}],
 "model":"qwen3:0.6b",
 "usage":{"prefill_speed_tps":54.66,"decoding_speed_tps":80.30, ...}}
$ curl http://192.168.48.1:13305/...  (control, no rule)  -> timeout
```

**Three conditions, all required.** This was found the hard way; each was
individually insufficient.

1. A **Hyper-V firewall rule** for the WSL VM.
   `New-NetFirewallHyperVRule -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
   -Direction Inbound -Action Allow -Protocol TCP -LocalPorts 8000`.
   Proven necessary by control: a port with only condition 2 (18080, host allow
   rule, listener bound `0.0.0.0`, reachable from Windows itself) **timed out**
   from the guest.
2. A **host-level Windows Defender Firewall inbound allow** for the same port.
   The host firewall's default inbound action is block, and it applies to
   traffic arriving on the `vEthernet (WSL)` interface independently of the
   Hyper-V layer.
3. **No application-specific inbound BLOCK rule for the listener binary.** This
   was the real blocker and it hides well. Windows had auto-created
   `TCP/UDP Query User{...}` **Block** rules for `lemonade.exe` and
   `lemonadeserver.exe`, and in Windows Firewall **block beats allow**, so
   conditions 1 and 2 were both satisfied and traffic still died. Drop logging
   is what found it:
   ```
   2026-08-17 00:39:54 DROP TCP 192.168.50.92 192.168.48.1 46816 8000 60 S ... RECEIVE 2624
   ```

**This corrects the earlier filing.** It recorded WSL->Windows as blocked and
attributed the block to `DefaultInboundAction=Block` on the WSL VM setting. That
attribution is wrong: for a VM, *inbound* means into the VM, and guest->host is
outbound. The earlier probe used Python listeners — and a
`python.exe` inbound **Block** rule of exactly this auto-created kind exists on
this host too. The measured asymmetry was real; the cause named for it was not.

Diagnostic that generalises: enable `Set-NetFirewallProfile -All -LogBlocked
True` and read `%systemroot%\system32\LogFiles\Firewall\pfirewall.log`. A drop
with `RECEIVE` and the listener's PID is the host layer; silence there points at
the Hyper-V layer.

## 7. The `-ngl 0` trap: applied here, and the baseline survives it

ESMERALDINHA's warning (794-kmqe) is that `-ngl 0` controls weight offload, not
op scheduling, so with the backend merely **registered** ggml still schedules ops
onto it and a "CPU-only" run records ~2x too fast, flatteringly. The falsifiable
test is backend **presence**.

Yolanda's 2026-08-16 CPU arm has the same shape of risk: it ran with
`OLLAMA_VULKAN=0` **while the Vulkan packages were installed**. A flag, not an
absence.

The test was applied. The Vulkan packages are currently removed, and backend
presence is falsified at the loader level rather than asserted:

```
$ ldd .../lib/ollama/vulkan/libggml-vulkan.so
	libvulkan.so.1 => not found
```

The backend binary exists but cannot load, so it cannot register and cannot be
scheduled onto. Re-measuring in that state gives a baseline that is true **by
construction**:

| | recorded 2026-08-16 (`OLLAMA_VULKAN=0`) | re-measured, backend absent |
|---|---|---|
| qwen2.5:0.5b prefill | 397.5 tok/s | **455.9** tok/s (450.7 / 455.9 / 464.5) |
| qwen2.5:0.5b decode | 78.68 tok/s | **76.5** tok/s (78.6 / 75.9 / 76.5) |

**Not contaminated.** Contamination inflates; the honest number is 15% *higher*
on prefill and within 3% on decode. A number cannot have been flattered upward
past a true value that is above it. The recorded baseline was, if anything,
slightly pessimistic — which means the iGPU's measured prefill advantage was
*overstated*, not understated: 737.8/455.9 = **1.62x**, not 1.86x. The routing
conclusion is unchanged in direction and slightly weaker in magnitude.

Unlike llama.cpp's `-ngl 0`, ollama's `OLLAMA_VULKAN` gates a **separately
dlopen'd backend library** (`lib/ollama/vulkan/libggml-vulkan.so`), which is a
different mechanism and a plausible reason the trap did not bite here. Stated as
the explanation for a measured result, not as a claim tested on its own.

## 8. A trap in the shared instrument itself

`scripts/bench-inference-floor.sh` is the common instrument 794-kmqe proposes so
the two hosts' numbers are comparable. **Its prefill number is prompt-cache
contaminated on this host**, in the same flattering direction as the `-ngl 0`
trap:

```
gen: model=qwen2.5:0.5b engine=cpu offload_pct=0 prefill_tok_s=6965.08 ... prompt_tok=82
```

6965 tok/s against a true 455.9 tok/s for the same model on the same lane — a
**15x** inflation. The cause is structural: `bench_model()` sends a warm-up with
the *identical fixed* `$PROMPT`, then measures a second request with that same
prompt, so ollama serves the prefill from cache and
`prompt_eval_duration` collapses. Yolanda's 2026-08-16 filing already warned
ESMERALDINHA about this trap in hand-run form ("a first pass that reused one
prompt measured 76,000 prefill tok/s"); it was not noticed that the committed
harness has it too.

The harness's **decode**, **embed** and derived-`engine=` behaviour are sound —
decode is unaffected by prefix caching, and deriving the engine from `/api/ps`
rather than a flag is exactly right and is what makes the harness worth fixing
rather than replacing. Fix: give each rep a unique prompt prefix, as section 4's
runs do. Until then, **`prefill_tok_s` from this harness must not be pooled
across hosts**, and any decision resting on it should be re-derived.

## 9. Everything installed, and how to reverse it

| what | where | reverse |
|---|---|---|
| Lemonade Server 11.6.0 | `%LOCALAPPDATA%\lemonade_server` | `winget uninstall AMD.LemonadeServer` |
| FastFlowLM 0.9.46 (`flm:npu` backend) | Lemonade backend dir | `lemonade backends` manages it; removed with Lemonade |
| 3 FLM models (~0.16 GB cache) | `%USERPROFILE%\.cache\lemonade` | `lemonade delete <model>` or delete the dir |
| DirectX-Headers clone + 2 test binaries | guest `/root/npu-probe` | `rm -rf /root/npu-probe` |
| host firewall rule TCP 8000 | Windows Defender Firewall | `Remove-NetFirewallRule -Name 'Tillandsias-Research-Inference-8000-Host'` |
| 4 auto-created `lemonade*.exe` inbound Block rules **disabled** | Windows Defender Firewall | `Get-NetFirewallRule -Direction Inbound \| Where DisplayName -match '^lemonade' \| Enable-NetFirewallRule` |

**Left deliberately in place, and stated loudly:** Lemonade is reconfigured from
its defaults to `port=8000` and `host=0.0.0.0` (defaults were `13305` /
`localhost`) so that it answers on the port the Hyper-V rule opens. It is
reachable from the WSL subnet `192.168.48.0/20` and from anything else that can
route to this host on 8000. `lemonade config set port=13305 host=localhost`
restores the defaults.

**Not changed:** the dev-inference lane. `tillandsias-build` still has no Vulkan
loader, so ollama on 127.0.0.1:11434 remains CPU-only exactly as commit
`c6df04f17` left it. The runtime distro `tillandsias`, the tray and the enclave
were not touched, and no e2e gate was run. Firewall drop logging was enabled for
the diagnosis in section 6 and has been turned back off.
