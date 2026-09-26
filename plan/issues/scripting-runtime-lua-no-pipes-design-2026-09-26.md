# Scripting runtime: bash → Rust-hosted Lua, no pipes (design)

- Date: 2026-09-26. Author: macuahuitl (Fable agent, delegated by the coordinator session). Base: origin/linux-next `9594a4303`.
- Operator direction (2026-09-26, verbatim in the delegation): get rid of the unpredictable moving parts; if bash is unstable use something stable that we control; Lua is the candidate but VERIFY it; remove every pipe from tests and scripts; control every execution and every success/error state transfer; proper deterministic language semantics, non-blocking observable streams and non-blocking callbacks.
- Builds on plan/issues/lua-runtime-host-dependency-replacement-design-2026-09-26.md (the jq/yq/timeout inventory, "one Rust implementation, three front doors", Go not adopted). This document does not repeat that inventory; it answers the five questions the operator asked about the SCRIPT LAYER itself.
- Code is cited by symbol. Counts are `git grep` over the worktree at the base above and each one names its command in §2. Sources for the language comparison are in §3.5.
- Packets filed from this design: see §9.

## 0. The answer in five lines

1. Lua 5.4 through mlua stays the runtime — with three corrections the measurements below force: a fixed iteration/encoding order (the current binary prints `json.encode` keys in a DIFFERENT order every process, §3.2), `os.setlocale` withheld (it is exposed today and flips `%.2f` to `3,50` in one call, §3.2), and mlua's `async` feature so streams and callbacks are host-driven coroutines rather than threads.
2. Starlark is the only alternative that is deterministic by design, and it is rejected for one reason: it has no coroutines, no callbacks and no `while`, so "non-blocking observable streams" cannot be expressed in it; every other candidate is either not deterministic (JS/V8, Rhai) or not embeddable at our cost (Go, V8's 30+ MB prebuilt archive per platform).
3. Processes run through `proc.run{argv=…}` / `proc.spawn{argv=…}` on `tillandsias_exec::Command`: argv only, two captured fds, `status` as a closed vocabulary (`exited|signaled|timed_out|spawn_failed`), a process GROUP kill, and composition by passing bytes (`stdin=a.stdout`) — there is no OS pipe between stages, so SIGPIPE, `pipefail`, `PIPESTATUS` and "`$?` is tail's" have nothing to attach to.
4. Migration is by ratchet, not sweep: `scripts/lua/` beside `scripts/`, gate steps may name `STEP_LUA=`, a counter on every `--check`, and NO new `.sh` decider or piped litmus `command:` once the Lua door exists. The first ports are the deciders with recorded incidents (§7), then the litmus step executor, then the land/relay tooling; build.sh becomes a launcher that bootstraps the plan binary and hands over.
5. Bash cannot reach zero: the toolchain bootstrap (`cargo build` of the plan binary itself, `install-macos.sh`, the `.ps1` installers, the git hook stubs, the container entrypoints before the binary is in the image) stays shell and is listed by name in §6.5 with what each implies.

## 1. What is unstable, precisely

The operator's word was "unpredictable". Measured on this tree the instability is five mechanisms, not one, and the design has to close each by construction:

| Class | Mechanism | Today's evidence (orders) | Closed by |
|---|---|---|---|
| A. exit-status masking | a pipeline yields ONE status; `grep -q` exits early, the producer takes SIGPIPE, `pipefail` turns a MATCH into rc=141; `if ! producer \| consumer` inverts; `\| tail -1; echo rc=$?` reports tail | 792-ksr8 (twice today in new fixtures), 795-imz3, 1252-fg9e's 5/5 measurement | §4: no OS pipe exists; each stage's `Completion` is a value |
| B. bash dialect | bash 3.2 on macOS: `mapfile`, `read -N`, `. <(…)` reads EMPTY; `declare -A`; `${var,,}` | 1373-sr9g, 1374-4u6i, 761-g36m | §3: one interpreter, vendored, same bytes on every host |
| C. GNU vs BSD userland | `date +%s%N`, `date -d`, `sed -i`, `stat -c`, `awk` `\b`, `find -printf`, `readlink -f` | 1279-a7b6, 1130-i6xj, 1132-r4mt (awk `\b` on macOS) | §5: `time`, `text`, `fs` in Rust; no external text tool on the verdict path |
| D. locale | `awk %.2f` under `LC_NUMERIC=fr_FR` prints `100,00`; `$EPOCHREALTIME` carries the locale comma | 1254-fdsu | §5.1: the host never calls `setlocale`, `os.setlocale` withheld, formatting in Rust |
| E. platform boundary | `wsl.exe … bash -lc` returns rc=0 always; Git Bash quoting; CRLF from jq.exe | 1155-jurn, 1186-w3ph | §4.2: status is a field of a typed result, never an integer that crossed a shell boundary; LF written by the host |
| F. process lifecycle | `timeout` kills the leader, children keep the pipe open; `setsid` absent on macOS refused 108 guards at once; the container-side gate survives its host wrapper | 1132-r4mt, 1352-vmbc, 1353-ryhq, 1305-udgs | §4.3: `proc.spawn{group=true}`, `kill` is a group kill, `TimedOut` is a distinct status |
| G. front-door drift | the preflight door classifies a guard's outcome by grepping its MERGED output (`^skip:`, `^could-not-run:`, `not found`), and passes trees the gate refuses | 1359-qf3p | §4.4: outcomes are typed, the door and the gate call the same `verdict` classifier |

The quantification of the population these mechanisms live in is in §2.

## 2. The population: how much shell, how many pipes

(Counts produced by the audit in this session; every number names its command so the ratchet in §6.3 can pin it.)

Populations: P1 = `scripts/*.sh` (git's pathspec is recursive: 760 files) + build.sh + launch.sh = 762 files, 151,551 lines; P2 = scripts/gate-steps.d/*.step, 102 files (data, not code — six carry a pipe inside prose or a STEP_ERROR string); P3 = images/*.sh, 83 files, 19,660 lines; P4 = openspec/litmus-tests/*.yaml, 462 files, 39,696 lines, 2,921 `command:` lines (one block scalar; the rest single-line quoted strings). There is no install.sh on this tree (the installers are scripts/install-macos.sh and the five `.ps1` files).

| Metric (git grep -E pattern) | P1 scripts | P3 images | P4 litmus `command:` |
|---|---|---|---|
| pipe sites, raw `[^|]\|[^|]` | 4,940 | 550 | 1,103 (1,260 whole-file) |
| pipe sites, quoted spans stripped | 2,985 | 410 | 911 (outer YAML quote kept, nested quotes stripped) |
| files with `set -o pipefail` | 694 | 26 | 0 (the runner's own `set -eo pipefail` applies to every step) |
| files with a pipe and NO pipefail | 54 | 25 | 334 |
| `PIPESTATUS` (lines/files) | 49 / 14 | 0 | 1 / 1 |
| `if ! <pipeline>` on one line | 24 | 13 | 0 |
| `2>&1 \|` (merged-stream verdicts) | 416 | 54 | 150 |
| `\| tail -1` / `-n 1` | 214 | 5 | 102 |
| `rc=$?` (any) | 668 | 18 | 208 |
| `<(` / `>(` (lines/files) | 166 / 98 | 7 / 4 | 22 / 11 |
| `mapfile`/`readarray` (lines/files) | 28 / 16 | 0 | 0 |
| `declare -A` | 10 | 0 | 0 |
| `date +%s%N`/`%3N`; `date -d`; `date -j` | 30; 17; 17 | 9; 0; 0 | 2; 1; 0 |
| awk `printf %.N` | 10 | 0 | 2 |
| `LC_NUMERIC`/`LC_ALL=` pins (the manual remedy) | 75 | 4 | 4 |
| `timeout` / `setsid` / `flock` | 185 / 48 / 59 | 33 / 0 / 0 | 44 / 3 / 13 |
| `eval` (lines/files) | 85 / 44 | 3 / 3 | 10 / 4 |
| `bash -c` / `sh -c` with a string (lines/files) | 173 / 75 | 3 / 1 | 56 / 29 |
| `$(…)` substitutions | 9,159 | 866 | 788 |
| `\| while read` | 12 | 2 | 0 |

Deciders (P1 basenames `check-`/`verify-`/`guard-`): 146 files, 1,025 raw pipe sites, 140 of 146 contain at least one pipe. `test-` fixtures: 394 files. Scripts that source a lib (`. `/`source`): 196. Top pipe carriers: cycle-metrics.sh 105, select-work-batch.sh 82, run-litmus-test.sh 66, local-ci.sh 65, test-claims-fleet-visible.sh 52, build.sh 51, hooks/pre-push-local-gate.sh 45.

Reading: the litmus corpus is the worst per line (911 pipes in 2,921 steps, and NOTHING in it can see `pipefail` because the runner sets it for every step and merges both streams before adjudication); the 54 P1 files with pipes and no pipefail are the 795-imz3 shape (a verdict that works "by the absence of pipefail"); the 694 with pipefail are the 792-ksr8 shape (a match that reads as failure). Both halves of the population are wrong in opposite directions, which is why no shell option fixes it.

Incident evidence, this ledger (`git grep -l` over plan/index.d and plan/index.yaml): `pipefail` 57 files, `SIGPIPE` 31, `wsl.exe` 38, `bash 3.2` 15, `PIPESTATUS` 9, `mapfile` 9, `LC_NUMERIC` 7. Today alone (2026-09-26): 792-ksr8's guard refused two new `printf | grep -qF` verdicts in 1370-tjme's fixture at 01:15Z after `--preflight` had scored `refused=0` on the same tree (1359-qf3p, instance 1); the same door passed a `%s%N` GNU-date-ism that the gate then refused at 04:26Z (instance 2); 1378-7w2p found `$EPOCHREALTIME` carrying the fr_FR comma into timer arithmetic (a negative duration); 1373-sr9g and 1374-4u6i (macOS, 2026-09-25) are bash 3.2 `. <(…)` sourcing nothing and one `mapfile` line counted twice; 1132-r4mt closed on yoga with the finding that two concurrent gates share one scratch path and a SIGKILLed archiver leaks it.

## 3. Is Lua the right runtime? (verified, not assumed)

### 3.1 What is on the tree

- mlua 0.10.5, features `vendored, lua54, send, serialize` (crates/tillandsias-plan/Cargo.toml); lua-src 547.0.0 compiles Lua 5.4.7 from bundled C through the `cc` crate. `lua-src`'s build script sets `LUA_USE_LINUX` / `LUA_USE_MACOSX` / `LUA_USE_WINDOWS` per target, so the same source builds natively on all three; yolanda's native `tillandsias-plan.exe` and the osx-next build are the existence proof (1267-uafx, 1375-btuf context).
- Three environments share `lua_std::register` since 1375-btuf: `LuaRuntime::new` (expert-serve), `build_environment(PredicateClass)` (predicates and the `lua` CLI), and `run_lua_cli` (sandboxed by default; `--unsandboxed` has one caller, scripts/archive-plan-packets.sh, until 1380-u7sq).
- The Observing class already has `sh.run{argv}` → `{code, ok, run_id, status, stderr, stdout}` on `tillandsias_exec::Command` (probed: `sh.run{"printf","a b*c\n"}` returns `status="exited"`, `stdout="a b*c\n"`; the `*` reached the child unexpanded). That is the seed of §4's `proc` table; it is synchronous and has no spawn/stream form yet.
- `tillandsias_exec` (1252-fg9e, landed as `326def3d2` and `98859cdc7`) has `Command::run` (argv, three fds drained with `tokio::join!`, timeout), `Command::spawn` → `Running` (inherit stdio; `try_completion`, `wait`, `kill` = SIGKILL of the child only), and `Pipeline` (stages run one after another, each stage's stdout handed to the next as `stdin_bytes` — an in-memory chain, already not an OS pipe, keeping every stage's `Output`). Missing for this design: a process-group/session kill, a streaming (line-callback) reader, `Completion::Signaled` surfaced to Lua, and a run trace.

### 3.2 Two determinism defects measured in the current runtime

Both are reproducible with the installed binary and neither is in any packet yet:

1. Iteration order is per-process random. `tillandsias-plan lua --class observing -e 'expert.log_info(json.encode({alpha=1,beta=2,gamma=3,delta=4,eps=5,zeta=6}))'` printed, in three consecutive runs, `{"gamma":3,"eps":5,…}`, `{"delta":4,"alpha":1,…}`, `{"eps":5,"zeta":6,…}`; a `json.parse` → `json.encode` round trip of a six-key object also reorders per run. Cause: Lua 5.4.7 `luai_makeseed` (lstate.c) seeds string hashing from ASLR addresses and `time(NULL)`, and `pairs` walks the hash part. Consequence today: any verdict, fragment or fixture that encodes a table is not byte-stable, which breaks the "same script, same bytes" requirement before any script is written. Remedy in §5.2.
2. Locale is one call away. `os.setlocale` is present in the Observing environment. Measured with `LC_ALL=br_FR.iso88591`: before the call `string.format("%.2f", 3.5)` is `3.50` and `tonumber("3,5")` is `nil`; after `os.setlocale("")` they are `3,50` and `3,5`, and `tostring(3.5+0)` becomes `3,5`. The reason it is `3.50` BEFORE the call is the property to keep: a Rust binary never calls `setlocale(LC_ALL, "")`, so the C library stays in the `"C"` locale regardless of `LANG`, and Lua's `lua_getlocaledecpoint` (luaconf.h, used by `l_str2d` in lobject.c) reads `.`. Withholding `os.setlocale` makes 1254-fdsu's class unconstructible; §5.1.

(`fr_FR` is not installed on this host, so the `LC_NUMERIC` demonstration used `br_FR`, which shares the comma radix; the mechanism is the C library's, not the locale's.)

### 3.3 The alternatives, against the operator's criteria

Criteria, in the operator's order: determinism, sandboxing, embedding cost, native builds on Fedora/macOS (x86_64 and aarch64)/Windows MSVC, how well agents author it, async/streams/callbacks, error-value semantics.

| Candidate | Determinism | Sandbox | Embedding cost | Native on 3 platforms | Agents author it | Async / streams | Errors as values | Verdict |
|---|---|---|---|---|---|---|---|---|
| Lua 5.4 / mlua (on the tree) | `pairs` order unspecified by the manual [1]; hash seed from ASLR+clock (`luai_makeseed`, measured §3.2); number↔string uses `localeconv()` [2][3] — both fixable in the host | `Lua::new_with(StdLib)` subset [8]; our allow-list env (1367-upz6) already pins it; `set_memory_limit`, `set_hook` instruction limits [7] | C sources via `cc` [5]; already linked | yes — yolanda's .exe, osx-next; lua-src sets the per-OS define [5] | MultiPL-E classes Lua "low-resource" [30][31] — measurably worse than Python/JS, still far above bash, and our std API is small | full: `create_async_function`, `call_async`, coroutines driven by Rust futures [6][7] | `pcall`/`error`; mlua `Error` [10]; we return tables and raise only for programmer errors | KEEP, with §5 corrections |
| Luau (mlua `luau`) | `sandbox()` mode [7]; a deterministic-simulation deployment still had to strip `os`/`loadstring` and force `-ffp-contract=off` on arm64 [14] | best-in-class `sandbox()` | C++17 toolchain [13] — heavier than C on MSVC and macOS | yes, but a second compiler class | same as Lua | same mlua machinery | same | not worth a C++ toolchain for a sandbox we already have by allow-list |
| Starlark (starlark-rust) | spec: "deterministic and hermetic", no fs/network/clock [15] | by design — no I/O exists | pure Rust [16] | yes | Python-like syntax, high-resource | NONE: synchronous, no coroutines, no `while`, no callbacks [15] | no exceptions; `fail()` aborts [15][17] | best for pure assertions; cannot express §4.3 |
| Rhai | no determinism statement; `IndexMap` maps are insertion-ordered [34] | no std by default; op/depth/size limits [18] | pure Rust [18] | yes | little training data (judgment) | NONE (synchronous) | `throw`/`try` → `EvalAltResult::ErrorRuntime` [19-21] | no async, no corpus |
| JS: deno_core / rusty_v8 | JS key order spec-defined; runtime is an event loop you curate [23] | ops you register only [23] | V8 prebuilt static libs per target, downloaded at build time; offline needs `RUSTY_V8_ARCHIVE` per platform [24] | prebuilts for all three [24], each a ~tens-of-MB asset our release lane must mirror | best of all (JS is the largest corpus) [30] | async-first [23] | exceptions | rejected on embedding cost: a second binary-asset supply chain per platform |
| JS: QuickJS (rquickjs) / Boa | JS semantics | bindings you expose | C library with its own platform limits — "might not compile on all platforms Rust supports" [26]; Boa pure Rust | QuickJS risk on MSVC per its README [26] | JS | synchronous | exceptions | no async in-engine; Boa immature |
| Go, separate binary (Docker) | whatever the author writes | none | second toolchain, second release asset and signature per platform | yes | good | goroutines | `error` values | rejected (previous design §5); Docker's reason was ONE static binary [29], which the Rust plan binary already is |
| Rust-only subcommands | total | in code | zero | yes | good | tokio | `Result` | right for PRIMITIVES (exec, json, hash, time); wrong for 540 deciders — every verdict change is a recompile and a stale-binary class (1267-uafx) |
| Wasm (wasmtime + guest) | guest-dependent | capability-based, strongest | wasmtime + a guest toolchain | yes | guest-dependent | host-async | guest-dependent | doubles the toolchain problem |
| Nushell | a shell, not a VM | none | a separate binary | yes | small corpus | n/a | shell-style | the Go shape again |

### 3.4 Decision

Lua 5.4 on mlua, with the corrections in §5 and the `async` feature for §4. The reasons that survive the comparison:

1. It is the only candidate already built natively on all three platforms in a binary every gate host has (1267-uafx), inside a sandbox that is an allow-list rather than a deny-list (1367-upz6) and that a fixture already pins.
2. Coroutines are the primitive the streams-and-callbacks requirement needs; mlua exposes them to Rust futures (`create_async_function`, `call_async`), so a `proc.spawn(...):on_line(fn)` can be non-blocking with ONE thread and no Lua-visible concurrency — deterministic callback order per fd, no data races.
3. The two determinism defects are closable in the host (a sorted encoder and iterator, one withheld function); they are not properties of the language spec we would have to fight.

Said plainly for the operator: Starlark would be the answer if the requirement were "deterministic assertions only" — its evaluator is hermetic by specification. It is not the answer for a script that supervises a long-running build, kills a process group on a deadline and reports each line as it arrives; that is a coroutine problem and Starlark has no coroutines. Go remains rejected for the reason the previous design gave (a second toolchain and signing asset per platform to reach syscalls Rust already reaches); Docker's precedent is about STATIC BINARIES and no runtime dependency, which the Rust plan binary already satisfies.

### 3.5 Sources

[1] Lua 5.4 reference manual, `next`/`pairs` ("the order in which the indices are enumerated is not specified") — https://www.lua.org/manual/5.4/manual.html
[2] Lua 5.4 luaconf.h, `lua_getlocaledecpoint` — https://www.lua.org/source/5.4/luaconf.h.html
[3] Lua 5.4 lobject.c, `l_str2d`/`l_str2dloc` — https://www.lua.org/source/5.4/lobject.c.html
[4] lua-l, seeding `luai_makeseed` — http://lua-users.org/lists/lua-l/2015-12/msg00188.html (and the vendored lstate.c in lua-src 547.0.0, read locally)
[5] lua-src-rs (the `vendored` build: `cc`, per-OS defines) — https://github.com/mlua-rs/lua-src-rs
[6] mlua README, async — https://github.com/mlua-rs/mlua
[7] mlua `Lua` docs: `create_async_function`, `call_async`, `sandbox`, `set_memory_limit`, `set_hook` — https://docs.rs/mlua/latest/mlua/struct.Lua.html
[8] mlua `StdLib` — https://docs.rs/mlua/latest/mlua/struct.StdLib.html
[10] mlua `Error` — https://docs.rs/mlua/latest/mlua/enum.Error.html
[13] luau-lang/luau (C++11/17 toolchain) — https://github.com/luau-lang/luau
[14] oddurs/rim PR #19 (Luau determinism: stripping `os`, `-ffp-contract=off`) — https://github.com/oddurs/rim/pull/19
[15] Starlark specification ("deterministic and hermetic") — https://github.com/bazelbuild/starlark/blob/master/spec.md
[16] facebook/starlark-rust — https://github.com/facebook/starlark-rust
[17] Starlark issue #47, `fail` — https://github.com/bazelbuild/starlark/issues/47
[18] Rhai features — https://rhai.rs/book/about/features.html
[19]-[21] Rhai `throw`, `try/catch`, `EvalAltResult` — https://rhai.rs/book/language/throw.html, https://rhai.rs/book/language/try-catch.html, https://docs.rs/rhai/latest/rhai/enum.EvalAltResult.html
[23] deno_core — https://docs.rs/deno_core/latest/deno_core/
[24] denoland/rusty_v8 (prebuilt archives, `RUSTY_V8_ARCHIVE`) — https://github.com/denoland/rusty_v8
[26] rquickjs README (C library, platform limits) — https://github.com/delskayn/rquickjs
[29] Solomon Hykes on why Docker chose Go — https://x.com/solomonstre/status/1842342755194048981
[30] MultiPL-E (Lua classed low-resource) — https://arxiv.org/pdf/2208.08227 ; [31] https://nuprl.github.io/MultiPL-E/
[34] indexmap — https://docs.rs/indexmap/latest/indexmap/map/struct.IndexMap.html
Local measurements: `tillandsias-plan lua` probes in §3.2 (build-id `0.1.0+4312ec2ceb0c33ae`); vendored lua-src 547.0.0 lstate.c `luai_makeseed`; the §2 grep census.

## 4. The execution model

Everything below is one Rust implementation (`tillandsias_exec`) behind three front doors: the `proc` Lua table (Observing class only), the `tillandsias-plan run` verb (1375-amye) and the litmus `steps:` form (902-5bf9). The Cacheable class never sees `proc`, `time` or `env` (1367-upz6 stays the rule).

### 4.1 One process: `proc.run`

```lua
local r = proc.run{
  argv       = {"git", "-C", repo, "status", "--porcelain"},  -- REQUIRED, a table; never a string
  cwd        = repo,          -- default: the repo root; relative paths are refused
  env        = {GIT_DIR = "…"},  -- ADDED to the base set (§5.3); nothing else is inherited
  stdin      = bytes,         -- optional; absent means /dev/null, never the caller's terminal
  timeout_ms = 30000,         -- default 300000; 0 means no deadline and must be written out
  group      = true,          -- own process group/session (Unix) or job object (Windows); default true
}
```

`r` is a plain table, always returned, never raised for an operational outcome:

| field | type | meaning |
|---|---|---|
| `status` | `"exited" \| "signaled" \| "timed_out" \| "spawn_failed"` | closed vocabulary; `timed_out` is NOT an exit code (the child produced none) |
| `code` | integer or nil | present only when `status == "exited"` |
| `signal` | integer or nil | present only when `status == "signaled"` |
| `ok` | boolean | `status == "exited" and code == 0`, nothing else |
| `stdout`, `stderr` | byte strings | captured SEPARATELY, both drained concurrently (`Command::run`'s `tokio::join!`) |
| `run_id` | string | the 1252-fg9e identity; a stale artifact cannot present as this result |
| `wall_ms` | integer | monotonic, measured by the host |
| `argv` | table | echoed, so a verdict can print what ran without re-quoting |

Rules: a non-zero `code` is data. `error()` is raised only for programmer errors — `argv` missing or empty, a non-string element, a relative `cwd`, an unknown field (an unknown field is a typo that would otherwise silently do nothing; `timeout_ms` misspelt as `timeout` must not become "no deadline").

### 4.2 Composition without pipes

There is no pipe operator and no string form. Three ways to compose, all explicit about which status is whose:

```lua
-- 1. Bytes flow through a variable. Every stage is asserted on its own.
local a = proc.run{argv = {"sed", "s://.*::", f}}
if not a.ok then return verdict.refused("seam-writers:sed", a) end
local hits = text.count_matches(a.stdout, [[(set_var|remove_var)\("TILLANDSIAS_PODMAN_BIN"]])

-- 2. A consumer that must be a process gets the bytes as stdin.
local b = proc.run{argv = {"sort", "-u"}, stdin = a.stdout}

-- 3. A chain when the caller wants all stages run in order (tillandsias_exec::Pipeline):
local c = proc.chain{ {argv = {"git", "ls-files"}}, {argv = {"sort"}} }
-- c.stages[1], c.stages[2] are full results; c.ok is every stage ok; c.first_failure names the stage.
```

The chain form exists because 902-5bf9's corpus has 1,248 piped `command:` steps and a faithful port needs a one-to-one shape; it still runs each stage to completion in memory, so a consumer cannot SIGPIPE its producer. `text.*` (Rust regex, byte-exact, no locale): `lines`, `count_matches`, `first_match`, `grep(lines, pattern)`, `contains`. Flags are explicit (`ere=true` is the default; `literal=true`, `icase=true`), because scripts/litmus-stdlib.sh's `mf_holds` family measured that dropping the BRE/ERE flag silently reinterprets 74 patterns.

### 4.3 Long-running processes: `proc.spawn` and streams

```lua
local p = proc.spawn{argv = {"bash", "./build.sh", "--check"}, group = true, timeout_ms = 1500000}
p:on_line("stdout", function(line) if line:match("^refused:") then log.note(line) end end)
p:on_line("stderr", function(line) errs[#errs + 1] = line end)
p:on_exit(function(c) log.note("exited", c.status, c.code) end)
local c = p:wait()            -- suspends this script's coroutine; callbacks run while it waits
if c.status == "timed_out" then … end   -- the group was killed by the host, then reaped
```

How it is non-blocking, and why it is deterministic:

- The script runs as a Lua coroutine inside a single-threaded tokio runtime (`Builder::new_current_thread`). `proc.spawn`, `wait`, `select`, `sleep_ms` are mlua async functions (`Lua::create_async_function`); calling one yields the coroutine to the host, which polls the child's fds and timer.
- Line callbacks are ordinary Lua functions invoked by the host ON THE SAME THREAD, only while the script is suspended in `wait`/`select`. No callback ever runs concurrently with script code; a callback that raises aborts `wait` with that error. Per fd, lines are delivered in arrival order, byte-exact, split on LF (a trailing CR is preserved, not stripped — CRLF is the child's statement, not the host's). The interleaving BETWEEN stdout and stderr is not exposed as one stream, because 1252-fg9e measured that a merged stream is what makes "only stdout" unknowable.
- `p:kill()` signals the GROUP (`killpg` on Unix after `setsid`; `TerminateJobObject` on Windows), waits, and returns `{status="signaled"|"exited", …}`. `timeout_ms` does the same and reports `timed_out`. This is the 1132-r4mt/1305-udgs shape: the deadline kills what the guard started, not only the guard.
- `proc.select{p1, p2, timeout_ms=…}` returns the first completed handle; `proc.all{…}` waits for every one and returns results in argument order, never completion order (so output is stable).
- Memory: a stream is line-delivered and not retained unless the script keeps it; `p:wait()` still returns `stdout`/`stderr` tails bounded by `capture_bytes` (default 1 MiB, the child's last bytes), so a 200,000-line producer cannot hold the run in memory.

### 4.4 Verdicts, errors and observability

- `verdict` is the house grammar as a module: `verdict.ok(name, n)` prints `ok:<name>:<n>` and exits 0; `verdict.refused(name, detail)` prints `refused:<name>` (stdout) with detail on stderr and exits 1; `verdict.skip(name, why)` prints `skip:<name>:<why>` and exits 0; `verdict.could_not_run(name, why)` exits 3; `verdict.blocked(reason)` exits 2. A script that returns without calling one is reported by the host as `refused:no-verdict:<script>` — the "silent green" of a guard whose last pipeline swallowed its status is unconstructible, because there is no status to swallow and no default verdict.
- The preflight door (`_pf_run_guard` and the classifier below it in build.sh) and the gate loop (`_run bash "$STEP_SCRIPT"`) today infer the class of an outcome from text; with typed results both read the same Rust `Verdict` enum from the same runner, which is the 1359-qf3p fix by construction.
- Observability hooks are host-side and free for the script: every `proc.run`/`spawn` appends `{run_id, argv, wall_ms, status, code}` to the run's trace; the host writes one timing record per script to `TILLANDSIAS_TIMING_LOG` (the field set `cycle-metrics.sh` reads) and the verdict record to `target/convergence/check-logs.jsonl` (the shape `record-ci-phase-result.sh` writes). `--trace` prints the trace on stderr. 1204-3s2s's rule (a step must not write the shared metrics path) is enforced by the host choosing the path, not by each script exporting a variable.
- `log.note`, `log.warn` go to stderr with a fixed prefix; `out.line(s)` is the ONLY stdout writer and writes LF. `print`, `io.write`, `io.read` are withheld.

## 5. Determinism rules (one script, one verdict, three platforms)

1. Locale: the host never calls `setlocale`; `os.setlocale` is withheld from both classes; all number formatting the script can reach (`fmt.int`, `fmt.fixed(x, digits)`, `json.encode`, `string.format`) is `"C"` by construction. Fixture: run with `LC_ALL=fr_FR.UTF-8` (or `br_FR`) on Linux and macOS, assert `3.50`.
2. Order: `json.encode` and `yaml.encode` emit keys sorted (byte order) unless given an ordered document from `json.parse` with `preserve_order` (1375-rn9b); `table.keys(t)` returns sorted keys; the std environment's `pairs` iterates string keys in sorted order and integer keys ascending (an O(n log n) wrapper over `next`, registered by `lua_std::register`); `next` itself is withheld. Fixture: the same script in three processes, `sha256` of stdout identical.
3. Clock: `time.monotonic_ms()` (Rust `Instant`) for durations, `time.now_ms()`/`time.iso_utc()` for timestamps, Observing only; there is no `date` to fork and no `%N` to be absent.
4. Environment: no `os.getenv`. A script declares `script{env = {"TILLANDSIAS_TIMING_LOG", "HOME"}}` at the top; `env.get` answers only those names and `nil` for any other (a misspelt name is a `nil`, never the host's value). `proc.run` children receive the host's BASE set (`PATH`, `HOME`, `TMPDIR`, `TILLANDSIAS_*`, `LC_ALL=C`, `LANG=C`, `TZ=UTC`, `GIT_TERMINAL_PROMPT=0`) plus what the call adds — the list lives in one Rust constant so the fleet has one answer to "what does a child see".
5. Paths: `path.*` is lexical and always emits `/`; `fs.*` accepts `/` on Windows and returns repo-relative `/` paths; the repo root is resolved once by the host (1367-q9yc's `fs.read` rule extends to `fs.list`, `fs.exists`, `fs.write` under the scratch root only).
6. Bytes: stdout is LF-only and UTF-8 checked; the host refuses to emit a partial line at exit; `json.encode` uses the `float_roundtrip` shortest form and never `%.14g`.
7. Randomness and time in Cacheable: none (already 1367-upz6); in Observing: `math.random` withheld unless `script{random = true}`.
8. Process defaults are the safe ones: `stdin` null, `group` true, `timeout_ms` 300000, `cwd` repo root. A script that wants the unsafe value writes it out.
9. Windows is native, not WSL: the same `proc.run` uses `CreateProcess` with an argv → command-line quoting done ONCE in Rust (`std::process::Command` does this), a job object for the group, and returns the same table; the litmus `steps:` form therefore runs on yolanda's native binary with no bash involved, which is the 1155-jurn class removed rather than worked around.

## 6. Migration strategy

### 6.1 Order of attack (highest incident rate first)

1. Deciders wired by scripts/gate-steps.d (the `check-*`/`test-*` scripts named by `STEP_SCRIPT`) that carry a recorded pipe/dialect incident: the §7 pilots first, then every step whose script matches the §2 pipe census top list.
2. The litmus step executor: run-litmus-test.sh runs each `command:` as `timeout … bash -c 'source stdlib; <string>' >capture 2>&1`. 902-5bf9's `steps:` form replaces the STRING with a Lua chunk in the Observing environment; the runner's own dispatch (`run_rust_queries_for_litmus` is the precedent) moves into `tillandsias-litmus-rust` so the runner is a Rust verb and the YAML is data.
3. Land/relay tooling: land-queue.sh, land-on-platform-branch.sh, push-plan-fragments-to-trunk.sh and the scripts/hooks/pre-push-* family — the trunk's only gate, and where `| tail -1` and `gh` timeouts bite.
4. build.sh's orchestration: the gate loop over gate-steps.d, `_run`, `_now_ms`, the preflight door, the stamp digest — each becomes a `tillandsias-plan gate <phase>` verb; build.sh keeps the flag parser and becomes the launcher in §6.4.
5. images/: the 83 in-image scripts run where the plan binary is not yet guaranteed; they migrate after the image ships the binary (the MCP servers already resolve it), entrypoints last.

### 6.2 Coexistence

- `scripts/lua/<name>.lua` beside `scripts/<name>.sh`; a gate step may set `STEP_LUA="scripts/lua/<name>.lua"` instead of `STEP_SCRIPT=`; build.sh's loop runs `"$PLAN_BIN" script run "$STEP_LUA"` (exit codes 0 ok, 1 refused, 2 blocked, 3 could-not-run, 124 timed out — the vocabulary the loop already branches on). The literal-path rule (1063-nraf) holds: `STEP_LUA` is a plain string a grep finds.
- A ported script keeps its verdict grammar byte-for-byte (`ok:<name>:<n>`), so every consumer (the preflight door, check-logs.jsonl, the freshness auditor) is unchanged. The `.sh` is deleted in the same commit as the `.lua` is wired (never two substrates for one verdict; 1252-fg9e's sweep warning).
- Litmus: `command:` and `steps:` coexist per file; a file may mix. No file is rewritten by the runner change.
- Shell scripts that must remain call the binary for anything with a pipe today: `tillandsias-plan run`, `json get`, `hash`, `time` (the previous design's verbs).

### 6.3 Forcing function and adoption counter (the rust_queries lesson)

One guard, `check-shell-ratchet.sh` (later itself a Lua script), printed on every `--check`:

```
ok:shell-ratchet:sh=<n>:floor:<f> pipes=<p>:floor:<pf> litmus-form:command=<c>:steps=<s>:rust_queries=<r> gate-steps:sh=<a>:lua=<b>
```

Rules: (1) the count of `.sh` files under scripts/ whose basename matches `check-|test-|verify-|guard-` may not exceed the floor file `scripts/portability/shell-decider-floor.txt`; a NEW one is refused with the message "write scripts/lua/<name>.lua; the runner is `tillandsias-plan script run`". (2) The count of pipe sites (the §2 command) may not exceed its floor; a NEW pipe in a file that gained lines is refused, standing debt is not reddened (1130-i6xj). (3) A NEW litmus `command:` containing `|` outside quotes is refused once `steps:` exists (902-5bf9's counter feeds it). (4) Floors only descend; a migration commit lowers them and that delta is the row's closure metric. (5) The population is asserted non-empty and the pattern is in the script header (1374-4u6i, 1174-jd8n: an empty population is a refusal).

### 6.4 build.sh as a launcher

Phase 1 (this design): build.sh keeps flags and `cargo build --release -p tillandsias-plan` (the only thing bash must do before the binary exists), then delegates each phase: `--check` → the gate loop stays in bash but runs Lua steps; `--preflight` → `tillandsias-plan gate preflight` (the door is the §7.2 pilot). Phase 2: the loop itself moves (`tillandsias-plan gate check` reads gate-steps.d as data — it already is data, 1072-b7eq); build.sh is ~200 lines: detect cargo, build the plan binary, exec it with the original argv. The stamp digest, `_now_ms`, `_run`'s OOM postmortem, and the metrics isolation check (1204-3s2s) all become host-side and platform-free.

### 6.5 What stays shell, and what it implies

| Stays | Why | Implication |
|---|---|---|
| `install-macos.sh`, `scripts/*.ps1`, `launch.sh`'s first lines, the curl-install path | runs before any of our binaries exist | these are the ONLY scripts allowed a pipe; they are excluded from the ratchet by path, and each must be bash-3.2/PowerShell-5 clean (check-bash-dialect.sh keeps scanning them) |
| `cargo build` bootstrap in build.sh | the binary cannot build itself | the launcher's shell part is under 200 lines and has no verdict logic |
| scripts/hooks/* entry stubs | git execs them with `sh` | each stub is `exec "$PLAN_BIN" hook <name> "$@"`; the logic moves |
| images/*/entrypoint*.sh until the image ships the binary | the container starts before anything else | migrate after the image build copies the plan binary; `lib-*.sh` first |
| `scripts/ensure_toolbox.sh` | it creates the toolbox that carries tools | stays; its callers stop needing it as tools move into the binary |

## 7. Pilot: three deciders with recorded incidents, as sketches

Each sketch keeps the script's verdict grammar and shows which incident class becomes UNREPRESENTABLE (not merely avoided).

### 7.1 check-seam-writers-canonical.sh (1251-54p3; SIGPIPE class 795-imz3/792-ksr8)

Today: `grep -rln … | while read f; do … sed 's://.*::' "$f" | grep -cE …` — the script's own comments say the pipeline "worked by the ABSENCE of pipefail". The port:

```lua
script{name = "seam-writers-canonical", class = "observing"}
local crate, var, canon = arg[1] or "crates/tillandsias-headless/src", arg[2] or "TILLANDSIAS_PODMAN_BIN", arg[3] or "podman_seam_lock"
local writer_re = [[(set_var|remove_var)\("]] .. text.escape(var) .. [["]]
local writers = {}
for _, f in ipairs(fs.list(crate, {glob = "**/*.rs"})) do          -- sorted, repo-relative
  local src = text.strip_line_comments(fs.read(f), "//")           -- pure, no sed fork
  if text.count_matches(src, writer_re) > 0 then writers[#writers + 1] = f end
end
if #writers == 0 then return verdict.refused("seam-var-has-no-writers:" .. var) end
local bad = {}
for _, f in ipairs(writers) do
  if text.count_matches(text.strip_line_comments(fs.read(f), "//"), text.escape(canon)) == 0 then bad[#bad + 1] = f end
end
for _, f in ipairs(bad) do out.line("refused:seam-writer-uncanonical:" .. f) end
if #bad > 0 then return verdict.refused("seam-writers-canonical") end
return verdict.ok("seam-writers-canonical", #writers)
```

Class A cannot occur: there is no consumer process to exit early, no `pipefail` to consult, and `count_matches` returns an integer, not a status. Class C cannot occur: no `sed`/`grep -r` (GNU `-r` follows symlinks, BSD does not — 1087-h2z9). The script is also Cacheable-eligible (it only reads the tree), so the memo can answer it without running.

### 7.2 The preflight door (`_pf_run_guard` and its classifier; 1352-vmbc, 1353-ryhq, 1359-qf3p, 1132-r4mt)

Today: `exec setsid bash "$_p" >"$_out" 2>&1 &`, a tenth-second poll loop, `kill -- -$pid` with a fallback to `$pid`, then `grep -qE '^skip:'` / `'^could-not-run:'` / `'not found'` over the merged capture to decide the class. The port:

```lua
script{name = "preflight", class = "observing", env = {"TILLANDSIAS_PREFLIGHT_DEADLINE"}}
local counts = {ran = 0, skipped = 0, cantrun = 0, deadline = 0, failed = 0}
for _, g in ipairs(roster) do                                   -- roster from gate-steps.d, sorted
  local r = (g.lua and proc.run{argv = {env.plan_bin, "script", "run", g.lua}, group = true, timeout_ms = deadline_ms})
         or proc.run{argv = {"bash", g.sh}, group = true, timeout_ms = deadline_ms}
  local v = verdict.classify(r)      -- reads r.status, r.code AND the first stdout line; one Rust function shared with the gate
  if v.kind == "ok" then counts.ran = counts.ran + 1
  elseif v.kind == "skip" then counts.skipped = counts.skipped + 1; out.line(v.line)
  elseif v.kind == "could_not_run" then counts.cantrun = counts.cantrun + 1; out.line(v.line)
  elseif r.status == "timed_out" then counts.deadline = counts.deadline + 1; out.line(("skip:preflight:%s:deadline:%dms"):format(g.name, r.wall_ms))
  elseif r.status == "spawn_failed" then counts.cantrun = counts.cantrun + 1; log.warn(r.stderr)
  else counts.failed = counts.failed + 1; log.warn(r.stderr); out.line("refused:preflight:" .. g.name) end
end
verdict.summary("preflight", counts, #roster)     -- refuses on an accounting mismatch, as today
```

Class F cannot occur: `group=true` is the default, so a guard's children die with it on every platform (there is no `setsid` to be absent; on Windows it is a job object), and `timed_out` is a status the child never produced rather than a 124 inferred from a killed leader. Class G cannot occur: `verdict.classify` is the SAME function the gate loop calls, so a class the door recognises is a class the gate recognises. Class E cannot occur: `r.status` never crossed a shell.

### 7.3 check-bash-dialect.sh (761-g36m; 1374-4u6i "mapfile double-counted"; awk `\b` 1132-r4mt; `_now_ms` date `%3N` 1279-a7b6)

Today the count is `grep -cE PAT_BUILTIN` plus `grep -cE PAT_BASH4` over the same file, and one `mapfile` line matches both patterns (the script's own comment at its counter). The port keeps ONE regex per idiom in a table and counts each file once:

```lua
script{name = "bash-dialect", class = "cacheable"}
local idioms = {
  {name = "mapfile",  re = [[(^|[^A-Za-z0-9_])(mapfile|readarray)([^A-Za-z0-9_]|$)]]},
  {name = "read -N",  re = [[(^|[^A-Za-z0-9_])read([[:space:]]+-[A-Za-z]*)*[[:space:]]+-[A-Za-z]*N]]},
  {name = "declare -A", re = [[(^|[^A-Za-z0-9_])declare[[:space:]]+-[a-zA-Z]*A]]},
}
local offenders, checked = {}, 0
for _, f in ipairs(fs.list("scripts", {glob = "**/*.sh"})) do
  checked = checked + 1
  local src = fs.read(f)
  if not text.first_match(src, [[BASH_VERSINFO\[0\]]], {lines = 40}) then     -- the loud-refusal exemption
    local hit = {}
    for _, i in ipairs(idioms) do if text.count_matches(src, i.re) > 0 then hit[#hit + 1] = i.name end end
    if #hit > 0 then offenders[#offenders + 1] = f .. ":" .. table.concat(hit, ",") end
  end
end
if checked == 0 then return verdict.could_not_run("bash-dialect", "empty population") end
for _, o in ipairs(offenders) do log.warn("unguarded bash-4 idiom: " .. o) end
if #offenders > 0 then return verdict.refused("bash4-unguarded:" .. #offenders) end
return verdict.ok("bash-dialect-clean", checked)
```

The double count is unrepresentable because a file is a set element, not a sum of grep exits; the regex engine is Rust's on every host (no `\b`-on-BSD silence; `[[:space:]]` and `\b` mean the same thing on all three); the empty-population refusal is a typed branch. Being Cacheable, its verdict is memoised on the bytes read (1367-q9yc), so a `--check` on an unchanged scripts/ does not rerun it.

Timing (`_now_ms`, 1279-a7b6, 1254-fdsu): every Lua script gets `wall_ms` from the host's `Instant`; there is no `date` to fork and no `%3N` to degrade to seconds silently, and `fmt.fixed(ms / 1000, 2)` is `"C"`-locale by §5.1.

## 8. Risks and what was not verified

- mlua `async` is an additional feature (adds `futures-util`, already a workspace dependency); its interaction with `send` and the `serialize` bridge must be built and tested on all three platforms before §4.3 is relied on (green on one regime is not green). Not built in this session (the main checkout is in use; no builds were run).
- Windows job objects and `CreateProcess` argv quoting for `cmd.exe`-style children (`.cmd` wrappers) are the one place "argv only" is a translation, not a syscall; the fixture must run a child with a space and a `*` in one argument on yolanda natively.
- The sorted `pairs` wrapper costs O(n log n) per iteration start; for the ledger-sized tables in expert-serve (`collect.lua`) this must be measured, and those `.lua` files may keep raw `next` under the expert environment if the cost matters — the determinism rule is for verdict-producing scripts.
- The ratchet refuses NEW `.sh` deciders; it cannot refuse a new pipe inside a `.lua` because there is none to write. The residual risk is `proc.run{argv={"bash","-c","a | b"}}` — refused by the host: `bash -c`/`sh -c` with a single string argument is rejected by `proc.run` unless `script{allow_shell_strings = true}` is declared, and that declaration is counted by the ratchet.
- `fr_FR` was not available on this host; the locale fixture must run on a host that has it (yolanda or macbookair carry French locales per 1254-fdsu).
- The counts in §2 are grep approximations of "a pipe outside a string"; the ratchet pins the command, not the concept.

## 9. Packets

New rows (fragment `plan/index.d/20260926t044959z-1384-aixy-scripting-runtime-lua-no-pipes-packets-macuahuitl.yaml`); hosts follow the fleet tiers (Linux → lenovinha then yoga; macOS → macbookair; Windows → yolanda; never macuahuitl):

| Order | Slice | Role / priority / release | Depends on | Host |
|---|---|---|---|---|
| 1384-aixy | `proc.run` / `proc.spawn` / `proc.chain` on tillandsias_exec with mlua async; group kill; line streams; run trace | linux, p1, v0.6 | 1252-fg9e, 1375-btuf | lenovinha; arm (3) also on yolanda native |
| 1384-bp6t | determinism: sorted `json.encode`/`pairs`/`table.keys`, `next` and `os.setlocale` withheld, three-process byte-identity fixture | linux, p1, v0.5 | — | lenovinha; locale arm on a host with fr_FR |
| 1384-bqhy | `tillandsias-plan script run`, the `verdict` module, `verdict.classify` shared by gate and door, `STEP_LUA=` in gate-steps.d | linux, p1, v0.6 | 1384-aixy, 1384-bp6t | lenovinha / yoga |
| 1384-bxhk | `check-shell-ratchet.sh`: counts every `--check`, refuses new `.sh` deciders and new piped litmus `command:`, floors only descend | any, p2, v0.6 | 1384-bqhy | any (macbookair verifies BSD grep) |
| 1384-ddua | the pilot: seam-writers-canonical, the preflight door, check-bash-dialect ported; `.sh` deleted; negative arms per class | linux, p1, v0.6 | 1384-bqhy | lenovinha; macOS event by macbookair |
| 1384-j3cv | build.sh → launcher; `tillandsias-plan gate <phase>` | linux, p3, v0.7 | 1384-bqhy, 1384-ddua | yoga |

Events (fragment `…t045000z-…-events-macuahuitl.yaml`): 902-5bf9 (the `steps:` form's API is §4; the five acceptance items mapped to construction), 1252-fg9e (landed as `326def3d2`/`98859cdc7` while still `ready`; the delta is 1384-aixy), 1375-amye (`run` verb and `proc.run` share one implementation; the door's first caller is also 1384-ddua's subject), 1375-btuf (the two determinism defects; add `os.setlocale == nil` to its closure or defer to 1384-bp6t).

Sequence: 1384-bp6t (independent, smallest, closes a live defect) → 1384-aixy → 1384-bqhy → 1384-ddua and 1384-bxhk in parallel → 902-5bf9's `steps:` form on the same API → 1384-j3cv.
