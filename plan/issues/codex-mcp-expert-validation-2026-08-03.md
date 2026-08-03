# Codex MCP expert validation — 2026-08-03

- **Packet**: `codex-mcp-expert-validation` (order 558)
- **Status**: verification slice complete; packet remains `ready`
- **Agent**: `forge-tillandsias-codex-20260803t214004z`
- **Host / branch**: `forge` / `linux-next`
- **Checkout**: `/home/forge/src/tillandsias` at startup head `fefd21dd543fc478b17f9dae072086e805d0d1b8`
- **Direction**: operator-owned forge-local EXPERTS theme in `plan/loop_status.md`

## Verdict

The Codex-specific validation is **RED at launch**. This is not an expert-engine
implementation failure: the raw stdio server starts and advertises its tools.
Codex has no MCP registration, and the launch-installed plan binary predates the
capability manifest. Rebuilding or installing a binary by hand would not prove
the launch contract and was deliberately not used as completion evidence.

| Criterion | Verdict | Evidence |
|---|---|---|
| Codex lists `forge-plan` and `project-info` at launch | **FAIL** | `codex mcp list` returned `No MCP servers configured yet.`; no MCP block or expert server name exists in `/home/forge/.codex/config.toml`; the running harness exposes no forge-plan/project-info tools. |
| `plan_answer` and `methodology_ask` return verified cited envelopes | **FAIL at launch** | Direct stdio calls reached the raw server, but both returned `confidence=unsupported`, zero citations, and `degraded(stale-binary:pre-capability-manifest)` with `skew=relaunch-required`. `tillandsias-plan verify-answer` accepted both honest refusal envelopes. |
| `spec_answer` is advertised and verified-or-typed-unsupported | **FAIL as a Codex surface; underlying fail-soft path PASS** | Raw `tools/list` advertises `spec_answer`; the call returned typed `unsupported`, zero citations, the same named stale-binary reason, and verified successfully. Codex itself cannot discover or call it because no MCP server is registered. |

`TILLANDSIAS_HOST_KIND=forge` is present but `TILLANDSIAS_AGENT` is unset. The
startup context identifies the harness as OpenAI Codex, so this cycle could
measure the as-found Codex state, but order 570 remains the routing-signal
blocker for automatic harness-affinity selection.

## Reproduction

```bash
codex mcp list

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"codex-validation","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | /home/forge/.config-overlay/mcp/forge-plan.sh
```

The second command lists `plan_answer`, `methodology_ask`, `spec_answer`, and
the deterministic plan tools, proving that transport and server discovery are
separate boundaries. Direct `tools/call` responses were extracted from
`result.content[0].text` and checked with:

```bash
tillandsias-plan verify-answer --root /home/forge/src/tillandsias
```

All three returned `ok: envelope verified — 0 citation(s) resolve,
confidence=Unsupported`; the zero-citation refusal is the intended fail-soft
contract, not a passing answer criterion.

## Root cause and shaped child

OpenCode has `images/default/config-overlay/opencode/config.json`; Claude has
`images/default/config-overlay/claude/mcp.json`; Codex has no equivalent MCP
registration or entrypoint merge. Child `codex-mcp-config-registration`
(order `600-xrqk`) owns that missing mechanism. A fresh Codex launch must rerun
order 558 after that child and order 570 land.

## Incidental enforcement findings resolved in this slice

The mandatory pre-push gate initially could not record its stamp because
`scripts/gate-stamp.sh` passed tracked skill symlinks to `sha256sum`, which
followed them into directories and exited `123`. The installer also wrote
`.git/hooks` even though this forge configures an external `core.hooksPath`, so
it reported success for hooks Git would never execute. The fixes hash symlink
target text, resolve the effective hook path through Git, and extend
`litmus:release-gates-run-locally`; all 15 steps pass. This is a completed
Linux/forge slice of `hooks-shipped-but-never-installed-audit` (order
`599-4wzr`); Windows and macOS activation evidence remains.

`codex mcp list` also emitted Node's `UNDICI-EHPA` experimental proxy-agent
warning. It did not affect this verdict, but it is captured here so the runtime
warning does not evaporate.
