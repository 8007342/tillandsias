# Lua runtime layer — audit of the managed-process slices (2026-10-04)

Requested by the operator on 2026-10-04: "take a look at the [Lua] runtime
layer and see where it stands, Codex pushed some changes relevant to it, but
I'm not sure if it's integrated into linux-next. Send a Fable to audit those
recent changes, and fix any issues you find, with their corresponding tracking
./plan and specs for durable knowledge."

Audited tree: `origin/linux-next` cdda9674d (the audited paths are unchanged
at 724309173). Plan binary `build-id` `0.1.0+579b43ef754b46de`. The audit was
run by an independent Fable 5.1 sub-agent, read-only, exercising the prebuilt
binary with probe scripts; the coordinating yoga session re-ran the probes
for F1, F3, F6 and F8 in a scratch tree of its own before changing anything.
Packets: `1551-nyzb`, `1551-n45s`, `1551-mkr9`, `1551-sprq`, `1551-af3e`,
`1551-pemw`, `1551-333i`, `1551-8gkg`, `1551-7hyq`, `1551-geib`, all under milestone
`1443-6r3q`.

## 1. Where the layer stands

- **It is on `linux-next`.** The managed-process work is not on an unmerged
  branch: 1534-puyz (live streaming and script-owned supervision) and
  1538-pwdr (select / all / chain and exit callbacks) fold `completed`;
  1539-dt84 (terminal trace) landed its first slice and was released back to
  `ready`. `git merge-base --is-ancestor d3dd5f676` is true for
  `origin/linux-next` and false for `origin/windows-next`, `origin/osx-next`
  and `origin/main`: it has reached no other platform branch and no release.
- **Working, measured:** `proc.run`, `proc.spawn`, `proc.select`,
  `proc.all`, `proc.chain`, `on_line`, `on_exit`; a policy refusal is
  returned as data; a clipped capture gives `ok=false`; no verdict gives
  `refused:no-verdict` rc 1; a script error gives `refused:script-error`
  rc 1; the runner's own `--timeout` exits 124 and reaps the child group.
- **Linux only in practice.** The `managed_script` test module and all of
  `lua_proc_trace.rs` are `cfg(target_os = "linux")`; the unit tests of the
  host and of the supervisor are `cfg(all(test, unix))`. Native macOS and
  Windows conformance are open rows (1543-ffhg, 1544-cnae, 1543-f44v).
- **1539-dt84, what landed:** one `trace:proc:` JSON line per real output,
  for `proc.run` and for dispatcher completions, deduplicated by run id.
  **What did not:** no record for `sh.run`, none for a handle still
  outstanding at the verdict, nothing on the outer timeout — whose remedy
  text still says "run it with --trace".
- **"Gate red" in commit cbafa30a1 is historical:** the candidate gate exited
  1 at `violation:scorable-obligation-missing:1` because a newly filed packet
  had no `unscoreable:`; the same commit adds it. `./build.sh --check` passed
  on cdda9674d on yoga at 2026-10-04T19:00Z.
- **OpenSpec change `lua-command-runtime-and-policies`:** 14 tasks checked,
  9 open (1.5, 2.5, 3.2, 3b.3, 3b.4, 4.2, 4.3, 5.0, 5.1). The tree holds 37
  `.lua` files against 869 `scripts/*.sh`.
- **A gap in the spec itself:** the supervisor and the Lua host both carry
  `@trace spec:command-runtime`, and before this audit that spec had no
  requirement about script-owned processes at all. The four requirements
  added with these fixes are the first.

## 2. Findings

Probe invocation for every measurement: runner started in `<scratch>/cwd`
with `TILLANDSIAS_REPO_ROOT=<scratch>/root`, `TILLANDSIAS_POLICY_AUDIT=off`,
`tillandsias-plan script run <probe>.lua --timeout <t>`.

### F1 — `sh.run` / `expert.shell` is authorised against the root and runs in the inherited cwd, with the caller's environment and no deadline — CONFIRMED, FIXED (`1551-nyzb`)

Both installers of the legacy door (`build_environment_logged` in
`lua_predicate.rs` and `Host::install` in `lua_process.rs`) called
`policy_gate(&argv, None, "sh.run")`, which substitutes the repository root
for the cwd, and then built the command with no `current_dir`, no
`env_clear` and a timeout only when the call named one.

| Measured (two sessions, same result) | |
|---|---|
| `proc.run{argv={'pwd'}}` | `<scratch>/root` |
| `sh.run{'pwd'}` | `<scratch>/cwd` |
| `proc.run{argv={'rm','-r','victim'}, cwd=<scratch>/cwd}` | `status=policy_consent_required`, `consent:policy:workspace-destroy` |
| `sh.run{'rm','-r','victim'}` | `status=exited`; `<scratch>/cwd/victim` gone, `<scratch>/root/victim` intact |
| `sh.run{'printenv','AUDIT_PROBE_SECRET'}` with the variable set on the runner | `"hunter2\n"` (`proc.run`: `""`) |
| `sh.run{'true', timeout_ms=0}` | `timed_out` (`proc.run` with 0: `exited`) |

The spec already required the opposite ("Every run SHALL have a deadline";
the child "starts from a fixed base environment"). No shipped `.lua` calls
the door (0 of 37 files, counted two ways), so the exposure was to
agent-authored scripts. BY READING, not run: under `regime=fixture` the same
substitution feeds the fixture rule's "touches the real checkout" test, so a
`git push` through this door would be judged against the scratch root while
running in the real checkout.

Fix: `prepare_shell` in `lua_predicate.rs`, called by both installers —
one cwd for the policy request and the child, `base_env_command`, default
deadline with `0` meaning none.

### F2 — a TERM to the runner orphans every script-owned child — CONFIRMED, FIXED (`1551-n45s`)

`cli_run` had no signal handling and every child runs in its own process
group. Measured by the audit agent with the preflight door's shape (no
`--timeout`, `kill -TERM -<runner group>`): the runner ended, and its child
was still alive one second later, re-parented. Control with `--timeout 1s`:
rc 124 and the child gone. The preflight door (`_pf_run_guard` in
`build.sh`) stops a `.lua` guard exactly this way, and
`check-centicolon-ratchet.lua` runs `bash centicolon-grade.sh` through
`proc.run`.

Fix: `reap_on_termination` in `script_run.rs` — TERM, INT and HUP close the
scope (bounded) and exit 128+signal; installed before any script code runs.
Unix only. NOT changed: `_pf_run_guard` still passes no `--timeout` to a
`.lua` guard; with the handler it no longer needs to for this defect.

### F3 — killing a handle whose child has exited but whose lines are undelivered returns `ok=true` with an empty capture — CONFIRMED, FIXED (`1551-mkr9`)

Measured (two sessions): `proc.spawn{seq 1 2000}`, half a second of other
work, then `p:kill()` gave `status=exited code=0 ok=true stdout_len=0
truncated=false dropped=0` with 32 lines delivered; the trace line said the
same. Control with `p:wait()`: 8893 bytes, 2000 lines. In `supervise`
(`managed.rs`) a cancellation with a known exit status and no drained
capture fell into the empty-capture arm with `truncated: dropped > 0`.

Fix: a capture abandoned by a kill or a scope close is `truncated`. A
deadline stays `timed_out`.

### F4 — `timeout_ms` on `proc.spawn` is charged for the host's own line delivery — CONFIRMED, PARTLY FIXED (`1551-sprq`)

Measured by the audit agent: `proc.run{seq 1 400000, timeout_ms=3000}` exited
in 10 ms; the same argv through `proc.spawn` was `timed_out` after 3004 ms
with 156114 lines delivered and an empty capture. `seq 1 2000` with
`timeout_ms=200`, waited after half a second of other work, was `timed_out`
although the child had long exited. 600,000 lines took 15.5 s.

Two causes. (a) `Host::wait` and the `proc.select` loop slept 1 ms after
every pump, including one that had just dispatched a full batch — FIXED:
they now only yield while events are flowing. (b) the per-process timer in
`supervise` keeps running after the leader has exited, so it bounds delivery
as well as the child — OPEN: a comment in `read_stream` says delivery is
meant to be bounded "within the process deadline", so removing that is a
design decision for the row's owner, and it fails closed today.

### F5 — one child's stream anomaly, or the 64-process limit, closes the whole scope; the same anomaly raises from `proc.run` — CONFIRMED, OPEN (`1551-af3e`)

Measured by the audit agent: a child that leaves a session-detached
descendant holding its stdout makes `proc.run` RAISE `group-pipe-eof-timeout`
through `script run` (the legacy `lua` door returns `exited` with an empty
capture instead); waiting on an unrelated `sleep 2` then raises the same
error and every later call answers `script-scope-closed`; the 65th
`proc.spawn` answers `script-process-limit` and closes the scope too
(`MAX_ACTIVE_PROCESSES = 64` has no test and no documentation). The design
says an operational outcome is "always returned, never raised". Not fixed
here: turning these into typed results changes the door's vocabulary.

FIXED 2026-10-08 (`1551-af3e`, on `work/1551-af3e`): the cut-off capture is
the child's result (real status, the bytes read, `truncated:true`) on both
doors, and the 65th live process is a `spawn_failed` value naming
`script-process-limit`. No new status word.

### F6 — the instruction hook does not follow script-created coroutines — CONFIRMED, FIXED (`1551-pemw`)

Measured (two sessions): after `pcall(verdict.ok, …)` on the main thread
nothing further ran; inside `coroutine.wrap` the script ran 20,000,000 more
iterations and `fs.write` succeeded (the file exists), and only `proc.run`
was refused. `p:wait()` inside a coroutine returned a truthy userdata instead
of waiting, so `if co() then verdict.ok(…)` goes green without waiting. mlua
0.10 keeps one hook thread; a hook that fires on another thread removes
itself.

Fix: the Observing `coroutine` table is narrowed to `yield` alone, so script code cannot create a coroutine. It could not be removed outright: mlua builds every async function from `coroutine.yield` read from the globals, and dropping the table made every Observing script fail to start. No shipped `.lua`
used it.

### F7 — a spawn that takes more than a second to set up is raised, and closes the scope for `proc.spawn` — PLAUSIBLE, OPEN (`1551-333i`)

By reading `Scope::spawn_observed` (`SPAWN_SETUP_BOUND`). Not measured: no
way was found to slow `exec` on demand.

REPRODUCED 2026-10-08 on macuahuitl (Linux), the debug plan binary at
`dff7585e3`: under `gdb -batch` with a breakpoint on glibc `_Fork` that holds
the `proc-1` supervisor thread for 2 s (`shell sleep 2`, then `continue`),
`pcall(proc.spawn, {argv={'true'}})` returned false after 2012 ms with
`proc-spawn-setup-failed:timed out waiting on channel`, and the next
`proc.run` answered `script-scope-closed`. The bound covers the supervisor
thread, not the child's own start, so the hold has to be on that thread;
gdb in all-stop mode holds every thread, and the waiting caller's monotonic
timeout still expires. Command file, run as `gdb -batch -nx -x slow.gdb
--args tillandsias-plan script run probe.lua --timeout 60s`:

```
set breakpoint pending on
handle SIGCHLD nostop noprint pass
break _Fork
run
shell sleep 2
delete 1
continue
```

A CPU quota
(`systemd-run --user --scope -p CPUQuota=2% -p CPUQuotaPeriodSec=1s`) did not:
the worst spawn was 982 ms, one period. FIXED under the same row:
`SPAWN_SETUP_BOUND` is 30 s, so slow setup is latency; after the fix the same
gdb run gave a handle after 2010 ms and the later `proc.run` exited 0.

### F8 — Observing `load` accepts binary chunks — CONFIRMED, FIXED (`1551-8gkg`)

Measured (two sessions): `load(<binary chunk>)` returned a callable that
answered 42. Lua 5.4 does not verify bytecode. No exploit was built.

Fix: `string.dump` is removed in both classes, and Observing `load` is
text-only whatever mode is asked for.

### F9 — a worker panic under `--timeout` is reported as a timeout — PLAUSIBLE, OPEN (`1551-7hyq`)

By reading `cli_run`: a disconnected channel falls into the same arm as an
elapsed deadline and prints `status=timed_out`, rc 124. Without `--timeout`
a panic unwinds past the scope cleanup. Not fixed: there is no seam to force
the branch, and an untested branch is not a fix.

## 3. Checked and held

Cacheable isolation (no `proc`, `sh`, `expert.shell`, clock, `os`, `io`,
`env`, `fs.walk`; `fs.read` refuses absolute paths outside the root and
`..`); `fs` containment against in-root symlinks pointing out; single reads
in `validate_proc`; verdict integrity after the deadline; cleanup failure
winning as `refused:cleanup-incomplete`; advisory reachable only at rc 0;
dispatcher ordering, re-entrancy refusal and lock order; no full-pipe
deadlock at 2 MB per fd.

## 4. Not checked

No mutation runs of the existing tests; `scripts/test-script-run-verb.sh`
(its fifth arm runs the gate steps); anything on Windows or macOS; the
fixture-regime half of F1; the memo validity of 1470-dbuw beyond reading.

## 5. What the fixes changed

- `crates/tillandsias-plan/src/lua_predicate.rs`: `base_env_command`,
  `default_cwd`, `prepare_shell`; `coroutine` narrowed to `yield`; text-only `load`;
  `string.dump` removed.
- `crates/tillandsias-plan/src/lua_process.rs`: the script host's shell door
  uses `prepare_shell`; `pump` reports progress and waiters yield instead of
  sleeping while events flow.
- `crates/tillandsias-plan/src/script_run.rs`: `reap_on_termination`.
- `crates/tillandsias-exec/src/managed.rs`: an abandoned capture is
  `truncated`.
- Tests: `the_legacy_shell_door_runs_where_it_was_authorised_from_the_base_environment`,
  `script_code_has_no_coroutines_and_cannot_load_bytecode`,
  `a_terminated_runner_takes_its_script_owned_child_with_it`
  (`tests/lua_proc.rs`), and
  `a_kill_after_exit_with_undelivered_lines_is_not_a_whole_capture`
  (`managed.rs`).
- Spec: four additions to `command-runtime` (durable draft and the change's
  delta).

## 6. The finding the audit missed — Python in the Lua runtime's own tests (`1551-geib`)

Raised by the operator while the fixes above were in progress, verbatim: "I
see some tests sneaking in python. What's that about? The whole reason of
gettig rid of BASH in favor of LUA is for it to work along with our ban of
python. We don't like random scripting languages in this project. Justify
sneaking in pythin inside another scripted language".

There is no justification. Measured on linux-next 724309173:

| | |
|---|---|
| lines naming Python in `crates/tillandsias-plan/tests/lua_proc.rs` | 40 |
| `python3` invocations | 23 |
| distinct Python programs | 13 (10 written to the fixture directory at 17 sites under 12 file names, 3 passed inline with `-c`) |
| introduced by | the 1534-puyz commits from d3dd5f676 (2026-10-02) and the 1538-pwdr commits (2026-10-03) |
| `scripts/check-no-python-scripts.sh` on that tree | rc 0, "ok: no Python runtime references in scripts/harness files" |

Why the guard said ok, read from `check_no_python_scripts` in the policy
crate: it scans script extensions, `scripts/`, the litmus YAML and a few
named files, for lines that BEGIN with `python` or contain forms such as
`python3 -c`. A Rust file under `crates/*/tests/` was never scanned, and
`"python3"` as a quoted argv entry matches none of its forms. The likely
reason the programs were written at all: the command policy refuses
`sh -c <string>`, so the tests needed a program in a file.

Neither the audit sub-agent nor the coordinating session flagged it, although
the coordinating session had those lines on screen while reading the test
file. The audit brief listed what to look for and the project's language
policy was not on the list; that is the brief's defect, not the sub-agent's.

Fix, in the same landing: every child program is a mode of one Rust helper,
`crates/tillandsias-plan/tests/support/fixture_child.rs`, built as a
`[[bin]]` of the plan crate and copied by no installer; the guard now also
scans `crates/*/tests/**.rs` for a quoted interpreter name or a quoted `*.py`
file name, and its unit test holds the exact lines that landed and asserts
the old matcher saw none of them. Declared limit: unit tests inside `src/`
are still not scanned. Not done: later tests in the same file write small
`sh` files; `sh` is not banned, and replacing them is left as a stated
follow-up.

## 7. Corrections made while fixing

- F1's first test asserted that `sh.run{'rm','-r','victim'}` in the root is
  refused. It is not: the policy allows `rm -r` of a directory inside the
  workspace and asks consent from a cwd outside it. The defect was the
  mismatch between the directory judged and the directory acted in, so the
  test now keeps the victim only in the inherited cwd and asserts it survives.
- F6's first fix removed the `coroutine` global. Every Observing script then
  failed to start, because mlua reads `coroutine.yield` from the globals to
  build async functions. The table is narrowed to `yield` instead.
- The supervisor test for F3 first waited for publication without draining
  the event queue, and never saw it: the `Finished` receipt queues behind the
  parked lines. The test now drains while it waits, as the Lua host does.
- The first land gate failed in 45 seconds at the ledger integrity step:
  `cargo run -p tillandsias-plan -- check` answered "could not determine
  which binary to run", because the crate now has two `[[bin]]` targets and
  twelve callers name none. `default-run = "tillandsias-plan"` restores every
  one of them. The full preflight roster had passed; it does not run that
  step. A second binary changes how the first is resolved.
- The first findings fragment carried event timestamps composed by hand,
  about an hour ahead of the clock; `check-fragment-ts-skew` refused it. They
  are now the value read from `date -u`.
- The files touched also include `crates/tillandsias-plan/Cargo.toml` (the
  fixture `[[bin]]`), `crates/tillandsias-plan/tests/support/fixture_child.rs`
  and `crates/tillandsias-policy/src/main.rs` (the widened guard).
