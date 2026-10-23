# Design — local-coding-experts-delegation-ladder

## 1. Routing

The four tiers, cheapest first: local (new) → haiku → sonnet → opus.

```
select-work-batch.sh
  row.implementer_tier == local?
     ├─ TILLANDSIAS_INFERENCE_ENDPOINT answers → offer to local-delegate.sh
     │     ├─ verdict ok + frontier verifies → frontier commits; outcome accepted
     │     └─ any other verdict / frontier rejects → row runs at haiku; outcome rejected
     └─ endpoint down → row runs at haiku (no outcome recorded)
```

- **Today the vocabulary is closed.** `crates/tillandsias-plan/src/lib.rs` allows only haiku, sonnet and opus. `local` is added there.
- **The fixture changes too.** `scripts/test-packet-tier-fields.sh` gains an arm that `local` is accepted, and keeps the arm that `gpt` is refused.

## 2. The delegate

`scripts/local-delegate.sh implement <order>` uses the same argument shape and verdict style as `scripts/claude-delegate.sh`.

### Inputs

- **Row fields** come through `tillandsias-plan json get` / `yaml-get`. The script uses no jq and no python.
- **The prompt** is built in this order:
  1. the context pack (`.forge-expert-context.md`, from change local-experts-grounded-tellme-and-context-pack);
  2. the goal (title and context);
  3. the exit criteria;
  4. the owned files;
  5. for each owned file, 3–5 of the nearest existing code chunks, retrieved from the expert as idioms to copy.

### Tool loop

- Requests are OpenAI-compatible chat completions with tools.
- The tools are `read_file`, `write_file` (owned files only), `run_closure` and `finish`.
- The loop is bounded by a turn count and by wall time.

### Scope check

After the loop, `git diff --name-only` must name only files in `owned_files`. Any stray edit is reverted, and the verdict becomes `out-of-scope`.

### Closure

The script runs the row's closure command once at the end. The command comes from `verifiable_closure` or `unscoreable`, whichever names it.

### Output

- The script prints one verdict line: `local-delegate:<order>:<ok|closure-red|out-of-scope|timeout|no-endpoint>`.
- It never creates a commit.
- The frontier session then reviews the diff, runs the gate, and commits or discards.

## 3. Outcome ledger

The frontier session records each outcome as a token in an event summary:

```
local-delegate:<model>:<quant>:<order>:<accepted|rejected|reverted>:<frontier_tokens_avoided>:<retries>
```

### Recording

- The token is written by `scripts/delegate-outcome.sh local-record`.
- The existing `delegate-outcome:<id>:<disposition>` grammar is unchanged.
- `reverted` means the result was accepted and later reverted. It counts against acceptance and also counts as a revert.

### Aggregation

`scripts/local-delegate-ladder.sh` groups the tokens by (model, quant) and prints `rung=<R0..R4|none:sample>`. For R1–R3 it requires at least 20 outcomes before it reports a rung.

## 4. Bench and replay

### Tool-call arm

`scripts/bench-inference-floor.sh --tool-call` prints `tool_call_roundtrip=ok|malformed|none` and the latency. It shows whether a model can produce a well-formed tool call and then use the tool's result.

### Replay set

`scripts/local-delegate-replay/` holds 20 landed size:S packets. Each one records:

- the pre-fix commit (the merge parent);
- the owned files;
- the closure command.

`verify-set.sh` checks that every closure fails on its pre-fix commit and passes on its landed commit.

### Models

| Model | Host | Note |
|---|---|---|
| Qwen3-Coder-30B-A3B, Q5 | macuahuitl | pull approved by the operator |
| Devstral Small 2 | a Mac (Metal) | handed to that host as a condition-shaped message |

Every result is recorded with its regime: host, GPU, quant and ollama version.

## 5. Deferred: SFT/QLoRA

This work starts only if the aggregator records the best model below 80% acceptance over at least 50 outcomes (R3 stalled). Until then the packet stays `pending`.
