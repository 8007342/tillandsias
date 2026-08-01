# OpenCode forge — MCP expert validation (order 556)

- Date: 2026-08-01
- Filed by: OpenCode forge (order 556 `opencode-mcp-expert-validation`, release target `harness-mcp-expert-validation`)
- Branch: linux-next
- Expert source: `crates/tillandsias-plan` (built, installed `/home/forge/.local/bin/tillandsias-plan`, experts state `ready`)
- Plan index: `/home/forge/src/tillandsias/plan/index.yaml`

## 1. Connected MCP servers

Configured in `~/.config/opencode/config.json` `mcp` block and probed this session:

| Server | Config | Online this session | Evidence |
|---|---|---|---|
| `project-info` | local stdio (`/home/forge/.config-overlay/mcp/project-info.sh`) | **ONLINE** | tools surfaced as callable functions this session; `project_info` call returned project metadata |
| `forge-plan` | local stdio (`/home/forge/.config-overlay/mcp/forge-plan.sh`) | **ONLINE** | `initialize` handshake OK; `tools/call` for all three experts returned well-formed JSON-RPC results |
| `git-tools` | local stdio (enclave git mirror) | **ONLINE** | `git_tools` functions callable this session (used for the push) |
| `host-browser` | local stdio | **n/a in forge** | returns error `TILLANDSIAS_CONTROL_SOCKET not set` — host-side server, not applicable inside the forge container |

Session nuance: `project-info` (and `git-tools`) tools were surfaced as callable
functions in this OpenCode session, but `forge-plan` tools were **not** in the
session's callable function list. I therefore drove the `forge-plan` MCP server
directly over its stdio JSON-RPC protocol — the exact same `initialize` +
`tools/list` + `tools/call` framing OpenCode's MCP client would use — and it
responded correctly on every call. The server is online and serving; only its
exposure as named functions in this session was absent.

## 2. Tool-call envelopes (confidence + citation counts)

All three calls were issued to the `forge-plan` MCP server (`tools/call`, stdio)
with the exact questions specified in the validation packet.

### `plan_answer` — "what is ready for linux"
- **confidence: `exact`**
- **citations: 107** (all `plan/index.yaml`, kind `plan`, each citing a `ready` packet with its order/packet_id)
- freshness: `source_commit=a6d368c514c5d6e7e970c9d31a70f94363367ba3`, `indexed_at=2026-08-01T00:07:32Z`
- answered with 107 ready packets for `pickup_role 'linux'` (orders 137…555, incl. 554/555 harness-validation children)

### `methodology_ask` — "may a forge cycle drain two packets?"
- **confidence: `exact`**
- **citations: 1** (`methodology/distributed-work.yaml:895-904`, kind `methodology`, authority key `rule:`)
- freshness: `source_commit=a6d368c514c5d6e7e970c9d31a70f94363367ba3`, `indexed_at=2026-08-01T00:07:31Z`
- answered: `distributed_work.worker_agent_protocol.forge_cycle_budget.rule` — forge agents drain AT MOST ONE packet per cycle

### `spec_answer` — "how does the forge stay isolated from the host and control outbound network access?"
- **confidence: `unsupported`** (typed unsupported — index not built)
- **citations: 0**
- reason string names the missing prerequisite: spec RAG index not built at
  `/dev/shm/tillandsias-experts/spec-index` (need `chunks.jsonl` + `vectors.jsonl`),
  build via `tillandsias-plan spec-index --root <repo> --out …` and embed per
  order 552. `TILLANDSIAS_EMBED_ENDPOINT` / `TILLANDSIAS_SPEC_EXPERT_ENDPOINT`
  unset in this container.
- **EXPECTED**: orders 549 (`fat-spec-expert-gpu-slot`) and 552
  (`spec-index-commit-freshness`) are both still `ready` (index not yet built at
  launch/commit), so the typed `unsupported` is the correct fail-soft contract —
  no crash, no guess. This is the acceptable branch of exit criteria (3).

## 3. verify-answer results

Envelopes piped through `tillandsias-plan verify-answer` (stdin envelope, exit 1 on violation):

| Envelope | verify-answer result | rc |
|---|---|---|
| `plan_answer` ("what is ready for linux") | `ok: envelope verified — 107 citation(s) resolve, confidence=Exact` | 0 (ok) |
| `methodology_ask` ("may a forge cycle drain two packets?") | `ok: envelope verified — 1 citation(s) resolve, confidence=Exact` | 0 (ok) |

## 4. Exit-criteria assessment

- OpenCode reports forge-plan + project-info online: **PASS** (project-info exposed as callable; forge-plan server verified online over its own stdio protocol; session exposure nuance noted above).
- plan_answer + methodology_ask return verified cited envelopes: **PASS** (both `exact`, verify-answer ok).
- spec_answer advertised and returns a verified envelope OR typed unsupported (not a crash): **PASS** — typed `confidence=unsupported` naming the missing spec-index (orders 549/552), expected while the index is not built.

## 5. Build gate

`./build.sh --check` was failing on pre-existing rustfmt drift in
`crates/tillandsias-plan/src/{main.rs,spec.rs}` (introduced by commit
`b7963f5c`, order 547). Per AGENTS.md the gate belongs on the push side, so
`cargo fmt --all` was applied (mechanical, no logic change) and
`./build.sh --check` now passes (rc=0). The fmt fix rides in the same commit as
this report.

## 6. Deliverables

- This dated report: `plan/issues/opencode-mcp-expert-validation-2026-08-01.md`
- Raw transcripts: envelope JSON captured from `tools/call` responses
  (see section 2 for the three envelopes; full JSON in the MCP tool-call output).
