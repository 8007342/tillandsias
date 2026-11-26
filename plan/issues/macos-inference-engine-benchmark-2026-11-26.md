# macOS inference engine benchmark — base M5 16 GB — 2026-11-26

Order **2381-tfna** (from ruling 2381-778w). Same shape as doris's XDNA 2 row **2392-bj3a**, so the two sit side by side for 2381-zueb and 2381-iy9u.

## Host and engines

- Apple M5 (base), 16 GB unified memory, macOS 27.2.1, tlatoanis-macbook-air. Quiet host: the Tillandsias VM was down, with no forks or builds running.
- **Ollama 0.40.18**, MLX engine (log: `mlx runner is ready`). Tags `qwen3.5:{0.8b,2b,4b}-nvfp4` are **nvfp4**. The default `-mlx` tags are **mxfp8** at 0.8B and 2B; they are measured as supplementary rows. `qwen3-embedding:0.6b` is Q8_0 GGUF, served by Ollama's llama.cpp path. Requests pass `num_ctx 8192` and `think:false`.
- **mlx_lm.server 0.32.2**, mlx 0.32.5. Models: `mlx-community/Qwen3.5-{0.8B,2B,4B}-4bit`, with `enable_thinking:false`.
- **llama-server** build 12359 (b1b770d90). Models: `unsloth/Qwen3.5-{0.8B,2B,4B}-GGUF` Q4_K_M, with `-ngl 99 -c 8192 --reasoning off`. `Qwen/Qwen3-Embedding-0.6B-GGUF` Q8_0, with `--embedding --pooling last`.
- Licences: every model is Apache-2.0 and ungated, checked on the Hugging Face API. One exception: the mlx-community 4B card names no licence, but it is a 4-bit repack of the Apache-2.0 base.
- **Skipped: EmbeddingGemma** (`google/embeddinggemma-300m`, `gated=manual`, Gemma licence). It needs a click-through, so it was not pulled.
- **Not served: embeddings on mlx_lm.server.** mlx_lm has no embeddings endpoint, and mlx-embeddings is not installed.
- **Power: not reported.** `powermetrics` needs root. No figure is estimated.

## Method

- Harness: `bench.py`, standard library only. The same client-side instrument is used for every engine. Each engine/model pair runs on its own, followed by a 20 s settle; servers are stopped by PID.
- One warm-up request, which loads the model and is excluded. Then three runs of each of two prompts:
  - **short**: 66–70 prompt tokens.
  - **long**: about 2,208 prompt tokens (a build log to summarise).
- Every request starts with a fresh nonce, so no prompt cache serves it. Settings: temperature 0, seed 1, max 256 output tokens. Every run produced exactly 256 tokens.
- **TTFT**: time from send to the first content chunk.
- **Prefill tok/s**: prompt tokens ÷ TTFT, on the long prompt.
- **Decode tok/s**: (completion tokens − 1) ÷ (end − first chunk).
- Values are medians of three runs. Each run also records the engine's own counters (raw below).
- **Memory, MLX and Ollama:** `footprint` phys_footprint of the serving process after the runs, which counts Metal buffers. Peak is shown in brackets.
- **Memory, llama-server:** RSS after the same load, re-measured separately. llama.cpp memory-maps its weights, and footprint leaves out clean file-backed pages. Measured on 2B: footprint 335 MB against RSS 1593 MB. So the footprint column under-reports llama.cpp and is not used for it.

## Chat (Qwen3.5, 4-bit class)

| Model | Engine | Decode tok/s (short / long) | TTFT short | TTFT long | Prefill tok/s (long) | Memory MB |
|---|---|---|---|---|---|---|
| 0.8B | Ollama-MLX nvfp4 | 133.9 / 132.0 | 0.0 s | 0.3 s | 6450 | 1540 (2816) |
| 0.8B | mlx_lm 4bit | **199.5 / 190.5** | 0.0 s | 0.3 s | **7160** | 1223 (2431) |
| 0.8B | llama Q4_K_M | 159.9 / 152.8 | 0.0 s | 0.5 s | 4344 | RSS 1262 |
| 0.8B | Ollama-MLX mxfp8 (`-mlx` default) | 109.3 / 106.2 | 0.0 s | 0.4 s | 5919 | 1781 (2955) |
| 2B | Ollama-MLX nvfp4 | 65.8 / 64.7 | 0.1 s | 0.7 s | 3368 | 2918 (4022) |
| 2B | mlx_lm 4bit | **99.9 / 96.9** | 0.1 s | 0.6 s | **3584** | 1831 (2936) |
| 2B | llama Q4_K_M | 81.6 / 79.8 | 0.1 s | 0.9 s | 2368 | RSS 1979 |
| 2B | Ollama-MLX mxfp8 (`-mlx` default) | 49.4 / 49.0 | 0.1 s | 0.7 s | 3009 | 3550 (4654) |
| 4B | Ollama-MLX nvfp4 | 35.6 / 34.6 | 0.2 s | 1.7 s | 1334 | 4968 (6479) |
| 4B | mlx_lm 4bit | **46.9 / 45.2** | 0.1 s | 1.5 s | **1437** | 3324 (4807) |
| 4B | llama Q4_K_M | 39.8 / 39.0 | 0.1 s | 2.5 s | 890 | RSS 4275 |

## Embeddings (Qwen3-Embedding-0.6B, Q8_0, dim 1024)

Batch of 64 passages, about 88 tokens each. Median of three runs.

| Engine | Inputs/s | Tokens/s | Memory MB |
|---|---|---|---|
| Ollama (llama.cpp path) | 47.4 | 4168 | 1000 |
| llama-server | **75.4** | **6599** | RSS 1668 (footprint 1018) |
| mlx_lm.server | not served | — | — |
| EmbeddingGemma | skipped: gated (Gemma terms) | — | — |

## Reading (measurements only; the engine choice belongs to 2381-iy9u)

- **mlx_lm.server is fastest at every size**, both decode and prefill.
  - Decode: about 1.25× llama.cpp, and 1.3–1.5× Ollama-MLX nvfp4.
  - Prefill: 1.6× llama.cpp at 4B.
  - It also has the smallest MLX footprint.
- **Ollama-MLX trails mlx_lm on the same engine family.**
  - Its runner reports `drafting=shared-verification`.
  - The gap may come from model packaging (nvfp4 against affine 4-bit) or from scheduler overhead. That is unmeasured.
  - Its default `-mlx` tags (mxfp8) are slower again and larger.
- **llama.cpp sits in the middle on decode and is weakest on prefill.** It is fastest for embeddings: 1.6× Ollama.
- **Memory reserves for 2381-zueb** (resident, after load, at an 8k context):
  - mlx_lm: about 1.2 / 1.8 / 3.3 GB.
  - llama.cpp RSS: about 1.3 / 2.0 / 4.3 GB.
  - Ollama-MLX: about 1.5 / 2.9 / 5.0 GB.
  - Embedding: about 1.0–1.7 GB.
  - The 4B model on Ollama peaks at 6.5 GB of the 16 GB.

## Raw runs

`runs.jsonl`, 85 lines, one per measured run plus one memory line per engine/model. llama-server memory lines there are footprint; see the RSS note above.

```jsonl
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "prompt": "short", "run": 1, "ttft_s": 0.042114000068977475, "prefill_tps": 1614.6649543767985, "decode_tps": 134.22400466646724, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 1.9419232080690563, "engine_reported": {"decode_tps": 134.22458394152733, "prefill_tps": 2224.018007742984}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "prompt": "short", "run": 2, "ttft_s": 0.03767308313399553, "prefill_tps": 1831.5464055485177, "decode_tps": 133.91286677588894, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 1.941896375035867, "engine_reported": {"decode_tps": 133.93747043179923, "prefill_tps": 2618.144630179672}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "prompt": "short", "run": 3, "ttft_s": 0.03681316692382097, "prefill_tps": 1928.6577584298377, "decode_tps": 133.93245200852817, "prompt_tokens": 71, "completion_tokens": 256, "wall_s": 1.9407580001279712, "engine_reported": {"decode_tps": 133.97053361444245, "prefill_tps": 2760.5647493378046}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "prompt": "long", "run": 1, "ttft_s": 0.3420125001575798, "prefill_tps": 6450.056647004427, "decode_tps": 131.9731217381624, "prompt_tokens": 2206, "completion_tokens": 256, "wall_s": 2.2742241250816733, "engine_reported": {"decode_tps": 131.98373944863147, "prefill_tps": 6689.089124113569}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "prompt": "long", "run": 2, "ttft_s": 0.42179729091003537, "prefill_tps": 5237.112820791338, "decode_tps": 132.26993203575492, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 2.349673083052039, "engine_reported": {"decode_tps": 132.27852686079854, "prefill_tps": 5379.643565128025}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "prompt": "long", "run": 3, "ttft_s": 0.3327240420039743, "prefill_tps": 6639.135503089416, "decode_tps": 131.35975463317192, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 2.2739578750915825, "engine_reported": {"decode_tps": 131.36491782164555, "prefill_tps": 6880.427651750378}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-nvfp4", "ts": "2026-11-26T13:44:50Z", "memory": {"footprint_mb": 1540.0, "peak_footprint_mb": 2816.0, "pids_arg": ["children:90643"]}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "prompt": "short", "run": 1, "ttft_s": 0.20458245812915266, "prefill_tps": 327.49630937420346, "decode_tps": 65.84607608277686, "prompt_tokens": 67, "completion_tokens": 256, "wall_s": 4.077250583097339, "engine_reported": {"decode_tps": 65.84560216969757, "prefill_tps": 366.4668261074489}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "prompt": "short", "run": 2, "ttft_s": 0.05766829219646752, "prefill_tps": 1127.135857926127, "decode_tps": 65.80353362146448, "prompt_tokens": 65, "completion_tokens": 256, "wall_s": 3.932840125169605, "engine_reported": {"decode_tps": 65.80142082231984, "prefill_tps": 1680.514798044522}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "prompt": "short", "run": 3, "ttft_s": 0.05913770804181695, "prefill_tps": 1132.9488784486462, "decode_tps": 65.77411832870041, "prompt_tokens": 67, "completion_tokens": 256, "wall_s": 3.9360425830818713, "engine_reported": {"decode_tps": 65.77159630783508, "prefill_tps": 1709.3363363906556}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "prompt": "long", "run": 1, "ttft_s": 0.6547844589222223, "prefill_tps": 3367.520364837978, "decode_tps": 64.70502118656854, "prompt_tokens": 2205, "completion_tokens": 256, "wall_s": 4.595745999831706, "engine_reported": {"decode_tps": 64.70145680005676, "prefill_tps": 3477.801644767694}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "prompt": "long", "run": 2, "ttft_s": 0.6547911670058966, "prefill_tps": 3375.1218882586095, "decode_tps": 64.68925018114534, "prompt_tokens": 2210, "completion_tokens": 256, "wall_s": 4.596713500097394, "engine_reported": {"decode_tps": 64.686470353424, "prefill_tps": 3485.191253623326}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "prompt": "long", "run": 3, "ttft_s": 0.6560160832013935, "prefill_tps": 3367.295492543357, "decode_tps": 64.57581025193697, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 4.604863167041913, "engine_reported": {"decode_tps": 64.57195891130475, "prefill_tps": 3476.5005082560333}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-nvfp4", "ts": "2026-11-26T13:45:25Z", "memory": {"footprint_mb": 2918.0, "peak_footprint_mb": 4022.0, "pids_arg": ["children:90643"]}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "prompt": "short", "run": 1, "ttft_s": 0.22554145799949765, "prefill_tps": 301.49667650082966, "decode_tps": 35.61492058519563, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 7.385461957892403, "engine_reported": {"decode_tps": 35.614850779977225, "prefill_tps": 364.98562375302396}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "prompt": "short", "run": 2, "ttft_s": 0.1329553339164704, "prefill_tps": 503.92863547763307, "decode_tps": 35.58244316858809, "prompt_tokens": 67, "completion_tokens": 256, "wall_s": 7.2994109590072185, "engine_reported": {"decode_tps": 35.58206192827763, "prefill_tps": 714.3510796942112}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "prompt": "short", "run": 3, "ttft_s": 0.17853874992579222, "prefill_tps": 375.26867432334916, "decode_tps": 35.59082525821144, "prompt_tokens": 67, "completion_tokens": 256, "wall_s": 7.343306584050879, "engine_reported": {"decode_tps": 35.59037955065678, "prefill_tps": 479.9358175384307}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "prompt": "long", "run": 1, "ttft_s": 1.7180950839538127, "prefill_tps": 1285.1442394671083, "decode_tps": 34.619302002754296, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 9.083928166888654, "engine_reported": {"decode_tps": 34.618710540385116, "prefill_tps": 1317.3284096593047}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "prompt": "long", "run": 2, "ttft_s": 1.65659987507388, "prefill_tps": 1333.454163095047, "decode_tps": 34.635437319430835, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 9.01900149998255, "engine_reported": {"decode_tps": 34.635540983891595, "prefill_tps": 1368.1600639159788}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "prompt": "long", "run": 3, "ttft_s": 1.6461279999930412, "prefill_tps": 1341.3294713469027, "decode_tps": 34.61817188554975, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 9.012201542034745, "engine_reported": {"decode_tps": 34.61818096240465, "prefill_tps": 1376.2568686109994}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:4b-nvfp4", "ts": "2026-11-26T13:46:16Z", "memory": {"footprint_mb": 4968.0, "peak_footprint_mb": 6479.0, "pids_arg": ["children:90643"]}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "prompt": "short", "run": 1, "ttft_s": 0.04925362509675324, "prefill_tps": 1380.6090387544389, "decode_tps": 109.27918485831387, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 2.38272637501359, "engine_reported": {"decode_tps": 109.32014559436344, "prefill_tps": 1935.734083881962}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "prompt": "short", "run": 2, "ttft_s": 0.045090417144820094, "prefill_tps": 1419.3703241743508, "decode_tps": 109.19571362156607, "prompt_tokens": 64, "completion_tokens": 256, "wall_s": 2.3803469170816243, "engine_reported": {"decode_tps": 109.26119712087817, "prefill_tps": 2102.652134274051}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "prompt": "short", "run": 3, "ttft_s": 0.04446387500502169, "prefill_tps": 1529.3313952578396, "decode_tps": 109.27161438201041, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 2.3780982908792794, "engine_reported": {"decode_tps": 109.3252537666118, "prefill_tps": 2330.809215484923}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "prompt": "long", "run": 1, "ttft_s": 0.37994024995714426, "prefill_tps": 5806.176103344745, "decode_tps": 106.36805377852181, "prompt_tokens": 2206, "completion_tokens": 256, "wall_s": 2.7772765830159187, "engine_reported": {"decode_tps": 106.43386847827843, "prefill_tps": 6071.8103096658215}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "prompt": "long", "run": 2, "ttft_s": 0.3652731250040233, "prefill_tps": 6039.316470314377, "decode_tps": 106.20277666438248, "prompt_tokens": 2206, "completion_tokens": 256, "wall_s": 2.7663402911275625, "engine_reported": {"decode_tps": 106.23231848127729, "prefill_tps": 6365.826534834036}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "prompt": "long", "run": 3, "ttft_s": 0.3727177500259131, "prefill_tps": 5918.687800209752, "decode_tps": 106.12987424919767, "prompt_tokens": 2206, "completion_tokens": 256, "wall_s": 2.77543425001204, "engine_reported": {"decode_tps": 106.19812646211122, "prefill_tps": 6243.1105746576695}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:0.8b-mlx", "ts": "2026-11-26T13:47:34Z", "memory": {"footprint_mb": 1781.0, "peak_footprint_mb": 2955.0, "pids_arg": ["children:90643"]}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "prompt": "short", "run": 1, "ttft_s": 0.09047950012609363, "prefill_tps": 762.6036826445829, "decode_tps": 49.44945985090263, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 5.247259791940451, "engine_reported": {"decode_tps": 49.45594277544664, "prefill_tps": 1086.912997277267}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "prompt": "short", "run": 2, "ttft_s": 0.093856249935925, "prefill_tps": 756.4759943900507, "decode_tps": 49.45866480844077, "prompt_tokens": 71, "completion_tokens": 256, "wall_s": 5.24967679195106, "engine_reported": {"decode_tps": 49.46428385571769, "prefill_tps": 1103.7899436123466}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "prompt": "short", "run": 3, "ttft_s": 0.07450562482699752, "prefill_tps": 872.4173530646897, "decode_tps": 49.34297093233753, "prompt_tokens": 65, "completion_tokens": 256, "wall_s": 5.242414957843721, "engine_reported": {"decode_tps": 49.34732817032003, "prefill_tps": 1440.9568166080514}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "prompt": "long", "run": 1, "ttft_s": 0.7337267498951405, "prefill_tps": 3009.2946731403117, "decode_tps": 48.82739729150193, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 5.956204582937062, "engine_reported": {"decode_tps": 48.830978115085394, "prefill_tps": 3142.532642203872}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "prompt": "long", "run": 2, "ttft_s": 0.8349250829778612, "prefill_tps": 2644.548648754091, "decode_tps": 49.100278316865136, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 6.028378332965076, "engine_reported": {"decode_tps": 49.09872788024993, "prefill_tps": 2743.9196328507282}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "prompt": "long", "run": 3, "ttft_s": 0.7065123750362545, "prefill_tps": 3122.3798449203377, "decode_tps": 49.04556882605715, "prompt_tokens": 2206, "completion_tokens": 256, "wall_s": 5.9057588330470026, "engine_reported": {"decode_tps": 49.04475364729817, "prefill_tps": 3244.6301888838225}}
{"mode": "chat", "engine": "ollama", "model": "qwen3.5:2b-mlx", "ts": "2026-11-26T13:48:12Z", "memory": {"footprint_mb": 3550.0, "peak_footprint_mb": 4654.0, "pids_arg": ["children:90643"]}}
{"mode": "embed", "engine": "ollama", "model": "qwen3-embedding:0.6b", "ts": "2026-11-26T13:49:12Z", "run": 1, "inputs": 64, "dim": 1024, "wall_s": 1.3500722921453416, "inputs_per_s": 47.404868889132125, "tokens": 5627, "tokens_per_s": 4167.924956861663}
{"mode": "embed", "engine": "ollama", "model": "qwen3-embedding:0.6b", "ts": "2026-11-26T13:49:12Z", "run": 2, "inputs": 64, "dim": 1024, "wall_s": 1.3485765419900417, "inputs_per_s": 47.45744717282246, "tokens": 5635, "tokens_per_s": 4178.479919044603}
{"mode": "embed", "engine": "ollama", "model": "qwen3-embedding:0.6b", "ts": "2026-11-26T13:49:12Z", "run": 3, "inputs": 64, "dim": 1024, "wall_s": 1.3553660411853343, "inputs_per_s": 47.219716338789816, "tokens": 5620, "tokens_per_s": 4146.481340999981}
{"mode": "embed", "engine": "ollama", "model": "qwen3-embedding:0.6b", "ts": "2026-11-26T13:49:12Z", "memory": {"footprint_mb": 1000.0, "peak_footprint_mb": 1000.0, "pids_arg": ["children:90643"]}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "prompt": "short", "run": 1, "ttft_s": 0.02583066583611071, "prefill_tps": 2632.5298941747556, "decode_tps": 199.08467890029624, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 1.3066926659084857, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "prompt": "short", "run": 2, "ttft_s": 0.025882292073220015, "prefill_tps": 2665.91536038623, "decode_tps": 199.8152819889113, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 1.3020609579980373, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "prompt": "short", "run": 3, "ttft_s": 0.02593987504951656, "prefill_tps": 2698.548079602434, "decode_tps": 199.50156546817593, "prompt_tokens": 70, "completion_tokens": 256, "wall_s": 1.3041253339033574, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "prompt": "long", "run": 1, "ttft_s": 0.4029263339471072, "prefill_tps": 5477.428040952311, "decode_tps": 190.5160607188411, "prompt_tokens": 2207, "completion_tokens": 256, "wall_s": 1.741396167082712, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "prompt": "long", "run": 2, "ttft_s": 0.3041950410697609, "prefill_tps": 7261.788332352897, "decode_tps": 189.09954226596713, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 1.6526911661494523, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "prompt": "long", "run": 3, "ttft_s": 0.30825037485919893, "prefill_tps": 7159.764204692703, "decode_tps": 190.68968215097183, "prompt_tokens": 2207, "completion_tokens": 256, "wall_s": 1.6455015419051051, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-0.8B-4bit", "ts": "2026-11-26T13:49:39Z", "memory": {"footprint_mb": 1223.0, "peak_footprint_mb": 2431.0, "pids_arg": ["91179"]}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "prompt": "short", "run": 1, "ttft_s": 0.05008016596548259, "prefill_tps": 1417.7269310356571, "decode_tps": 100.13925738105486, "prompt_tokens": 71, "completion_tokens": 256, "wall_s": 2.5965340409893543, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "prompt": "short", "run": 2, "ttft_s": 0.05020516598597169, "prefill_tps": 1354.4422902416165, "decode_tps": 99.9198893598568, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 2.6022496251389384, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "prompt": "short", "run": 3, "ttft_s": 0.05046491604298353, "prefill_tps": 1406.91802478232, "decode_tps": 99.8714693420838, "prompt_tokens": 71, "completion_tokens": 256, "wall_s": 2.603746665874496, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "prompt": "long", "run": 1, "ttft_s": 0.6117053749039769, "prefill_tps": 3604.6765166092127, "decode_tps": 97.30088459685149, "prompt_tokens": 2205, "completion_tokens": 256, "wall_s": 3.2324420830700547, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "prompt": "long", "run": 2, "ttft_s": 0.6166561669670045, "prefill_tps": 3583.844804260671, "decode_tps": 96.85650014313408, "prompt_tokens": 2210, "completion_tokens": 256, "wall_s": 3.2494169999845326, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "prompt": "long", "run": 3, "ttft_s": 0.617931375047192, "prefill_tps": 3574.8306190655826, "decode_tps": 96.8769023662974, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 3.2501377500593662, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-2B-4bit", "ts": "2026-11-26T13:50:48Z", "memory": {"footprint_mb": 1831.0, "peak_footprint_mb": 2936.0, "pids_arg": ["91189"]}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "prompt": "short", "run": 1, "ttft_s": 0.11134858406148851, "prefill_tps": 619.6755942751555, "decode_tps": 46.948645294777606, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 5.54281520890072, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "prompt": "short", "run": 2, "ttft_s": 0.1112163751386106, "prefill_tps": 620.412236183784, "decode_tps": 46.8817755288788, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 5.550430166069418, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "prompt": "short", "run": 3, "ttft_s": 0.11169291706755757, "prefill_tps": 626.7183438110085, "decode_tps": 46.835098328887646, "prompt_tokens": 70, "completion_tokens": 256, "wall_s": 5.556327584199607, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "prompt": "long", "run": 1, "ttft_s": 1.5310490420088172, "prefill_tps": 1442.1484481666162, "decode_tps": 45.1512510435637, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 7.178733084117994, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "prompt": "long", "run": 2, "ttft_s": 1.5370374170597643, "prefill_tps": 1436.5297653089904, "decode_tps": 45.22941991942117, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 7.174960708012804, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "prompt": "long", "run": 3, "ttft_s": 1.540755124995485, "prefill_tps": 1434.3616088938702, "decode_tps": 45.18473880066661, "prompt_tokens": 2210, "completion_tokens": 256, "wall_s": 7.184253500076011, "engine_reported": {}}
{"mode": "chat", "engine": "mlx", "model": "mlx-community/Qwen3.5-4B-4bit", "ts": "2026-11-26T13:52:05Z", "memory": {"footprint_mb": 3324.0, "peak_footprint_mb": 4807.0, "pids_arg": ["91211"]}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "prompt": "short", "run": 1, "ttft_s": 0.03949633287265897, "prefill_tps": 1746.997631969137, "decode_tps": 160.07372179574875, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 1.6325123328715563, "engine_reported": {"decode_tps": 160.0848763736695, "prefill_tps": 1888.7550640534328}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "prompt": "short", "run": 2, "ttft_s": 0.03913445887155831, "prefill_tps": 1763.1520146084613, "decode_tps": 159.09572483581235, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 1.641943084076047, "engine_reported": {"decode_tps": 159.10491939931967, "prefill_tps": 1898.629684662374}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "prompt": "short", "run": 3, "ttft_s": 0.04489074996672571, "prefill_tps": 1492.5123783777792, "decode_tps": 159.9238428312077, "prompt_tokens": 67, "completion_tokens": 256, "wall_s": 1.6393997080158442, "engine_reported": {"decode_tps": 159.92965603834799, "prefill_tps": 1601.9127316198446}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "prompt": "long", "run": 1, "ttft_s": 0.7317629579920322, "prefill_tps": 3018.7371140806677, "decode_tps": 148.62265772135896, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 2.447517499793321, "engine_reported": {"decode_tps": 148.62521674510776, "prefill_tps": 3037.749782379401}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "prompt": "long", "run": 2, "ttft_s": 0.5084019999485463, "prefill_tps": 4344.986841561531, "decode_tps": 152.80210596215184, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 2.1772271669469774, "engine_reported": {"decode_tps": 152.80102250848944, "prefill_tps": 4390.550279651618}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "prompt": "long", "run": 3, "ttft_s": 0.5082696250174195, "prefill_tps": 4344.1510004150405, "decode_tps": 152.91617137876392, "prompt_tokens": 2208, "completion_tokens": 256, "wall_s": 2.1758499580901116, "engine_reported": {"decode_tps": 152.9186778471209, "prefill_tps": 4393.041962702914}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-0.8B", "ts": "2026-11-26T13:53:16Z", "memory": {"footprint_mb": 720.0, "peak_footprint_mb": 720.0, "pids_arg": ["91229"]}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "prompt": "short", "run": 1, "ttft_s": 0.12611775007098913, "prefill_tps": 539.1786640795937, "decode_tps": 81.6758801609089, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 3.2482145000249147, "engine_reported": {"decode_tps": 81.67605674404005, "prefill_tps": 551.8719007929101}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "prompt": "short", "run": 2, "ttft_s": 0.0695869589690119, "prefill_tps": 991.5651010231201, "decode_tps": 81.55066510765016, "prompt_tokens": 69, "completion_tokens": 256, "wall_s": 3.196477459045127, "engine_reported": {"decode_tps": 81.55339060620074, "prefill_tps": 1037.3132084548542}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "prompt": "short", "run": 3, "ttft_s": 0.06920400005765259, "prefill_tps": 982.6021609061678, "decode_tps": 81.44958326076747, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 3.199975083116442, "engine_reported": {"decode_tps": 81.45262938670322, "prefill_tps": 1024.4512406405834}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "prompt": "long", "run": 1, "ttft_s": 0.9329145841766149, "prefill_tps": 2368.919982048017, "decode_tps": 79.7864341564568, "prompt_tokens": 2210, "completion_tokens": 256, "wall_s": 4.128946625161916, "engine_reported": {"decode_tps": 79.78758355011568, "prefill_tps": 2379.788381894656}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "prompt": "long", "run": 2, "ttft_s": 0.9328984580934048, "prefill_tps": 2367.8890031768365, "decode_tps": 79.75171777560608, "prompt_tokens": 2209, "completion_tokens": 256, "wall_s": 4.130321750184521, "engine_reported": {"decode_tps": 79.75282254621676, "prefill_tps": 2381.373326893887}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "prompt": "long", "run": 3, "ttft_s": 0.9389936670195311, "prefill_tps": 2350.388588887143, "decode_tps": 79.89885954494538, "prompt_tokens": 2207, "completion_tokens": 256, "wall_s": 4.130528583191335, "engine_reported": {"decode_tps": 79.89990891410385, "prefill_tps": 2363.370013578401}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-2B", "ts": "2026-11-26T13:53:51Z", "memory": {"footprint_mb": 722.0, "peak_footprint_mb": 722.0, "pids_arg": ["91258"]}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "prompt": "short", "run": 1, "ttft_s": 0.14777475013397634, "prefill_tps": 460.1598036088674, "decode_tps": 39.82978779312312, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 6.550018250010908, "engine_reported": {"decode_tps": 39.830325935462064, "prefill_tps": 481.75699610343605}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "prompt": "short", "run": 2, "ttft_s": 0.1493031249847263, "prefill_tps": 475.5426251611498, "decode_tps": 39.77126246834596, "prompt_tokens": 71, "completion_tokens": 256, "wall_s": 6.560967833967879, "engine_reported": {"decode_tps": 39.77153359501443, "prefill_tps": 495.7477412057144}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "prompt": "short", "run": 3, "ttft_s": 0.1478889579884708, "prefill_tps": 459.80444331280756, "decode_tps": 39.96544764759162, "prompt_tokens": 68, "completion_tokens": 256, "wall_s": 6.528400500072166, "engine_reported": {"decode_tps": 39.96610873978866, "prefill_tps": 479.31880339470496}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "prompt": "long", "run": 1, "ttft_s": 2.4843438749667257, "prefill_tps": 889.5708932522878, "decode_tps": 38.728934345584214, "prompt_tokens": 2210, "completion_tokens": 256, "wall_s": 9.06856841687113, "engine_reported": {"decode_tps": 38.729190464235415, "prefill_tps": 891.9432901648926}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "prompt": "long", "run": 2, "ttft_s": 2.4217637500260025, "prefill_tps": 910.0805146564505, "decode_tps": 39.04980816039744, "prompt_tokens": 2204, "completion_tokens": 256, "wall_s": 8.951885459013283, "engine_reported": {"decode_tps": 39.04996189948815, "prefill_tps": 914.3027819031105}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "prompt": "long", "run": 3, "ttft_s": 2.4793332498520613, "prefill_tps": 890.1586747693917, "decode_tps": 39.0547821279976, "prompt_tokens": 2207, "completion_tokens": 256, "wall_s": 9.008623290807009, "engine_reported": {"decode_tps": 39.05503957807079, "prefill_tps": 894.2159180967909}}
{"mode": "chat", "engine": "llama", "model": "qwen3.5-4B", "ts": "2026-11-26T13:54:37Z", "memory": {"footprint_mb": 1626.0, "peak_footprint_mb": 1626.0, "pids_arg": ["91269"]}}
{"mode": "embed", "engine": "llama", "model": "qwen3-embedding", "ts": "2026-11-26T13:55:51Z", "run": 1, "inputs": 64, "dim": 1024, "wall_s": 0.8489044590387493, "inputs_per_s": 75.39128734518596, "tokens": 5602, "tokens_per_s": 6599.093620433309}
{"mode": "embed", "engine": "llama", "model": "qwen3-embedding", "ts": "2026-11-26T13:55:51Z", "run": 2, "inputs": 64, "dim": 1024, "wall_s": 0.8491057909559458, "inputs_per_s": 75.37341127770087, "tokens": 5607, "tokens_per_s": 6603.417453657324}
{"mode": "embed", "engine": "llama", "model": "qwen3-embedding", "ts": "2026-11-26T13:55:51Z", "run": 3, "inputs": 64, "dim": 1024, "wall_s": 0.8578650830313563, "inputs_per_s": 74.60380573347184, "tokens": 5622, "tokens_per_s": 6553.478059899667}
{"mode": "embed", "engine": "llama", "model": "qwen3-embedding", "ts": "2026-11-26T13:55:51Z", "memory": {"footprint_mb": 1018.0, "peak_footprint_mb": 1018.0, "pids_arg": ["91280"]}}
```

### llama-server RSS re-measure (same load, 2026-11-26T14:0xZ)

```
Qwen3.5-0.8B-Q4_K_M rss_mb=1262
Qwen3.5-2B-Q4_K_M   rss_mb=1979
Qwen3.5-4B-Q4_K_M   rss_mb=4275
Qwen3-Embedding-0.6B-Q8_0 rss_mb=1668 (footprint 1017)
2B mmap check: rss_mb=1593 phys_footprint 335 MB
```

## Appendix: harness (bench.py) and driver (drive.sh), as run

```python
"""2381-tfna: small-model inference on a base M5 16 GB.

One engine, one model per invocation; prints one JSON line per measured run.

  bench.py chat  <engine> <base_url> <model> <server_pids,comma>
  bench.py embed <engine> <base_url> <model> <server_pids,comma>

engine: ollama | mlx | llama. Client-side timing for every engine (the same
instrument), plus the engine's own counters where it reports them.
Every request starts with a fresh nonce so no prompt cache serves it.
"""
import json, sys, time, uuid, subprocess, urllib.request

RUNS = 3
MAX_TOKENS = 256
SHORT = "Write a detailed, multi-paragraph explanation of how a bicycle's gears work, for a curious twelve-year-old."
LONG_BODY = (
    "The following is a log of a build system. Summarise the failures and their likely causes in a numbered list.\n"
    + "\n".join(
        f"[{i:04d}] step=compile target=crate_{i % 37} status={'ok' if i % 7 else 'FAILED'} "
        f"wall={(i * 13) % 97}s note=dependency graph resolved with {i % 11} warnings about unused imports"
        for i in range(60)
    )
)


def post(url, body, stream):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=600)


def footprint(pids):
    # "children:<pid>" = the server's children at measurement time (ollama's runner)
    if pids and pids[0].startswith("children:"):
        pids = subprocess.run(["pgrep", "-P", pids[0].split(":", 1)[1]], capture_output=True, text=True).stdout.split()
    total = peak = 0
    for p in pids:
        if not p:
            continue
        out = subprocess.run(["footprint", "-p", p], capture_output=True, text=True).stdout
        for line in out.splitlines():
            l = line.strip()
            if l.startswith("phys_footprint_peak:"):
                peak += to_mb(l.split(":", 1)[1])
            elif l.startswith("phys_footprint:"):
                total += to_mb(l.split(":", 1)[1])
    return round(total, 1), round(peak, 1)


def to_mb(s):
    parts = s.strip().split()
    if not parts:
        return 0.0
    v = float(parts[0])
    unit = parts[1].upper() if len(parts) > 1 else "B"
    return v * {"B": 1 / 1048576, "KB": 1 / 1024, "MB": 1, "GB": 1024}.get(unit, 1)


def chat_once(engine, base, model, prompt):
    nonce = f"[run {uuid.uuid4().hex}]\n"
    msgs = [{"role": "user", "content": nonce + prompt}]
    t0 = time.perf_counter()
    first = None
    n_chunks = 0
    rep = {}
    if engine == "ollama":
        body = {"model": model, "messages": msgs, "stream": True, "think": False,
                "options": {"temperature": 0, "num_predict": MAX_TOKENS, "seed": 1, "num_ctx": 8192}}
        with post(base + "/api/chat", body, True) as r:
            for raw in r:
                if not raw.strip():
                    continue
                d = json.loads(raw)
                if d.get("message", {}).get("content"):
                    n_chunks += 1
                    if first is None:
                        first = time.perf_counter()
                if d.get("done"):
                    rep = {k: d.get(k) for k in ("prompt_eval_count", "prompt_eval_duration", "eval_count", "eval_duration", "load_duration")}
    else:
        body = {"model": model, "messages": msgs, "stream": True, "temperature": 0, "max_tokens": MAX_TOKENS,
                "seed": 1, "stream_options": {"include_usage": True}}
        with post(base + "/v1/chat/completions", body, True) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                d = json.loads(data)
                ch = d.get("choices") or []
                if ch and (ch[0].get("delta") or {}).get("content"):
                    n_chunks += 1
                    if first is None:
                        first = time.perf_counter()
                if d.get("usage"):
                    rep["usage"] = d["usage"]
                if d.get("timings"):
                    rep["timings"] = d["timings"]
    t1 = time.perf_counter()
    if engine == "ollama":
        ptok, ctok = rep.get("prompt_eval_count"), rep.get("eval_count")
    else:
        u = rep.get("usage") or {}
        ptok, ctok = u.get("prompt_tokens"), u.get("completion_tokens")
    ctok = ctok or n_chunks
    ttft = (first - t0) if first else None
    decode = (ctok - 1) / (t1 - first) if first and ctok and ctok > 1 and t1 > first else None
    prefill = (ptok / ttft) if ptok and ttft else None
    eng = {}
    if engine == "ollama" and rep.get("eval_duration"):
        eng = {"decode_tps": rep["eval_count"] / (rep["eval_duration"] / 1e9),
               "prefill_tps": (rep["prompt_eval_count"] / (rep["prompt_eval_duration"] / 1e9)) if rep.get("prompt_eval_duration") else None}
    elif rep.get("timings"):
        t = rep["timings"]
        eng = {"decode_tps": t.get("predicted_per_second"), "prefill_tps": t.get("prompt_per_second")}
    return {"ttft_s": ttft, "prefill_tps": prefill, "decode_tps": decode, "prompt_tokens": ptok,
            "completion_tokens": ctok, "wall_s": t1 - t0, "engine_reported": eng}


PASSAGES = [f"Passage {i}: " + ("Unified memory lets the CPU and GPU share one pool of RAM, so a model's weights "
            "are not copied between devices. " * 3) for i in range(64)]


def embed_once(engine, base, model):
    batch = [f"[{uuid.uuid4().hex[:8]}] {p}" for p in PASSAGES]
    t0 = time.perf_counter()
    if engine == "ollama":
        with post(base + "/api/embed", {"model": model, "input": batch, "options": {"num_ctx": 8192}}, False) as r:
            d = json.load(r)
        n = len(d.get("embeddings") or [])
        dim = len(d["embeddings"][0]) if n else None
        ptok = d.get("prompt_eval_count")
    else:
        with post(base + "/v1/embeddings", {"model": model, "input": batch}, False) as r:
            d = json.load(r)
        n = len(d.get("data") or [])
        dim = len(d["data"][0]["embedding"]) if n else None
        ptok = (d.get("usage") or {}).get("prompt_tokens")
    dt = time.perf_counter() - t0
    return {"inputs": n, "dim": dim, "wall_s": dt, "inputs_per_s": n / dt if dt else None,
            "tokens": ptok, "tokens_per_s": (ptok / dt) if ptok and dt else None}


def main():
    mode, engine, base, model, pids = sys.argv[1:6]
    pids = pids.split(",")
    meta = {"mode": mode, "engine": engine, "model": model, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if mode == "chat":
        chat_once(engine, base, model, SHORT)  # warm-up: load, excluded
        for prompt_name, prompt in (("short", SHORT), ("long", LONG_BODY)):
            for i in range(RUNS):
                r = chat_once(engine, base, model, prompt)
                print(json.dumps({**meta, "prompt": prompt_name, "run": i + 1, **r}), flush=True)
    else:
        embed_once(engine, base, model)  # warm-up
        for i in range(RUNS):
            print(json.dumps({**meta, "run": i + 1, **embed_once(engine, base, model)}), flush=True)
    fp, peak = footprint(pids)
    print(json.dumps({**meta, "memory": {"footprint_mb": fp, "peak_footprint_mb": peak, "pids_arg": pids}}), flush=True)


if __name__ == "__main__":
    main()
```

```bash
#!/usr/bin/env bash
# 2381-tfna driver: one engine x one model at a time; servers killed by PID.
set -u
D="$(cd "$(dirname "$0")" && pwd)"
OUT="$D/runs.jsonl"
: > "$OUT"
OLLAMA_PID="$(cat "$D/../ollama.pid")"
HFC="$HOME/.cache/huggingface/hub"
MLXS="$HOME/.local/bin/mlx_lm.server"
PY="python3 -I $D/bench.py"

gguf() { find "$HFC" -name "$1" -path '*snapshots*' | head -1; }
wait_http() { local i=0; while [ $i -lt 180 ]; do curl -s -o /dev/null "$1" && return 0; sleep 1; i=$((i + 1)); done; return 1; }
settle() { sleep 20; }

ollama_run() { # mode model
    $PY "$1" ollama http://127.0.0.1:11434 "$2" "children:$OLLAMA_PID" >> "$OUT" 2>>"$D/errors.log"
    # the runner only exists once the model is loaded; re-read memory with it present
    curl -s http://127.0.0.1:11434/api/generate -d "{\"model\":\"$2\",\"keep_alive\":0}" >/dev/null
    settle
}

for m in qwen3.5:0.8b-nvfp4 qwen3.5:2b-nvfp4 qwen3.5:4b-nvfp4 qwen3.5:0.8b-mlx qwen3.5:2b-mlx; do echo "ollama chat $m"; ollama_run chat "$m"; done
echo "ollama embed"; ollama_run embed qwen3-embedding:0.6b

for s in 0.8B 2B 4B; do
    echo "mlx chat $s"
    "$MLXS" --model "mlx-community/Qwen3.5-$s-4bit" --port 8081 --chat-template-args '{"enable_thinking":false}' > "$D/mlx-$s.log" 2>&1 &
    P=$!
    if wait_http http://127.0.0.1:8081/v1/models; then
        $PY chat mlx http://127.0.0.1:8081 "mlx-community/Qwen3.5-$s-4bit" "$P" >> "$OUT" 2>>"$D/errors.log"
    else echo "mlx $s never answered" >> "$D/errors.log"; fi
    kill "$P"; wait "$P" 2>/dev/null; settle
done

for s in 0.8B 2B 4B; do
    echo "llama chat $s"
    llama-server -m "$(gguf "Qwen3.5-$s-Q4_K_M.gguf")" --port 8082 -ngl 99 -c 8192 --reasoning off > "$D/llama-$s.log" 2>&1 &
    P=$!
    if wait_http http://127.0.0.1:8082/health; then
        $PY chat llama http://127.0.0.1:8082 "qwen3.5-$s" "$P" >> "$OUT" 2>>"$D/errors.log"
    else echo "llama $s never answered" >> "$D/errors.log"; fi
    kill "$P"; wait "$P" 2>/dev/null; settle
done

echo "llama embed"
llama-server -m "$(gguf Qwen3-Embedding-0.6B-Q8_0.gguf)" --port 8083 -ngl 99 -c 8192 -b 8192 -ub 8192 --embedding --pooling last > "$D/llama-embed.log" 2>&1 &
P=$!
if wait_http http://127.0.0.1:8083/health; then
    $PY embed llama http://127.0.0.1:8083 qwen3-embedding "$P" >> "$OUT" 2>>"$D/errors.log"
else echo "llama embed never answered" >> "$D/errors.log"; fi
kill "$P"; wait "$P" 2>/dev/null
echo done
```
