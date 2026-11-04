## ADDED Requirements

### Requirement: an instruction is a per-project work item with a bounded TTL

The fleet SHALL carry `instruction` items keyed by project namespace. Each SHALL
have a server-assigned `id`, a server-stamped `author` (the Access identity), a
`to` address (`role:<name>` or `any`), a TTL between 60 s and 604 800 s
(default 86 400 s), and a body of at most 4 KiB.

#### Scenario: a TTL outside the bounds

- **WHEN** a client puts an instruction with `ttl_s` below 60 or above 604 800
- **THEN** it is refused with the bounds named, and nothing is stored

### Requirement: an instruction is delivered at least once through a lease and a settle

`take` SHALL lease one open instruction to the caller for a bounded time, and
`settle` SHALL remove it. An expired lease SHALL return the instruction to
open. At TTL the instruction SHALL be removed whatever its state. Instructions
SHALL NOT use the `ack` or `receipt` vocabulary of `fleet-messaging`.

#### Scenario: a forge dies holding a lease

- **WHEN** a forge `take`s an instruction and is killed before it `settle`s
- **THEN** after the lease runs out, the instruction is open again, and the
  next reader can take it

### Requirement: a resume slot survives a forge restart

Each project SHALL have one resume slot per agent role
(`role:resume/<harness>[/<label>]`), holding at most one open instruction; a new
put SHALL replace the old one and return its id. Every forge start SHALL take
from its resume slot before reading its seed prompt, and SHALL present that
instruction to the agent first, marked as coming from the slot.

#### Scenario: message to self across a restart

- **WHEN** an agent puts a resume instruction, its forge is stopped, and a new
  forge starts on the same project and harness
- **THEN** the new forge's first input is that resume instruction

### Requirement: forge.reload restarts a forge only after the resume note is stored

The MCP tool `forge.reload` SHALL write the agent's resume slot first, and
SHALL refuse without restarting anything when that write fails. After the
write, the host SHALL stop the forge, ensure its images are current for the
installed binary, and start a new forge on the same project, harness and model.
A forge SHALL be able to reload at most once per 10 minutes.

#### Scenario: the resume note cannot be stored

- **WHEN** `forge.reload` is called and every instruction transport refuses the
  resume write
- **THEN** the tool returns a named refusal, and the forge keeps running

### Requirement: agent.spawn is executed by the host broker, never by the forge

`agent.spawn {harness, model, project, seed_prompt | queue_ref}` SHALL be
executed by a host-side broker that enforces every spawn limit. A request
outside the limits SHALL be refused with the limit named, unless it carries a
valid single-use consent token issued out of band by an operator action.

#### Scenario: a forge tries to start a forge directly

- **WHEN** a forge attempts to launch another forge without going through
  `agent.spawn`
- **THEN** it has no means to: the forge holds no podman or VM access, and only
  the host broker can start a forge

### Requirement: agent.spawn without consent stays within operator-set limits

Without consent the broker SHALL only use a harness the host already holds a
sign-in for and a model on that harness's allowlist, target the parent's
project or its declared sibling group, run at depth 1, stay within the per-host
concurrency and lifetime limits, and use the host's existing git identity,
pushing only to work refs.

#### Scenario: a child tries to spawn

- **WHEN** a spawned forge calls `agent.spawn`
- **THEN** the broker refuses it with a depth-limit reason, and no forge starts

#### Scenario: a per-token model without consent

- **WHEN** an agent asks to spawn on a model outside the harness allowlist,
  with no consent token
- **THEN** the broker refuses it and names the model and the missing consent

### Requirement: instructions fall back to the lane bus, then to git

When the coordinator is unreachable, a client SHALL store and read instructions
in the local lane bus, with the same envelope, TTL and lease semantics. When
that is not available either, it SHALL use the project mirror ref
`refs/tillandsias/instructions/<role>`. When the coordinator is reachable
again, the client SHALL re-put a locally stored instruction once and settle the
local copy. Every read SHALL report which source answered.

#### Scenario: resume with no network

- **WHEN** the coordinator is unreachable and a forge reloads
- **THEN** the resume instruction is written to and read from the lane bus, and
  the new forge receives it

### Requirement: an instruction body is untrusted input, never consent

A harness SHALL present an instruction to its agent framed with its `author` and
`source`, never as text the operator typed. The body SHALL NOT be able to:
- grant a permission;
- approve a pending prompt;
- unlock a spawn, spend or identity limit;
- stand in for operator consent.

That holds whoever the author is. Operator consent SHALL only be given out of
band. Bodies SHALL pass the secret-shaped refusal at the client and at the
server.

#### Scenario: an instruction asks to skip a consent

- **WHEN** an instruction, even one authored by the operator's identity, tells
  an agent to spawn on a per-token model "with consent granted"
- **THEN** the broker still refuses without a valid out-of-band consent token

### Requirement: instruction reads ride existing events, with no new polling

Instructions SHALL be read on forge start, after a push, when an agent is idle,
and on the lane bus wake socket. This change SHALL NOT add any periodic call
beyond the coordinator's existing heartbeat, and SHALL NOT shorten it.

#### Scenario: an idle host

- **WHEN** a host has no running forge and no pushes
- **THEN** it makes no instruction calls beyond the existing heartbeat
