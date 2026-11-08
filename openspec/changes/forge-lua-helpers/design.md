# Design — forge-lua-helpers

## Context

`plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md` sets the
migration order: deciders with recorded incidents, then the litmus executor,
then land/relay tooling, and `images/` **after the image ships the plan
binary**, `lib-*.sh` first. The image now does:

- `scripts/build-forge-plan-bin.sh` builds `tillandsias-plan` as a static musl
  binary and stages it at `images/default/policy-bin/tillandsias-plan`;
- `Containerfile` copies `policy-bin/` and symlinks
  `/usr/local/bin/tillandsias-plan`;
- the staged binary's `capabilities` include `lua` and `script`.

So a `lib-*.sh` in the image can call `tillandsias-plan script run` at
entrypoint time. What it cannot do is print a decider verdict: these helpers
are **sourced functions**, not gate steps, and one of them is sourced by MCP
servers whose stdout is the JSON-RPC stream.

## Census (measured 2026-11-08, macuahuitl)

- `scripts/*.sh`: 864 files; `scripts/lua/`: 259 deciders already.
- `images/default/lib-common.sh`: 5738 lines, 114 functions, 117 pipe sites.
  - `inject_startup_context`: 590 lines, **71** command substitutions on 38
    executing lines (167 heredoc-body lines are template, not commands); 12
    `git`, 8 `tillandsias-plan`, 3 `node`, 2 `python3`.
  - `ensure_forge_harnesses`: 176 lines, 19 substitutions, 13 `npm`, 9
    `openspec`, 5 `curl`.
  - `ensure_forge_experts`: 215 lines, 24 substitutions, 16 `cargo`, 8
    `tillandsias-plan`.
- `scripts/common.sh`: 387 lines, 2 execve at source time, 3 ms.
- `scripts/lib-ca-path.sh`: 57 lines, 10 execve at source time, 3 ms.
- `tillandsias-plan script run` on a trivial decider: 1–6 ms over 10 runs;
  `bash -c ':'` is 1–2 ms.
- The five target helpers: see the table in `proposal.md`.

## D1 — The helper contract

Add `tillandsias-plan script run --helper <file.lua> [-- args...]`.

- **No verdict.** `--helper` does not register `verdict.*`; a helper that
  calls one is refused (`refused:helper-called-verdict:<name>`). A normal
  return exits 0; a Lua error exits 1 with a stderr diagnostic. A helper is
  not a decider and must never be wired as a gate step.
- **stdout belongs to the script.** The runner adds nothing. This is what makes
  a helper safe to source from an MCP server: the JSON-RPC stream is untouched.
- **Same environment.** The `Cacheable`/`Observing` split, `@env`,
  `@read-env`, fs roots, `json`/`yaml`/`hash`/`path`/`time` and
  `proc.run`/`spawn`/`select`/`all`/`chain` are unchanged. No pipes, as in
  every script.
- **Value shape.** A multi-value helper prints one value per line, in the
  order its header documents; absent/unknown is `-` or `unknown`, never an
  empty line (an empty line would read as a missing value). A one-value helper
  prints one line. The shell wrapper reads with `IFS= read -r`; no `eval`, no
  `sed`.
- **Class.** All five helpers are `-- @class observing`: they take runtime
  arguments (a directory, an endpoint, a binary path) and the `Cacheable`
  cache is keyed on script content and reads, not arguments, so memoising them
  would be wrong. `cacheable` remains for argument-free predicates.

**Fallback if a runtime change is rejected.** Express each value helper as a
decider whose `ok:<name>` payload is the same fixed-order values and have the
wrapper capture and strip the prefix. That cannot serve the side-effect helper
cleanly (its stdout must be captured, not printed), which is why `--helper` is
recommended.

## D2 — Module layout and the shell boundary

- New directory `images/default/lua/`, copied to
  `/usr/local/lib/tillandsias/lua/`.
- Each `.sh` keeps its filename and public function name; only its body
  changes. Every caller, litmus fixture and test keeps working.
- The wrapper resolves the module beside itself:
  `${BASH_SOURCE[0]%/*}/lua/<name>.lua`. In the image that is
  `/usr/local/lib/tillandsias/lua/...`; in a checkout it is
  `images/default/lua/...`. The MCP wrappers resolve the `.sh` the same way
  they do today (source tree, then image path).
- **There is no second implementation.** If the binary or module is missing,
  the wrapper emits the same named fallback the old code emitted when its tool
  was absent (`unknown`, `unavailable`, `NOT-READY (probe-tool-missing: ...)`),
  never a silently different answer.

## D3 — The five conversions

### D3.1 `lib-inference-state.sh` → `lua/inference-state.lua`

- `proc.run{argv={"curl","-fsS","--max-time","1", endpoint.."/api/tags"}}`.
- `json.decode`; count and byte-sort `models[].name` (the shell used
  `sort -u`). Replace `tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'`.
- Preserve the closed reason vocabulary exactly: `probe-tool-missing`,
  `endpoint-unreachable` (with the engine-refused suffix), `endpoint-timeout`,
  `endpoint-http-error`, `probe-error-<n>`, `no-models` (with the long
  detail). A malformed body maps to `no-models`/`probe-error` exactly as the
  `sed` did.
- Print the two lines the current function emits (`inference_state=...` then
  the human status); the wrapper sets the same `TILLANDSIAS_INFERENCE_*`
  variables. Keep the file POSIX-`sh`-sourceable.

### D3.2 `lib-experts-probe.sh` → `lua/experts-probe.lua`

- `proc.run` the binary's `capabilities` (must contain `experts-probe`) then
  `experts-probe`; parse the `experts_probe: l0=... l1=... l2=... embed=...
  synth=... advice=...` line with string matching (advice runs to EOL).
- Preserve `probe-binary-missing`, `probe-subcommand-missing`,
  `probe-no-verdict`, and the closed tier vocabulary
  (`ready|unset|unreachable|scheme-unsupported|malformed|unknown`).

### D3.3 `lib-ledger-freshness.sh` → `lua/ledger-freshness.lua`

- Three `proc.run` git calls: `rev-parse --short HEAD`, `log -1 --format=%ct`,
  `for-each-ref refs/remotes/origin --sort=-committerdate
  --format=%(refname:short) %(committerdate:unix)`.
- Skip `origin` and `origin/HEAD`; strip `origin/`; compute
  `(newest_ts - head_ts) / 3600`, floored at 0. Any failure keeps
  `unknown`/`0`; never a guessed negative.

### D3.4 `lib-mcp-build-id.sh` → `lua/mcp-build-id.lua`

- `hash.sha256` over the file; print the first 12 hex chars, or `unknown` if
  unreadable. This deletes the `sha256sum`/`shasum`/`cksum` fallback chain and
  the `cut`.
- Caveat: `hash.sha256` takes a string, so the file is read whole. The MCP
  server script is ~111 KB; a future large-file caller would need a streaming
  path. Recorded, not solved here.

### D3.5 `config-overlay/mcp/mcp-usage-log.sh` → `lua/mcp-usage-log.lua`

- `time.now_ms()` replaces `date +%s%3N` (the `%3N` hazard of `841-ruh9`);
  `json.encode` builds the record; append one line to
  `TILLANDSIAS_EXPERT_USAGE_LOG` (default `/tmp/forge-expert-usage.jsonl`).
- Best-effort by construction: any error is swallowed and the helper exits 0.
  The wrapper redirects stdout to `/dev/null`, so the MCP stream is untouched.
- Keep `mcp_now_ms` and `mcp_log_usage` names and signatures.

## D4 — Hardening

- **Ratchet.** `scripts/lua/check-helper-shell-population.lua` counts
  `lib-*.sh` functions in `images/default/` that shell out, with a baseline
  that may only decrease; it names each migrated file and refuses a new
  shell-out. Wire it as a gate step beside `check-carried-obligations.lua`.
- **Shipped-libs guard (prerequisite `2047-ci2k`).** Every `lib-*.sh` sourced
  by `lib-common.sh` or the two MCP wrappers, and every `lua/*.lua` module the
  wrappers name, must appear in the Containerfile. This is the defect this
  survey found; the guard is what stops the next one.
- **Determinism.** `observing` for all five; fixed-order lines; byte-sorted
  model names; `os.setlocale` already withheld by `lua_std`.
- **MCP stdout safety.** A test runs each wrapper with the binary present and
  asserts it writes exactly the documented lines (or nothing) to stdout, so a
  future edit cannot corrupt JSON-RPC.

## D5 — What stays shell, and why

| stays shell | why |
|---|---|
| `scripts/lib-sigpipe-verdict.sh` | the mechanism is the OS pipe race; `proc.chain` would measure the runtime, not the shell site |
| `scripts/lib-env-forward.sh` | its output is `%q`-quoted shell source prepended to a remote `bash -c` |
| `scripts/lib-ca-path.sh`, `scripts/lib-cargo-sites.sh` | sourced by `build.sh` / host launchers before a host plan binary exists; the image's binary is not the host's |
| `scripts/common.sh` | resolves podman at the top of `build.sh`, before anything is built |
| `images/default/entrypoint*.sh` | the container's first process; it may call the binary, but it must run before it |
| `images/default/lib-localized-errors.sh` | sources locale bundles at source time; pure string formatting, no forks to remove |
| `scripts/build-forge-plan-bin.sh` | it builds the binary |

## D6 — Verification

- **Per-helper fixture** (`scripts/lua/test-<name>.lua`, the litmus pattern):
  run the helper against a fake `curl`/`git`/binary on `PATH` and assert every
  branch of its grammar, including the named fallbacks. One arm per reason
  token.
- **Pre/post fork count**: `strace -f -e execve` (or the litmus wrapper's call
  file) records the old count and asserts the new wrapper's count is lower by
  at least the documented amount.
- **Existing litmus stays green**: `litmus:inference-model-preload-policy`,
  `litmus:forge-ledger-freshness-shape`, `litmus:mcp-usage-telemetry-shape`,
  `litmus:mcp-live-build-check-fixture`.
- **Gate**: `./build.sh --check` on a host that can run it. This forge cannot
  complete it (`2042-w7v4`, `1747-nghx`); the work ref records that caveat.

## Wave 2 (designed, not implemented here)

Decompose `inject_startup_context` (590 lines, 71 substitutions) into
`lua/startup-context.lua` plus a thin shell orchestrator: the Lua side emits
one fixed-order line per section (base head, ledger lag, inference line, expert
line, capability lines, context-pack paths); the shell concatenates the
sections it prints today. Target: cut ~70 forks per launch. It depends on this
change's `--helper` mode and on the same shipped-module guard. Split into its
own packet so the five easy helpers can land first.

## Risks

- **`--helper` is a runtime change.** Mitigated by the decider-capture
  fallback for value helpers; the side-effect helper needs `--helper` to keep
  MCP stdout clean.
- **`json.decode` assumes Ollama's `/api/tags` shape** where `sed` was
  tolerant. The fixture pins the real shape and a malformed body keeps today's
  reason tokens.
- **`hash.sha256` reads whole files.** Fine for the 111 KB server script;
  documented as a future limit.
- **One extra process per call.** ~2 ms, offset by 4–9 removed forks; the MCP
  servers pay it once per session, not per tool call (the usage-log writer is
  the exception and is best-effort).
- **The image is currently missing three of the libs.** `2047-ci2k` must land
  (or land with this change) or the ports are invisible in the image.
