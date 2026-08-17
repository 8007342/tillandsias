# The XDNA2 NPU path is Windows-native only — what serving it would actually cost

- **Host**: windows/Yolanda (AMD Ryzen AI 7 350, Krackan Point, XDNA 2 NPU).
- **Filed by**: `windows-opus5-accel-20260816`, 2026-08-16 (host local, UTC-7).
- **Order**: 793-ee2g (decision packet), companion to 793-zumy / 793-a8e7.
- **Status of every claim below**: measured-here, or sourced-with-date, or
  explicitly flagged `UNVERIFIED`. Nothing here is inference from vibes.

## 1. Measured on this host: the NPU is real, healthy, and unreachable from WSL2

Windows side (`Get-PnpDevice -Class ComputeAccelerator`, 2026-08-16):

```
Status       : OK
FriendlyName : NPU Compute Accelerator Device
InstanceId   : PCI\VEN_1022&DEV_17F0&SUBSYS_382317AA&REV_20\4&5785F6E&0&0142
DriverVersion : 32.0.20102.3930   Provider: AMD   DriverDate: 2026-06-05
```

`C:\Windows\System32\xrt_coreutil.dll` is present — the XRT core runtime shim
ships with the NPU driver. Nothing else of the AI stack is installed:

```
C:\Program Files\RyzenAI                          : False
C:\Program Files\Lemonade                         : False
C:\Program Files\flm                              : False
%LOCALAPPDATA%\lemonade_server                    : False
```

Guest side, distro `tillandsias-build` (Fedora 44, kernel
6.18.33.2-microsoft-standard-WSL2):

```
PRESENT /dev/dxg      <- D3D12 paravirtualisation (GPU only)
ABSENT  /dev/dri
ABSENT  /dev/accel    <- the amdxdna accel class. NOT forwarded by WSL2.
ABSENT  /dev/kfd
```

**Conclusion (measured):** WSL2 paravirtualises the *graphics* adapter through
`/dev/dxg` and nothing else. There is no `/dev/accel`, no `amdxdna` driver, and
no PCI passthrough for `VEN_1022&DEV_17F0`. A Linux process inside WSL2 cannot
touch this NPU by any path we found. This is a **structural** boundary, not a
missing package — no install inside the distro can cross it.

## 2. What a Windows-side NPU service actually requires (Aug 2026)

Four candidate stacks. Only two can serve an HTTP endpoint at all.

### 2a. AMD Ryzen AI Software (Vitis AI EP for ONNX Runtime)

- The SDK layer, not a server. "Ryzen AI software consists of the Vitis AI
  execution provider (EP) for ONNX Runtime combined with quantization tools and
  a pre-optimized model zoo." — [AMD Ryzen AI Software](https://www.amd.com/en/developer/resources/ryzen-ai-software.html) (fetched 2026-08-16).
- Model format: **ONNX only**, compiled by the Vitis compiler into a micro-coded
  executable for the NPU. PyTorch/TF models must be exported and quantized
  first. — [Vitis AI Execution Provider](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html) (fetched 2026-08-16).
- **Windows only** for NPU/hybrid: "Ryzen AI SW's implementation of NPU and
  hybrid inference is currently supported only on Windows." — [Lemonade FAQ](https://lemonade-server.ai/docs/guide/faq/) (fetched 2026-08-16).
- Serves no HTTP endpoint on its own. Would require us to write and maintain the
  server. **Not a candidate on its own.**

### 2b. Lemonade Server — the OpenAI-compatible front end AMD actually ships

- OpenAI-compatible: `POST /api/v1/chat/completions`, `/api/v1/completions`,
  `/api/v1/responses`, plus `/v1/embeddings`. — [Server Interface (REST API), Ryzen AI SW 1.8.0](https://ryzenai.docs.amd.com/en/latest/llm/server_interface.html) and [Lemonade API docs](https://github.com/lemonade-sdk/lemonade) (fetched 2026-08-16).
- Backends: `llamacpp` (GGUF, CPU + GPU via Vulkan/ROCm), `OnnxRuntime GenAI`
  (ONNX, **NPU and NPU+iGPU hybrid**), and `FastFlowLM` (FLM, NPU).
- **The hybrid split is the load-bearing fact for our routing policy:** "The NPU
  handles prompt processing. The GPU handles token generation." — [Lemonade FAQ](https://lemonade-server.ai/docs/guide/faq/) (fetched 2026-08-16).
- NPU execution is gated to **Ryzen AI 300-series**. This host (Ryzen AI 7 350)
  qualifies. Ryzen 7000/8000/200-series fall back to "GPU acceleration via
  llama.cpp + Vulkan backend" — i.e. exactly the path measured in 793-zumy.
- **Refutes half the operator hypothesis:** the embeddings endpoint "is only
  available for models using the `llamacpp` or `flm` recipes. ONNX models (OGA
  recipes) do not support embeddings." — [Lemonade OpenAI API docs](https://github.com/lemonade-sdk/lemonade/blob/main/docs/api/openai.md) (fetched 2026-08-16). So the ONNX/Vitis NPU path **cannot serve embeddings at all**.
- Reranking: a `reranking` deployment mode is named in the model labels, but no
  corresponding HTTP endpoint is documented. `UNVERIFIED` whether reranking is
  servable, and on which device.
- Install: `Lemonade_Server_Installer.exe`, a GUI installer, plus the Ryzen AI
  NPU driver. Unattended/silent-install flags are `UNVERIFIED` — we did not find
  documented silent-install switches, and we did not run the installer.
- Model library is the real constraint: "GGUF models number in the tens of
  thousands on Hugging Face while FLM and ONNX builds for the NPU path number in
  the dozens." — [InfoWorld first look](https://www.infoworld.com/article/4169474/first-look-lemonade-serves-up-local-ai-with-limitations.html) (fetched 2026-08-16).

### 2c. FastFlowLM (FLM) — the one stack that puts embeddings on the NPU

- Repository now lives under the ROCm org: [ROCm/FastFlowLM](https://github.com/ROCm/FastFlowLM) (fetched 2026-08-16).
- Supports **all XDNA2 parts — Strix, Strix Halo, Kraken, Gorgon Point**. This
  host (Ryzen AI 7 350 = Krackan/Kraken) is in scope.
- "FastFlowLM executes Vision (Gemma3), Audio (Whisper), and **Embedding** models
  entirely on the NPU." — FastFlowLM README/docs (fetched 2026-08-16).
- Serves an **OpenAI-compatible API**, positioned as an ollama drop-in.
- Windows installer available; Linux quick-setup guides exist — but Linux there
  means **native Linux with the `amdxdna` driver**, which WSL2 does not provide
  (§1). On this host FLM is a Windows-native service.
- Its own model management uses `FLM_MODEL_PATH`; models must be in FLM format.
- **This is the only stack we found that vindicates the "NPU for the embedding
  tier" hypothesis** — and it does so outside the ONNX/Vitis path entirely.

### 2d. Windows ML (Microsoft) — the device-selection layer, not a server

- Windows ML auto-registers `VitisAIExecutionProvider` for AMD Ryzen AI parts and
  `MIGraphXExecutionProvider` for AMD GPUs. — [Windows ML execution providers](https://learn.microsoft.com/en-us/windows/ai/new-windows-ml/supported-execution-providers) (fetched 2026-08-16).
- Device policy API `SessionOptions.SetEpSelectionPolicy` with
  `OrtExecutionProviderDevicePolicy` values `PREFER_NPU`, `MAX_PERFORMANCE`,
  `MAX_EFFICIENCY`. This is the closest thing to a vendor-neutral routing
  primitive on Windows, and it is worth mirroring in our own envelope grammar.
- **DirectML is in "sustained engineering"** — supported, but new feature work
  moved to Windows ML. — [Is DML being deprecated? #23783](https://github.com/microsoft/onnxruntime/issues/23783) and the Learn docs above (fetched 2026-08-16). *Any design that targets DirectML as its forward path is targeting a maintenance-mode API.*
- Serves no HTTP endpoint. It is a library we would host, not a service we adopt.

## 3. What this means for the "cheap expert RAG models" the operator named

| Work | Can the NPU serve it today? | Via what |
|---|---|---|
| Generative chat/completion, small LLM | Yes | Lemonade OGA-hybrid (NPU prefill + iGPU decode) or FLM |
| **Embeddings** | Yes, but **only via FLM** | ONNX/OGA explicitly does not support embeddings |
| **Reranking** | `UNVERIFIED` | mode named, endpoint undocumented |
| Small classifiers | `UNVERIFIED` for a served endpoint | Vitis AI EP can run them; nothing serves them over HTTP out of the box |

The operator's hypothesis — *NPU for fixed-shape INT8/INT4 embedding/rerank/
classifier work* — is **half-confirmed and half-refuted**:

- **Confirmed** that XDNA2 can run embeddings entirely on the NPU (FLM).
- **Refuted** that this is where AMD's mainline stack puts them: Lemonade's
  ONNX/Vitis NPU path serves no embeddings, and AMD's own hybrid design uses the
  NPU for **LLM prefill**, handing decode to the iGPU.
- Which matters because our measured iGPU data (793-zumy) shows the same shape
  from the other side: the iGPU wins **prefill** and is at best neutral on
  **decode** at small model sizes. Prefill is the contended resource, and both
  AMD's design and our measurements point at it.

## 4. Cost to adopt, and what needs the operator

Everything in §2 is a **host-level install on the Windows side**, outside any
distro we own, and outside anything this agent should do unilaterally:

1. Ryzen AI NPU driver is already present (32.0.20102.3930, 2026-06-05) — no
   action needed.
2. Lemonade Server and/or FastFlowLM would be new host software with a listening
   socket. Neither is installed. Unattended-install support is `UNVERIFIED`.
3. Either one places an inference endpoint on the **Windows** side of the WSL
   boundary — which is precisely the direction our measurement shows is
   **firewalled shut** (see 793-qc6q and §5 of
   `plan/issues/research/wsl2-igpu-vulkan-over-dxg-measured-2026-08-16.md`).

**Recommended sequencing** (argued in 793-ee2g): do not install anything until
the networking question is settled, because an NPU service the enclave cannot
reach is worth zero. The acceleration decision and the networking decision are
the same decision.

## 5. Explicitly unverified

- Silent/unattended install switches for `Lemonade_Server_Installer.exe`.
- Whether a reranking HTTP endpoint exists and which device serves it.
- FLM's exact embedding model list, quantization requirements, and licence.
- Measured NPU throughput on this host — **we measured none**, because
  installing the stack is an operator decision we did not take.
- Whether Lemonade/FLM can bind to the WSL-facing interface and whether that
  survives the Hyper-V firewall default-block.
