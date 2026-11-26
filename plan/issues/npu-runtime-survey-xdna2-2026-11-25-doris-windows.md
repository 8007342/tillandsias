# NPU runtime survey: AMD XDNA 2 on Windows (host doris, 2026-11-25)

Read-and-record only; nothing was installed. Hardware: AMD Ryzen AI 9 HX 370
(Strix Point), XDNA 2 NPU (PCI VEN_1022 DEV_17F0), NPU driver 32.0.203.257,
Windows 11 Home 26H2 build 26300.9974. Capability tags: `npu`, `large-ram`.

## Runtimes that reach this NPU

| Runtime | Reaches XDNA 2 via | Needs installed | Admin? | Licence |
|---|---|---|---|---|
| AMD Ryzen AI Software 1.8.0 | ONNX Runtime + Vitis AI EP, AIE2P (STX/KRK) overlay | Installer from AMD account (EULA-gated); NPU driver 32.0.203.376 recommended (host has .257, older); VS 2022, cmake >= 3.26, conda | Driver update yes | AMD EULA (gated download; terms not public in search) |
| ONNX Runtime Vitis AI EP (standalone docs) | Same EP | Requires Ryzen AI Software on Windows | as above | ORT MIT; EP binaries under AMD terms |
| Windows ML (ExecutionProviderCatalog) | VitisAIExecutionProvider, downloaded on demand via Windows Update (e.g. KB5103226, EP 2.2606.1.0) | Windows 11 24H2+ (host qualifies), Windows App SDK; EP auto-delivered | No for the app; OS delivers EP | Microsoft Windows terms; EP AMD |
| DirectML | DmlExecutionProvider | Ships with Windows ML ORT | No | MIT (DirectML redistributable) — Microsoft labels it **legacy**; GPU-first, not the NPU path to pick |
| Lemonade Server + FastFlowLM | FLM NPU kernels for LLMs on Ryzen AI 300/400 (XDNA 2) | **Already present on this host**: lemonade 2026.48.3 in `%LOCALAPPDATA%\lemonade_server` (user scope). `flm` not on PATH | No (user install) | Lemonade Apache-2.0; FastFlowLM orchestration MIT, NPU kernels free incl. commercial per current README (an older third-party source said non-commercial; verify LICENSE) |
| OpenVINO / QNN | Not applicable: Intel and Qualcomm NPUs only | — | — | — |

## Recommendation

1. Lowest-friction LLM path: Lemonade (already installed) with its FLM NPU
   backend. Next step is a read-only check of which backends it lists, then the
   operator decides on any backend download (it may carry a licence prompt).
2. For ONNX/CNN models: Windows ML with the auto-delivered VitisAI EP; no EULA
   on our side beyond the OS.
3. Ryzen AI Software only if the above fail: it is EULA-gated and wants an NPU
   driver update (admin). Both are operator decisions.

## Sources

- https://ryzenai.docs.amd.com/en/latest/inst.html
- https://ryzenai.docs.amd.com/en/1.5/modelrun.html
- https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html
- https://learn.microsoft.com/en-in/windows/ai/new-windows-ml/supported-execution-providers
- https://ryzenai.docs.amd.com/projects/WinML/en/latest/winml_ep.html
- https://support.microsoft.com/en-US/servicing/os/windows/ai-components/2026/06/kb5103226-amd-vitis-ai-execution-provider-update-version-2-2606-1-0
- https://github.com/FastFlowLM/FastFlowLM
- https://raw.githubusercontent.com/FastFlowLM/FastFlowLM/main/README.md
- https://www.amd.com/en/developer/resources/technical-articles/unlocking-a-wave-of-llm-apps-on-ryzen-ai-through-lemonade-server.html
- https://www.amd.com/en/blogs/2026/fastflowlm-joins-amd-to-advance-ai-inference.html

## Lemonade probe on this host (2026-11-26, read-only)

Status and list commands only (`lemonade status`, `lemonade backends --all`,
`lemonade backends info`, `GET /api/v1/system-info`, `GET /api/v1/models`). No
model downloaded or loaded, no backend installed, no terms accepted.

- Server 2026.48.3 running on 127.0.0.1:13305; no models loaded, none downloaded.
- `system-info` sees the NPU: `amd_npu: {available: true, family: XDNA2}`;
  iGPU `gfx1150` (Radeon 890M); 64 GB RAM.
- NPU-capable backends:

| Backend | State | Licence (as Lemonade reports it) |
|---|---|---|
| `flm:npu` (FastFlowLM; LLMs, speech, embeddings) | **installed v1.0.13** | MIT (CLI) + FastFlowLM NPU Binary License (kernels) |
| `whispercpp:npu` (whisper.cpp, encoder on the NPU) | **installed v1.8.4** | MIT |
| `ryzenai-llm:npu` (ONNX Runtime GenAI on the NPU) | installable v1.7.0, not installed | MIT (server) + **AMD EULA** (Ryzen AI libraries) |

- Also installed: `llamacpp:cpu`, `llamacpp:vulkan` (b12233), `onnxruntime:cpu` 0.4.0,
  `whispercpp:cpu`, `acestep:vulkan`. ROCm backends are installable, not installed.
- `flm.exe` printed nothing in Git Bash (likely a GUI-subsystem binary), so the NPU
  check above comes from Lemonade's own system-info, not `flm validate`.

So the NPU path the operator still has to decide on is narrow: FLM and
whisper.cpp NPU are already on disk. Only `ryzenai-llm:npu` carries an AMD EULA.

## FastFlowLM licence text (installed copies, read only)

Read from the installed backend at `%USERPROFILE%\.cache\lemonade\bin\flm\npu\`
(v1.0.13), so these are the terms that ship with the binaries already on this host.

| File | sha256 |
|---|---|
| `LICENSE_BINARY.txt` (20 lines) | `2d12d19323c82de7ec3bd7c15da8d405ba9034e8080a96c447b26b741aad57b6` |
| `LICENSE_RUNTIME.txt` (21 lines, MIT) | `c80cdfb368086f7d3ca55414393e9db2cd716f0e3b9b3aa10e89d246eca20a4b` |

`LICENSE_RUNTIME.txt` is the standard MIT licence, "Copyright (c) 2026 Advanced
Micro Devices, Inc."

`LICENSE_BINARY.txt`, the operative clauses quoted in full:

> This license covers the FastFlowLM NPU kernel binaries (.xclbin files) and
> prebuilt NPU engine libraries (the "Binaries"). The Binaries are not open
> source.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of the Binaries, to use, copy, and redistribute the Binaries for any purpose,
> including commercial use, provided that the Binaries are redistributed
> unmodified and this license is included with them.
>
> THE BINARIES ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND [...]

Reading: use is free for any purpose, including commercial use. The conditions
apply only to redistribution: the binaries must stay unmodified and the licence
must ship with them. There is no click-through clause. This settles the older
third-party "non-commercial" claim noted above: it does not match the shipped text.
