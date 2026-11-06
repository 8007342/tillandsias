# Addendum — the agent message queue on the Free plan (order 2011-amqd)

> **Superseded in part by `fuzzy-context-cache.md` (revision 8, operator ruling
> 2026-11-06).** Its store (Queues), delivery (leases, receipts, DLQ) and budget
> no longer apply: the operator set a soft goal under 1 % of each free quota,
> which Queues cannot meet. The sections below stay as the record of what was
> weighed. Sections that still apply are named in revision 8 §5.

Status: **proposed, design only. Revision 7** (the operator ruled 2026-11-06
to stretch Cloudflare usage much further; immediate responses are not needed).
Built on revision 6, after the operator's rulings of
2026-11-06 (section 13 approved, the wake path, push research) and three
adversarial reviews. Nothing is built, deployed or created
on Cloudflare by this addendum.

@trace order:2011-amqd, spec:fleet-instructions

This addendum extends `fleet-durable-instructions` (design.md) and the local lane
bus (1506). The limits it cites are in
`cheatsheets/cloud/cloudflare-free-tier-storage-limits.md`, read 2026-11-06.
§14 lists the changes from each revision; the earlier text is in git.

Labels:
- **[doc]**: stated on an official page;
- **[doc, by absence]**: no official page offers it;
- **[inferred]**: implied, not stated;
- **[code]**: what this repository does today;
- **[proposed]**: what this design adds;
- **[unproven]**: needs a measurement before anything relies on it.

## 1. The operator's preferred shape, tested against the docs

The shape proposed was a COORDINATOR Worker with no route and workers.dev off,
reached through the app's account access. **It does not hold.**

- **[doc]** A Worker runs from its handlers (fetch, scheduled, queue, email,
  tail, alarm, connect).
- No official page describes a REST endpoint that invokes a Worker or calls a
  Durable Object.
- A Worker with no route is therefore reachable only from inside Cloudflare.
  Disabling workers.dev "does not disable Version URLs, Preview URLs, or
  Deployment URLs".
- Durable Objects with SQLite would stay well under their own Free limits
  (100 000 requests/day, 100 000 rows written/day, 5 GB). Reachability rules
  them out, not their limits.

**The operator's fallback holds:** account-scoped REST access to named stores,
with Cloudflare checking the token. There is no public endpoint and no Worker
code.

| Store over REST | Verdict |
|---|---|
| **Queues, HTTP pull consumer** | **chosen for messages**: leases (visibility timeout up to 12 h), ack and retry by `lease_id`, redelivery, an `attempts` count, a dead-letter queue |
| **KV** | **chosen for the warm plan cache** (§8): rebuildable and read-mostly |
| **D1** | not chosen: its REST API "primarily interacts with the control plane", and the atomicity of a REST batch is not documented |

## 2. Routing: one queue per addressee host, routed by the sender

[doc] Retried messages "can be delivered to any consumer". A message that
reaches `max_retries` is "deleted permanently" unless a dead-letter queue (DLQ)
is configured. [doc] A late ack is accepted, even when the message has since
gone to another consumer:

> "if a consumer acknowledges a message by its lease ID *after* the visibility
> timeout is reached, Queues will still accept that acknowledgment. If the
> message was delivered to another consumer during the intervening period, it
> will also be able to acknowledge the message without an error."

**So no correctness may rest on the lease.** Correctness rests on routing,
signatures, dedupe and receipts (§3–§4). [proposed]:

- **One queue per host:** `<prefix>-<host>` (revision 7; it carries every
  project of that host, routed by the envelope's `project` field). Only that
  host pulls it, so nothing is retried for routing.
- **No shared `-any` queue.** Two hosts could both run a message from one, and
  dedupe is per host (review 3, finding 4).
  - The **sender** resolves a role to one host from the fleet roster in git,
    then pushes to that host's queue.
  - A role with no reachable host stays in the sender's outbox (§4) until one
    appears.
- **The consumer** on every queue is created with `max_retries` = 100 (the
  documented maximum, "Message retries | 100") and a DLQ
  `<prefix>-<host>-dlq`. Both are verified with a GET after creation.
  [doc] The default is 3, which would let a host that crash-loops 3 times delete
  the message.
  - [doc] DLQ messages "persist for four (4) days" without a consumer.
  - The host polls its DLQ once an hour and treats what it finds as §4's
    escalation.
- **Pull with `batch_size` up to 100** (revision 7) and a 15 min lease. Each
  message is written to its lane inbox, then the batch is acked in one request.
- **[unproven]** Whether a lease expiry or a failed ack increments `attempts`.
  Row j measures it.
- **TTL on Free is 24 h.** [doc] Retention is "24 hours (non-configurable)".
  - The client **refuses to push** a message with `ttl_s` above 86 400, or with
    no `sent_at`.
  - Longer-lived work is ledger rows or git refs, read at start, with git as
    the record.
- **Size.** Envelopes are capped at 48 KB before encoding and pushed as `json`.
  [doc] Over 64 KB costs 2 operations, and pulled bodies come back base64.
- **Ordering.** [doc] No ordering is promised, and retries reorder. `seq`
  belongs to the lane, never to the queue.

## 3. Authenticity: every envelope is signed by its sending host

**The problem** (review 3, blocker 1): Queues Edit grants "full CRUDL" on every
queue in the account. [code] The lane inbox trusts the envelope's `from` and
only dedupes on it (`crates/tillandsias-msg/src/store.rs:582`). Anyone holding
the token could therefore write an instruction into any lane, as any sender.
That includes a leaked host token, and a member's own token on a shared
account.

[proposed]:
- **Each host has its own signing key**, generated on the host and held in
  Vault, never in a forge. Its public half is listed on the **fleet roster in
  git** (`plan/fleet/peers/<host>.pub`, the location 1506 already planned).
  The roster is the source of truth for which hosts may send.
- **The sending host signs** the canonical envelope (id, from, to, sent_at,
  ttl_s, kind, body).
- **The receiving host verifies** the signature against the roster, and checks
  that the `from` host matches the signing key, **before** the inbox write.
  - A failure is acked (so it does not loop), moved to quarantine, and reported
    once by name: `refused:fleet:bad-signature:<id>`. It never reaches an agent.
- **Effect:** a leaked token can delete, purge or flood queues, but it **cannot
  inject an instruction** an agent will act on. Adding a host to the roster is a
  git commit, reviewed like any other.

## 4. Delivery: inbox outcome, ack verification, receipts and expiry

### 4a. The pull handler

[code] `store.rs:537-571` returns Accepted, Duplicate (meaning "the caller
acks AGAIN"), Expired, or an error. [proposed]:

| Outcome | Action |
|---|---|
| bad signature, or does not parse or validate | ack, quarantine, report once |
| **Accepted** (fsynced into the 1506 inbox) | ack |
| **Duplicate** (already `seen`) | ack again |
| **Expired** | ack; nothing is written |
| I/O error on the inbox write | do **not** ack; the lease expires and it is redelivered |

**Ack verification.** [doc] The ack response is `{ackCount, retryCount,
warnings}`, with warnings "Map of lease IDs to warning messages". Whether ack is
idempotent is not documented.
- [proposed] An ack counts only when `ackCount` = 1 and `warnings` is empty.
- Anything else is retried with backoff. [doc] A late ack is accepted.
- A lost ack response leads to a redelivery, which `seen` turns into a
  Duplicate.

### 4b. The dedupe window

[code] A `seen` entry expires at the sender's `sent_at + ttl_s`, and an
unparseable `sent_at` gives expiry 0 (`store.rs:587-592`, `:786-797`).
[proposed]:
- keep `seen` until the later of the envelope's expiry and arrival + 24 h, so a
  queue redelivery inside retention is always caught;
- reject a `sent_at` more than 5 min in the future.

### 4c. Receipts and the outbox: no silent loss

**The problem** (review 3, blocker 2): a host down past 24 h loses its queued
mail. [doc] Expiry costs "only a write and delete operation", and nobody is
told. Git held no record of a queued message.

[proposed]:
- **The sender keeps an outbox record** of every message it pushed. For an
  instruction, the record is a ledger event on its row, so git holds it.
- **The receiving host sends a signed receipt** to the sender's own queue when
  it accepts a message (Accepted or Duplicate). This is 1506's
  infrastructure-only ack: "delivered", never "done".
- **No receipt within 20 h:** the sender re-pushes once with the same `id`,
  which the receiver dedupes. If there is still none by 24 h, it reports
  `undelivered:<id>:<to>` once, as 1506 reports expiry. For an instruction, it
  adds a ledger event.
- **Receipts are only for instructions** (revision 7). Every other kind is
  fire-and-forget on the queue; ASK and BLOCKED are also on the ledger or the
  lane bus.

## 5. Waking an idle agent: the tray polls, a held call waits

The operator's shape, 2026-11-06:
- the **tray** polls the queue;
- a **local model on the forge's host** decides whether there is targeted
  work, and may start a terminal with an agent and a seed prompt;
- a sleeping agent **does not poll**. A launching forge's agent starts with a
  "what's next for me?" call, which stays idle on the local MCP server (or a
  blocking shell command) until the tray pushes "there's work for you" over a
  local socket.

### 5a. What the harnesses allow, read 2026-11-06

| Harness | Hold one MCP call | Server push with no pending call | Notifications to the model |
|---|---|---|---|
| **Claude Code** | **[doc]** hard limit about 28 h (`MCP_TOOL_TIMEOUT` unset). The **idle** limit is 30 min for stdio servers and 5 min for HTTP or SSE. Progress counts as activity, and `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=0` disables it. A call over 2 min **auto-backgrounds**; `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=0` keeps it waiting. | **[doc]** "channels": `notifications/claude/channel` "arrives in Claude's context". It is a research preview, interactive only, stdio only, and needs `--dangerously-load-development-channels`. | `list_changed` only; logging is not documented as shown |
| **OpenCode** | **[code]** `mcp.timeout.execution` defaults to 12 h. "The SDK timeout does not reset on progress", so 12 h is the wall. | none found | only `list_changed` and elicitation; no logging handler |
| **Codex CLI** | **[code]** `tool_timeout_sec` defaults to 300 s, configurable | none | logged only |

Sources, read 2026-11-06:
- Claude Code: <https://code.claude.com/docs/en/mcp>, `/env-vars`,
  `/tools-reference` and `/channels-reference`.
- OpenCode: <https://opencode.ai/docs/mcp-servers/>, and
  `packages/core/src/mcp/client.ts:37` ("12 hours") and `:520-521` at
  sst/opencode@ec53c3b3.
- Codex: `codex-rs/codex-mcp/src/rmcp_client.rs:122-123` and
  `codex-rs/rmcp-client/src/logging_client_handler.rs` at openai/codex@ebe94e25.
- MCP specification:
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle>,
  "Timeouts".

**[doc]** MCP itself: implementations "MAY … reset the timeout clock when
receiving a progress notification", but "SHOULD always enforce a maximum
timeout".

**Waiting costs no tokens.** The model is sampled only when a result, a
notification or a user message arrives. **[unproven]** No harness documents
this as billing; row b measures it.

### 5b. [proposed] The wake path

1. **The tray polls** each project queue with a live lane, on §6's backoff, and
   writes accepted messages into the lane inbox (§4a).
2. **The tray decides** whether a message is targeted work for a lane:
   - deterministically first: the lane's queue and address;
   - the local T0 model only to choose among several idle lanes of one host for
     a role-addressed message, off by default until measured (row k).
3. **The tray may start** a terminal with an agent and a seed prompt when the
   project has no live lane and the message is an instruction for it. This uses
   the 2011-rsme relaunch-with-prompt.
4. **A live lane's agent waits on a held call.** At launch the seed prompt has
   it call `what_next {wait: true}` on the local MCP server.
   - The server holds the call and sends a **progress notification every
     10 min**. That keeps Claude Code's stdio idle limit, which progress
     resets, from firing.
   - When the tray pushes "work for you" over the local socket, the call
     returns at once with the inbox item and any **continuation affordances**:
     the item, its refs, and the `deliveries` and `attempts` counts.
5. **Re-arm on expiry.** When the harness ends the call, the agent calls
   `what_next` again. That costs **one short turn per expiry**:
   - about every 28 h on Claude Code (hard limit, with progress keeping the
     idle check alive);
   - about every 12 h on OpenCode;
   - about every 5 min on Codex, unless `tool_timeout_sec` is raised in the
     forge's Codex config, which is what this design does.
6. **Per-harness launch settings**, set by the forge, never by the agent:
   - **Claude Code:** `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=0`, so the call holds
     rather than backgrounds. The idle limit stays on, because progress
     refreshes it.
   - **OpenCode:** the default 12 h.
   - **Codex:** `tool_timeout_sec` = 43 200.
7. **Reconnect.** If the MCP server restarts:
   - Claude Code retries a remote server up to five times;
   - OpenCode marks it failed, which the user reconnects from `/mcps`.

   **[proposed]** The local server is stdio, spawned by the harness, so a
   restart is the harness's own respawn. Whether Claude Code respawns a crashed
   stdio server is **[unproven]**, and row b checks it. Until then the agent
   re-arms on any error.
8. **Optional, Claude Code only:** a channel server can push with no pending
   call, but it is preview and interactive-only behind a dangerous flag.
   **Not the default.** It may be used where the operator enables it, never as
   the only path.

**Row b measures all of this** in a real forge:
- that a held call costs no tokens while waiting;
- each harness's real timeout and what it does at expiry;
- that a progress notification keeps Claude Code's idle check alive;
- the reconnect behaviour;
- headless versus interactive.

### 5d. Idle agents shut down gracefully (revision 7, with 2014-slpw)

The operator: "if you're inactive, just do a graceful shutdown with pushes to
remote". [proposed]:
- **The `what_next` held call is for short waits:** a lane that has just
  finished work and expects more soon, up to the harness limit.
- **Long idleness ends the agent.** When `what_next` has waited 30 min with no
  work, it returns a **quick shutdown suggestion**: commit and push to the
  remote, record a resume note, then exit.
- **Waking a stopped agent is the tray's job.** When work arrives for a lane
  with no live agent, the tray starts a terminal with an agent and a seed
  prompt (2011-rsme / 2014-slpw).
- **Which waits block and which exit** is settled in 2014-slpw. This design
  defers to it: a block only while short, an exit when long.

### 5c. Do we need to poll the queue at all? Push options on the Free plan

Researched 2026-11-06 (cheatsheet):
- **Queues:** pull is short-poll only, [doc] "Queues does not hold an open
  connection (often referred to as 'long polling')", and push consumers are
  Workers only.
- **Durable Object WebSockets with hibernation:**
  - available on Free;
  - **[doc]** 20:1 billing on incoming messages, free outgoing, no duration
    while hibernated;
  - roughly 500–1 000 requests/day for 15 hosts, under 1 % of quota.
  - **But** clients connect through a Worker on a reachable hostname, so the
    endpoint is public. It answers anyone, at least with 401. Unauthenticated
    hits spend the shared Free request quota, and token checks must be written
    in Worker code, since Access is excluded.
  - A queue also cannot have a Worker consumer and an HTTP pull consumer at
    once, so the producer would have to notify the push channel itself.
- **Pub/Sub:** gone (its page redirects).
- **Tunnel:** inbound to the host, with a public hostname per host; private
  mode is Zero Trust.
- **SSE Workers:** public too.
- **Email, Realtime and Cron:** not host channels.

**Recommendation, stated plainly: keep polling.** No push option on the Free
plan works without a public endpoint, and the operator approved the
nothing-public shape.
- The tray's conservative poll (§6: a 5 min start with stagger, ×4 backoff to 120 min, a 6-hourly DLQ pull, no
  polling without a live lane) costs about 40 % of the free queue operations at
  planning load, and **nothing in agent tokens**, because agents wait on held
  calls.
- If the operator later accepts one token-checked public endpoint, the
  hibernated Durable Object WebSocket is the cheap push to add **beside**
  polling, never instead of it. That needs its own design row and review.

## 6. Polling and the budget (revision 7: stretched)

The operator, 2026-11-06: "stretch Cloudflare usage much further; immediate
responses aren't needed".

**[proposed] Changes from revision 6:**
- **One queue per host,** not per (project, host). It is named
  `<prefix>-<host>` and carries every project of that host, each routed by the
  envelope's `project` field to its lane inbox. This halves the queues to
  poll, and halves the empty pulls with them. The DLQ is likewise one per
  host.
- **Batch reads.** A pull takes up to `batch_size` = 100 (the documented
  maximum), and the acks for a batch go in **one** ack request ([doc] ack
  "takes an array of lease_id objects").
  - Several messages for one host are one pull and one ack, never several.
  - [doc] Operations are still "per message, not per batch": batching cuts
    **API requests**, not the 3 operations each message costs.
  - The lease covers the batch. Each message is written to its lane inbox,
    then the whole batch is acked.
- **Polling starts no faster than every 5 min,** with a **per-host random
  stagger**: a fixed random offset of 0 to 5 min per host, plus ±20 % jitter,
  so hosts never align.
- **Back off quickly when idle:** ×4 per empty pull, 5 → 20 → 80 → **120 min**
  ceiling.
  - Resets happen on a delivery, a local send or a lane start, and only back to
    5 min.
- **The DLQ is pulled every 6 h,** not hourly.
- **Receipts are only for instructions** (not ASK, BLOCKED or FYI). ASK and
  BLOCKED still go on the ledger or the lane bus, as today.
- **Idle agents shut down gracefully** (§5d).

**The planning fleet:** 15 hosts, so 15 queues and 15 DLQs.

| Item | Queue operations/day | API requests/day |
|---|---|---|
| idle pulls: 5 + 20 + 80 = 105 min for the first 3, then every 120 min, about 14/queue | 15 × 14 = 210 | 210 |
| DLQ pulls every 6 h | 15 × 4 = 60 | 60 |
| busy pulls: 2 busy hours, resets roughly every 20 min, about 8/hour | 15 × 16 = 240 | 240 |
| 400 messages (write, read, delete) | 1 200 | about 400 pushes + batched pull/ack, at most 800 |
| 100 receipts (instructions only) | 300 | about 200 |
| **total** | **about 2 010 of 10 000 (20 %)** | **about 1 500** |

- **Target, stated in the row:** a planning day is at most **2 500 queue
  operations (25 %)** and **2 000 API requests**. The fixture (row a)
  **fails above either**.
- **Headroom:** the operation cap is reached at about 5× the planning load.
  Message traffic is now 75 % of the operations, which is the irreducible cost
  of the messages themselves. Idle polling is 13 %.
- **Peak:** a busy hour is about 120 pulls plus pushes, under 15 requests per
  5 min. That is about **1 %** of the per-user API limit.
- **Worst-case pickup:** an idle host sees a new message within **about 2 h**,
  a busy one within 5–20 min. Local events wake at once. The seed prompt tells
  agents so.

**Brakes:**
- [proposed] A per-host daily budget, persisted, in operations and requests:
  1/20 of the caps.
- Polling stops at 80 % of it.
- 429 with `retry-after` is honoured, with full-jitter backoff.
- Cloudflare's own caps are the backstop.

## 7. Identity, scopes, blast radius and the generic product

**Scope ids:** [code] `cloudflare_login.rs:333-334` records that
`GET /client/v4/oauth/scopes` lists them. Row j reads the exact ids from it.

**What a host needs, as two separate grants** (review 3, finding 9):
- **The queue grant:** Queues Read + Queues Edit (pull needs both, since acking
  writes), and Workers KV Storage Read + KV Storage Edit.
- **The existing CI grant**, kept apart: `workers-ci.read`/`.write`,
  `workers-routes.read`, `workers-scripts.metadata_read`,
  `account-settings.read`.
- **Not requested:** `Workers Scripts Write` (which queue push also accepts),
  D1, Workers AI, API Tokens, Account Settings Edit, billing.

**What a leaked queue grant exposes:** [doc] "`Edit` is full CRUDL (create,
read, update, delete, list) access", on every queue and KV namespace in the
account. [doc, by absence] Per-resource scoping is documented for zones only.
The holder can:
- create, delete and **purge** queues;
- change or remove consumers, for example `max_retries` 0 or no DLQ, or attach
  its own consumer;
- read and delete messages;
- read, write and delete KV;
- burn the account's 10 000 operations/day and the shared per-user API limit.

It **cannot inject an instruction an agent acts on** (§3). Revision 4 said a
token "does not expose script deploys". That was too strong for the CI grant:
`workers-ci.write` triggers Workers Builds, which run the repository's deploy
command. Keeping the grants separate limits a queue-grant leak to the queue
store.

**[proposed] Mitigations:**
- **A dedicated Cloudflare account is required**, not just recommended, for the
  queue grant. The account holds nothing else.
- Tokens are held in Vault on the host and never in a forge (§9).
- **Drift detection:** the host lists the account's queues and consumers once a
  day and compares them with the seeded set. It reports any extra queue or
  consumer, a changed `max_retries`, or a missing DLQ.
- **A revoke-and-rotate runbook:** revoke the grant (logout already revokes,
  best-effort, `cloudflare_login.rs:1532`), sign in again, re-verify the
  consumers, and rotate any host signing key that might be exposed.
- [doc, by absence] The OAuth access-token lifetime is not stated on an
  official page; the code trusts `expires_in` (`:1240`).

**Generic product.** [code] The login uses **the Tillandsias OAuth client** and,
by default, the relay `cloudflare.tillandsias.org` (`cloudflare_login.rs:89`,
`:297`). The relay sees only the code and state, never a token: the flow is
Authorization Code with PKCE, and the verifier goes only to the token endpoint
(`:25`, `:31`).
- [proposed] The relay becomes config with no default, and loopback is the
  default receiver.
- Users can bring their own OAuth client, or an API token scoped to the
  dedicated account with exactly the queue grant.
- Names come from the user's repo (§10).

## 8. The plan warm cache (its own row)

- **Contents:** a compact overview of 64 KiB or less: the project's active rows,
  its sibling heads, `synced_sha` and a generated-at time. Never the 5.9 MB
  ledger.
- **Storage:** KV, `overview:<project>`, with `expiration_ttl` 7 d.
- **Writes:**
  - one writer, the host whose mirror received the push;
  - at most once per 10 min per project;
  - typically 200 of 1 000 writes/day.
- **Reads:** at forge start, cached for the session.
- **Freshness:** a `synced_sha` that differs from the mirror's head marks the
  overview `might_be_outdated`. [doc] KV may lag by 60 s or more.
- **Git is the truth:** the cache is derived and rebuildable from the ledger,
  and a missing cache means starting from the ledger.

## 9. No credential in a forge

[code] `coordinator_client.rs:243-244` and `main.rs:999` read
`TILLANDSIAS_COORD_CLIENT_SECRET` and `TILLANDSIAS_COORD_JWT` from the
environment.

[proposed]:
- **the litmus that refuses those, and any Cloudflare credential or signing
  key, in a forge environment lands first**;
- then the host proxy, reading from Vault per call, in memory only;
- then the env path is removed.

Forges reach the host only over the lane MCP socket.

## 10. Names seeded in the user's repo

[proposed] On first use the host asks once and seeds the committed
`.tillandsias/config.toml`:

```toml
[fleet]
queue_prefix = "tillandsias"   # queues <prefix>-<host> and <prefix>-<host>-dlq
cache = "tillandsias-cache"    # KV namespace
```

- The dedicated account's id stays in host config.
- Creating the queues, consumers, DLQs and the namespace is one explicit
  consent prompt, naming each resource.
- A repo without `[fleet]` is local-only.

## 11. What happens to `cloud/coordinator`

It is not used. It stays as a reference until row j proves the Queues path,
then is retired (row l).

## 12. Implementation rows (small, for forge-only hosts)

| # | Row | Needs |
|---|---|---|
| a | **Fixture first.** A fake Queues and KV REST server counts every request type and every queue operation. It covers: empty pulls costing a read, late acks accepted, a lost ack response, an Expired outcome, a poison message, the §6 budgets, and a crash-loop host. | local |
| b | Measure the wake path in Claude Code and OpenCode, idle and busy | a forge |
| c | Queue client: push (ttl ≤ 86 400 and `sent_at` required, 48 KB cap), pull (batch up to 100, lease; one ack request per batch), ack verified by `ackCount` and warnings, 429 / `retry-after`, a per-host budget in operations and requests | local |
| d | Host poller: 5 min start, per-host stagger, ×4 backoff to 120 min, a DLQ pull every 6 h, resets | local |
| e | Inbox handler: the §4a outcome table, the §4b dedupe window, quarantine | local |
| f | Wake: deterministic routing plus whichever path row b proved | after b |
| g | Warm cache (single writer, throttle, freshness) | local |
| h | Credentials: the forge env-refusal litmus first, then the Vault host proxy, then remove the env path | local |
| i | Generic: `[fleet]` seeding, create with consent, the relay as config with a loopback default, bring your own client or token | local |
| j | Real API: scope ids, whether a lease expiry or failed ack counts as an attempt, the `max_retries` 100 + DLQ verified by GET, wrong-account and no-token refusals | **operator**, blocked |
| k | Optional local classifier, measured on the smallest host | a low-end host |
| l | Retire `cloud/coordinator` after j | blocked on j |
| m | **Signing:** per-host keys in Vault, `plan/fleet/peers/<host>.pub`, sign at send, verify before the inbox write, quarantine | local |
| n | **Receipts and outbox:** a signed receipt per instruction, ASK and BLOCKED; re-push at 20 h; `undelivered` at 24 h; a ledger event for instructions | local |
| o | **Drift check and runbook:** a daily listing of queues and consumers against the seeded set; the revoke-and-rotate steps | j for the real list |

## 13. Operator answers (2026-11-06) and remaining questions

The operator, first-hand: "I approve all the recommendations": a 60 min idle
ceiling, a dedicated account required, a 24 h TTL, T0 off by default, loopback
login by default, and signing keys on a git roster. Exception: **the relay stays
at `cloudflare.tillandsias.org` for now.** Real API use stays within this
design's limits. Row j is unblocked.

Remaining:
- whether to add a token-checked public push endpoint later (§5c; recommended:
  no, keep polling);
- whether the Claude Code channel may be enabled where available (§5b.8).

### Earlier questions (answered)

1. Is a 60 min idle ceiling acceptable? The busy floor is 5 min, and local
   events wake at once.
2. **A dedicated Cloudflare account is now required** for the queue grant. Is
   that acceptable as a product requirement?
3. Is a 24 h TTL acceptable, with longer work in the ledger and git?
4. Should T0 stay off by default (longest-idle lane) until it is measured?
5. Should login default to loopback, with the relay opt-in?
6. **New:** are per-host signing keys on a git roster (`plan/fleet/peers/`)
   acceptable as the trust root for who may send?

## 14. Changes

**Revision 2 → 3:** the Worker, Durable Object and Access path were dropped;
messages moved to Queues REST and the cache to KV; the host polls with backoff;
the wake decision is deterministic first; names are seeded in the repo.

**Revision 3 → 4:** one queue per host; the ack happens after the inbox write;
the zero-token wake was marked unproven; the per-user API limit was budgeted;
the TTL became 24 h; the OAuth and relay dependency was stated; the cache got a
single writer.

**Revision 6 → 7:** stretched usage, by the operator's ruling:
- one queue per host, for all its projects;
- batched pulls and acks;
- a 5 min start with per-host stagger, then ×4 backoff to a 120 min ceiling;
- the DLQ pulled every 6 h;
- receipts for instructions only;
- a graceful shutdown for idle agents.

The planning day is about 2 010 operations (20 %), with a fixture target of
2 500 (25 %) and 2 000 requests.

**Revision 5 → 6:** the wake path follows the operator: the tray polls, the
tray decides, and agents wait on a held `what_next` call with progress
keep-alives, re-armed on expiry, under per-harness launch settings. Notifications
are not relied on: no harness surfaces logging to the model. Push on Free was
researched; none works without a public endpoint, so polling stays. Section 13
records the operator's approval.

**Revision 4 → 5,** after review 3:

Corrected claims:
- **A late ack is accepted** by Cloudflare. "Only the current holder can
  settle" was false, so correctness no longer rests on the lease.
- **An empty pull costs a read**; the budget was recomputed.
- Revision 4 said `attempts` was documented. It is, but whether a lease expiry
  counts as an attempt is not.

New:
- signed envelopes and a roster, so a token leak cannot inject an instruction;
- receipts plus the sender's outbox, so a host down past 24 h is reported,
  never lost silently;
- the inbox outcome table, so an Expired or invalid message does not loop;
- ack verification by `ackCount` and warnings;
- the dedupe window set to arrival + 24 h;
- `-any` dropped in favour of sender-side role routing;
- `max_retries` 100 plus a DLQ, verified by GET;
- the blast radius restated as full CRUDL, with the queue and CI grants split
  and a dedicated account required;
- the drift check and the runbook;
- the busy floor raised to 5 min;
- the 48 KB size cap.
