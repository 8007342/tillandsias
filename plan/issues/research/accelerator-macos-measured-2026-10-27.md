# macOS accelerators: what a forge in the vz guest reaches, measured 2026-10-27

Order 1905-btc3 (parent 1905-zt65). Host: tlatoanis-macbook-air, Apple M5,
10 cores, 16 GiB. Guest: the installed release v56.10.20.1 (git f0e61287e),
reached only through its own `tillandsias-tray --exec-guest`. The operator
approved stopping the running tray for this (2026-10-27). No sudo and no
host-wide install: the host tools were built in a scratch sandbox (a cmake
venv and a whisper.cpp clone), and the guest work ran in throwaway containers
that were removed afterwards. Every licence involved is MIT (ollama,
whisper.cpp, the ggml base.en model), so no licence needed accepting.

## 1. What the guest sees: no GPU and no Neural Engine

Guest: 8 vCPU / 8 GiB (919-jii2 sizing), kernel `6.19.10-300.fc44.aarch64`.

- `/dev/dri` and `/dev/accel` do not exist, in the guest or in a container.
  `/sys/class/drm` holds only `version`, with no card.
- PCI is the Apple host bridge `106b:1a05` plus virtio only: net, console, rng,
  balloon, vsock, 4 × blk and 4 × virtiofs. There is no virtio-gpu and no
  display or accelerator class device.
- The guest CPU flags do include `sme sme2 sme2p1 i8mm bf16`. The M5's matrix
  extension reaches the guest as CPU instructions. That is the only
  acceleration a forge gets.

Virtualization.framework has no GPU or ANE passthrough for Linux guests, so
this is expected and is a property of the platform, not of Tillandsias.

## 2. Timings: guest CPU vs host-native helpers

Same models as 1905-w47z. Warm runs (runs 1–3); run 0 is the model load and is
reported apart. Placement proof is listed in each row.

| Workload | Guest CPU (forge placement today) | Host CPU only | Host Metal (GPU) |
|---|---|---|---|
| Chat, qwen2.5:0.5b Q4_K_M, 128-token cap, temp 0 | 176–207 tok/s, 0.31–0.38 s per answer (61 tok) | 162 tok/s, 0.45 s (71 tok) | **233–235 tok/s, 0.26 s** (59 tok) |
| Embedding, nomic-embed-text F16, 64 sentences per call | 0.51–0.54 s | 1.77 s | 0.50–0.58 s |
| Speech-to-text, whisper.cpp base.en, `samples/jfk.wav` (11 s), 4 threads | 614–626 ms (~18× real time) | 335–344 ms (~33×) | **162–169 ms (~67×)** |

Placement proof:
- ollama `/api/ps`: `size_vram` equals `size` (483,624,221 / 335,733,063) on
  Metal; `size_vram: 0` with `num_gpu: 0` on the host and in the guest.
- whisper.cpp: on the host, `use gpu = 1` with `GPU name: MTL0 (Apple M5)`
  and `-ng` gives `use gpu = 0`. In the guest, `system_info` lists only CPU
  features (NEON, DOTPROD, MATMUL_INT8, OPENMP) and no GPU backend, so the
  guest's `use gpu = 1` is a default flag with nothing behind it.

Commands:
- ollama 0.40.8 on both sides. The host is the user-run `ollama serve`.
  The guest is `docker.io/ollama/ollama:0.40.8` in podman, with models pulled
  into a throwaway volume. Driver scripts: `ollama_bench.py` (host, `num_gpu`
  0 for the CPU row) and a curl loop in the guest with identical prompt,
  options and inputs.
- whisper.cpp 231638a (2026-10-19), model sha1
  `137c40403d78fd54d454da0f9bd998f78703390c`.
  - Host build: `-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`.
  - Guest build: fedora:44 container, CPU default.
  - Run: `whisper-cli -m base.en -f jfk.wav -t 4 -nt`, plus `-ng` for host CPU.

Caveats, stated rather than explained away:
- Output lengths differ by placement (59/61/71 tokens) at temperature 0.
  Compare tok/s, not wall time.
- The host-CPU ollama rows are slower than the guest CPU rows: chat 162 vs
  ~200 tok/s, embedding 1.77 vs 0.53 s. The cause was NOT investigated. A
  plausible one is the thread count ollama's macOS build picks with
  `num_gpu: 0`; that is a guess, not a measurement. Don't use the host-CPU
  column to argue for or against the guest.
- n=3 warm runs each, on one machine, with nothing else under load.

## 3. What a host-native hop costs: not measured

A forge reaching a host Metal helper needs a guest-to-host path. The host
ollama listens on 127.0.0.1 only. Exposing it on the VM's NAT address to time
the hop would open it to the LAN, which is out of scope without an operator
ruling. That latency is therefore NOT measured here. The payloads involved are
small (one prompt, 128 tokens out; 64 sentences in), so a vsock relay of the
kind 1897-gex1 built is the natural carrier. Measuring it is follow-up work.

## 4. What this means for routing

- **Chat, small models:** the guest CPU is within ~15% of host Metal for a
  0.5B model. A host hop buys little until models get larger. qwen2.5:7b was
  not measured here.
- **Embedding:** the guest CPU matches host Metal at this batch size, so keep
  it in the guest.
- **Speech-to-text:** host Metal is ~3.7× the guest CPU (169 vs 620 ms for
  11 s of audio). This is the one workload here where a host-native helper
  clearly pays, if the hop costs less than ~450 ms.
- **Neural Engine:** unreachable from the guest, and not measured on the host.
  Core ML would need coremltools/torch to convert the model, a multi-GB
  install that was left out under the sandbox ruling. Open.
- Images remain 1874-qyfv (host-native Metal sd-server).
