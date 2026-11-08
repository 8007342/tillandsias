# Proposal — forge-lua-helpers

Umbrella packet: `2048-wu3h` (desired release v0.6). It executes the
`lib-*.sh first` step of
`plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md` §6.1/§6.5,
now that the image ships the plan binary.

## Why

The forge's shared helpers run on the two paths that every session pays for:

- **cold start** — `images/default/lib-common.sh` (5738 lines, 114 functions,
  117 pipe sites) is sourced by every entrypoint; `inject_startup_context`
  alone executes 71 command substitutions on 38 lines (167 further heredoc
  lines are template text, not commands), and `ensure_forge_harnesses` forks
  `npm` 13 times, `openspec` 9 and `curl` 5;
- **warm start** — both MCP servers (`forge-plan.sh`, 1809 lines / 117 pipes;
  `project-info.sh`, 1471 lines / 120 pipes) source three small helpers on
  every session and the usage-log writer on every tool call.

The five helpers below are small, pure, and hot. Measured on `macuahuitl`
2026-11-08 with `strace -f -e execve` and wall time:

| helper | lines | execve | wall | sourced by | paid |
|---|---:|---:|---:|---|---|
| `lib-inference-state.sh` | 132 | 8 | 9 ms | `lib-common`, both MCP servers, capability probes, litmus | cold + per session |
| `lib-experts-probe.sh` | 91 | 9 | 18 ms | both MCP servers | per session |
| `lib-ledger-freshness.sh` | 70 | 4 | 31 ms | `lib-common::inject_startup_context` | cold |
| `lib-mcp-build-id.sh` | 59 | 5 | 3 ms | both MCP servers | per session |
| `config-overlay/mcp/mcp-usage-log.sh` | 222 | `date` ×2 per call | — | every MCP server | per tool call |

Their parsing is also the fragile part: `tr ',' '\n' | sed | sort -u` for
Ollama JSON, three `sed` captures for the expert line, a `while read` loop over
`git for-each-ref`, a `sha256sum`/`shasum`/`cksum` fallback chain, and a
`date +%s%3N` clock whose BSD failure mode aborted an MCP server mid-call
(order `841-ruh9`).

Two facts make this the right moment:

1. The image now ships `policy-bin/tillandsias-plan` — a static musl build
   staged by `scripts/build-forge-plan-bin.sh` and symlinked to
   `/usr/local/bin/tillandsias-plan` — and its capabilities include `lua` and
   `script`. The design doc's precondition for `images/` (`§6.1` item 5,
   `§6.5`) is satisfied for `lib-*.sh`; entrypoints stay shell.
2. `tillandsias-plan script run` costs ~2 ms, the same order as a bash no-op
   (measured 1–6 ms over 10 runs). The win is not runner startup; it is
   removing 4–9 forks and the shell parse chain per helper.

A live defect sharpens the need: three of the helpers are **not copied into the
image at all** (`2047-ci2k`), so today the startup context drops ledger
freshness and both MCP servers report the tier probe and build id as `unknown`.

## What changes

- **Five helpers move to Lua** under `images/default/lua/`, keeping their file
  names, public function names, machine-line grammar and fail-soft fallbacks:
  `inference-state`, `experts-probe`, `ledger-freshness`, `mcp-build-id`,
  `mcp-usage-log`. The `.sh` files become thin resolvers that invoke the
  binary and read fixed-order lines.
- **A helper mode for the runner**: `tillandsias-plan script run --helper
  <file.lua>` — no verdict required, `verdict.*` refused, stdout is the
  script's alone, same stdlib restriction, `proc.*` and no pipes. Side-effect
  helpers (usage log) write nothing to stdout, so an MCP server's JSON-RPC
  stream is never touched.
- **Image packaging**: `Containerfile` copies `lua/` to
  `/usr/local/lib/tillandsias/lua/` and copies the three currently-omitted
  libs (`2047-ci2k`). A guard proves every sourced lib and every named Lua
  module is shipped.
- **A ratchet** (`check-helper-shell-population.lua`) counts shell-outs in
  `images/default/lib-*.sh` and refuses growth, so the migration is monotone.
- **Explicitly stays shell**: `lib-sigpipe-verdict.sh` (measures the OS pipe
  race), `lib-env-forward.sh` (emits shell source), `lib-ca-path.sh` and
  `lib-cargo-sites.sh` (host-side, before a host binary exists),
  `scripts/common.sh` (podman resolution at the top of `build.sh`),
  `entrypoint*.sh`, `lib-localized-errors.sh`, and
  `scripts/build-forge-plan-bin.sh` (it builds the binary).

## Impact

- **Cold start**: four helpers run per launch; ~26 forks and four shell parse
  chains removed. Wave 2 (decomposing `inject_startup_context`) is the larger
  prize and is designed here but not implemented in this change.
- **Warm start**: three helpers per MCP session and one writer per tool call;
  forks and the `%3N` crash class removed.
- **Cold/warm build**: indirect. The host build path is out of scope by
  ordering; the ratchet and the shipped-libs guard protect the image build
  from the regression this change found.
- **Stability**: JSON/structured parsing, deterministic byte ordering, one
  helper contract, and every named fallback preserved.

## Non-goals

- Porting `lib-common.sh` wholesale, the MCP server dispatch, or `build.sh`.
- Porting the host-side `scripts/lib-*.sh` that run before a host binary.
- Replacing `lib-sigpipe-verdict.sh`: it must measure real OS pipes.
- Rebuilding or booting the image; the normal release path does that.
