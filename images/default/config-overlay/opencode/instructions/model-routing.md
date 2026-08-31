# Model routing inside Tillandsias forge

This forge runs two model pools that have different roles. Pick the
right one for each subtask.

## Default: opencode (Zen) for tool-driven work

The default model is `opencode/big-pickle` and `small_model` is
`opencode/gpt-5-nano`. These are tool-call-capable Zen models that
route through `models.dev` (allowlisted in the enclave proxy) and
require no user-supplied API key.

Use them for:

- Writing files, editing files, running commands.
- Multi-step tool calls (read file, modify, run tests, commit).
- Anything where opencode's tool protocol is involved.

## Local pool: ollama for offline analysis

The `ollama/*` models served from `http://inference:11434/v1` are
available for analysis tasks where tool calling is not needed.
Examples:

- Summarize a long log file.
- Classify a list of error messages.
- Generate a commit message draft from a diff.
- Translate or paraphrase free-text content.

Invoke them by sub-prompting with `--model ollama/<name>` (e.g.
`ollama/llama3.2:3b`). Stay inside the enclave; nothing leaks externally.

Do **not** rely on local ollama models to follow tool-call protocols
yet — that pathway is being prepared but is not in scope for the
current setup. Tool calling stays with the Zen models.

## Local model tier ladder (CPU-first, order 919-vvyv)

Which local model a host can honestly run is a RAM question first and a
GPU question second. The ladder below is anchored in measurements, not
vibes; where a rung is inferred rather than measured it says so. Read
the host's envelope from `.forge-startup-context.md` (`accel_class`,
`accel_ram_gb`) before picking.

| RAM (guest) | Model | Mode to expect |
| --- | --- | --- |
| < 4 GiB, CPU | `qwen2.5:0.5b` | RAG **mandatory**; retrieval-only is the NORMAL mode |
| 4–8 GiB, CPU | `qwen2.5:3b` + RAG | cited retrieval-only digest expected |
| 8–16 GiB, CPU | `qwen2.5:7b` **if** budget policy allows (927-2q4w open) | grounded synthesis, slow |
| GPU | `qwen2.5:7b`+ | grounded synthesis |

What each rung rests on:

- **Never trust raw small-model prose about this project.** On a
  CPU-only 3.8 GiB forge, 0.5b and 1.5b each hallucinated **6/6** spec
  queries without RAG (forge cache = "blockchain"; measured, 919-ipki).
  Below 4 GiB, 1.5b is the practical ceiling and RAG is not optional.
- **3b runs comfortably in 8 GiB but cannot satisfy the citation
  contract.** Measured resident: qwen2.5:3b (Q4_K_M, 2.42 GB) in an
  8 GiB guest with ~4.7 GiB still free, swap untouched (919-jii2).
  Measured contract: 3b echoed **0/6** retrieved keys and emitted no
  `Sources:` line, so its prose never survives the only-if-used
  citation filter — the pipeline degrades to the cited retrieval-only
  digest, which is the honest output for this rung (927-2q4w).
- **7b is the smallest model that passes the citation contract** (3/6
  keys verbatim plus a correct `Sources:` line, same prompt and
  context, only the model varied) — **but** it took 10–24s per
  synthesis on a measured CPU host, blowing the quick-tier 3000ms
  budget, so in-pipeline it times out into retrieval-only anyway. Until
  927-2q4w decides the budget policy, "7b on 8–16 GiB CPU" buys
  contract-capable synthesis only where the budget lets it finish.
  The 10–24s figure is one host (darwin M5, CPU-only); other CPUs
  should measure with `scripts/bench-inference-floor.sh` rather than
  inherit it.
- **GPU rung**: inferred from sibling-host reports (7b as the sweet
  spot) plus the measured CUDA tuning A/B in
  `images/inference/engine-tuning.sh`; it is the one rung with no
  citation-contract measurement of its own yet.

Whatever the rung, `spec_answer` / Local Experts answers are cited or
refuse typed — the ladder changes HOW MUCH synthesis you get, never
whether uncited prose is acceptable (it is not, at any size).

## Local Experts mode: grounded (order 920-pxg6)

The `local-experts` agent talks to the grounded loopback endpoint served
by `tillandsias-plan expert-serve` beside these MCP servers (provider
`tillandsias-experts`, `http://127.0.0.1:11436/v1`; the model backend
stays `inference:11434` via env). Every completion is either a CITED
answer — retrieval from the published spec index, citations kept only if
the prose used them, Rust-validated — or a TYPED refusal whose content
begins `unsupported: ` naming the missing capability. There is no
raw-model fallback. The model id selects the retrieval domain: `all`,
`spec`, `code`, `methodology`, `cheatsheet`.

Non-stream responses carry `rag_source_commit` (the index entry's own
build commit, 801-g9nn — not this checkout's HEAD) and
`tillandsias_envelope`, the full ratified envelope, which
`tillandsias-plan verify-answer` audits. The `tillandsias-plan pipeline`
CLI arm is the SAME pipeline's second front-end and emits that envelope
directly. Pick the lane by question shape: deterministic single-node
lookups (one packet, one rule) → `plan_answer` / `methodology_ask`;
cross-spec joins → `spec_answer`; conversational or synthesis status →
this Local Experts mode. If the endpoint refuses connections,
expert-serve is not running in this forge (a pre-920-pxg6 binary, or
the port was taken) — use the forge-plan MCP tools (`spec_answer`,
`plan_answer`, `methodology_ask`) instead. On a typed `unsupported:`
refusal or a degraded `experts_state` (see `.forge-startup-context.md`;
`scripts/check-mcp-expert-health.sh` probes it), fall back to reading
the `plan/` files and RECORD the fallback in your output
(`mcp_first_read_path`).

## Fleet naming (Zen siblings)

Coordination ledgers name in-forge agents after their Zen model:
**BigPickle** is `opencode/big-pickle` (the default above); **Hy3** is
BigPickle's bigger Zen sibling, `opencode/hy3-free`, selected for heavier
in-forge work. This identifier was resolved on 2026-07-20 from the live
opencode models catalog; re-verify it on opencode upgrades because the Zen
catalog is upstream-controlled.
Other free Zen models may be trialed over time (operator, 2026-07-17);
identify yourself in plan ledger entries by the model you actually ran
as (e.g. `linux-bigpickle-opencode-<ts>`). As local experts mature,
work will progressively split across models by capability — see
plan/issues/agent-fleet-and-zeroclaw-roadmap-2026-07-17.md.
