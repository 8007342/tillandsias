# Tasks — forge-lua-helpers

Umbrella `2048-wu3h`. Each task's closure is the refusal arm named here,
written red against today's code first. Sub-orders are minted on claim.

## 0. Runtime door (must land first)

- [ ] 0.1 `tillandsias-plan script run --helper <file.lua>`: no verdict
      required, `verdict.*` refused, stdout is the script's, same stdlib and
      `proc.*`, exit 0 on return / 1 on Lua error. Arms: a helper that returns
      cleanly is 0 with only its own stdout; a helper that calls
      `verdict.ok` is `refused:helper-called-verdict`; a Lua error is 1 with a
      stderr diagnostic; `--timeout` still works. `[mint on claim]`
- [ ] 0.2 Fallback decision recorded: if 0.1 is rejected, value helpers become
      deciders with a fixed-order `ok:<name>` payload and the wrapper strips
      the prefix; `mcp-usage-log` is deferred. `[mint on claim]`

## 1. The five helpers

Each item: write the fixture red, port, prove the existing litmus stays green,
record the pre/post `strace -f -e execve` count in the packet.

- [ ] 1.1 `lib-inference-state.sh` → `lua/inference-state.lua`; every reason
      token (`probe-tool-missing`, `endpoint-unreachable` + engine suffix,
      `endpoint-timeout`, `endpoint-http-error`, `probe-error-<n>`,
      `no-models`) has an arm; model names byte-sorted; 8 execve → 1.
      `[mint on claim]`
- [ ] 1.2 `lib-experts-probe.sh` → `lua/experts-probe.lua`; the three named
      substitutes and the closed tier vocabulary have arms; 9 execve → 2.
      `[mint on claim]`
- [ ] 1.3 `lib-ledger-freshness.sh` → `lua/ledger-freshness.lua`; `origin` /
      `origin/HEAD` skipped, lag floored at 0, unknown kept on failure; 4
      execve → 1 runner + 3 git. `[mint on claim]`
- [ ] 1.4 `lib-mcp-build-id.sh` → `lua/mcp-build-id.lua`; 12 hex, `unknown`
      on unreadable, no fallback chain; 5 execve → 1. `[mint on claim]`
- [ ] 1.5 `config-overlay/mcp/mcp-usage-log.sh` → `lua/mcp-usage-log.lua`;
      `time.now_ms` clock, one JSONL line, base four keys always present,
      best-effort, nothing on stdout; `mcp_now_ms`/`mcp_log_usage` signatures
      unchanged. `[mint on claim]`

## 2. Packaging and guards

- [ ] 2.1 `Containerfile` copies `images/default/lua/` to
      `/usr/local/lib/tillandsias/lua/`. `[mint on claim]`
- [ ] 2.2 Land `2047-ci2k` (PR #1015): the four omitted libs are copied and
      `check-forge-lib-copies.lua` is red before / green after; extend it to
      every `lua/*.lua` module a wrapper names. `[2047-ci2k]`
- [ ] 2.3 Register the shell-outs in `images/default/lib-*.sh` as a counter
      of the shell-to-lua backlog in `check-carried-obligations.lua` (not a
      separate gate step): floor may only decrease, names each migrated file,
      waives with the existing grammar (`blocked-by:2006-me5t` until its
      `cross-cutting` token lands). `[mint on claim]`
- [ ] 2.4 Helper environment arm (2029-39bt): a helper spawning `printenv`
      with `HTTPS_PROXY` and `TILLANDSIAS_X_SECRET` set in the caller sees
      neither; `inference-state` records whether today's shell curl went via
      the proxy. `[mint on claim]`

## 3. Wave 2 (separate change)

- [ ] 3.1 Decompose `inject_startup_context` into
      `lua/startup-context.lua` + a thin shell orchestrator; target ~70 forks
      per launch removed; own packet and its own approval. `[mint on claim]`

## Non-goals (explicit)

- No port of `lib-common.sh` wholesale, the MCP dispatch, `build.sh`, or the
  host-side `scripts/lib-*.sh` listed in `design.md` D5.
- No change to `lib-sigpipe-verdict.sh`; it measures real OS pipes.
- No image rebuild or boot in this change; the release path does that.
