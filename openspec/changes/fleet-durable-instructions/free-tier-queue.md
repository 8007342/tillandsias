# Addendum — the agent message queue on the Free plan (order 2011-amqd)

Status: **proposed, design only. Revision 5**, after the operator's ruling of
2026-11-06 and three adversarial reviews. Nothing is built, deployed or created
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

- **One queue per (project, host):** `<prefix>-<project>-<host>`. Only that host
  pulls it, so nothing is retried for routing.
- **No shared `-any` queue.** Two hosts could both run a message from one, and
  dedupe is per host (review 3, finding 4).
  - The **sender** resolves a role to one host from the fleet roster in git,
    then pushes to that host's queue.
  - A role with no reachable host stays in the sender's outbox (§4) until one
    appears.
- **The consumer** on every queue is created with `max_retries` = 100 (the
  documented maximum, "Message retries | 100") and a DLQ
  `<prefix>-<project>-<host>-dlq`. Both are verified with a GET after creation.
  [doc] The default is 3, which would let a host that crash-loops 3 times delete
  the message.
  - [doc] DLQ messages "persist for four (4) days" without a consumer.
  - The host polls its DLQ once an hour and treats what it finds as §4's
    escalation.
- **Pull with `batch_size` = 1** and a 15 min lease.
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
- **Receipts are only for kinds that need them:** instruction, ASK, BLOCKED.
  FYI and HEADS-UP messages are fire-and-forget, to keep the operation count
  down (§6).

## 5. Waking an idle agent

**[unproven]** The host can send an MCP `notifications/message` on a lane's
connection. [code] `lane_events.rs` uses it, but as MCP's **logging**
notification. Nothing shows that Claude Code or OpenCode surfaces it to an idle
model.

[proposed]:
- **Row b measures it**, idle and busy, in both harnesses. If it works, idle
  costs zero tokens.
- **If not:** the host wakes the lane through the harness's own input path,
  the 2011-rsme relaunch-with-prompt, at the tokens of one turn per wake.
- **No agent ever polls on a timer.**
- **The wake decision is deterministic:** a message in a lane's inbox is for
  that lane. A model is needed only to choose among several idle lanes of one
  host for a role-addressed message.
  - The T0 local model is `qwen2.5-0.5b` Q4_K_M, 491 MB. It ran at 72 tok/s on
    macuahuitl's CPU, the first run in a container was about 19× slower, and
    nothing in the repo measures a low-end host. It is **off by default**; the
    default is the longest-idle lane.
  - The cloud alternative, Workers AI (10 000 neurons/day, roughly 20 000
    decisions/day on `llama-3.2-1b`), is not chosen: content would leave the
    host, and it needs another account-wide permission.

## 6. Polling and the budget

[doc] **An empty pull costs a read operation:** "Pull-based consumers that
attempt to pull from a queue, even when empty, will incur a read operation."
Revision 4 had inferred the opposite.

[doc] The API limit is "1,200 requests per five minute period **per user**",
cumulative across the dashboard, keys and tokens.

**The poller** [proposed]:
- only the host polls;
- one poller per host, for its own queue per project with a live lane;
- empty pulls back off from **5 min** (raised from 2) doubling to **60 min**,
  with ±20 % jitter;
- reset on a delivery, a local send or a lane start;
- the DLQ is polled once an hour;
- no polling without a live lane.

**The planning fleet:** 15 hosts × 2 project lanes = 30 queues.

| Item | Queue operations/day | API requests/day |
|---|---|---|
| idle pulls: 5 + 10 + 20 + 40 = 75 min for the first 4, then hourly, about 26/queue | 30 × 26 = 780 | 780 |
| DLQ pulls, hourly | 30 × 24 = 720 | 720 |
| busy pulls: 2 busy hours at a 5 min floor | 30 × 24 = 720 | 720 |
| 400 messages (write, read, delete) | 1 200 | 1 200 (push, pull, ack) |
| 200 receipts (instruction, ASK and BLOCKED only) | 600 | 600 |
| **total** | **about 4 000 of 10 000 (40 %)** | **about 4 000**. The busy-hour peak is 360 pulls + 600 for messages + 300 for receipts ≈ 1 260/h, ≈ 105 per 5 min, **9 %** of the per-user limit |

**Headroom:** the operation cap is reached at about **2.5× the planning load**.
Idle polling is now **38 % of operations** (DLQ plus idle pulls, 1 500 of
4 000). The idle schedule is therefore the first thing to stretch if the
fleet grows.

**[proposed] Brakes:**
- a per-host daily budget, persisted across restarts, **in both queue
  operations and API requests**, by default 1/20 of the account cap each;
- polling stops at 80 % of it;
- 429 is honoured with `retry-after`;
- full-jitter backoff on 5xx;
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
queue_prefix = "tillandsias"   # queues <prefix>-<project>-<host> and -dlq
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
| c | Queue client: push (ttl ≤ 86 400 and `sent_at` required, 48 KB cap), pull (batch 1, lease), ack verified by `ackCount` and warnings, 429 / `retry-after`, a per-host budget in operations and requests | local |
| d | Host poller: 5 → 60 min backoff, an hourly DLQ pull, resets | local |
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

## 13. Open questions for the operator

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
