# host-session-job-tools delta — host-session-job-tools

@trace order:2094-65yz, order:2094-dyvk

## ADDED Requirements

### Requirement: A host session reaches the job tools through a host lane

The tray MUST serve one host lane per known project at
`$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-host/mcp.sock`, with the
directory and socket modes `mcp-tool-socket` requires, attributed from the
accepting listener. The host lane's directory MUST NOT be mounted into any
container. The host lane MUST offer `watch.*`, `queue.*` and `gpu.status`
and MUST NOT offer any other tool family.

> Delta: on 2026-11-17 `.mcp.json` gave a host session the `forge-plan` and
> `project-info` servers and no client for the tray's lane socket existed.

#### Scenario: A host session lists the job tools
- **WHEN** a host session's bridge sends `tools/list`
- **THEN** the answer names the `watch.*` and `queue.*` tools and `gpu.status`
- **AND** names no browser, publish, studio or cloud tool

#### Scenario: A forge cannot reach the host lane
- **WHEN** a process inside any forge looks for a host lane socket
- **THEN** no such path exists in the container

### Requirement: The bridge is the installed binary and fails by name

The stdio bridge a host session registers MUST be a subcommand of the
installed product binary and MUST NOT be a shell script. It MUST resolve the
project from its working directory. When the tray is not running it MUST
answer `initialize` and `tools/list`, and MUST refuse each tool call within
one second with the reason `tray-not-running` and the command that starts
the tray. It MUST NOT start the tray.

#### Scenario: The tray is stopped
- **WHEN** a host session calls `queue.submit` while no tray is running
- **THEN** the call is refused within one second with `tray-not-running`
- **AND** no process is started

### Requirement: A host job runs in its own scope under a memory ceiling

A job started for a host lane MUST run in a transient systemd user scope
under a slice of its own beneath `tillandsias.slice`, created without root,
with `MemoryHigh` and `MemoryMax` set from the job's class. The job MUST
belong to the tray's scope and not to the requesting session's process tree.
The tray MUST add no credential to the job's environment.

> Delta: on 2026-11-17 a host gate was a child of the agent harness: reaped
> with the harness's background tasks under memory pressure, killed at the
> harness's 10-minute limit when run in the foreground, and bounded by no
> memory limit.

#### Scenario: A runaway host job is stopped inside its scope
- **WHEN** a host job allocates past its scope's `MemoryMax`
- **THEN** the kernel stops it inside that scope
- **AND** its ticket reports the exit and the reason `memory`
- **AND** no process outside the scope is killed

#### Scenario: The job outlives the session's tool call
- **WHEN** the session that submitted a host job ends its tool call, or exits
- **THEN** the job continues
- **AND** a later session on the same project reads its status by ticket id

### Requirement: A requester waits inside one call

The job tools MUST offer `watch.wait`, taking a watch or ticket id and
`timeout_minutes` of at most 9. It MUST block until the job's next event
(`admitted`, `done`, `requeued`, `escalated`) or the timeout, and MUST then
return the current status. It MUST NOT ask the judge anything and MUST NOT
re-read the job's files while it blocks. Events MUST also be delivered as an
MCP notification on the requester's live connection and to the lane inbox.

> Delta: on 2026-11-17 a session waited by sleeping and reading a log; no
> harness woke an ended turn on a notification (2012-kuw4, 2014-slpw).

#### Scenario: A wait returns at the event
- **WHEN** a session calls `watch.wait` and the job finishes 40 seconds later
- **THEN** the call returns at the finish with state `done`

#### Scenario: A wait is bounded
- **WHEN** nothing happens for `timeout_minutes`
- **THEN** the call returns the current status with no event
- **AND** no judge request was made

### Requirement: The host lane's isolation is described as attribution

The host lane's tool descriptions and this capability's documentation MUST
state that processes of the same user can reach one another's host lanes,
and MUST NOT describe the host lane as isolating one host session from
another.

#### Scenario: The limit is in the description
- **WHEN** a host session reads the `queue.submit` description on the host lane
- **THEN** it states that other sessions of the same user on this computer can read this lane's tickets
