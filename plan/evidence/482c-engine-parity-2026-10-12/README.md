# 482c evidence: T0 engine parity, ollama vs llama-server, CUDA and Vulkan (lenovinha, 2026-10-12)

Scope, as ruled by the coordinator: ollama (at the detected tier) against
llama-server at T0, on CUDA and on Vulkan. The 5690 MiB 7B memory guard is
482c-2 (order 482-5f3t), and /api/tags is 482-ksqx. ollama stays the default.
Nothing here promotes llama-server.

Host: lenovinha, Fedora 44 Silverblue, kernel 7.2.7, rootless podman. GPUs:
NVIDIA RTX 3070 Laptop (8192 MiB, CDI spec in /var/run/cdi) and AMD Cezanne iGPU
(renderD128). The operator's live `tillandsias-inference` (v56.9.27.2) held 4958 MiB
of the 3070 throughout. It was never stopped, and only read.

## How it ran

`scripts/inference-engine-parity-smoke.sh` drives the PRODUCT code paths of the
binary built from this branch:
- image: `tillandsias --internal-ensure-image <repo> inference <tag>`
- ensure: `tillandsias --internal-inference-slot ensure <certs>`. This is the launch
  path's own `ensure_inference_for_launch` (the running-check, then
  `build_inference_run_args`) plus `report_inference_readiness`.
- teardown: `tillandsias --internal-inference-slot teardown`, which is
  `cleanup_shared_stack_if_no_running_forge`.

Every consumer request goes from a SEPARATE container on the network to
`http://inference:11434`, the alias forges use, with `curl -m 1` for /api/version.

Isolation:
- Private: graphroot, runroot (netavark rootless netns, aardvark-dns config,
  IPAM), libpod `engine.tmp_dir`, network config dir, `REGISTRY_AUTH_FILE`, and HOME.
- HOME matters: XDG_CACHE_HOME alone would make `adopt_legacy_cache` MOVE the
  operator's model cache into scratch.
- A store guard (GraphRoot and RunRoot) runs before every mutation.
- XDG_RUNTIME_DIR stays real ON PURPOSE. netavark starts aardvark-dns through
  `systemd-run --user`, and a private runtime dir has no user bus. Runs 2 and 3
  failed on exactly that, with linked, relayed and masked bus variants.
- Run 5's substrate was under /var/tmp. Per operator direction (2026-10-12), dev
  scratch now lives inside the checkout. The harness defaults to
  `<checkout>/target/work/inference-parity/` for graphroot, HOME/model cache,
  network config and logs.
- The runroot and libpod tmp_dir go to a private `$XDG_RUNTIME_DIR/tillandsias-parity.*`
  instead. The first relocated attempt put them in the checkout, and pasta's SELinux
  domain refused its pid file there ("rootless-netns-conn.pid: Permission denied").
- `relocated-degraded-check.txt`: the degraded lane re-run on the final layout. ok,
  both dirs removed, operator unchanged.

Lanes:
- ollama: engine unset (the default), tier gpu-cuda, so CDI device and cuda_v13.
- llama-cuda: engine=llama-server, `TILLANDSIAS_INFERENCE_LLAMA_BACKEND=cuda`.
- llama-vulkan: engine=llama-server, `TILLANDSIAS_INFERENCE_LLAMA_BACKEND=vulkan`,
  with render nodes.
- degraded: llama-server on an `--internal` network with an empty cache.

Per normal lane, in order:
1. Free VRAM before.
2. Cold ensure on an egress network. There is no enclave proxy, so the image runs
   direct.
3. Readiness, then a bounded wait until the T0 model is listed and the cache has
   no `-partial` files.
4. Probes.
5. Second ensure.
6. Remove the container and recreate the network `--internal` (no egress at all).
7. Third ensure from cache.
8. Compare every cached file over 1 MiB (inode, size, mtime).
9. Probes again.
10. Teardown.

## Results (run 5, `run5-transcript.txt`; per-lane files in `run5/`)

| | ollama (default) | llama-server CUDA | llama-server Vulkan |
|---|---|---|---|
| backend | cuda_v13, CUDA0 = RTX 3070 (`ollama.engine-lines.txt`) | `core+cuda_v13`, `reason=requested:cuda-lane-delivered`, closure pin `cuda_v13/libggml-cuda.so` | `core+vulkan`, `reason=render-node:renderD128`, closure pin `vulkan/libggml-vulkan.so` |
| cold ensure | ready in 33 s | soft: `ready=false` after 64 s (payload + GGUF download), DEGRADED logged, then ready | ready in 46 s |
| /api/version via `inference:11434`, `curl -m 1` | 200 in 1.3 ms / 1.5 ms (cold/warm) | 200 in 1.5 ms / 1.7 ms | 200 in 1.5 ms / 1.7 ms |
| /v1/models | `nomic-embed-text:latest qwen2.5:0.5b` | `qwen2.5-0.5b-instruct` | `qwen2.5-0.5b-instruct` |
| /v1/chat/completions (T0, "Reply with the single word: pong") | `pong` / `pong` | `pong` / `pong` | `pong` / `pong` |
| engine processes | ollama=1, llama-server=1 (ollama's own runner child) | ollama=0, llama-server=1 | ollama=0, llama-server=1 |
| double ensure | same id `19850313a7d4`, 1 container, "already running; reusing" | same id `41f0128acf2a`, 1 container | same id `5679be12db5d`, 1 container |
| no-egress recreate | ready in 2 s; 19 files over 1 MiB unchanged | ready in 20 s; 18 unchanged | ready in 2 s; 16 unchanged |
| teardown | no inference container left | none left | none left |

VRAM (nvidia used / free, amdgpu used):

| lane | before | serving | after teardown |
|---|---|---|---|
| ollama | 4958 / 2937 MiB | 5621 MiB after the chat loaded the model (+663) | 4958 MiB |
| llama-cuda | 4958 / 2936 MiB | 5579 MiB (+621); iGPU not involved | 4958 MiB |
| llama-vulkan | iGPU 577 MiB, NVIDIA 4958 | iGPU 1035 MiB (+458); NVIDIA unchanged | iGPU 577 MiB |
| degraded | 4958 / 2936 MiB | n/a | 4958 / 2936 MiB |

The iGPU also backs the desktop, so its absolute numbers drift between lanes.
The deltas within a lane are the signal.

## Degraded (SLOT-8 "Readiness failure is soft")

From `run5/degraded.ensure-1.log` and `run5/degraded.container.log`:

```
inference-slot: ensure ready=false            (ensure rc=0 after 63 s)
[tillandsias] [forge-launch] DEGRADED: local inference not ready (engine=llama-server): inference did not become ready within 60s. Last probe: probe failed: Container command failed (status Some(255), retry Unknown): podman exec tillandsias-inference curl -fsS --max-time 2 http://127.0.0.1:11434/api/version
[inference] engine=llama-server backend=vulkan reason=render-node:renderD128
[inference] FATAL: proxy egress never became ready within bounded backoff (5 probes) — skipping self-install this launch
[inference] FATAL: reason=engine-integrity-refused:no-engine — refusing to execute the engine in /home/ollama/.ollama/models/.tools
container: exited exit=1
teardown: inference containers left: none
```

Before this branch the same failure printed "WARNING: local inference not ready".
SLOT-8 requires a DEGRADED line.

## Operator guardrails

- `operator-guard.txt`: for tillandsias-inference and tillandsias-dev-inference,
  the id, start time, health, and network name:IP:MAC are identical before and
  after run 5.
- `operator-netavark-diff.txt`: the operator's `/run/user/1000/containers/networks`
  changed in one second, 08:07:24-26 PDT.
  - What changed: its `tillandsias-enclave%int` aardvark entry was rewritten at the
    same size, ipam.db was touched, and the netns ref-count stayed 1.
  - `operator-events-08-07-25.txt` (that store's own `podman events`) shows the
    installed tray doing it: tillandsias-vault execs, a secret create, a short-lived
    `tillandsias-git` container on the enclave, and a secret remove.
  - None of the scratch ids are in that store.
  - Coordinator accepted the attribution.
- Healthcheck timers, a known podman 5 behaviour. The scratch image is re-layered
  `HEALTHCHECK NONE` (docker format, `{"Test":["NONE"]}`). podman still arms a
  transient user timer for any non-empty healthcheck.
  - `healthcheck-timer-sampler.txt` (147 samples at 3 s): one unit pair per scratch
    container, i.e. the three lane slots and the `--rm` consumer probes.
  - Each runs a plain `/usr/bin/podman healthcheck run <scratch-id>` without the
    scratch env, which is a no-such-container no-op against the operator's store.
  - 0 remained after the run, and there were 0 failed units.
  - Not claimed as zero.

## How the harness got here (runs 1-4, not kept)

- Run 1: `podman run` refused. The image HEALTHCHECK needs a systemd connection,
  and the runtime dir was private then.
- Runs 2-3: aardvark-dns failed to start through `systemd-run --user`. This led to
  the real-runtime-dir plus private runroot/tmp_dir design.
- Run 4: llama-cuda, llama-vulkan and degraded passed. ollama failed on two harness
  bugs, both fixed:
  - it probed and snapshotted before the runtime T0 pull finished, so a `-partial`
    blob made the cache diff red;
  - it picked the first listed model, the embed model, which refuses chat.

Every run removed its substrate, and the operator's containers were unchanged
after each.

## Quick closure

`litmus:inference-engine-parity-shape` (5 steps, instant) pins the code this run
exercised. Each step checks a scratch copy, goes red on ONE seeded regression,
and goes green again after byte-identical restoration (sha256 pre == post):
- default promotion to LlamaServer;
- removing the running-check before the inference run site (idempotency);
- moving the shim off :11434 (endpoint);
- making readiness a hard gate (soft readiness);
- dropping the guard from the harness.

## Not here

- The 7B / 32768-ctx / fa+q8_0 profile and its 5690 MiB headroom guard: 482-5f3t.
  It needs 482-igky's pins, plus 527 on the operator install or an operator window.
- /api/tags under llama-server (`tillandsias-models` lists nothing): 482-ksqx.
- Promotion of llama-server to the default.
