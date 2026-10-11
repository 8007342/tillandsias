<!-- @trace spec:command-runtime -->
# command-runtime Specification

## Status

status: draft

Draft filed 2026-09-27 under umbrella 1443-6r3q (operator direction: a Lua
runtime for bash execution with named parameters and no pipes). The change
that carries the delta and the packets is
`openspec/changes/lua-command-runtime-and-policies/`. Flip to `active` once
1443-8pur and 1443-esm5 close and the platform events are filed (L1
verification per methodology/spec-system.yaml).

## Purpose

Agents and committed automation execute commands through ONE Rust-hosted
runtime (`tillandsias_exec` behind the plan binary's Lua environment and its
`run` verb) instead of through shell strings. A command is an argv with named
parameters; stdout, stderr and the completion are three separate values; time
and output are bounded; the child starts from a fixed base environment; and
every result carries the identity of the run that produced it. There is no
pipe operator: composition happens in Lua by passing bytes. This spec fixes
the AGENT-facing doors onto the runtime that 1252-fg9e, 1384-aixy and
1375-btuf built; it does not restate their internals.

## Requirements

### Requirement: A command is an argv with named parameters, never a shell string
<!-- req-id: b4a50a1b -->

Every door onto the runtime — `proc.run{}` and `sh.run{}` in the Observing
Lua environment, `tillandsias-plan run`, and the MCP `run_command` tool — SHALL
accept the program and its arguments as a SEQUENCE of strings and SHALL
expose no entry point that parses a command line. Named parameters
(`cwd`, `env`, `stdin`, `timeout_ms`, `capture_bytes`, `group`) SHALL be
explicit fields or flags. A request whose program is a shell (`sh`, `bash`,
`dash`, `zsh`, `ksh`, `fish`, `cmd`, `powershell`, `pwsh`, with or without
`.exe`) carrying a `-c`, `-lc`, `/c` or `-Command` string SHALL be refused by
the policy engine's `no-shell-strings` rule.

#### Scenario: An argument with a space, a quote and a glob is one argv entry

- **WHEN** a caller runs `printf` with the single argument `a "b" *` through
  any door
- **THEN** the child receives exactly one argument whose bytes are `a "b" *`
- **AND** this holds on Linux, macOS and the native Windows binary

#### Scenario: An argument containing a newline arrives as one argv entry, byte-identical, on Windows

- **WHEN** a caller runs a child with a single argument containing LF, or CRLF,
  or a lone CR, on native Windows, whether the child is an MSYS program (Git's
  `printf`) or a native one (MSVC CRT command-line rules)
- **THEN** the child receives exactly one argument with exactly those bytes
- **AND** an argument without CR or LF is delivered exactly as Rust std
  delivers it, so no argv that worked before changes
- Measured 2026-10-08 on yolanda-windows (order 1553-q3wi): std quotes only a
  space, a tab or an empty argument, so a bare newline reached Git's MSYS
  `printf` as a separator and `a\nb` arrived as two entries. The fix forces
  CommandLineToArgvW / MSVC CRT quoting for arguments holding CR or LF only.
  MSYS keeps the CR of a quoted CRLF.

@trace order:1553-q3wi, spec:command-runtime

#### Scenario: A shell string is refused with an affordance

- **WHEN** a caller runs `bash -c "a | b"` through any door
- **THEN** the door answers `refused:policy:no-shell-strings`
- **AND** the `remedy:` line names the argv form and Lua composition

### Requirement: The run verb is the agent's door and reads argv as JSON when asked
<!-- req-id: 48b22c5d -->

`tillandsias-plan run [--cwd P] [--env K=V]… [--timeout-ms N]
[--capture-bytes N] [--stdin-file F] [--json] -- <argv…>` SHALL run one child
through `tillandsias_exec::Command` after the policy engine answers allow.
With `--argv-json -` the verb SHALL read the argv as a JSON array from stdin
so that no argument is present on the process command line; this is the
required form on Git Bash (MSYS argument conversion) and for any cross-locus
dispatch (`wsl.exe`). The child SHALL start from the base environment
(`PROC_RUN_BASE_ENV_PASSTHROUGH` plus `TILLANDSIAS_*` plus
`PROC_RUN_BASE_ENV_FIXED`) and the call's `--env` additions only.

#### Scenario: The caller's secrets are not inherited

- **WHEN** the caller's environment carries `GH_TOKEN=x`
- **AND** the caller runs `tillandsias-plan run -- env`
- **THEN** `GH_TOKEN` is absent from the child's stdout

#### Scenario: argv-json survives MSYS

- **WHEN** Git Bash on a Windows host feeds `["printf","%s","C:\\x\\."]` to
  `tillandsias-plan run --argv-json -`
- **THEN** the child's third argument is unconverted

### Requirement: A result is typed and carries its run identity
<!-- req-id: d3c32f18 -->

Every door SHALL return the same result shape: `run_id`, `status` from the
closed vocabulary `exited | signaled | timed_out | spawn_failed |
policy_denied`, `code` (only when exited), `signal` (only when signaled),
`ok` (true only for `exited` with code 0 and not truncated), `stdout`,
`stderr` (separate, both drained concurrently), `truncated`, `wall_ms`,
`argv` (echoed), and `policy` (`rule_id`, `decision`). A non-zero `code` is
DATA; the verb's own exit status reports only whether the verb ran (unless
`--exit-with-child` is given). A `timed_out` run SHALL NOT invent an exit
status.

A status the runtime produced by killing the child ITSELF (the deadline, the
group reap) SHALL come from the runtime's own knowledge (`timed_out`), never
from the child's exit code, on every locus.

WINDOWS-REGIME LIMIT, named `limit:windows-external-kill-reads-as-exited`: a
child killed from OUTSIDE the runtime on Windows (an MSYS `kill -KILL <pid>`)
has no signal channel to a native parent, which reads the MSYS encoding
(signal N as exit code N<<8: 2304 for SIGKILL) as `exited`. The runtime SHALL
NOT decode it, because a native program may exit 2304 on purpose; a consumer
that must tell an external kill from an exit on Windows SHALL treat that
regime as declared-limited (order 1260-2qgi, yolanda's measurement,
2026-09-28).

#### Scenario: Exit status is a value

- **WHEN** an agent runs `tillandsias-plan run --json -- false`
- **THEN** the JSON carries `status:"exited"`, `code:1`, `ok:false`
- **AND** the verb exits 0

#### Scenario: The runtime's own kill is typed on every locus

- **WHEN** a child outlives `tillandsias-plan run --json --timeout-ms 300`
- **THEN** the JSON carries `status:"timed_out"` and `code:null` on Linux,
  macOS and Windows alike

### Requirement: Time and output are bounded and a clipped capture cannot look whole
<!-- req-id: 0fb0fa97 -->

Every run SHALL have a deadline (default 300000 ms; `0` must be written out)
and a capture bound (default 8 MiB per fd). When a child writes past the
bound the runtime SHALL keep draining (no deadlock), SHALL report
`truncated:true` and `dropped:<bytes>`, and SHALL set `ok:false`. When the
deadline passes the runtime SHALL kill the process GROUP and report
`timed_out` with no partial output presented as complete.

#### Scenario: Output past the cap is reported, not hidden

- **WHEN** a child writes 3 MiB to stdout under `capture_bytes` of 1 MiB
- **THEN** `stdout` holds 1 MiB, `truncated` is true, `dropped` is 2 MiB,
  `status` is `exited` and `ok` is false

A capture ABANDONED before it was drained — because the handle was killed or
the script scope closed — SHALL be reported `truncated:true`, and therefore
`ok:false`, whatever exit status the child had already produced (order
1551-mkr9). A per-process deadline that passes while the child still runs
is reported as `timed_out` and is not this case.

A per-process deadline (`timeout_ms`) bounds the CHILD, not the delivery of
its output to the script. Once the leader has exited, its `timeout_ms` no
longer applies: a child that exited inside its `timeout_ms` SHALL keep its
real exit status and SHALL NOT be reported `timed_out`, however slowly the
script consumes its lines. Only the enclosing scope deadline can still cut
delivery off; when it does, the result SHALL keep the real exit status and
SHALL be reported `truncated:true` (an abandoned capture), never `timed_out`
(order 1551-sprq).

A capture CUT OFF because a descendant that left the process group still
holds the child's pipe when the group drain grace expires is ONE child's
condition, not a runtime failure. On every door (`proc.run`, `p:wait()`,
`proc.all`, `proc.chain` and the legacy `lua` door) the result SHALL keep the
leader's real status, SHALL hold the bytes read before the cut, and SHALL be
reported `truncated:true` (so `ok:false`); it SHALL NOT be raised, and it
SHALL NOT close the script scope or affect any other handle (order
1551-af3e).

At most `MAX_ACTIVE_PROCESSES` (64) script-owned processes SHALL be live in
one script scope; a process counts until it has been reaped and its result
published. A spawn past the limit SHALL be refused for that call only, as a
`spawn_failed` result whose `stderr` names `script-process-limit`; it SHALL
NOT be raised and SHALL NOT close the scope, and a slot freed by a wait or a
kill SHALL be usable again (order 1551-af3e).

A spawn whose setup is slow (a loaded host, an antivirus scan at process
creation) is LATENCY: the spawning door SHALL wait for the supervisor to
report the child started, up to `SPAWN_SETUP_BOUND` (30 s) capped by the
scope deadline, and SHALL then return the child's true outcome. Only a setup
stalled past that bound is a failure; it is raised and closes the scope,
because a late child may still start and a `spawn_failed` value would claim
it never ran (order 1551-333i).

#### Scenario: One child's held pipe does not close the scope

- **WHEN** a script-owned child exits 0 while a session-detached descendant
  still holds its stdout, and an unrelated handle is live
- **THEN** that child's result carries `status:"exited"`, `code:0`, the
  bytes it wrote, `truncated:true` and `ok:false`
- **AND** the unrelated handle is still waitable and later calls still run

#### Scenario: The 65th live process is a value

- **WHEN** a script holds 64 live `proc.spawn` handles and spawns once more
- **THEN** the call returns `status:"spawn_failed"`, `ok:false`, with
  `script-process-limit` in `stderr`, and the scope stays open

#### Scenario: A kill after exit does not return a whole-looking empty capture

- **WHEN** a script-owned child has exited 0 while its output is still queued
  for delivery, and the script kills its handle
- **THEN** the result carries `status:"exited"`, `truncated:true` and
  `ok:false`

#### Scenario: Slow line delivery does not turn an exited child into a timeout

- **WHEN** a script-owned child exits 0 well inside its `timeout_ms` and the
  script consumes its lines more slowly than that timeout
- **THEN** the result carries `status:"exited"`, `code:0` and the whole
  capture, not `timed_out`
- **AND** if the scope deadline passes before delivery completes, the result
  carries `status:"exited"` and `truncated:true`

### Requirement: Every Lua door judges and runs in one directory, from one environment, under one deadline rule
<!-- req-id: 231502c2 -->

`proc.run`, `proc.spawn`, `proc.chain` and the positional `sh.run` /
`expert.shell` SHALL each resolve the child's working directory ONCE per call
— the call's `cwd` where the door has one, else the repository root, else the
process cwd — and SHALL use that same value both as the cwd of the policy
request and as the cwd the child runs in. Each SHALL start the child from the
base environment (`PROC_RUN_BASE_ENV_PASSTHROUGH` plus `TILLANDSIAS_*` plus
`PROC_RUN_BASE_ENV_FIXED`) and the call's own additions only, and SHALL apply
the default deadline when the call names none; `timeout_ms = 0` SHALL mean no
deadline on every door (order 1551-nyzb).

#### Scenario: The positional door acts where it was judged

- **WHEN** the runner is started in a directory other than the repository
  root and a script calls `sh.run{'pwd'}` and `proc.run{argv={'pwd'}}`
- **THEN** both print the same directory
- **AND** `sh.run{'rm','-r','victim'}` removes nothing in the directory the
  runner was started in

#### Scenario: The caller's environment does not reach a child through any door

- **WHEN** the runner's environment carries a variable outside the base set
- **THEN** it is absent from the child of `sh.run`, as it is from the child
  of `proc.run`

### Requirement: Script code cannot outrun its verdict or load bytecode
<!-- req-id: a7234e98 -->

A script SHALL NOT be able to keep executing after its verdict or its
deadline. The script environments SHALL therefore expose no way to create a
coroutine: the Cacheable class has no `coroutine` table, and the Observing
class's table holds `yield` alone (the host's async doors are built from it).
`string.dump` SHALL be absent from both classes and Observing `load` SHALL
accept text chunks only, whatever mode the caller requests (orders 1551-pemw,
1551-8gkg).

#### Scenario: Nothing runs after a caught verdict

- **WHEN** a script catches its own `verdict.ok` with `pcall` and continues
- **THEN** no further script code runs, on any thread the script could create

#### Scenario: A binary chunk is refused

- **WHEN** a script calls `load` on a string that begins with the binary-chunk
  signature
- **THEN** `load` returns nil and a message naming a binary chunk

### Requirement: A terminated runner leaves no script-owned process behind
<!-- req-id: d38fb023 -->

When `tillandsias-plan script run` receives SIGTERM, SIGINT or SIGHUP it
SHALL close its script scope, kill and reap every script-owned process group
within the executor's cleanup bound, and exit with 128 plus the signal
number. The handlers SHALL be installed before any script code runs. On
Windows the job object owns the group and this requirement is met by it
(order 1551-n45s).

A script worker that ends WITHOUT a verdict (a panic in the runner) SHALL be
reported as a crash, `refused:script-worker-died:<name>` with exit status 1,
with or without `--timeout`; it SHALL NOT be reported `timed_out` or exit
124, SHALL NOT report a verdict the script recorded before the crash, and the
runner SHALL close its scope and reap every script-owned process group first
(order 1551-7hyq).

#### Scenario: A dead worker is a crash, not a timeout

- **WHEN** the runner's script worker panics after the script spawned a
  child, with or without `--timeout`
- **THEN** the runner prints `refused:script-worker-died:<name>` and exits 1
- **AND** the child is gone when the runner exits

#### Scenario: A TERM to the runner reaches the child in its own group

- **WHEN** a script holds a child that runs in its own process group and the
  runner receives SIGTERM
- **THEN** the runner exits 143 and the child is gone within the cleanup bound

### Requirement: The runtime runs identically on every locus
<!-- req-id: 54d853a1 -->

The plan binary is native on Linux, macOS and Windows and is resolved by
`resolve_plan_binary`. The same argv SHALL produce the same result shape on
each; the Windows door uses `CreateProcess` argv quoting done once in Rust
and a job object for the group. Bash 3.2 hosts SHALL need nothing beyond
the binary: any shell stub that invokes a door SHALL be bash-3.2-clean and
under sixty lines.

#### Scenario: A hook stub fails closed without a binary

- **WHEN** a hook stub cannot resolve a runnable plan binary
- **THEN** it prints `blocked:<hook>:no-plan-binary` and exits non-zero
- **AND** it never falls back to shell logic
