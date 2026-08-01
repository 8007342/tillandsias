# Live forge launch — experts + MCP servers validated in-enclave (2026-08-01)

- class: validation (order 556 evidence) + optimization (two launch bugs found)
- host: yoga (linux_immutable). Tray built + installed v0.4.260731.1
  (`./build.sh --install`), stack provisioned (`tillandsias --debug --init`),
  OpenCode forge launched against this repo — all NON-destructive
  (TILLANDSIAS_DESTRUCTIVE_RESET_OK=0; the rocm-fastflowlm + lemonade NPU
  toolboxes and the Qwen3-4B/nomic models were preserved throughout).

## Headline

**A freshly built + launched OpenCode forge brings the expert MCP servers online
and answers verified, cited queries — including the new fat spec expert tool.**
Proven by direct exec into the running `tillandsias-tillandsias-forge` container.

## In-forge validation (order 556, direct-exec evidence)

The forge built the plan expert binary at launch (`ensure_forge_experts` →
`~/.local/bin/tillandsias-plan`, experts state = `ready`). `forge-plan.sh`
tools/list advertises all 10 tools including the new **`spec_answer`**:

    plan_check plan_status plan_ready plan_blocked_by plan_closure plan_burndown
    plan_answer methodology_path methodology_ask spec_answer

Calling them inside the forge:

| tool | confidence | citations | note |
|---|---|---:|---|
| `plan_answer` {"what is ready for linux"} | exact | 107 | real ledger answer |
| `methodology_ask` {"may a forge cycle drain two packets?"} | exact | 1 | routed to forge_cycle_budget.rule |
| `spec_answer` {"forge isolation + egress?"} | unsupported | 0 | typed fail-soft: "the spec RAG index is not built at /dev/shm/tillandsias-experts/spec-index" — EXPECTED (index build is orders 549/552) |

`tillandsias-plan verify-answer` on the methodology_ask envelope (re-parsed
across the tool boundary): **`ok: envelope verified — 1 citation(s) resolve,
confidence=Exact`**.

So: MCP servers ONLINE at forge launch ✓; the plan + methodology experts answer
with verified cited envelopes in-enclave ✓; the fat spec expert is present +
advertised + returns an honest typed `unsupported` (never a crash/guess) until
its RAG index + enclave embedding endpoint are wired (orders 549/552) ✓. An
OpenCode forge's MCP panel will therefore list forge-plan (with all three expert
tool families) + project-info.

## Two launch bugs found (this is what live testing is for)

### 1. opencode harness install is not idempotent — ENOTEMPTY on a stale temp dir (order 559)
First launch died: `opencode install FAILED … npm error ENOTEMPTY: directory not
empty, rename '…/node_modules/opencode-ai' -> '…/.opencode-ai-ff9y6F6O'`. A
previous partial/interrupted npm global install left both `opencode-ai` and a
`.opencode-ai-<rand>` temp dir in the persistent npm cache volume
(`tillandsias-forge-cache-tillandsias`), so npm's atomic-rename install fails
every launch — the forge never starts the agent. Fixed THIS launch by hand
(removed the stale dirs via a root container), and the relaunch installed
opencode cleanly and the forge came up. But it will recur on any interrupted
install: the launch-time install must be self-healing (clear a stale
`.<pkg>-*` temp + a half-written `<pkg>` dir before `npm i -g`, or install into
a fresh prefix and swap). Filed as order 559.

### 2. inference exit_code=1 during the failed launch was teardown collateral, not a bug
The first (failed) launch logged `container_exit tillandsias-inference
exit_code=1` right as opencode failed. Running the v0.4 inference image
standalone starts cleanly (installs ollama, listens on :11434, discovers GPUs) —
the exit-1 was the launch's failed-lane cleanup removing inference, not an
independent inference defect. No packet needed; noted for future triage so it is
not mistaken for an inference regression.

## Verified non-destructive

Throughout build → init → two forge launches: the NPU toolboxes
(rocm-fastflowlm, lemonade) and the Qwen3-4B/nomic HF models remained intact
(TILLANDSIAS_DESTRUCTIVE_RESET_OK=0; no `podman system reset` was run).

## Next

- Order 559: make the opencode (and other npm-harness) launch install idempotent.
- Orders 549/552: build the spec RAG index at forge launch + wire
  TILLANDSIAS_EMBED/SPEC_EXPERT_ENDPOINT to the enclave inference so `spec_answer`
  retrieves in-enclave (it already works against a local endpoint — proven in
  spec-experts-live-2026-07-31.md).
- Orders 556/557/558: the per-harness validation packets can now be drained by a
  forge running each harness (this doc is the OpenCode direct-exec evidence; the
  in-forge opencode LLM agent was also dispatched to self-report).
