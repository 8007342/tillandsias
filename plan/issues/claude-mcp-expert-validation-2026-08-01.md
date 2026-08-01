# Claude forge — MCP expert validation (order 557)

- Date: 2026-08-01
- Filed by: Claude forge (`forge-claude-fable-metaorch-20260801`, container
  `tillandsias-tillandsias-forge-claude`, order 557
  `claude-mcp-expert-validation`, release target `harness-mcp-expert-validation`)
- Branch: linux-next (worktree from origin/linux-next 1c76d655; checkout itself
  was a `main` snapshot, which turned out to be load-bearing — see defect B)
- Evidence: raw transcripts, envelopes, and timing files under the cycle
  scratchpad `557-evidence/` (ephemeral); every claim below is reproduced in
  this report with its command.

## 1. MCP discovery in the Claude harness — criterion 1 FAILS

Claude Code discovers MCP servers from project `.mcp.json`, `~/.claude.json`
(user and per-project scope), settings files, managed config, plugins, or a
`--mcp-config` launch flag. **All nine surfaces were probed; none exists or
none carries the expert servers:**

| Surface | State |
|---|---|
| `<repo>/.mcp.json` (checkout AND linux-next) | absent — never committed |
| `~/.claude.json` top-level `mcpServers` | key absent entirely |
| `~/.claude.json` `projects[<repo>].mcpServers` | `{}` (empty); `enabledMcpjsonServers=[]` |
| `~/.claude/settings.json` / `settings.local.json` | no MCP keys / file absent |
| `<repo>/.claude/settings.json` / `settings.local.json` | absent / permissions-only |
| `/etc/claude-code/` managed config | absent |
| `entrypoint-forge-claude.sh` `--mcp-config` flag | not passed |
| Plugins (`~/.claude/plugins`) | marketplace metadata only |

Contrast — how opencode gets them: `images/default/Containerfile:105-120`
bakes `config-overlay/opencode/config.json` (whose `mcp` block registers
git-tools / project-info / host-browser / forge-plan) into
`~/.config/opencode/` and the overlay copy, and
`lib-common.sh::apply_opencode_config_overlay()` (line 2523) re-applies it at
runtime from `entrypoint-forge-opencode{,-web}.sh` and
`entrypoint-terminal.sh`. **`entrypoint-forge-claude.sh` has no equivalent** —
the only Claude config it materializes is `openspec init --tools claude`
(which is also the source of the order-540 opsx dirt). The expert servers and
binary DO exist in Claude forges (`ensure_forge_experts` is harness-agnostic);
only the registration pointer is missing.

Shaped as **order 568** with three candidate mechanisms (repo `.mcp.json`;
forge-only `apply_claude_config_overlay()`; `--mcp-config` launch flag) and
their tradeoffs recorded in the packet.

## 2. Tool-call envelopes as found — DEGRADED, and honestly so

`forge-plan.sh` tools/list advertises all 10 tools (incl. `plan_answer`,
`methodology_ask`, `methodology_path`, `spec_answer`). Called over stdio
JSON-RPC (the framing a real MCP client would use), as found at launch:

| Tool | Result | Cold overhead |
|---|---|---|
| `plan_answer` "what is ready for linux" | `confidence=unsupported`, 0 citations, freshness unknown | 5–6 ms |
| `methodology_ask` "may a forge cycle drain two packets?" | `confidence=unsupported`, 0 citations | 3–5 ms |
| `spec_answer` (isolation question) | typed unsupported naming the missing `/dev/shm/…/spec-index` — the EXPECTED branch while 549/552 are open | 5–6 ms |
| `project-info` `plan_query` status=ready | correct JSON array of 5 ready packets | ~5 ms |

**Root cause (hash-proven):** `~/.local/bin/tillandsias-plan` (587 KB, built at
provision 00:42Z) is a pre-394b build — usage lists only
check/status/blocked-by/blocked-closure/ready/burndown/append-event; no
`answer`, no `methodology-*`, no `verify-answer`, no `grade`. Replicating
`lib-common.sh::_forge_experts_source_hash` (sha256 over the plan crate's
sorted sources + Cargo.lock) over the **main** checkout reproduces
`/dev/shm/tillandsias-experts/plan-source-hash` exactly: the launch-time
expert build compiles whatever crate the mounted checkout carries, and this
container's checkout is a `main` snapshot. `state=ready` means "launch build
completed", not "expert capable" — misleading. The wrapper's envelope-shape
guard correctly downgraded the stale binary's output to typed unsupported
envelopes (fail-soft contract HELD; no crash, no fabricated answer).

## 3. Post-fix re-probe — the lane heals end-to-end

`cargo build -p tillandsias-plan --release` from the linux-next worktree took
**12.79 s** (landing in the redirected `CARGO_TARGET_DIR` under
`~/.cache/tillandsias-project/cargo/target` — which is exactly why the
wrapper's `<root>/target/release` fallback probe misses it; order 561
reproduced live). After `install -m0755` over the canonical path:

- `plan_answer` → **`confidence=exact`, 83 citations**, honest freshness
  (`source_commit=7a593409` = the main checkout it indexes, `indexed_at`
  stamped). 83 ready-for-linux on main vs 110 on linux-next — the delta is
  branch skew, correctly attributed by the envelope's own freshness field.
- `methodology_ask` → **`confidence=exact`, 1 citation** —
  `methodology/distributed-work.yaml:895-904`, the `forge_cycle_budget` rule
  (AT MOST ONE packet per forge cycle), independently confirmed by reading the
  cited span.
- `tillandsias-plan verify-answer` on both direct envelopes: **rc=0**,
  `ok: envelope verified — 83/1 citation(s) resolve, confidence=Exact`.
- Ground-truth harness `scripts/check-forge-expert-base.sh` (linux-next):
  `ok:expert-base-ready`, rc=0.

## 4. Exit-criteria assessment

- Claude `/mcp` listing shows the expert servers at launch: **FAIL** — no
  discovery surface exists (section 1). Fix shaped as order 568.
- `plan_answer` + `methodology_ask` return verified cited envelopes: **PASS
  with two caveats** — requires a capability-current binary (defect B) and was
  exercised over raw stdio because of the FAIL above; with both, envelopes are
  exact, cited, and `verify-answer`-green.
- `spec_answer` advertised + verified-or-typed-unsupported: **PASS** — typed
  unsupported naming the unbuilt spec-index (orders 549/552), same as the 556
  opencode result.

Order 557 therefore stays open (multi_cycle) pending 563; this cycle's
progress event records the evidence.

## 5. Defects captured this run

- **A. No Claude MCP registration surface** → promoted as **order 568**.
- **B. Stale expert binary with `state=ready`** — a forge whose checkout is
  `main` builds a pre-394b expert and reports ready; the stale binary also
  prints usage and **exits 0 on unknown subcommands**, so nothing downstream
  can tell capability from success. Promoted as **order 569**, together with:
  wrapper JSON-RPC framing **un-escapes control characters** (the binary's
  strict-valid `\n`/`\t` become raw bytes inside the JSON-RPC string — a
  strict client rejects the frame; reproduced: python `json.loads` fails
  strict, passes `strict=False`), and the CLI's YAML-warning diagnostics go to
  **stdout**, corrupting the envelope stream (observed with main's
  `methodology/provenance.yaml` duplicate-`limits` key, which is already
  clean on linux-next).
- **C. `TILLANDSIAS_AGENT` is never set** — `SelectedAgent::as_env_str()`
  (tillandsias-core `config.rs`) and the `container_profile.rs` ProfileEnvVar
  exist, but only unit tests consume that machinery; the real forge launch
  path (`tillandsias-headless` `tray/mod.rs` ~1760-1822) builds the podman
  spec by hand and omits the var. `entrypoint-forge-claude.sh` exports only
  `TILLANDSIAS_AGENT_NAME="Claude Code"` (attribution). Order 555's
  harness-affinity routing has no signal in ANY live forge. Promoted as
  **order 570** (555 should depend on it).
- Cosmetic, noted only: `tillandsias-plan ready | head` panics on broken pipe;
  the opencode overlay advertises 10 ollama models at `http://inference:11434`
  which does not resolve on this forge's network (consistent with the
  393-amended "rung 1 ships ZERO inference" decision — the deterministic lane
  is the expert lane; the dead provider entries are an affordance wart for the
  397/406 lanes to clean up).

## 6. Time / cost / quality — the expert lane vs the alternatives

Corpora (linux-next): `plan/index.yaml` 1.65 MB / 27,358 lines ≈ 413k est
tokens; `methodology/` 487 KB ≈ 122k; `openspec/specs/` 1.38 MB ≈ 344k. The
plan ledger alone no longer fits in most model context budgets, and Claude
Code's `Read` caps at 2000 lines → 14 serial reads to browse it naively.

Measured in this container (medians of 3):

| Lane | Wall time | Tokens (in/out) | $/query Fable 5 | $/query Opus 5 |
|---|---:|---:|---:|---:|
| Deterministic CLI (`tillandsias-plan ready`) | **30 ms** | 0 | $0 | $0 |
| Cold MCP stdio round-trip (wrapper overhead) | +7.5 ms | — | — | — |
| MCP expert call from a cloud agent | ~11 s | 3.5k / 300 | **$0.050** | $0.025 |
| Grep-browse (4 excerpt round-trips) | ~20 s | 12k / 700 | $0.155 | $0.078 |
| Naive full-ledger Read (14 calls) | ~50 s | 415k / 700 | **$4.18** | $2.09 |
| (reference) full python yaml.safe_load | 621 ms | — | — | — |

The expert lane is ~80× cheaper and ~5× faster than naive browsing for a
cloud agent, and effectively free/instant (30 ms, $0) when the agent shells
out to the CLI directly. Quality is higher, not lower: answers arrive as
CITED envelopes that `verify-answer` can mechanically audit, vs. un-audited
prose synthesis over a 413k-token context. This independently re-confirms the
393 amended decision ("an expert is a cited retrieval surface, not a model")
from inside a Claude forge, on live measurements.

## 7. Deliverables

- This report (order 557's dated deliverable).
- Orders 568 / 569 / 570 filed in `plan/index.yaml`; progress events appended
  to 557 (this validation), 555 (env-var blocker), 561 (target-dir repro) via
  the validated `append-event` path.
- Ledger hygiene: `npu-container-citizenship-e2e` `done`→`completed` (last
  order-440 vocabulary straggler; schema-drift advisory now zero).
- `chore(opsx)` sync of the 22 launch-regenerated openspec files (order-540
  class, merged per the 2026-07-31 operator decision instead of refusing).
- Freshness audit (order 372): `scripts/check-cheatsheet-staleness.sh`
  re-validated → **refreshed** (ran clean, exit 0).
