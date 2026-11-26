# Rust-phase census: scripts that stay shell because stock Lua cannot carry them

Filed by lenovinha, 2026-11-26, at macuahuitl's request. The tree is origin/linux-next at 90140df5f. This is a read-only census and nothing in it was ported. It is the input to the operator's Rust-phase plan. Row: see `related` on the plan fragment that filed this report.

Sources: plan/index.d and plan/issues (searched for stays shell, Rust/Go, PID 1, job object, wait -n, signal forward); seed rows 2370-euvb (a port batch with no stays-shell content), 2374-wy4f and 2395-3zw7; D3.6 rows 2393-j27x and 2396-x2x9 (none of them carries a literal "B list"); `scripts/portability/bootstrap-shell-allowlist.txt`; `openspec/changes/forge-lua-helpers/design.md` D5; `plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md` §6.5; the bodies of the last 200 PRs (#1473, #1488, #1582, #1585, #1591, #1603, #1610, #1619 are the relevant ones). Line counts were re-checked with `wc -l` on this tree.

## A. Needs a process runtime: Rust (or Go)

| # | Script | Lines | Why it is not Lua | Callers | Proposed home |
|---|---|---|---|---|---|
| 1 | images/proxy/squid-supervisor.sh | 237 | PID 1. It traps TERM/INT and forwards them to squid, waits and restarts (767-es4w). No ruling cites it; this classification is from the code (2374-wy4f note, 2026-11-26). | proxy Containerfile, proxy entrypoint.sh, tillandsias-headless main.rs, check-enclave-service-health.sh, litmus-proxy-crash-supervision-shape | new crate `tillandsias-supervise` (container PID-1 supervisor) |
| 2 | images/inference/supervise.sh | 45 | PID 1. It traps signals and waits on the shell's own jobs (2374-wy4f). | inference Containerfile + entrypoint.sh, test-inference-supervise.lua, litmus-dead-tray-run-is-reaped | `tillandsias-supervise` (same binary as #1) |
| 3 | images/inference/llama-server-lane.sh, serve function only | 281 (whole file) | Two children, a trap, wait -n (2374-wy4f). Its select, verdict, pin and check verbs are portable. | tillandsias-headless engine_slots.rs, inference Containerfile/entrypoint, llama-server.Caddyfile | serve on `tillandsias-supervise`; the verbs follow the 2374-wy4f ruling |
| 4 | images/inference/gpu-stall-watchdog.sh | 147 | A backgrounded loop calling decode-floor-pin's _tdf_pin (2374-wy4f). The tick is pure enough to split, so only the loop needs a runtime. | inference Containerfile/entrypoint, gate step 850-1648-gy9z, test-gpu-stall-watchdog.lua | the loop on `tillandsias-supervise`; the tick becomes portable if 2374-wy4f is answered yes |
| 5 | images/default/cli/flutter-lane (python3) | 283 | A unix MCP socket, select and signal forwarding. Stock Lua has no sockets (2395-3zw7). | tillandsias-headless toolchain_exec.rs, default Containerfile, cli/flutter, litmus-flutter-shim-falls-back-or-refuses-typed | `tillandsias-control-wire` client, shipped as a forge binary; or a socket primitive in the plan binary's Lua runtime |
| 6 | scripts/test-wsl-builder-kill-reaches-guest.sh | 222 | "DEFERRED to the Rust/Go phase (macuahuitl, 2026-11-25)": its subject is shell job control and signals to a live builder run (yolanda fragment 20261125t111648z-3120575c). | gate step 820-1567-9fgi, portability/bare-mktemp-floor.txt | a Rust test in `tillandsias-exec` |
| 7 | images/inference/entrypoint.sh | 1022 | PID 1 and on the bootstrap allowlist. The image has no Lua and no plan binary (2374-wy4f). | inference Containerfile | stays shell unless #2 becomes PID 1; then a thin exec into `tillandsias-supervise` |

Runtime gaps behind this list. Fixing these would fix the runner, not one script:

- **2392-tv47 (PR #1610):** on Windows, the job object in `tillandsias-exec` (KILL_ON_JOB_CLOSE) ends a fold's shell before its trap runs, and `detach` changes nothing there (PR #1473). Home: `tillandsias-exec`.
- **No socket or signal primitive in the plan binary's Lua runtime.** Adding one would make #5 portable without a separate binary, and would make the supervisor loops (#1 to #4) expressible too. This is a design choice for the operator: one Rust supervisor crate, or growing the Lua runtime.

## B. Shell because shell is the subject (probably permanent)

| Script | Lines | Reason |
|---|---|---|
| scripts/lib-sigpipe-verdict.sh | 180 | It measures the OS pipe race at a shell site; `proc.chain` would measure the runtime instead (forge-lua-helpers design D5; PR #1591). |
| scripts/test-awk-float-lc-numeric.sh | 200 | Its TERM trap is the subject that test-awk-float-lc-numeric-signal.lua checks (PR #1585). |

## C. Shell for bootstrap or ruling reasons, not runtime ability (not Rust work)

- **The bootstrap allowlist** (1443-xkwb): installers and every .ps1, launch.sh, build.sh, three early checkers, nine hook stubs, every images/*/entrypoint*.sh, ensure_toolbox.sh.
- **The toolbox bootstrap**, a standing coordinator exception since 2026-11-19: with-tillandsias-builder.sh (688), with-wsl2-builder.sh (498), with-nix-builder.sh, nix-toolbox.sh, nix-cache-service.sh.
- **Bootstrap-path libs** (PR #1591, option A): lib-env-forward, lib-dispatch-reap (197), lib-freeze-paths, lib-ca-path, lib-build-version, with-smoke-lock, lib-e2e-mode, lib-wsl-exec.
- **Fork cost on hot paths:** lib-lane.sh, lib-embed-endpoint.sh, lib-provider-limit.sh (PR #1619), and _tillandsias_spec_index_paths (D3.6 task 1.7, 2396-x2x9).
- **Images without a Lua runner:** the 2374-wy4f question, which now covers images/git, images/inference and nine small images. These become Lua work, not Rust work, if the answer is yes.
- **Runner policy, not runtime ability:**
  - gate-pins-surface-root and host-kind-evidence-not-from-workspace (PR #1488, consent token);
  - gate-stamp-memoization (PR #1603, check-checkout-writers);
  - test-check-credential-channel.sh (PR #1582, credential path);
  - test-git-mirror-vault-agent-auto-auth (PR #1603).

## D. Stale records found on the way

- **lib-rerun-failed-rust-tests.sh:** 2214-pj7i says it must stay shell. It is gone from this tree (scripts/lua/run-rust-test-on-host.lua exists), but `scripts/gate-divergence-declared.txt` still names it.

## Proposed operator decisions

1. **One new crate, `tillandsias-supervise`**, for container PID 1: forward signals, reap, restart, wait on several children. It would replace #1 to #4 and serve both proxy and inference. The alternative is to put that code in tillandsias-headless, which is the tray/headless binary. That is the wrong side of the container boundary.
2. **flutter-lane (#5):** a control-wire client binary, or a socket primitive in the Lua runtime.
3. **Windows job-object trap ordering (2392-tv47)** in tillandsias-exec. It is a prerequisite for porting #6 as a Rust test.
4. Whether the 2374-wy4f images get a Lua runner. This decides section C's image entries, and it is independent of 1 to 3.
