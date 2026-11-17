# Local babysitter across the fleet: per-host hardware, small models, admission and host sessions

- classification: research and design input, for operator review; nothing is built
- filed: 2026-11-17, macuahuitl (linux); two delegated research passes reviewed by the filing session
- packets: 2094-65yz (story and rulings), 2094-ay52, 2094-mzap, 2094-dyvk, 2094-y2bb, 2094-s3ub,
  2094-p3i3, 2094-zzg9, 2094-7t4f, 2094-3r2k
- OpenSpec change: `openspec/changes/job-admission-and-host-watch/`
- builds on: `openspec/changes/local-job-watchdog/` (2081-z7sh) and
  `plan/issues/local-job-watchdog-design-2026-11-13.md`

@trace order:2094-65yz, order:2081-z7sh

Marks used below: **[measured]** was run on the named host on the named day; **[ledger]** is read
from this repository's own records; **[source]** carries a URL; **[estimate]** and **[unmeasured]**
are nobody's measurement and must not be quoted as one.

## The ask, and what already answers part of it

Operator, 2026-11-17: move the babysitting of long-running tasks off cloud-model minutes and off
`until grep ... ; sleep` loops onto small local models on the fleet's own hardware. The babysitter
checks status, wakes every few minutes, retries sensibly, minds memory, and queues work so several
forges share one computer fairly. It must be available both to forges and to agent sessions running
directly on the host.

The 2026-11-13 design (2081-z7sh, eight packets, all `ready`, none claimed, waiting on seven
operator rulings) already covers the first half for a forge: `watch.register`, `watch.status`,
`watch.cancel` and `watch.list` on the lane socket, rules first, a tiny offline judge model second,
one escalation third, with no periodic poll. This note does not repeat it. It covers what that
design leaves out:

| Gap in the 2026-11-13 design | Why it matters now |
|---|---|
| No queue and no admission control. A watch attends one job; nothing decides whether a job may start | On the night of 2026-11-15 a forge's runaway tests starved macuahuitl of memory and froze the desktop while systemd-oomd marked the scope and never killed it (2093-gfak) |
| Forges only. A session on the bare host has no tool | Host sessions are where the release gates run. Their waiters are the `until grep` loops, and the harness reaps those under memory pressure |
| The judge is CPU-only on macOS and Windows, and one host was probed | The fleet has two XDNA2 NPUs, an Apple M5 and an idle integrated GPU that the design cannot reach |
| A watch ends on a progress file only | Most host waits are "this line appears in that log" or "this command exits" |

## Fleet hardware

Read from the fleet capability matrix (`tillandsias-plan capability-matrix`) and the capability-row
fragments, except macuahuitl, which was measured today. No peer was asked anything for this note;
the questions for peers are at the end.

| Host | CPU and memory | Accelerators | Schedulable today [ledger] | Present but unusable [ledger] |
|---|---|---|---|---|
| macuahuitl (Linux, bare metal) | Intel Core Ultra 7 265KF, 20 cores, 62 GiB RAM, 55 GiB swap [measured] | Intel NPU 8086:ad1d (3720 class), NVIDIA RTX A5000 24 GiB. No integrated GPU (KF part) [measured] | CPU and CUDA GPU, container and host-native Ollama | NPU: `engine-missing` |
| yoga (Linux, bare metal) | AMD Ryzen AI 5 340, 15.2 GiB RAM | AMD XDNA2 NPU, Radeon 840M integrated GPU | CPU and GPU in a container | NPU: `engine-missing` |
| yolanda (Windows host and WSL2 guest) | AMD Ryzen AI 7 350, 14.8 GiB RAM | XDNA2 NPU, Radeon 860M integrated GPU, both visible to Windows only | Nothing: no engine covers the host or the guest | NPU `engine-missing`; integrated GPU `host-native-only-not-container-reachable`; the guest's `/dev/dxg` has no Vulkan driver |
| lenovinha (Linux, bare metal) | AMD Ryzen 7 5800H, 13.5 GiB RAM | NVIDIA RTX 3070 Laptop (discrete), Radeon Vega "Cezanne" (integrated) | CPU and the discrete GPU | The integrated GPU is usable and unscheduled by policy (`discrete-gpu-preferred`: the discrete card decoded 4.3 to 4.9 times faster on 2026-09-04) |
| MacBook Air (macOS, bare metal) | Apple M5, 16 GiB unified memory | Metal GPU; the Neural Engine is not in the probe | CPU in a container; CPU and Metal host-native through Ollama | none listed |
| Floor tier: esmeraldinha (Intel N100), MacBook Neo (Apple A18 Pro) | small | none usable | nothing, or CPU only | no engine |

Every laptop has 13 to 16 GiB of memory. That, more than tokens per second, sets the model size:
a judge that holds 5 GiB resident is not acceptable there. Only macuahuitl has room for more.

## macuahuitl, measured 2026-11-17

**Devices.** `lscpu`: Intel Core Ultra 7 265KF, one thread per core, 20 cores, flags include
`avx2` and `avx_vnni` and no AVX-512. `lspci`: "Core Ultra 200 Series Processors NPU"
[8086:ad1d] and one VGA device, the RTX A5000. `intel_vpu` is loaded, `/dev/accel/accel0` is
`crw-rw-rw- root:render`, the kernel log names firmware `intel/vpu/vpu_37xx_v1.bin`, and
`npu_max_frequency_mhz` reads 1600.

**The NPU opens without root.** Fedora's own `npu-umd-test --gtest_filter='Device.*'`
(package `intel-npu-driver-test-1.32.0`) passed 6 of 6 device tests from an unprivileged shell,
including the Level Zero property and workload-type calls. That confirms the 2026-11-13 finding
by a second instrument: node, firmware, driver and permissions are in place.

**The NPU still cannot run a model.** Unchanged since 2026-11-13: Fedora's `intel-npu-driver`
ships only `libze_intel_npu.so` (`rpm -ql`), and Fedora's `openvino-2026.0.0-16` installs the CPU
and GPU plugins and no NPU plugin. There is no graph compiler in user space. Tokens per second on
this NPU remain [unmeasured]; that is 2081-4cpi's work and is not duplicated here.

**CPU and GPU, through the Ollama already on the host** (0.33.1, `ollama.service`, loopback
only). One warm request per row after one discarded cold request; a 156-token prompt holding a
six-line build log; the answer bound by a JSON schema to five states and a reason; 80 output
tokens at most; host load average about 4 from other work. One sample each, so these are orders
of magnitude, not benchmarks.

| Model | Placement | Decode | Resident (Ollama's figure, 32,768-token context) |
|---|---|---|---|
| qwen2.5:0.5b | CPU (`num_gpu` 0) | 42.9 tokens/s (80 in 1.87 s) | 936 MB |
| qwen2.5:0.5b | A5000 | 340 tokens/s (80 in 0.24 s) | 932 MB |
| qwen2.5:7b | CPU (`num_gpu` 0) | 5.3 tokens/s (29 in 5.50 s) | 6.9 GB |
| qwen2.5:7b | A5000 | 78.9 tokens/s (28 in 0.35 s) | 6.6 GB |

What the rows say:

- A half-billion-parameter model on the CPU answers a verdict in about two seconds. The CPU is
  enough for the judge on this host, as the 2026-11-13 design expected.
- A 7B model on the CPU is too slow and too large to be a babysitter anywhere in the fleet. The
  upper end of the operator's 0.5B to 8B range is only reachable on a GPU, and the judge must not
  take the GPU from a render.
- Resident size is set by the context window, not only the weights. Ollama's default 32,768-token
  context puts a 397 MB model at 936 MB. A judge bundle is at most 6 KB, so a 4,096-token context
  is ample and smaller. The saving is [unmeasured].
- Both models, at temperature 0, called a `No space left on device` build failure
  `failed_retryable`. A retry does not free a disk. One sample proves nothing about the models,
  but it is the argument for rules first in one line: a full disk is a rule, not a judgement.

**Memory pressure can be delivered as an event, without root.** Three probes from an
unprivileged shell on kernel 7.3.3:

- A pressure-stall trigger written to `/proc/pressure/memory` (`some 150000 2000000`: 150 ms of
  stall inside a 2 s window) was accepted. The same trigger with a 1 s window was refused with
  `Invalid argument`. The kernel's rule is that an unprivileged monitor's window must be a
  multiple of 2 s [source: https://docs.kernel.org/accounting/psi.html].
- The same trigger written to `memory.pressure` of the user's own `tillandsias.slice` cgroup was
  accepted. Pressure can be attributed to the forges' slice, not only to the whole machine.
- `memory.events` on that slice read `high 276147`, `max 0`, `oom 0`, `oom_kill 0`. Forges reach
  their `memory.high` throttle constantly and nothing is ever killed, which is the same picture
  2093-gfak gives from oomd's side.

`/proc/pressure/memory` read `avg10=0.00` during the probes. `oomctl` showed `Swap Used Limit
90%` with 24.5 of 55.9 GiB swap in use.

## Small models and licences

Licence, gating and revision were read today from the Hugging Face model API
(`https://huggingface.co/api/models/<repo>`), the same source the media register uses. Nothing was
downloaded and no terms were accepted.

| Model | Licence (API) | Gated | Revision read | Fits the open register |
|---|---|---|---|---|
| Qwen/Qwen2.5-0.5B-Instruct | apache-2.0 | no | 7ae55760 | yes; already pinned as tier T0 |
| Qwen/Qwen3-0.6B | apache-2.0 | no | c1899de2 | yes |
| Qwen/Qwen3-1.7B | apache-2.0 | no | 70d244cc | yes |
| Qwen/Qwen3-4B-Instruct-2507 | apache-2.0 | no | cdbee75f | yes |
| ibm-granite/granite-4.0-350m | apache-2.0 | no | bd8a1497 | yes |
| ibm-granite/granite-4.0-1b | apache-2.0 | no | 6a7381ba | yes |
| ibm-granite/granite-4.0-h-1b | apache-2.0 | no | d18cca4c | yes |
| HuggingFaceTB/SmolLM3-3B | apache-2.0 | no | a07cc9a0 | yes |
| microsoft/Phi-4-mini-instruct | mit | no | cfbefacb | yes |
| Qwen/Qwen2.5-7B-Instruct | apache-2.0 | no | a09a3545 | yes, but too large for the judge (above) |
| Qwen/Qwen2.5-3B-Instruct | other: qwen-research | no | aa8e7253 | **no**: non-commercial |
| LiquidAI/LFM2-1.2B | other: lfm1.0 | no | 40f3da0d | **no**: revenue cap |
| google/gemma-3-1b-it | gemma | manual | dcc83ea8 | **no**: gated, custom terms |
| meta-llama/Llama-3.2-1B-Instruct | llama3.2 | manual | 92131767 | **no**: gated, custom terms |

Not established today: the licence of each GGUF or OpenVINO conversion (a conversion repository
carries its own card and must be read when a file is pinned); Phi-3.5-mini, the small Mistral
models and Hermes-3 were not read.

**Where the pin lives.** `images/models/licence-register.tsv` and its restricted sibling hold
media models only; no text model is in either. Text models are pinned by sha256 in
`images/inference/tiers/gguf-pins.tsv`, and a tier row without a pin is refused. The judge's models
belong there, as 2081-bgh8 already says. No new register is needed.

**Function calling.** Published scores for models this small are thin and not comparable with one
another: Qwen3-1.7B 28.4 and Qwen3-4B-Instruct-2507 35.7 on a mirror of the Berkeley leaderboard
[source: https://www.datalearner.com/ai-models/leaderboard/berkeley-function-calling-leaderboard];
IBM's own 54.8 for Granite-4.0-1B on an earlier version of the same benchmark
[source: https://huggingface.co/blog/ibm-granite/granite-4-nano]. They matter little. The judge
calls no tool: it picks one word from a set the rules hand it, under a grammar. Every runtime
below can bind the answer to a JSON schema: Ollama's `format`
[source: https://docs.ollama.com/capabilities/structured-outputs], llama-server's `json_schema`
(2026-11-13 note), OpenVINO GenAI's `StructuredOutputConfig`
[source: https://docs.openvino.ai/2025/api/genai_api/_autosummary/openvino_genai.StructuredOutputConfig.html]
and OpenVINO Model Server's `response_format`
[source: https://docs.openvino.ai/2026/model-server/ovms_structured_output.html]. Whether the last
one holds on the NPU target is [unmeasured].

The order of preference stays the 2026-11-13 ladder, smallest first, promoted only on the labelled
set (2081-ngd8): Qwen2.5-0.5B, then Qwen3-0.6B, then Qwen3-1.7B. Granite-4.0-1B is the one
addition worth scoring beside Qwen3-1.7B. Nothing above about 2B is proposed for a laptop.

## Runtime per accelerator

| Hardware capability | Hosts that have it | Runtime | Speed | Blocked by |
|---|---|---|---|---|
| Any x86 or ARM CPU | all | llama-server in the inference image, 4 threads at most | 42.9 tokens/s decode for 0.5B on macuahuitl [measured]; laptops [unmeasured] | nothing |
| Intel NPU, 3720 class | macuahuitl | llama.cpp's OpenVINO backend or OpenVINO Model Server in a rootless container with `/dev/accel/accel0`. Model Server's NPU demo is documented as tested on Arrow Lake [source: https://docs.openvino.ai/2026/model-server/ovms_demos_llm_npu.html] | No published figure for this NPU. One blog measured about 9 tokens/s for a 1.5B model on the same NPU class with a 96 s first load [source: https://dev.to/mr1azl/i-tried-running-llms-on-intels-npu-heres-what-actually-happened-5h17] | The graph compiler is absent and its licence is unread (2081-4cpi, question 5 of 2081-z7sh). NPU prompts default to 1,024 tokens and models must be 4-bit symmetric, channel-wise [source: https://docs.openvino.ai/2026/openvino-workflow-generative/inference-with-genai/inference-with-genai-on-npu.html] |
| AMD XDNA2 NPU, Linux | yoga | FastFlowLM through Lemonade | Qwen3-0.6B on yoga, 2026-07-31: prefill about 1,950 tokens/s, decode 51 to 53 tokens/s [ledger: `plan/issues/npu-experts-poc-2026-07-31.md`] | FastFlowLM is mostly proprietary [ledger: `plan/issues/fedora-45-npu-igpu-research-2026-11-06.md`]. An operator licence decision (order 543) |
| AMD XDNA2 NPU, Windows | yolanda | The same pair, native on Windows. The NPU cannot be reached from WSL2, so the judge would be a process on the Windows host | [unmeasured] | The same licence decision, and a ruling on a judge outside a container |
| Integrated GPU beside a discrete one | lenovinha (Vega), yoga (840M), yolanda (860M, Windows side only) | llama-server on Vulkan through `/dev/dri`, the default Linux GPU lane of `inference-engine-slots` SLOT-4. The device is chosen by `GGML_VK_VISIBLE_DEVICES` [source: https://docs.ollama.com/gpu] | [unmeasured] for a 0.5B model. The 4.3 to 4.9 times deficit against the discrete card [ledger] is irrelevant for a 30-token answer | The `discrete-gpu-preferred` policy row must admit one exception: the judge |
| Apple Silicon, Metal | MacBook Air | llama-server or Ollama on the macOS host. The Linux guest sees neither Metal nor the Neural Engine | [unmeasured] on the M5 | A ruling on a judge outside a container |
| Apple Neural Engine | MacBook Air | Not proposed. The one project that runs language models on it is beta, short-context and reported several times slower than Metal [source: https://insiderllm.com/guides/apple-neural-engine-llm-inference/]; a secondary write-up, not checked against the project itself | — | — |
| Windows NPU through Foundry Local | yolanda | Not proposed now: its model catalogue for an AMD NPU was not confirmed, and its port is assigned at start [source: https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-local/concepts/foundry-local-architecture] | — | — |

Two honest conclusions:

1. **The CPU carries the judge everywhere today.** Every accelerator path is blocked by a licence,
   a missing compiler or a placement ruling, and none is needed for a two-second verdict asked a
   few times an hour. The NPU's real benefit is that a verdict would cost no CPU while a build is
   using all of it. That is worth having and not worth waiting for.
2. **On macOS and Windows the accelerator is outside the guest.** Reaching it means running the
   judge as a host process, which cannot be given `--network none`. That is a security posture
   change and belongs to the operator.

## Admission and queueing: what exists, what is missing

| Exists [ledger and code, by symbol] | What it does | What it does not do |
|---|---|---|
| `gpu_queue.rs`: `wait_for_gpu`, `GpuTurn`, `Arbiter::admit` | One GPU job at a time; evicts resident models to fit | Nothing about system memory or CPU |
| `studio_jobs.rs`: `studio.queue_workflow` | A ticket for one tool's batch | No admission, no restart |
| `memory_stall_watch.rs` (2067-dwqd) | Warns the desktop when a forge stalls at `memory.high` | Never acts |
| `oom_posture.rs` (1913-ebv8), `memory_protection.rs` with `forge_budget::ForgeBudget` (1913-fh6l) | Makes each forge the last oomd candidate; sets `memory.low` | Relies on oomd, whose kill does not land (2093-gfak) |
| `forge_swap.rs` (1376-8zdz) | A swapfile per forge | Delays the stall; does not prevent it |
| `resource_lock.rs`, `scripts/land-queue.sh` | Locks; serial landing | Not a queue for agents' jobs |

Nothing decides whether a heavy job may start. Three forges and a host gate can each start a
20-thread build in the same minute, and nothing stands between that and the swap.

A queue in the tray can do what oomd is failing to do, in a narrower and safer way: it only ever
stops a job that it started itself, by a declared argv, and it puts that job back in line. It does
not need oomd, root or a kill of anybody's forge. It does not fix 2093-gfak; a job started outside
the queue is still ungoverned, and the oomd defect still has to be found.

## Host sessions

`.mcp.json` gives a host session two stdio servers, `forge-plan` and `project-info`. No host
client for the lane socket exists. In a forge the bridge is a `socat` pipe to
`$TILLANDSIAS_CONTROL_SOCKET` (`images/default/config-overlay/mcp/host-browser.sh`), and the lane is
known from which listener accepted the connection (`mcp_socket.rs`: `LaneIdentity`,
`start_mcp_socket_server_for_lane`).

What a host session waits on today: 135 files under `scripts/` and `skills/` contain a `sleep N`,
314 lines in all, with 51 `while true` or `while :` lines and 15 `until` or `while !` lines (counted
2026-11-17 by search; the count includes fixtures). The standing notes on them: a background
waiter is reaped by the harness under memory pressure while a detached job survives; a foreground
command dies at the 10-minute tool limit; a waiter that only greps for a verdict cannot tell slow
from dead.

A host job started by the tray inside its own transient systemd scope answers all three: it
outlives the session's tool call, its exit is an event, and the scope carries a memory ceiling
that the kernel enforces on that job alone. `systemd-run --user --scope` needs no root, and the
user manager already delegates `tillandsias.slice` (the slice's `cgroup.kill`, `memory.events`
and `memory.pressure` are owned by the user [measured]).

Two limits to state plainly:

- Host processes of one user can all open one another's sockets. A host lane is attribution, not
  a wall. The wall that matters is that a forge cannot reach the host lane, because it is never
  mounted into one.
- A notification reaches a live connection. No harness today is woken from an ended turn by one
  (2012-kuw4 and 2014-slpw are the work for that). The practical bridge is one blocking call,
  `watch.wait`, that returns on the event or after a bound: a session waits inside a tool call
  that costs nothing while it blocks, instead of sleeping and looking.

## Language

`methodology.yaml` `runtime_language_policy`: Rust; POSIX shell only to dispatch existing binaries;
PowerShell only for Windows integration; anything else needs the operator. Go is not an accepted
language here (the only `.go` file is a template for user projects), so the babysitter is Rust in
the tray, beside `studio_jobs.rs` and `gpu_queue.rs`. Jobs, retry policies, classes and placements
are declared as data: tool arguments and TSV rows, never a shell string. `convergence.yaml`
`carried_obligations` puts `shell-to-lua` at the gentle stage; this work adds no shell, and each
replaced waiter loop under `scripts/` is one item a later pull request can carry.

## Questions for peers, to be relayed by the coordinator

Each is one measurement with more than one possible outcome. None asks a peer to install anything
or accept any terms.

1. **yoga:** is Lemonade with FastFlowLM still installed from the 2026-07-31 proof, and does
   `lsmod` still list `amdxdna`? Answer: installed and loaded / installed, driver absent / removed.
2. **yoga and lenovinha:** what does `vulkaninfo --summary` list, in order, and which index is
   the integrated GPU?
3. **lenovinha:** with the discrete card busy, how much memory is free at idle
   (`MemAvailable`)? The judge's size limit on a 13.5 GiB host depends on it.
4. **MacBook Air:** what decode rate and resident size does the host's Ollama report for
   `qwen2.5:0.5b` on Metal for one schema-bound request, as in the macuahuitl table above?
5. **yolanda:** which NPU driver version does Device Manager show, and is any of Lemonade,
   FastFlowLM or Foundry Local already present on the Windows side? Answer by listing; install
   nothing.

## Sources

Hugging Face model API (licences, gating, revisions, read 2026-11-17) ·
https://docs.kernel.org/accounting/psi.html ·
https://docs.openvino.ai/2026/model-server/ovms_demos_llm_npu.html ·
https://docs.openvino.ai/2026/openvino-workflow-generative/inference-with-genai/inference-with-genai-on-npu.html ·
https://docs.openvino.ai/2026/model-server/ovms_structured_output.html ·
https://docs.ollama.com/capabilities/structured-outputs · https://docs.ollama.com/gpu ·
https://lemonade-server.ai/flm_npu_linux.html · https://phoronix.com/news/amd-ryzen-ai-npus-linux-llms ·
https://huggingface.co/blog/ibm-granite/granite-4-nano ·
https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-local/concepts/foundry-local-architecture ·
https://insiderllm.com/guides/apple-neural-engine-llm-inference/ ·
https://dev.to/mr1azl/i-tried-running-llms-on-intels-npu-heres-what-actually-happened-5h17 ·
in this repository: `plan/issues/local-job-watchdog-design-2026-11-13.md`,
`plan/issues/npu-experts-poc-2026-07-31.md`, `plan/issues/fedora-45-npu-igpu-research-2026-11-06.md`,
the capability-row fragments under `plan/index.d/`, and packet 2093-gfak.
