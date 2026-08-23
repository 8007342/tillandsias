# At the floor, "which runtime" is the wrong question: Fedora's llama.cpp is 13x slower than ollama on identical weights, and the entire gap is build-time CPU dispatch

- classification: research
- filed: 2026-08-23 (windows/ESMERALDINHA), at `windows-next` `ab6abb327`
- closes: **858-tnnv** residual 1 / 855-wrr3 exit criterion 5 — "at least one
  alternative low-end runtime evaluated against ollama on the same model and
  prompt, or an explicit finding that none is available without layering"
- related: 858-ihcb (the harness this used, fixed the same day),
  `plan/issues/research/esmeraldinha-wsl2-cpu-inference-floor-2026-08-23.md`
  (the floor numbers this compares against),
  `plan/issues/research/engine-parity-ollama-vs-llamacpp-2026-08-17.md`
  (the earlier bare-metal comparison)

## Answer to the criterion, first

An alternative IS available without layering: **`llama-cpp b6153-3.fc44` is
packaged in Fedora 44** and installs with one `dnf install`. Two alternatives
were evaluated against ollama on the same model and the same prompt:

1. **Fedora's stock `llama-cpp`** — the obvious "leaner runtime" candidate.
2. **ollama's own bundled `/usr/lib/ollama/llama-server`, run directly** —
   same engine, same weights, without the ollama process around it. This
   isolates the ollama layer from the engine, which the first comparison
   cannot.

All three ran the **identical GGUF blob**
(`sha256-c5396e06…`, qwen2.5:0.5b Q4_K_M, 373.71 MiB, 494.03 M params) pulled
straight out of ollama's blob store, on 4 threads, CPU-only, on an idle box.

## The dominant result

| engine | prefill tok/s | decode tok/s |
|---|---:|---:|
| ollama (HTTP API) | **~125** (at 80 prompt tok) | **28.99** |
| ollama's bundled llama-server, direct | 59-91 (at 51 prompt tok) | **29.52** |
| **Fedora stock `llama-cpp`, `-ngl 0`** | **9.77** ± 0.04 (pp128) | **7.22** ± 0.38 (tg200) |

> Fedora's package is **~12.8x slower on prefill and 4.0x slower on decode**
> than ollama, running the same weights on the same cores.

And the gap is not the engine. Both ARE llama.cpp.

## The cause, with direct evidence

`llama-cli` prints what its ggml build dispatches to. Fedora's says:

```
system_info: n_threads = 4 (n_threads_batch = 4) / 4 |
  ROCm : NO_VMM = 1 | PEER_MAX_BATCH_SIZE = 128 |
  CPU : LLAMAFILE = 1 | REPACK = 1 |
```

**No AVX. No AVX2. No FMA. No AVX_VNNI.** This host's own capability row lists
`fma, avx, avx2, avx_vnni`; the distro build is discarding all of them.

ollama, by contrast, ships **17 microarchitecture-specific ggml builds** and
picks one at runtime:

```
libggml-cpu-alderlake.so      libggml-cpu-haswell.so     libggml-cpu-sapphirerapids.so
libggml-cpu-cannonlake.so     libggml-cpu-icelake.so     libggml-cpu-skylakex.so
libggml-cpu-cascadelake.so    libggml-cpu-ivybridge.so   libggml-cpu-sse42.so
libggml-cpu-cooperlake.so     libggml-cpu-piledriver.so  libggml-cpu-x64.so
libggml-cpu-sandybridge.so    libggml-cpu-zen4.so        (+ cuda_v12, cuda_v13, vulkan)
```

Verified by inspecting the running process rather than inferring it — the live
runner's memory map carries exactly one of them:

```
llama-server: libggml-cpu-alderlake.so
```

**Alder Lake is precisely this host's microarchitecture** (Intel N100 = 4
Alder Lake-N E-cores). ollama dispatched to the best available match; Fedora
shipped a generic baseline.

### A second trap in the same package

Fedora's build is ROCm/HIP-enabled, so it defaults to `ngl 99` and announces
`ggml_cuda_init: failed to initialize ROCm: no ROCm-capable device is detected`
before falling back. On a CPU-only host that line invites the wrong diagnosis
("GPU missing") when the real problem is the CPU path. Forcing `-ngl 0` changes
essentially nothing — 9.71 t/s at the default vs 9.77 with offload disabled —
which is itself the proof that offload was never the issue.

## Does the ollama LAYER cost anything? Barely, and it is not what you'd guess

Same user prompt, both servers, unique-first prompts, three reps:

| | prompt tokens | prefill tok/s | wall time-to-first-token |
|---|---:|---:|---:|
| ollama HTTP API | 80 | 124.86 / 125.10 / 125.17 | 1091 / 1191 / 1131 ms |
| bare llama-server | 51 | 61.9 / 62.0 / 58.7 | 841 / 844 / 904 ms |

- **Decode is at parity**: 29.52 vs 28.99, a 1.8% difference. The ollama
  process costs nothing measurable on generation.
- **Wall-clock TTFT favours the bare server by ~25%** (844 vs 1131 ms median),
  and the reason is token count, not speed: ollama applies the model's chat
  template, turning a 51-token user prompt into 80 tokens — **57% more tokens
  to process** for the same request.

So the honest framing for a scheduler: if you need the chat template, ollama is
not costing you anything worth reclaiming. If your workload is
template-free — which the 853-6gz3 unfold-and-verify sub-queries largely are —
a bare llama-server saves roughly a quarter of time-to-first-token. Against the
measured ~2.3 s per sub-query that is ~0.3 s: real, worth having, not
transformative.

### One number I am NOT claiming

ollama's per-token prefill (125 tok/s) reads as 2x the bare server's (~60-90),
on the same ggml. I could not attribute that and I am not going to guess:

- The bare server's prefill was **noisy across runs** — 58.7 to 91.5 tok/s
  across three sessions with different flags (±35%) — while ollama's was
  extraordinarily tight (124.86-125.17, ±0.1%).
- Adding `-b 512 -ub 512 -tb 4` and dropping `cache_prompt:false` moved the
  bare server from ~61 to ~87, but that changed two variables at once, so it
  attributes nothing.
- The prompt lengths differ (51 vs 80), and prefill throughput rises with
  prompt length as fixed cost amortises, which biases the comparison toward
  ollama.

The wall-clock TTFT column above is not subject to any of that, which is why
the recommendation rests on it.

## What this means for the fleet

1. **Do not swap ollama for a distro-packaged llama.cpp at the floor.** The
   naive read — "ollama is a wrapper, the bare engine must be leaner" — is a
   **12.8x prefill regression** here, and it would have looked like a
   reasonable simplification in a design review.
2. **Engine selection on CPU-only hosts is a packaging question, not a runtime
   question.** The variable that mattered by an order of magnitude was whether
   the ggml build dispatches to the host microarchitecture. Any future engine
   candidate should be checked with `llama-cli … | grep system_info` (or the
   equivalent) BEFORE it is benchmarked — a build without AVX2 on an AVX2 host
   is not a candidate, it is a misconfiguration.
3. **This is a floor-only finding by construction.** On a host with a real GPU
   the CPU dispatch is irrelevant because the weights are not on the CPU. It is
   visible here precisely because this host is the fleet's lower bound, which
   is the mandate working as intended.

## Reproduction

```bash
# in the runtime tillandsias WSL2 distro
dnf install -y llama-cpp
BLOB=/root/.ollama/models/blobs/sha256-c5396e06af294bd101b30dce59131a76d2b773e76950acc870eda801d3ab0515

# Fedora build, forced CPU
llama-bench -m "$BLOB" -t 4 -ngl 0 -p 128 -n 200 -r 3

# what it dispatches to
llama-cli -m "$BLOB" -ngl 0 -p hi -n 1 --no-warmup 2>&1 | grep system_info

# what ollama dispatches to, read from the live process
for p in /proc/[0-9]*; do grep -oE 'libggml-cpu-[a-z0-9]+\.so' "$p/maps" 2>/dev/null; done | sort -u

# the bare engine, same weights, no ollama
LD_LIBRARY_PATH=/usr/lib/ollama /usr/lib/ollama/llama-server \
  -m "$BLOB" -ngl 0 -t 4 --host 127.0.0.1 --port 11435 --no-webui
```

## Caveat on durability

`llama-cpp` was installed into the RUNTIME `tillandsias` distro, and this
host's 2026-08-16 record already establishes that destructive smoke e2e
unregisters that distro on every run. The package will not survive one. That is
fine for a measurement and is NOT a recommendation to provision it there — the
finding above argues against adopting it at all.
