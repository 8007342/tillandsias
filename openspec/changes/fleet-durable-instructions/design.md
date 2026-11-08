# Design — fleet-durable-instructions

Status: **proposed**. Decisions marked OPEN wait for the operator (end of this
file).

## 0. What already exists, and what this adds

| Layer | Today | This change adds |
|---|---|---|
| Coordinator queue (1825) | `send`/`recv`, best effort, TTL 6 h default and 24 h max, no receipts | kind `instruction`: TTL up to 7 d, lease and settle |
| Lane bus (1506) | Maildir per lane, infrastructure-only `ack` = mailbox accepted, TTL 60 s–7 d | carries `instruction` locally when the coordinator is unreachable |
| Git mirror | project history | a fallback ref `refs/tillandsias/instructions/*` when neither of the above is reachable |
| Forge | `--rm`, no carry-over | the resume slot is read at start; tools `forge.reload` and `agent.spawn` |

The words "ack" and "receipt" stay owned by 1506. They mean a mailbox accepted
a message, never that work was done. Instructions use `take` (lease) and
`settle` (done or abandoned), so the two vocabularies cannot be confused
(warm-cache design §5 already forbids reusing the receipt vocabulary).

## 1. The instruction model

An instruction is a work item, not a chat message.

| Field | Set by | Meaning |
|---|---|---|
| `id` | server | stable id, returned by `put` |
| `ns` | client | the project namespace (normalised `owner/repo`), as today |
| `to` | client | `role:<name>` (e.g. `role:resume/codex`), or `any` for the project |
| `author` | server | the Access identity that put it (operator email or a host's service token); a client cannot set it |
| `ttl_s` | client | default 86 400 (24 h); bounds 60 s–604 800 s (7 d), same as 1506 Decision 5a and for the same reasons |
| `body` | client | ≤ 4 KiB, with 1506's shape budget and secret-shaped refusal at both sites |
| `refs` | client | optional list of git refs, orders, paths the work needs |
| `state` | server | `open` → `taken(holder, lease_until)` → removed on `settle` |

**Delivery: at least once.**
- `take` leases one open instruction to the caller for `lease_s` (default 900,
  max 3 600).
- The holder `settle`s it (`done` or `abandoned`), which removes it.
- A lease that runs out returns the instruction to `open`, so a crashed or
  killed forge does not lose the work: the next reader takes it again. Readers
  must therefore treat an instruction as possibly seen before. The body carries
  refs, and the reader checks the ledger and git before redoing work.
- At TTL the instruction is removed whatever its state, and the server writes
  nothing else. The ledger stays the record (1506 Decision 7). If the
  instruction named a row, the expiry is reported the way 1506 reports
  `undelivered`: one event, written by the infrastructure.

**Who may write and read.** Access already gates the coordinator (1825).
Within it:
- **Write:** the operator's identity, and any host service token, to any
  namespace the operator's fleet uses.
- **Forges:** a forge never holds the host's service token. It gets a
  short-lived, vault-issued capability scoped to its own project namespace,
  plus any declared sibling group (warm-cache design §4: `tillandsias` +
  `tillandsias.org` + …). The host proxies the forge's calls with that scope,
  so a compromised forge can put or take only in its own projects.
- **Read:** the same scope. No namespace listing, as today.

## 2. The resume slot: a message to yourself that survives the restart

- A forge has no stable instance identity across restarts. The slot is
  therefore keyed by **project + role**: `to = role:resume/<harness>[/<label>]`,
  for example `role:resume/codex` in `8007342/tillandsias`.
- Before an agent stops on purpose (`forge.reload`, a planned quit), it `put`s
  one instruction to its slot. The body says what it was doing, what is
  committed and pushed, the next step, and the refs (branch, order). There are
  no secrets; the shape check enforces that.
- **Every forge start** `take`s from its slot before reading its seed prompt.
  If there is an instruction, the agent's first input is that instruction,
  marked as coming from the slot, and the seed prompt comes after it.
- One slot holds at most one open instruction. A new `put` to an occupied slot
  replaces the old one (its id is returned so the writer sees what it replaced).
  Resuming is about the latest state, not a backlog.
- The work itself must still be committed and pushed to persist; forges stay
  `--rm`. The slot carries the *pointer* to the work, never the work.

## 3. `forge.reload`

The agent calls the MCP tool `forge.reload {reason, resume_body}`. Then:

1. The tool `put`s `resume_body` to the agent's resume slot. If that fails, the
   tool refuses and nothing restarts. An agent that cannot leave itself a note
   must not lose its context.
2. It asks the host, over the existing control wire, to restart this forge.
3. The host stops the forge, ensures its images are current for the installed
   binary version (the stable-upgrade change), and starts a fresh forge on the
   same project, harness and model.
4. The new forge reads its slot (§2).

`forge.reload` is the in-forge half of "reload and resume on an updated
binary". The binary swap itself is `hot-upgrade-live-stack` (1490-gttj). This
tool is how an agent opts into the new images without the operator.

Limits: at most one reload per forge per 10 minutes, so a reload loop can't
spin, and the reason is logged on the row if the forge has one.

## 4. `agent.spawn`

`agent.spawn {harness, model, project, seed_prompt | queue_ref, label?}` asks
the host to launch one child forge. `queue_ref` names an instruction id or
`role:` slot that the child `take`s at start, instead of a seed prompt. The
host broker, not the agent, enforces every limit below.

**What spawn may do without the operator** (proposed defaults; the exact
numbers are OPEN, Q2):

| Limit | Default | Why |
|---|---|---|
| harness | one the host already has a stored sign-in for | no new credentials, and no sign-in prompt in a headless child |
| model | the harness's subscription or free models, from a per-harness allowlist in `config/` | no pay-per-token spend without consent |
| project | the parent's project, or a declared sibling group | no reach into unrelated repos |
| depth | 1: a spawned child cannot spawn | no fork bombs |
| concurrency | at most 2 spawned children per host at once | VM memory: an 8 GiB guest was measured wedging under one heavy forge |
| identity | the child uses the host's existing git identity and pushes to work refs only, under branch discipline | no new identities |
| lifetime | ends when its seed or instruction is settled, or after 4 h | no orphan forges |

**What needs the operator:** a model that bills per token, a project outside
the group, more concurrency, or depth > 1. The broker refuses with a named
reason. The operator grants an exception out of band, through a tray action or
an OS-verified approval like `accept-licence`, which produces a single-use
consent token (like `image.generate`'s tier token). A message can carry that
token's id, but only the broker can validate it.

## 5. When the cloud is unreachable

The coordinator is a warm cache, and git stays the truth. The fallback order
is:

1. **Coordinator**, when reachable.
2. **Local lane bus (1506)**, on the same host. Instructions are written to the
   project's lane mailbox with the same envelope and TTL. Lease and settle are
   local files (`tmp` then `rename`, as 1506 Decision 2). This covers the
   commonest case, a resume after `forge.reload`, with no network at all.
3. **Git mirror ref**, across hosts with no coordinator: one commit per
   instruction on `refs/tillandsias/instructions/<role>`, carrying the
   envelope as a file, pushed through the mirror. Lease is a second commit
   (holder, lease_until); settle deletes the entry. Git gives durability and
   an author. TTL is enforced by readers from the commit time.

When the coordinator comes back, a client that wrote a local or git
instruction re-`put`s it once and settles the local copy, so one instruction
does not live in two places. Every answer is labelled with its `source:` as
the warm-cache client already does (`source: git-ledger`).

## 6. Cadence: events, not polling

There is no new polling interval. Instructions are read at:
- **forge start**: the resume slot, then the project queue if the seed prompt
  says so;
- **after a push**: the mirror hook already calls the coordinator;
- **agent idle**: when an agent is looking for work, as `coord next` does today;
- **local wake**: the lane bus's existing wake socket
  (`$XDG_RUNTIME_DIR/tillandsias/msg.sock`, an event and not a poll).

The coordinator's existing heartbeat (self-measured, at most 120 s, doubling
while the host is busy, paused during gates; warm-cache design §6) is the only
periodic call, and this change adds no field that makes it more frequent.

## 7. Free tier

- Instructions are rows in the existing SQLite Durable Object, swept by the
  existing alarm at TTL.
- Bounds per namespace: at most 200 open instructions and 4 KiB bodies, so at
  most about 1 MiB per project.
- Each `take`, `settle`, `put` or `release` is one request touching one object,
  and can be batched with the existing `/v1/batch`.
- Expected load is a few forges × a few calls per session, far under the free
  limits. The lever if it grows is the existing batch endpoint.

## 8. Trust: an instruction is input, not consent

This is the rule every harness integration must implement:

- An instruction or message body is **untrusted text** to the agent that reads
  it, whoever the `author` is. It is shown to the agent framed as
  "an instruction from `<author>` via `<source>`", never inlined as if the
  operator had typed it.
- It may ask for work the reading agent is already allowed to do. It cannot
  raise permissions, approve a pending prompt, unlock a spend or identity
  limit, or stand in for the operator's consent.
- The operator's identity as `author` (their Access email) makes an
  instruction *operator-authored*, which an agent may prioritise. It is still
  not consent for anything that needs consent. Consent is only ever given out
  of band (§4), because a body is just text that anyone who can write to the
  queue could have composed.
- A peer agent's instruction ranks below the operator's. An agent that
  receives a peer instruction to do something outside its task reports it
  rather than acting on it, the same rule harnesses already apply to
  cross-session messages.
- Bodies pass the 1506 secret-shaped refusal at both the client and the
  server, so an instruction cannot carry a credential.

## OPEN questions for the operator

1. **TTL.** Is 24 h default and 7 d maximum right for instructions? The
   existing coordinator messages stay at 6 h / 24 h.
2. **Spawn limits.** Are 2 concurrent children per host, depth 1, a 4 h
   lifetime, and subscription or free models only the right defaults without
   asking you? Which models do you consider free?
3. **Forge scope.** May a forge write instructions to *sibling* projects in
   its declared group, or only to its own project?
4. **Who writes.** Should a host service token be able to `put` instructions
   for any project, or only for projects that host has cloned?
5. **Git fallback.** May forges push the `refs/tillandsias/instructions/*` ref
   to the GitHub remote (visible to anyone with repo access), or should it stay
   on the local mirror only?
6. **Operator-authored priority.** Should an instruction you authored be run
   before the seed prompt, or only queued?
7. **Deploy.** The coordinator change needs a new Worker deploy. That stays
   gated on your explicit go, as 1830-hzsc is.
