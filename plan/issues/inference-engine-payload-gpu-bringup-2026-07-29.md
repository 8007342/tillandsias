# Inference engine payload + GPU bringup — live findings on macuahuitl (2026-07-29)

Classification: `optimization/` + `research/` (order 406 / 408 / 392b evidence).
Host: `linux_mutable` (macuahuitl), Fedora 44, kernel 7.1.5, 20 cores, 62 GB RAM,
single NVIDIA RTX A5000 (24 GB VRAM), driver 610.43.03, CUDA UMD 13.3,
podman 5.8.4 rootless + crun, SELinux **Enforcing**.

Distilled per `plan/issues/markdown-distillation-audit-2026-05-24.md`: this file is
the evidence record for orders 406/408/392b. Durable behaviour lives in
`images/inference/{entrypoint.sh,engine-tuning.sh,Containerfile}` and
`openspec/litmus-tests/litmus-inference-engine-payload-and-tuning.yaml`.

## Headline (P0)

**The inference container could not serve a single token — on any host, on any
tier — and reported `Up (healthy)` while doing it.**

`images/inference/entrypoint.sh` extracted only `bin/ollama` from the release
tarball. Its comment described the remainder as skippable "~1.8GB GPU runner
libs". That remainder (`lib/ollama/`, 2101 MB) contains **`llama-server`**, the
binary ollama execs for *every* model load, plus `libggml*`/`libllama*` and all
CPU backends. Consequence, reproduced live:

```
POST /api/generate {"model":"qwen2.5:0.5b",...}  ->  HTTP 500
  {"error":"error starting llama-server: llama-server binary not found (checked: …)"}
```

while `podman ps` showed `Up 25 seconds (healthy)` and ollama's own boot log said
`inference compute id=cpu library=cpu`.

Two independent boundary failures let that state survive:

1. **The fail-loud guard asserted the wrong thing.** The order-268 guard checked
   `command -v ollama`, which passes on a payload that cannot load a model.
2. **`HEALTHCHECK` probed `/api/version` only**, which answers the moment the
   port binds. The launcher's `wait_for_inference_ready()` uses the same signal,
   so the whole enclave agreed the endpoint was ready.

This is the substrate under the entire EXPERTS milestone (391). It means the
expert slices already graded PASS (394b/394c/394d) were passing through the
**deterministic compiled Rust path** (`tillandsias-plan answer` / `methodology`
/ `grade`) — Layer 0 — and no model-backed expert has ever served a token here.

## Second, independent blocker: no CDI spec (order 408)

`effective_inference_tier()` (`crates/tillandsias-headless/src/main.rs:2969`)
correctly downgrades `gpu-cuda` -> `cpu` when `nvidia_cdi_available()` is false.
On this host the driver, all `/dev/nvidia*` nodes (mode `0666`, so rootless-
reachable), and `scripts/inference-tier-probe.sh` -> `tier:gpu-cuda` were all
present, but `nvidia-container-toolkit` was **not installed** and no CDI spec
existed in `/etc/cdi`, `/var/run/cdi`, or `~/.config/cdi`. So the GPU was never
handed to the container. Both blockers had to be cleared; each alone still
yields CPU-only.

### The no-sudo enablement recipe (validated end to end)

Host `sudo` requires a password here, and `toolbox` did **not** provide
passwordless sudo either. Neither is needed:

1. Extract the toolkit binaries from a rootless container (container-root can
   `dnf install`; no host privilege involved):
   `nvidia-ctk` and `nvidia-cdi-hook` (v1.19.1) -> `~/.local/bin/`.
2. Generate a **user-level** spec, no root:
   `nvidia-ctk cdi generate --nvidia-cdi-hook-path=$HOME/.local/bin/nvidia-cdi-hook --output=$HOME/.config/cdi/nvidia.yaml`
   (the `--nvidia-cdi-hook-path` flag matters: the spec embeds a hook path that
   must exist on the host, and the default `/usr/bin/nvidia-cdi-hook` does not.)
3. Teach rootless podman to read it — `~/.config/containers/containers.conf`:
   `cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi", "<abs-home>/.config/cdi"]`.
   Note `cdi_spec_dirs` takes **absolute paths only**; `$HOME` is not expanded,
   so order 408's automation must write the resolved path.
4. `--security-opt label=disable` is **required** on this host: SELinux is
   Enforcing and `container_use_devices` is `off` (flipping it persistently
   needs root). Without it NVML fails `Insufficient Permissions` even with the
   CDI device resolved. The inference container **already** passes
   `--security-opt=label=disable` (`main.rs:3298`), so product launches are
   unaffected — but any *other* GPU consumer would need it, and the security
   tradeoff should be recorded rather than inherited silently.

`nvidia_cdi_available()` already honours `$HOME/.config/cdi` (41c2bde2), so no
Rust change was needed for detection.

## Evidence after both fixes

```
inference compute id=0 library=CUDA compute=8.6 name=CUDA0
  description="NVIDIA RTX A5000" libdirs=ollama,cuda_v13 driver=13.3
  type=discrete total="23.5 GiB" available="22.5 GiB"
vram-based default context total_vram="23.5 GiB" default_num_ctx=32768
POST /api/generate -> HTTP 200
nvidia-smi: …/lib/ollama/llama-server  1126 MiB          (qwen2.5:0.5b)
/api/ps: size_vram=932446207 context_length=32768        (fully resident)
```

Warm throughput, qwen2.5:0.5b: **425 tok/s** generate, **6 600 tok/s** prompt
eval — against a 13.6 s prompt eval on the CPU-only path before the fix.

## Tier-aware backend selection (the size argument, corrected)

The original "skip the 1.8 GB" instinct was right about the *size* and wrong
about *what* to drop. Measured tarball layout (`ollama-linux-amd64.tar.zst`,
1422 MB compressed / 2139 MB extracted):

| component | size | needed by |
|---|---:|---|
| `bin/ollama` | 37 MB | always |
| `lib/ollama/` root (llama-server, libggml/libllama, CPU backends) | ~30 MB | **always** |
| `lib/ollama/cuda_v13/` | 844 MB | CUDA UMD >= 13 |
| `lib/ollama/cuda_v12/` | 1277 MB | CUDA UMD 12 |
| `lib/ollama/vulkan/` | 51 MB | mobile/integrated GPU, AMD lane |

Only **one** accelerator backend is ever usable on a given host. Selecting by
tier gives 871 MB installed on this host instead of 2139 MB, and the excluded
backends could never have loaded. The CPU tier now needs only 67 MB — and gets a
*working* engine for the first time.

Implementation notes worth keeping:
- Extraction is **two streaming passes** over the `.zst` (list, then extract) so
  the 2.1 GB intermediate `.tar` is never materialised; peak extra disk is the
  installed payload, not payload + 2.1 GB.
- Pass 1 discovers which backend dirs the release actually ships, so a
  newly-added backend is neither silently installed nor able to break the
  exclude list, and a *wanted* backend the release lacks is reported loudly.
- An `.engine-set` manifest forces reinstall when the required set changes — a
  CPU-only host that gains a GPU, or a driver major bump, must not keep serving
  from a payload whose backend it can no longer use.
- Undetectable CUDA major ships **both** majors: correctness over size, because
  guessing wrong silently downgrades a GPU host to CPU.

## Measured tuning: 30 % VRAM for free (order 406 tuning slice)

A/B on qwen2.5:7b Q4_K_M, `n_ctx` 32768, 200-token generations, warm runs only:

| config | throughput | VRAM |
|---|---:|---:|
| `flash_attn=off kv_cache=f16` (previous default) | 105.9 tok/s | 8098 MiB |
| `flash_attn=on  kv_cache=q8_0` | 106.8–107.7 tok/s | **5690 MiB** |

Throughput unchanged within noise; **2408 MiB saved at the same context length**.
That headroom is the whole point for milestone 391: each 2.4 GB is most of
another resident 7B expert slot. Codified in
`images/inference/engine-tuning.sh` (POSIX sh, side-effect-free when sourced,
standalone-runnable so litmus exercises every branch with stubbed inputs — the
same contract as order 392a's `preload-policy.sh`).

Deliberately **not** enabled on the vulkan/rocm lanes: flash attention was not
measured on those accelerators here, and shipping an unmeasured claim is the same
class of error as reporting a GPU tier podman cannot deliver. Those lanes stay
f16 until a host with that hardware measures them (orders 410, 481, 482).

`OLLAMA_NUM_PARALLEL` moved from a hardcoded `1` in the entrypoint into the tier
policy — hardcoding it there *looked like an operator override* and would have
suppressed the policy entirely.

## Related defects found in passing (filed, not yet fixed)

1. **`containers.conf [engine] env` breaks every host-level `podman pull` when
   the enclave is down.** `--init` writes the enclave proxy into the *global*
   `~/.config/containers/containers.conf` (`main.rs:5495`), and podman applies
   `[engine] env` to its own registry client, not just to containers. With the
   enclave stopped: `proxyconnect tcp: dial tcp: lookup proxy: no such host` on
   every pull, including `toolbox create`. `no_proxy` covers enclave aliases but
   not external registries. This is a first-run/bootstrap hazard on any host
   that has ever been `--init`ed.
2. **989 `registries.conf.backup.<epoch>` files** (3.9 MB) in
   `~/.config/containers/`. `scripts/setup-podman-registries.sh:32-37` copies
   the target unconditionally on every `build.sh` run — no content comparison, no
   retention bound. Every backup is byte-identical to the 1397-byte source.
3. **The expert-slot ladder is RAM-derived only** (`preload-policy.sh:83-89`).
   On a GPU host the binding constraint is **VRAM**: a 64 GB host with a 4 GB
   mobile GPU is granted 2 expert slots that cannot be resident, so models spill
   or thrash. Relevant to orders 397/480/481.
4. **`--pids-limit=128`** on the inference container is close for a CUDA
   `llama-server` on a 20-core host (the CUDA runtime is thread-heavy). Not
   observed failing, but worth a measured bound rather than a guessed one.
5. **`gpu-rocm` is CPU-only BY CONSTRUCTION** (filed as order 520). The fetched
   asset ships exactly three backend dirs — `cuda_v12`, `cuda_v13`, `vulkan`.
   ROCm is a *separate* 1 047 683 394-byte asset
   (`ollama-linux-amd64-rocm.tar.zst`) that nothing in the tree ever fetches. So
   `build_inference_run_args` passes `--device /dev/kfd --device /dev/dri` to an
   engine with no ROCm backend to use them with. Order 406 maps the rocm tier
   onto `vulkan` as a deliberate interim (Vulkan *is* the working AMD lane here,
   and SLOT-4 already makes it the default Linux GPU lane) — but that mapping is
   **reasoned, not measured**; no AMD host has exercised it.
6. **No integrity verification on the engine payload** (filed as order 521). A
   ~1.4 GB tarball is fetched from `.../releases/latest/download/...` and
   executables installed from it with no checksum, no signature, and no pinned
   version — through a Squid proxy that TLS-bumps with the *enclave* CA, so the
   transport trust anchor is the enclave's own CA rather than GitHub's. `latest`
   also means the engine can change under a host between launches with nothing
   recording which version is installed.
7. **SLOT-4 interaction.** `openspec/specs/inference-engine-slots/spec.md:115`
   makes **Vulkan via `/dev/dri` the default Linux GPU lane**, with CUDA-via-CDI
   a probe-gated vendor lane. The payload selector here is deliberately
   one-backend-per-tier for the *ollama* engine kind (which SLOT-3 keeps as the
   default engine until the llama-server lane has smoke evidence). Reconciling
   payload selection with the SLOT-4 lane abstraction belongs to order 482.

## Not verified here

- A genuinely cold engine install through the enclave Squid proxy: the tarball
  was fetched over direct host egress. The in-enclave path retains its order-486
  bounded egress probe, unchanged.
- `cuda_v12` and `vulkan` selection branches are policy-tested with stubbed
  inputs but not exercised against real CUDA-12 or Vulkan hardware.
- `gpu-rocm` -> `vulkan` mapping is reasoned (this ollama release ships no rocm
  backend dir) but unmeasured; order 410 owns it.
- The full forge launch path with GPU (vault/auth) was not re-run; evidence above
  is from the inference image with the product's own security posture and args.
