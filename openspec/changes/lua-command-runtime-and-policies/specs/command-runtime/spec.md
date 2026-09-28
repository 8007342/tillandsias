## ADDED Requirements

Mirror of the draft durable spec `openspec/specs/command-runtime/spec.md` (stamped req-ids live there; see tasks.md §5).

### Requirement: A command is an argv with named parameters, never a shell string

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

#### Scenario: A shell string is refused with an affordance

- **WHEN** a caller runs `bash -c "a | b"` through any door
- **THEN** the door answers `refused:policy:no-shell-strings`
- **AND** the `remedy:` line names the argv form and Lua composition

### Requirement: The run verb is the agent's door and reads argv as JSON when asked

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

### Requirement: The runtime runs identically on every locus

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
