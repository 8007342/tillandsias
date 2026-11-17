# Local job watchdog: a forge hands a long job to this computer instead of polling it from the cloud

- classification: research and design, for operator review; nothing is built
- filed: 2026-11-13, macuahuitl (linux), delegated research reviewed by the filing session
- packets: 2081-z7sh (story and design), 2081-v7qx, 2081-ic4j, 2081-bgh8, 2081-ngd8, 2081-fqw3, 2081-4cpi, 2081-bdss
- OpenSpec change: `openspec/changes/local-job-watchdog/`

@trace order:2081-z7sh

## The ask

Operator, 2026-11-13: containers should have NPU and GPU access; a watchdog for local agents
on NPU/GPU where available, tiny models running locally, and MCP tools whose descriptions say
what they cost, when to use them and when to prefer them, "so you wouldn't have to use cloud
minutes to babysit long running jobs, instead merely delegate to a local model with a timer or
queue"; re-research zeroclaw and its like; find "the minimalist super safe zero-credentials
offline container to run on NPU/GPU/CPU (fallback in that order)"; "given our infra it should
just take some wiring."

The incident behind it, same day: a forge ran a multi-hour render batch. The cloud agent
attended it with a scheduled wake every 20 to 30 minutes, two or three cloud turns an hour,
each one re-reading its context only to look at a checklist and restart dead workers.

## Prior art in this repository

| What | Where | What it gives the watchdog |
|---|---|---|
| Inference container, llama-server lane | `images/inference/llama-server-lane.sh`, `images/inference/tiers/gguf-pins.tsv` | A digest-pinned llama-server, backend pinning, and models that fail closed unless pinned by sha256. `qwen2.5-0.5b-instruct` is already pinned |
| Supervision and stall detection inside that image | `images/inference/supervise.sh` (`tillandsias_supervise`), `images/inference/gpu-stall-watchdog.sh` | The house style for a watchdog: fail safe and never blind, a pinned one-line grammar, seams for a fixture |
| One GPU queue and a VRAM arbiter | `gpu_queue.rs`: `wait_for_gpu`, `Arbiter::admit`, `gpu.status`, `gpu.unload_model` | Image jobs already take turns. `Arbiter::admit` evicts a resident LLM; nothing offers "take the GPU only if it is free" |
| A queued studio batch with a ticket | `studio_jobs.rs`: `studio.queue_workflow`, `studio.job_status` (order 2002-stjb) | The nearest relative. Its header states the problem: a long batch "needed an agent attending it, and a lane restart lost it". It covers one tool's jobs, and nothing restarts a dead one |
| Host tool index with "use when" text | `host_tools.rs`: `GROUPS`, `instructions`, `index_descriptor` | The seam where a `watch.*` group states cost and preference to every agent at `initialize` |
| NPU probe | `accel_probe.rs`: `enumerate_npus` | Lists `/sys/class/accel` devices. `usable` is a literal `false` with `engine-missing` (plan/issues/npu-usable-is-a-literal-2026-09-18-yoga.md) |
| NPU research and proof | plan/issues/heterogeneous-inference-cpu-gpu-npu-research-2026-07-24.md, npu-experts-poc-2026-07-31.md, fedora-45-npu-igpu-research-2026-11-06.md | Engine matrix; qwen3-0.6b answering on an AMD XDNA2 NPU; the lesson that a tiny model rephrases handed facts reliably and generalises when asked to retrieve |
| Open NPU packets | 481 npu-device-passthrough, 542 optional-component-registry, 543 npu-inference-container, 546 npu-beginner-experts-serving (all ready, unclaimed) | The NPU lane this design consumes instead of building a second one |
| Sleep and wake | `openspec/changes/forge-sleep-and-wake/` (2014-slpw), 2012-kuw4 (deterministic wake), 2012-sc0l (wake classifier measured before enabled) | The path an escalation uses to reach a session that has ended its turn. Section 5 there: "The model only proposes; the rules decide" |
| In-forge harness supervisor | `images/default/harness-supervisor.sh`, 1913-q2z4 | Restart budget precedent: back off, at most 3 restarts in 30 minutes |
| Fleet messaging | `forge-plan.sh` tools `msg_send`, `msg_recv`, `msg_status`; `msg_serve.rs`; 2011-amqd | A message with a delivery receipt, addressed to a lane |
| Lane push notifications | `lane_events.rs`: `register`, `listen_for_project` | An MCP `notifications/message` written to a live lane connection with no polling |
| Tray notifier | `tray/mod.rs` `notify_memory_stall`; `memory_stall_watch.rs` | A resident tray loop that names a problem to the user and kills nothing |
| Idle reaper | `openspec/changes/idle-container-reaper/` (1800-465n) | A forge whose only activity is a watched job must count as active |
| Zeroclaw and nanoclaw | plan/issues/agent-fleet-and-zeroclaw-roadmap-2026-07-17.md; `openspec/changes/nanoclawv2-orchestration/` | Zeroclaw was removed as a critical violation (a second release binary, an unisolated host socket running arbitrary host commands). Its return is operator-gated: last, as a container, local-only, after the experts are reliable. Nanoclaw work was halted |
| Delegation ladder | `openspec/changes/local-coding-experts-delegation-ladder/` | Trust is earned on measured results; a local model is promoted by its measured rates |
| Cycle driver | `scripts/tillandsias-cycle-driver.sh` | No stacking by a non-blocking lock; a skipped tick is a designed outcome; one verdict line |
| BigPickle skills | `skills/diagnose-forge/`, `skills/forge-continuous-enhancement/` | They diagnose and improve the forge between runs. Neither attends a running job |

No packet covered attending an agent's own long job. A search of every ledger title for
watchdog, babysit, supervise and wake returned the rows above plus unrelated supervisors
(the VM guest power-off, the proxy, the harness).

## This host's NPU (measured 2026-11-13, macuahuitl)

- Hardware: Intel Core Ultra 7 265KF (Arrow Lake). `lspci`: "Core Ultra 200 Series Processors
  NPU", PCI id 8086:AD1D. OpenVINO names it "Intel(R) AI Boost", `DEVICE_ARCHITECTURE 3720`.
- Kernel: `intel_vpu` bound, `/dev/accel/accel0` present, mode `crw-rw-rw- root:render`,
  SELinux label `container_file_t`, runtime status `suspended` when idle. Firmware package
  `intel-npu-firmware-20261019`, user-space driver `intel-npu-driver-1.32.0-2.fc45`.
- Reachable from a rootless container: yes. `podman run --device /dev/accel/accel0
  --group-add keep-groups` on `fedora-toolbox:45`, SELinux enforcing, default labelling,
  `container_use_devices` off: OpenVINO 2026.4.1 (PyPI wheel) lists `['CPU', 'NPU']`.
- Usable for inference: **no, not today.** Compiling the smallest model for the NPU fails
  with `ZE_RESULT_ERROR_UNSUPPORTED_FEATURE` and `NPU_COMPILER_VERSION` reads 0. Two
  independent causes:
  1. Fedora's `intel-npu-driver` ships only `libze_intel_npu.so`. It has no graph compiler
     (Intel's releases carry it as the separate `intel-driver-compiler-npu` package).
  2. The PyPI wheel has the NPU plugin but not `libopenvino_intel_npu_compiler_loader.so`,
     so `NPU_COMPILER_TYPE=PLUGIN` cannot load either.
  Fedora's own `openvino-2026.0.0-16.fc45` on the host has no NPU plugin at all and lists
  only CPU and GPU.
- So the device, node, firmware and permissions are all in place and what is absent is a
  compiler in user space. That is `engine-missing`, the same word `enumerate_npus` prints. The
  fix is a file in a container image, not a host change. Whether the compiler's licence lets
  us ship it is [unproven] and is question 5 below.
- The NPU is the 3720 class (the Meteor Lake design), not the Lunar Lake NPU 4. OpenVINO's
  NF4 quantisation needs the newer one. Tokens per second on this device are [unmeasured].
- The GPU at the time of the probe: 22.9 of 24.5 GiB held, 21.0 GiB of it by one resident
  LLM. A watchdog that wanted the GPU would have had to evict it. See "GPU sharing".

## External research (2026-11-13)

**Agent runtimes.** ZeroClaw (zeroclaw-labs/zeroclaw) is a single Rust binary, MIT or
Apache-2.0, with any OpenAI-compatible endpoint as a provider, a `supervised` default
autonomy level, Landlock, Bubblewrap and Docker sandboxes, cron triggers and a service
mode. It also carries 30 or more channels, a gateway with a web dashboard, and a shell tool.
For a three-verdict judge that is surface we would have to switch off and then prove off.
Verdict: **not used here.** The watchdog has no agent loop and gives the model no tools,
which is a smaller trusted base than any agent runtime configured down. This note does not
re-open the gated reintroduction; it gives that row a proven offline lane to stand on later.

**Models.** Only permissive and ungated weights qualify (operator ruling 2026-10-25).

| Model | Licence | Gated | Notes |
|---|---|---|---|
| Qwen2.5-0.5B-Instruct | Apache-2.0 | no | Already pinned as T0. Zero new download. The wake classifier row 2012-sc0l measures the same file |
| Qwen3-0.6B | Apache-2.0 | no | Official GGUF is Q8_0 only, 639 MB. Ran on the XDNA2 NPU in the July proof. Thinking is switched off with `/no_think` |
| Qwen3-1.7B | Apache-2.0 | no | Official GGUF is Q8_0 only, 1.83 GB. 32K context. On Intel's NPU-validated lists |
| Granite 4.0 nano (350M, 1B) | Apache-2.0 | no [not re-checked] | The 1B is "partial" on the llama.cpp NPU list |
| Phi-4-mini (3.8B) | MIT | no [not re-checked] | Larger than the job needs; a later tier at most |
| Gemma 3 | Gemma terms | yes | Excluded, as in 1921-s4bh |
| Gemma 4 | reported Apache-2.0 | [unproven] | Excluded until its gating and licence are read first-hand |
| LFM2 | LFM Open License | no | Excluded: a revenue cap |

Published tool-calling scores for sub-2B models are thin and self-reported (a third-party
model card reports about 27 on BFCL v4 for Qwen3-0.6B [unverified]). They matter little here: the judge calls no tools. It
picks one of three words under a grammar. What matters is whether it reads a log tail
correctly, and that is measured on our own labelled set before it is enabled (2081-ngd8).

**Runtimes.**
- llama-server (llama.cpp) binds a UNIX socket when `--host` ends in `.sock`, constrains
  output with `--json-schema` or a `response_format` schema, unloads after
  `--sleep-idle-seconds`, and has `--offline`. One binary covers CPU, CUDA and Vulkan.
- llama.cpp's OpenVINO backend lists Intel NPUs: `GGML_OPENVINO_DEVICE=NPU`, a static
  prefill chunk of 256, an explicit small `-c`, one slot only, stateless. It validated
  Qwen3 0.6B to 8B and Qwen2.5 on a Lunar Lake NPU with driver 1.38.0. A missing device is
  an error, never a silent fall to CPU. The backend is "actively under development".
- OpenVINO GenAI on NPU added Qwen3-1.7B, 4B and 8B in 2025.3.
- Intel's linux-npu-driver 1.38.0 is validated against OpenVINO 2026.3.1 and lists Arrow
  Lake. The host has 1.32.0.
- AMD XDNA2: unchanged from the two research notes above. FastFlowLM through Lemonade is
  the only working LLM path, with closed NPU kernels, so it needs an operator licence
  decision (543). ONNX Runtime with the Vitis AI provider is not built in Fedora.

Sources: https://github.com/zeroclaw-labs/zeroclaw ·
https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md ·
https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md ·
https://github.com/intel/linux-npu-driver/releases ·
https://huggingface.co/Qwen/Qwen3-0.6B-GGUF · https://huggingface.co/Qwen/Qwen3-1.7B-GGUF
(licence, gating, sizes and sha256 read from the Hugging Face model API) ·
https://www.intel.com/content/www/us/en/developer/articles/release-notes/openvino/2025-3.html

## Design summary

Full text: `openspec/changes/local-job-watchdog/design.md`.

**Three rungs.** Rules decide first and cost nothing. A tiny local model is asked only when
the rules cannot tell (a dead worker whose log tail may be transient or fatal). A cloud
agent is reached only by an escalation.

**Three parts.**
1. *Hands*, in the tray: the watch registry, the observations, the rules, and the one
   action. The tray already starts every sibling container for a lane.
2. *Judge*, in a container: llama-server on a UNIX socket. `--network none`, read-only
   root, all capabilities dropped, no credential, no project mount. It receives a bounded
   observation bundle and returns `ok`, `restart` or `escalate` under a schema.
3. *Tools*, on the lane socket: `watch.register`, `watch.status`, `watch.cancel`,
   `watch.list`.

**What it can do.** Nothing; re-run the one command the agent declared at registration, as
an argv with no shell, in the registering forge, at most 3 times in 30 minutes; or escalate
once per episode with the evidence. The model never writes a command, a path or a message.
A log line is data: the worst a hostile line can do is pick a different one of the three
verdicts, and the rules bound each of them.

**Cadence, stated for approval.** No periodic poll. A watched job costs: its exit event; one
deadline timer re-armed by progress, default 10 minutes and never under 2, so at most 6
wakeups an hour, each a `stat` and no inference; at most 6 judge calls an hour. This is a
new cadence and needs the operator's approval (question 1).

**Accelerator order.** NPU, then GPU, then CPU, each step taken only when it is honestly
available. On this host today that resolves to CPU: the NPU has no compiler, and the GPU
is full. CPU should be enough: a verdict is an estimated 1,500 prompt tokens and 30 output
tokens [unmeasured; 2081-ngd8 measures it].

**GPU sharing.** The judge takes the GPU only when free VRAM covers the model plus a margin
and no ticket waits in `wait_for_gpu`'s queue. It never calls `Arbiter::admit`, never
queues, and unloads after the verdict. A render is never delayed by it.

## Open questions for the operator

1. **Cadence.** Is one re-armed deadline timer per watched job at 10 minutes (floor 2), with
   exit events, approved? It is at most 6 wakeups an hour per job.
2. **Restart budget.** 3 restarts in 30 minutes with 30 s, 2 min, 10 min back-off, then
   escalate. Right numbers?
3. **Who is woken.** Until deterministic wake lands (2012-kuw4, 2014-slpw), an escalation
   reaches a live session, the lane inbox and a desktop notification, but cannot wake a
   session that ended its turn. Is a desktop notification enough for now, or should the
   agent keep one wake at the job's deadline as a backstop?
4. **Model default.** Start with the already-pinned Qwen2.5-0.5B (no download) and promote
   to Qwen3-0.6B or 1.7B only where the labelled set shows it is needed?
5. **Intel NPU compiler.** May the judge image carry Intel's NPU graph compiler from the
   linux-npu-driver releases, once its licence has been read? Without it this host's NPU
   stays unused.
6. **Rules-only hosts.** On a floor-tier host with no local inference, should an ambiguous
   case escalate straight away (the proposed default), or should the watchdog be refused
   there?
7. **Zeroclaw.** This design does not use it. Does the gated reintroduction row stay as it
   is, or should it now depend on the watchdog's offline lane?
