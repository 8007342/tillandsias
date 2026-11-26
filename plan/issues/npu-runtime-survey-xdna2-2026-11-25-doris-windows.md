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
