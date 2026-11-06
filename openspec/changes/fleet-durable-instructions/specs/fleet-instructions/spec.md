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

### Requirement: messages travel through a named Cloudflare queue over the account API, with no public endpoint

Fleet messages SHALL be pushed to, pulled from and acked on a Cloudflare Queue
named in the project's committed `.tillandsias/config.toml`, through the
Cloudflare REST API with the user's token, held on the host. There SHALL be no
Worker, route or public URL on this path, and no name, domain or account of the
Tillandsias project SHALL be hard-coded. (order 2011-amqd)

#### Scenario: another account's token

- **WHEN** a pull or push is made with a token of another Cloudflare account,
  or with no token
- **THEN** Cloudflare refuses it, and nothing is read or written

### Requirement: each addressee host has its own queue, routed by the sender, with a dead-letter queue

Messages SHALL be pushed to the addressee host's own queue per project. The
sender SHALL resolve a role to one host from the fleet roster, and there SHALL
be no queue shared by several consuming hosts. Each consumer SHALL be created
with `max_retries` at the documented maximum and a dead-letter queue, verified
after creation. The client SHALL refuse to push a message whose `ttl_s` exceeds
the queue's retention (86 400 s on the Free plan) or that has no `sent_at`.
Correctness SHALL NOT depend on the lease, because the queue accepts a late ack.
(order 2011-amqd)

#### Scenario: a late ack after a redelivery

- **WHEN** a message's lease expires on host A, it is redelivered to A, and A's
  late ack for the first lease also arrives
- **THEN** the lane inbox holds one copy by `id`, and the agent sees it once

### Requirement: every envelope is signed by its sending host and verified before the inbox

Each host SHALL sign every envelope it sends with its own key, held in Vault,
whose public half is on the fleet roster in git. The receiving host SHALL
verify the signature and that `from` matches the signing key before writing
to any lane inbox. A message that fails SHALL be acked, quarantined and
reported once by name, and SHALL never reach an agent. (order 2011-amqd)

#### Scenario: a forged instruction from a leaked token

- **WHEN** a holder of the account token pushes an instruction with a forged
  `from` and no valid signature
- **THEN** the receiving host refuses it as `bad-signature`, quarantines it, and
  no lane inbox receives it

### Requirement: the pull handler acks every final outcome and verifies the ack

The host SHALL ack a pulled message when it is accepted into the lane inbox,
already seen, expired, or invalid, and SHALL leave it un-acked only on an I/O
error writing the inbox. An ack SHALL count only when the response reports one
acknowledged message and no warning. A lane's dedupe record SHALL be kept until
the later of the envelope's expiry and its arrival plus 24 hours.
(order 2011-amqd)

#### Scenario: an expired message is not redelivered forever

- **WHEN** a pulled message is already past its TTL
- **THEN** nothing is written to the inbox, the message is acked, and it is not
  pulled again

### Requirement: a message the sender expects is receipted, and a missing receipt is reported

For instructions, ASK and BLOCKED messages, the sending host SHALL keep an
outbox record (a ledger event for an instruction), and the receiving host SHALL
send a signed receipt when it accepts the message. With no receipt after 20
hours the sender SHALL re-push once with the same `id`, and with none by 24
hours it SHALL report `undelivered` once. (order 2011-amqd)

#### Scenario: an addressee host down past 24 hours

- **WHEN** a host is down for 30 hours and its queued instruction expires
- **THEN** the sender reports `undelivered` for it, and the instruction's row
  carries the event

### Requirement: only the host polls, with backoff, and an agent never polls on a timer

Only one poller per host SHALL pull its own queues, and only while it has a
live lane of that project. Empty pulls SHALL back
off exponentially with jitter from 5 minutes to a 60-minute ceiling, and a
delivered message, a local send or a lane start SHALL reset it. Every request
type SHALL be counted against a per-user budget, and the host SHALL honour 429
and `retry-after`. An agent SHALL NOT poll its queue or inbox on a timer.
(order 2011-amqd)

#### Scenario: an idle day

- **WHEN** a host with one live lane sees no messages for 24 hours
- **THEN** it makes about 26 pulls per queue plus hourly dead-letter pulls, and the fixture's counted
  requests stay under the stated budget

### Requirement: a sleeping agent waits on a held call, and the tray wakes it

The tray SHALL poll the queue, write accepted messages into the lane inbox, and
decide which lane has targeted work: by queue and address first, and with the
local classifier only for judgement among several lanes. A launching forge's
agent SHALL start with a `what_next` call that the local MCP server holds open,
with a progress notification at least every 10 minutes, until the tray signals
work over a local socket. The agent SHALL re-arm the call when the harness ends
it. The forge SHALL set each harness's launch settings so that the call is held
rather than backgrounded. No agent SHALL poll on a timer. Whether a held call
costs tokens, and each harness's real timeout, reconnect and expiry behaviour,
SHALL be measured before this is relied on. (order 2011-amqd)

#### Scenario: work arrives for a waiting agent

- **WHEN** an agent is waiting on `what_next` and the tray accepts a message
  addressed to its lane
- **THEN** the held call returns with the inbox item and its refs, and no model
  turn ran while the agent waited

#### Scenario: the harness ends a held call

- **WHEN** the harness's tool timeout ends a held `what_next` call
- **THEN** the agent calls `what_next` again, costing one short turn

### Requirement: a plan warm cache is a rebuildable hint, never the record

The host SHALL keep a compact project overview (at most 64 KiB) in a named KV
namespace, written at most once per 10 minutes after a successful push. Each
overview SHALL carry its git `synced_sha`. A reader SHALL mark it possibly
outdated when the mirror's head differs, and SHALL be able to rebuild it from
the ledger at any time. (order 2011-amqd)

#### Scenario: a lost cache

- **WHEN** the overview key is missing or older than the mirror's head
- **THEN** the forge starts from the ledger, and the next push rewrites the
  overview
