## ADDED Requirements

### Requirement: cost-bearing actions are listed in one gate table

The host SHALL keep one gate table naming every action that costs cloud
minutes: triggering a GitHub workflow, updating or merging into an integration
or default branch, opening a pull request into an integration branch, creating
a remote worker, and creating or refreshing any Cloudflare resource (including
order 1853-qr4h's deploy tool). Host MCP tools that cause one SHALL be marked
cost-bearing.

#### Scenario: every cost-bearing tool is gated

- **WHEN** a test enumerates `tools/list` from `handle_mcp_jsonrpc`
- **THEN** every tool whose call can reach a cloud write API is in the gate
  table, and a tool that is not in the table makes only read requests

### Requirement: a gated call without approval sends nothing

`handle_mcp_jsonrpc` SHALL consult the gate table before dispatching a tool
call. A gated call with no valid approval bound to it SHALL return
`state: awaiting_approval` with an `approval_id` and `retry_after_s`, SHALL
ask the host broker to show the approval dialog, and SHALL NOT contact any
cloud API.

#### Scenario: a gated Cloudflare call waits

- **WHEN** a forge calls a cost-bearing Cloudflare tool and no approval exists
- **THEN** the response state is `awaiting_approval` and a fake Cloudflare API
  records no request

#### Scenario: an approved call proceeds once

- **WHEN** the operator approves that request and the forge calls again with
  the same arguments
- **THEN** the call is dispatched once, and a third identical call needs a new
  approval

#### Scenario: a declined call is reported, not retried

- **WHEN** the operator declines
- **THEN** the response state is `declined` and no cloud request is sent

### Requirement: an agent can never approve itself

Approval SHALL be produced only by the host broker after an OS-verified user
check, using a key the forge cannot reach. Any request argument that claims an
approval SHALL be ignored. The forge SHALL have no tool, socket or file that
creates or signs an approval.

#### Scenario: a forged approval argument is ignored

- **WHEN** a forge calls a gated tool with an argument `approved: true` or a
  pasted approval record
- **THEN** the response is `awaiting_approval` and no cloud request is sent

### Requirement: host scripts dispatch workflows only through the broker

Every host script or skill step that runs `gh workflow run` or creates a pull
request into an integration branch SHALL first obtain an approval with
`tillandsias approval request` and SHALL stop when it is declined or expires.

#### Scenario: a declined release dispatch stops

- **WHEN** the release step asks for approval and the operator declines
- **THEN** `gh workflow run` is not invoked and the step exits non-zero with one
  plain sentence
