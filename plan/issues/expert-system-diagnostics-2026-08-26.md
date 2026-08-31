# Expert System Diagnostics — 2026-08-26
## Host: forge-tillandsias (Apple Silicon M5, Fedora 44 aarch64)
## Container: 4 vCPUs, 3.8 GiB RAM, CPU-only inference

### Inference Benchmark

| Model | Params | Prefill tok/s | Gen tok/s | Load ms | Context |
|-------|--------|--------------|-----------|---------|---------|
| qwen2.5:0.5b | 494M | 435.0 | 127.5 | 1 | CPU, Q4_K_M |
| qwen2.5:1.5b | 1.5B | 77.9-106.2 | 12.5-18.4 | 1577 | CPU, Q4_K_M |
| nomic-embed-text | 137M | — | — | — | CPU, 768-dim |

### Embedding Speed (nomic-embed-text, CPU)
- 100 chars: 572ms
- 250 chars: 21,440ms (batch of 64)
- Per-chunk average at 250 chars: ~52ms (from bench script)
- Chunks per second: ~19

### Spec Index Build
- Total chunks: 21,799
- Embedding model: nomic-embed-text (768-dim)
- Build rate: ~6 vectors/sec on CPU
- Estimated total time: ~60 minutes
- Status: in progress (49% at time of drafting)

### Filesystem Baseline (rg on openspec/specs/*/spec.md)

| Query ID | Time (ms) | Files Found | Relevant | Total Lines |
|----------|-----------|-------------|----------|-------------|
| A1: forge cache | 55 | 13 | 2 | 1,999 |
| A2: podman orchestration | 35 | 34 | 6 | 7,318 |
| A3: tray app lifecycle | 32 | 35 | 14 | 6,845 |
| B1: forge isolation | 34 | 70 | 8 | 13,462 |
| B2: async inference | 27 | 100 | 5 | 18,355 |
| B3: browser+enclave CA | 35 | 34 | 14 | 5,294 |
| C1: Python testing | 14 | 0 | 0 | 0 |
| C2: AWS Lambda | 16 | 0 | 0 | 0 |

Average filesystem query time: ~33ms (but returns 100+ files / 18k+ lines for broad queries)

### L0 Expert (plan_answer — deterministic, no model)
- All spec-level queries correctly returned `unsupported` (plan_answer is for plan/methodology, not specs)
- Average response time: ~450ms (mostly binary startup overhead)
- Correct behavior: L0 refuses what L1 should answer

### L1 Synthesis WITHOUT RAG Context (hallucination test)

#### qwen2.5:0.5b
| Query | Time (ms) | Gen tok/s | Quality |
|-------|-----------|-----------|---------|
| Forge cache architecture | 5,852 | 33.7 | HALLUCINATED — "blockchain platform" |
| Podman orchestration | 13,953 | 30.0 | HALLUCINATED — generic container talk |
| Tray app lifecycle | 12,712 | 37.9 | HALLUCINATED — generic tray description |
| Forge isolation | 10,994 | 36.5 | HALLUCINATED — "metal casing" |
| Async inference | 13,333 | 30.6 | HALLUCINATED — "MLM model types" |
| Browser isolation + CA | 12,984 | 38.7 | HALLUCINATED — vague security talk |

#### qwen2.5:1.5b
| Query | Time (ms) | Gen tok/s | Quality |
|-------|-----------|-----------|---------|
| Forge cache architecture | 16,696 | 11.3 | HALLUCINATED — "Alibaba Cloud" |
| Podman orchestration | 43,219 | 12.1 | HALLUCINATED — "Docker and Kubernetes" |
| Tray app lifecycle | 28,039 | 17.1 | HALLUCINATED — generic lifecycle |
| Forge isolation | 42,257 | 11.7 | HALLUCINATED — "hypervisor" |
| Async inference | 21,008 | 11.7 | HALLUCINATED — generic inference talk |
| Browser isolation + CA | 23,160 | 18.6 | HALLUCINATED — vague security |

### Key Findings

1. **Both models hallucinate wildly without RAG context.** The0.5b invents "blockchain" for a forge cache question; the1.5b invents "Alibaba Cloud". Neither has meaningful knowledge of this project's specs.

2. **0.5b is 3-4x faster but equally useless.** Generation at 128 tok/s vs 18 tok/s doesn't matter when every token is fabricated.

3. **1.5b is3x slower and still hallucinates.** The larger model produces more structured but equally wrong answers. Without RAG context, model size doesn't help.

4. **The RAG pipeline is essential.** The synthesis model MUST receive retrieved spec chunks in its context window to produce grounded answers. This is by design (order 547/548).

5. **CPU-only embedding is very slow.** nomic-embed-text at ~19 chunks/sec means a full index build takes ~60 minutes. GPU-accelerated hosts would complete this in ~2 minutes.

6. **Filesystem search is fast but imprecise.** rg returns results in 30-55ms but a broad query like "async inference" matches100 files (18k lines) — an agent would need to read all of them to answer, which is exactly what RAG avoids.

7. **Container RAM severely limits model options.** 3.8 GiB total means 7b models are impossible. 3b is the theoretical ceiling but would leave <1 GB for OS+KV cache. 1.5b is the practical maximum.

8. **Host resources are under-provisioned.** The host has 16 GB RAM and10 CPU cores but only 4 cores and 3.8 GiB are allocated to the forge container. Half the host's RAM (8 GB) and6+ cores would enable 3b models and much faster embedding.
