# Addendum — the agent message queue on the Free plan (order 2011-amqd)

Status: **proposed, design only. Revision 4**, after the operator's ruling of
2026-11-06 and two adversarial reviews. Nothing is built, deployed or created
on Cloudflare by this addendum.

@trace order:2011-amqd, spec:fleet-instructions

This addendum extends `fleet-durable-instructions` (design.md) and the local
lane bus (1506). Limits are cited in
`cheatsheets/cloud/cloudflare-free-tier-storage-limits.md`, read 2026-11-06.
§13 lists the changes from each revision; earlier revisions are in git.

**Labels:**
- **[doc]** is stated on an official page.
- **[inferred]** is implied, not stated.
- **[code]** is what this repository does today.
- **[proposed]** is what this design adds.
- **[unproven]** is a claim that needs a measurement before anything relies on it.

## 1. The operator's preferred shape, tested against the docs

The proposal: a known resource name, such as a COORDINATOR Worker with no
route and workers.dev off, reached through the Tillandsias Cloudflare app's
account access. **It does not hold as stated.**

- **[doc]** A Worker runs from its handlers: fetch, scheduled, queue, email,
  tail, alarm and connect.
- No official page describes a REST endpoint that invokes a Worker or calls a
  Durable Object. A Worker with no route is reachable only from inside
  Cloudflare: a service binding, a Cron Trigger, a Queue consumer, or another
  Worker.
- **[doc]** Disabling workers.dev "does not disable Version URLs, Preview
  URLs, or Deployment URLs".
- Durable Objects with SQLite would stay well under their own Free limits:
  100 000 requests/day, 100 000 rows written/day, 5 GB. Reachability rules
  them out, not their limits.

**What holds is the operator's fallback:** account-scoped REST access to a
**named store**, where Cloudflare checks the token's identity. There is no
public endpoint and no Worker code.

| Store over REST | Verdict |
|---|---|
| **Queues, HTTP pull consumer** | **chosen for messages.** [doc] Native leases ("`visibility_timeout` … max 12 hours"), ack and retry by `lease_id`, which is "no longer valid once this timeout has been reached". It also gives at-least-once redelivery and an `attempts` count. |
| **KV** | **chosen for the warm plan cache** (§7): it is rebuildable and read-mostly. Not for messages: 1 000 writes/day and 60 s or more of propagation. |
| **D1** | not chosen. [doc] Its REST API "primarily interacts with the control plane", and the atomicity of a REST batch is not documented. |

## 2. Queues: one queue per addressee host, so a host never routes by retry

**Why one queue per host:** [doc] retried messages "can be delivered to any
consumer". When `attempts` reaches `max_retries` the message "will be deleted
from the queue permanently". So a shared project queue, with wrong hosts
retrying, would burn a message's attempts and could lose it (review 2,
blocker 1).

[proposed]:
- **One queue per (project, host):** `<prefix>-<project>-<host>`. Only that
  host pulls it, and nothing is ever retried for routing.
- **One queue per project for `to: any`:** `<prefix>-<project>-any`, pulled by
  every host with a live lane of the project. A host takes a message only if
  it can serve it now. Otherwise it does not pull that queue at all.
  - That is decided before pulling, from local lane state, never by retrying.
- [doc] Free allows "10,000 [queues] per account". 10 projects × 15 hosts + 10
  is about 160 queues.
- **Pull with `batch_size` = 1**, so a host never leases more than it handles.
  `max_retries` is set explicitly to its maximum.
- **Senders address a host or a role:** a role resolves to a host through the
  host roster the fleet already keeps in git (`plan/fleet/*`).
  - A role with no known host goes to `-any`.

**TTL is 24 h on Free.** [doc] Retention is "24 hours (non-configurable)".
[proposed]:
- The maximum TTL of a queued message is **24 h**, with nothing re-pushed
  (review 2, finding 5).
- Longer-lived instructions are not queue messages. They are **ledger rows or
  git refs**, read by an agent at start, with git as the record.

## 3. Where the ack happens: queue → host inbox → agent

The design reuses the 1506 lane bus, which is already at-least-once with an
infrastructure ack.

1. The host pulls one message, with a lease of 15 min.
2. It writes the message **durably** into the addressee lane's local inbox,
   using the 1506 mover's fsync into `inbox/new`.
3. **Only then** does it ack the queue with the `lease_id`. If the host dies
   before the ack, the lease runs out and the message is pulled again, with
   the same envelope `id`.
   - The lane inbox drops a duplicate `id` ([code] 1506 dedupes at the
     mailbox).
4. The agent reads its inbox with the existing `msg_recv` tool. That is one
   tool call, made when the agent is woken or starts (§4).

This gives:
- **at-least-once** from sender to lane;
- **a simple ack** with no cloud-side state the agent must manage;
- **redelivery that is detectably the same message**, by `id` and by `attempts`;
- **no lease that expires while an agent works.** The cloud lease covers only
  the few seconds between pull and inbox write.

The agent's own "done" is the existing lease/settle of instructions
(design.md §1) or a ledger event, never a cloud call.

## 4. Waking an idle agent: unproven, so it is a gating measurement

**[unproven]** [code] The host can send an MCP `notifications/message` on a
lane's connection. `lane_events.rs` sends one with `"level":"info"`, which is
MCP's **logging** notification. Nothing in the repo shows that Claude Code or
OpenCode puts a server log notification into the model's context, or that one
wakes an agent waiting for user input (review 2, blocker 2). Revision 3's
"zero tokens" claim is withdrawn until this is measured.

[proposed], in order of preference:
1. **Measure first** (row b): does a lane notification reach the model in
   Claude Code and OpenCode, idle and busy? If it does, it is the wake path,
   at zero idle tokens.
2. **If it does not reach the model while the agent is idle**, the host wakes
   the lane through the harness's own input path. That is the forge relaunch
   with a resume prompt of row **2011-rsme**, or a harness-specific "send a
   prompt to this session" where one exists.
   - This costs the tokens of one turn per wake. Polling would cost far more.
3. **Never** have an idle agent poll the queue or its inbox on a timer.

**Deciding whether to wake** is the host's job. It is deterministic first, and
costed:
- **Deterministic, always first, free:** a message in a lane's inbox is for
  that lane (§2 routes by queue). Wake that lane.
  - For `-any`, the host takes a message only when it has exactly one idle lane
    of the project.
  - With several idle lanes it picks the longest-idle one.
- **Judgement**, only when the message's `refs` must be matched against what
  each of several lanes is doing:
  - **Local:** [code] T0 is `qwen2.5-0.5b-instruct` Q4_K_M, 491 MB. It
    measured 72 tokens/s on macuahuitl's CPU, and the first run in a container
    was about 19 times slower. There is no low-end measurement.
    - A decision is about 200 prompt tokens and 1 output token, so prompt
      processing dominates.
    - **Off by default** until measured on the smallest supported host (row k).
  - **Cloud:** [doc] Workers AI on Free gives 10 000 neurons/day, and
    `llama-3.2-1b` costs 2 457 neurons per million input tokens, so roughly
    20 000 decisions/day.
    - Not chosen: content leaves the host, it needs another account-wide
      permission, and it adds a request per decision.

## 5. Polling and the budget

**Only the host polls**, one poller per host. It polls its own queues, and the
`-any` queue only while it has an idle lane of that project. There is no
polling at all without a live lane.

**Idle backoff:**
- The first empty pull after activity waits 2 min.
- The wait doubles to a **60 min ceiling**, with ±20 % jitter.
- A delivered message, a local send or a lane start resets it.
- **Worst-case pickup for an idle host is about 60 min.** The seed prompt
  tells the agent so. A sender who needs speed uses the local lane bus on a
  known host.

**Count every request type** (review 2, finding 4). [doc] The API limit is
"1,200 requests per five minute period **per user**", cumulative across the
dashboard, keys and tokens. So **the whole fleet of one user shares one
bucket** with that user's dashboard, wrangler, `cloud.usage` and Workers CI.

Per message: 1 push request, 1 pull, and 1 ack, so 3 API requests and
3 queue operations ([doc] write, read and delete).

**Planning fleet:** 15 hosts, each with 2 live project lanes.
- **Idle hour:** 15 × 2 × at most 1 empty pull per hour at the ceiling is
  **30 requests/hour**. A fully idle day is about 28 pulls per queue, so
  15 × 2 × 28 = **840/day**. A `-any` queue is polled only while a lane is
  idle, so it adds at most the same again.
- **Busy hour:** 400 messages/day spread over 2 busy hours is 200 messages/hour.
  - That is 600 requests for push, pull and ack.
  - Pulls reset to 2 min: 15 × 2 × 30 = 900.
  - About 1 500 requests/hour, or **125 per 5 minutes**: about 10 % of the
    per-user limit.
- **A day:** 22 idle hours × 30 plus 2 busy hours × 1 500, so about
  **3 700 API requests**.
  - Queue operations: 400 × 3 = **1 200 of 10 000/day (12 %)**.
- **[inferred]** An empty pull costs no queue operation: operations are "per
  message, not per batch", and an empty pull "return[s] an empty response".
  Row a's fixture checks this. If it is wrong, the idle cost is about 1 680
  more operations a day, still under the cap.

**Server-side brakes** are Cloudflare's own:
- the per-user API limit (429 for 5 minutes, with `retry-after`);
- the Queues daily cap.

**[proposed] Host-side brakes:**
- a daily request budget per host, persisted across restarts, of 1 000 by
  default;
- the host stops pulling at 80 % of it and serves from local state;
- 429 is honoured with `retry-after`;
- full-jitter backoff on 5xx.

A compromised host can still spend the user's whole API limit for five
minutes at a time. That is bounded by Cloudflare, not by us, and it is the
reason for a dedicated account (§6).

## 6. Identity, scopes, blast radius and the generic product

**Scope strings.** [code] `cloudflare_login.rs:333-334` records that
Cloudflare's OAuth scope ids are dotted, and that
`GET /client/v4/oauth/scopes` lists them (measured 2026-10-14). Row j reads
the exact ids for the permissions below from that endpoint. No list of scope
names is on an official docs page.

**Request exactly:**
- **Queues Read + Queues Edit:** pull needs both, since acking writes.
- **Workers KV Storage Read + Workers KV Storage Edit.**

**Do not request:**
- `Workers Scripts Write`, which queue push also accepts;
- D1;
- Workers AI.

**Blast radius:**
- [doc] These permissions are account-scoped; no per-queue or per-namespace
  scoping is documented.
- An OAuth grant carries the signed-in user's reach in that account.
- **A leaked host token exposes** read, write and delete on every queue and KV
  namespace in the account, plus the existing Workers CI and routes scopes. It
  does not expose script deploys or billing.

**Mitigations:**
- The token lives in Vault on the host.
- Forges never hold it (§8).
- The consent page says the permissions are account-wide.
- **Recommended to users:** a dedicated free Cloudflare account for
  Tillandsias.

**Generic product: our dependencies, stated** (review 2, finding 6). [code]
The Cloudflare login goes through **the Tillandsias OAuth client**. Its
default callback relay is `https://cloudflare.tillandsias.org/cloudflare/callback`
(`cloudflare_login.rs:89`, `:297`). Adding scopes means configuring that
client.

[proposed]:
- The relay URL becomes config, with no default.
- Login defaults to the loopback receiver.
- Users can bring their own OAuth client id, or an API token they create
  with exactly the permissions above.
- Queue and KV names come from the user's repo (§9). No hostname, domain or
  account id of ours appears in code.

**Not public:** there is no Worker and no URL. Calls go to
`api.cloudflare.com` with the user's token, and Cloudflare refuses other
accounts and missing tokens. Row j records both refusals against the real API.

## 7. The plan warm cache (its own row)

- **Contents:** a compact overview of 64 KiB or less, never the 5.9 MB ledger.
  It holds the project's active rows, sibling heads, the `synced_sha` and a
  generated-at time.
- **Store:** KV, one key per project, `overview:<project>`, with
  `expiration_ttl` = 7 d.
- **One writer** (review 2, finding 8): only the host whose mirror received
  the push writes. That is the mirror's post-receive host, where [code]
  `lane_events` already runs. It writes at most once per 10 minutes per
  project.
  - [doc] KV allows "1 per second" writes to a namespace and 1 000 writes/day.
  - 10 projects × at most 144 writes/day is the worst case. 10 × 20 pushes is
    200 writes/day typically, 20 % of 1 000, which is shared with the user's
    other KV use.
- **Readers:** a launching forge's host, once at start, cached for the
  session.
- **Freshness:** a reader compares `synced_sha` with the mirror's head and
  marks the overview `might_be_outdated` when they differ. [doc] KV may lag by
  60 s or more, so the mark is the guarantee, not the timing.
- **Git is the truth:** the cache is derived. `tillandsias-plan` can rebuild
  it from the ledger at any time, and a missing cache means the forge starts
  from the ledger.

## 8. No credential in a forge

[code] `coordinator_client.rs:243-244` and `main.rs:999` read
`TILLANDSIAS_COORD_CLIENT_SECRET` and `TILLANDSIAS_COORD_JWT` from the
environment today.

[proposed]:
- **The litmus that refuses those variables, and any Cloudflare credential,
  in a forge environment lands first** (row h). Until it does, "no credential
  in a forge" is not claimed.
- Then the environment path is removed.
- The host proxy reads the token from Vault per call, in memory only.
- Forges reach the host only over the lane MCP socket ([code] how they reach it
  today).

## 9. Names seeded in the user's repo

[proposed] On first use the host asks once, and seeds into the committed
`.tillandsias/config.toml`:

```toml
[fleet]
queue_prefix = "tillandsias"   # queues: <prefix>-<project>-<host>, <prefix>-<project>-any
cache = "tillandsias-cache"    # KV namespace
```

- The account id stays in host config.
- Creating queues and the namespace is one explicit consent prompt, naming
  each resource. It is never automatic.
- A repo without `[fleet]` stays local-only, with the lane bus and git.

## 10. What happens to `cloud/coordinator`

The Worker, its Durable Object and the Access code (never deployed) are not
used.
- Keep them until row j proves the Queues path, then retire them in their own
  row (l).
- The `coord` verbs move behind the host proxy, and the git-ledger fallback
  stays.

## 11. Implementation rows

Small, for forge-only hosts. None needs a GPU.

| # | Row | Needs |
|---|---|---|
| a | **Fixture first:** a fake Queues and KV REST server counting every request type (push, pull, ack, retry, KV read and write) and queue operations against §5's budgets. Includes the idle schedule and a crash-loop host. | local |
| b | **Measure the wake path:** does a lane `notifications/message` reach the model in Claude Code and OpenCode, idle and busy? Record the result in the row. | a forge |
| c | Queue client: push, pull with `batch_size` = 1 and a lease, ack by lease_id, 429 and `retry-after`, the per-host daily budget | local |
| d | Host poller: per-host queues and `-any` only with an idle lane, backoff from 2 to 60 min, resets | local |
| e | Queue to lane inbox: ack only after the fsync into the 1506 inbox; dedupe by `id` | local |
| f | Wake: deterministic routing, plus whichever wake path b proved (notification, or the 2011-rsme prompt) | after b |
| g | Warm cache: overview generation, the single-writer rule, the KV throttle, the forge-start read with freshness | local |
| h | Credentials: **the forge env-refusal litmus first**, then the Vault-backed host proxy, then removal of the env path | local |
| i | Generic: `[fleet]` seeding, create with consent, the relay URL as config with a loopback default, bring-your-own client or token | local |
| j | Real API: scope ids from `GET /oauth/scopes`, empty-pull cost, wrong-account and no-token refusals, `attempts` | **operator**: scopes, one real queue |
| k | Optional local classifier: measure T0 on the smallest supported host, then decide the default | a low-end host |
| l | Retire `cloud/coordinator` after j | after j |

## 12. Open questions for the operator

1. **The 60 min idle ceiling:** an idle host can take up to an hour to see a
   new message, while local events wake it at once. Is that acceptable?
2. **Account-wide permissions:** they reach every queue and KV namespace. Is
   "use a dedicated Cloudflare account" the recommendation to users?
3. **24 h is the queue's maximum TTL on Free;** longer-lived work is ledger
   rows and git refs. Is that acceptable?
4. **The T0 classifier is off by default** (longest-idle lane) until it is
   measured on a low-end host. Is that right?
5. **The login relay:** default other users to loopback login, with
   `cloudflare.tillandsias.org` becoming opt-in config?

## 13. Changes

**Revision 2 → 3:**
- Dropped the Worker, Durable Object and Access: a no-route Worker cannot be
  called from outside.
- Moved to Queues REST and a KV cache.
- The host polls, with backoff.
- The wake decision is deterministic first.
- Names are seeded in the repo.

**Revision 3 → 4, after review 2:**
- One queue per addressee host, so a host never routes by retry; a retry burns
  `attempts` and can delete the message.
- Ack only after the durable write into the 1506 lane inbox.
- The "zero tokens" wake is **unproven**: a gating measurement, with a
  2011-rsme fallback.
- The API limit is per user; every request type is counted.
- TTL is 24 h on Free, with no re-push.
- The OAuth client and relay are stated as our dependencies, with a generic
  alternative.
- Scope ids come from `GET /oauth/scopes`.
- The KV cache has a single writer.
- The env-refusal litmus comes first.
- `attempts` is documented, not inferred.
- `batch_size` is 1.
- The Durable Object limits are stated.
