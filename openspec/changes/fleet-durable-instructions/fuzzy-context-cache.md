# Revision 8 — a fuzzy fleet context cache on KV (order 2011-amqd)

Status: **proposed, design only.** This file **supersedes the store, delivery
and budget** in `free-tier-queue.md`, revisions 2–7: Queues, leases, receipts,
the DLQ and the polling budget. Those sections stay as the record of why Queues
was weighed and dropped. Nothing is built, deployed or created.

@trace order:2011-amqd, spec:fleet-instructions

## 1. The operator's ruling, 2026-11-06

- **Targets for a fleet our size:**
  - **soft goal: under 1 % of each free quota;**
  - **hard limit: 5 %**;
  - it "should never get near 1 %", to leave room for the user's other apps.
- **The cloud store is a soft, fuzzy, slightly stale, slightly unreliable
  context cache, not a system of record.** Agents confirm from their repos.
- **The warm cache is general guidance** on a project and its siblings, not as
  fine-grained as `./plan`.
- **Agents push only major milestones,** not every change. Pushes and reads are
  batched.
- **Cost affordances in our tools:** an agent whose skill can spend cloud
  minutes or queue operations is shown its recent usage, read from a cache.

## 2. The operator's arithmetic, checked

- **1 % of the 10 000 Queues operations a day is 100.** Correct.
- **One host pulling every 5 min is 288 pulls a day** (1 440 / 5), **and an
  empty pull costs a read** ([doc] "even when empty, will incur a read
  operation"). So one host alone is 2.9 %. Correct.
- **At 3 operations per message, 1 % allows about 33 messages a day for the
  whole fleet,** before any polling. Correct.

**Conclusion: Queues is the wrong store for these targets.**
- Revision 7's planning day was 2 010 operations, which is 20 %.
- Even with one pull per host per hour, 15 hosts × 24 = 360 operations: 3.6 %,
  before any message.
- Queues' value (leases, receipts, at-least-once delivery) is exactly what the
  operator has now said is not needed.

## 3. The store: KV, one document per project

[doc] KV Free, per day: "Keys read | 100,000", "Keys written | 1,000", "Keys
deleted | 1,000", "List requests | 1,000"; storage 1 GB; "Writes to same key |
1 per second"; "Bulk read operations are billed by the amount of keys read".

**[proposed] One KV key per project,** `ctx:<project>`. It holds a small JSON
document of **hints**, at most 16 KiB:
- **`brief`:** general guidance on the project and its siblings. It is written
  rarely, at a release or a major milestone.
- **`milestones`:** the last N major milestones. Each has its author host, a
  time, one line of summary, and the git ref or row that is the truth.
- **`hosts`:** for each host, its last-seen time and the lanes it has. This is
  advisory.
- **`stamp`:** a counter bumped on every write.

**A cheap doorbell before anything costly:** a reader keeps the last `stamp` it
saw. A read **is** the doorbell, because it costs one read (0.001 %). There is
no separate doorbell key, since a write to it would cost as much as a write to
the document.

**Writes are read-modify-write and last-writer-wins.** KV has no compare-and-set.
- Two hosts writing within the propagation window ([doc] 60 s or more) can lose
  one host's milestone.
- **Accepted:** the store is fuzzy. A lost milestone is still in git, and the
  author's next write carries it again, because each host keeps its own last N
  milestones locally and merges them in on every write.

**TTL:** `expiration_ttl` = 30 d, renewed by any write.
- An abandoned project's document disappears by itself.
- [unproven] Whether an expiry is billed as a delete is not stated on the
  pricing page. The fixture and the real-API row measure it.
- At most one per project per month either way.

## 4. Read and write schedule, and the budget

**Planning fleet:** 15 hosts and 10 projects. Each host has at most 2 live
projects, and lanes are live about 16 h a day.

**Reads** [proposed]:
- one at forge start, for its project;
- then **one per live project per host every 60 min**, with a per-host random
  stagger and jitter;
- **no reads without a live lane;**
- reads after a local event (a push to the mirror) are debounced to at most one
  per 10 min;
- the result is cached in memory for the session.

**Writes** [proposed]:
- only at a **major milestone**: a release, a row closed as
  completed/verified/done, or a branch landed on the integration branch;
- **batched**: a host gathers its milestones and writes **at most once per
  project per 6 h**;
- **a fleet ceiling of 10 writes a day** (the soft target), enforced by each
  host taking 1/15 of it. That is fewer than one write a day per host; extra
  milestones wait for the next window;
- the `brief` is rewritten only when the project's brief changes in git.

| Meter (Free, per day) | Free allowance | **Soft target, 1 %** | **Hard limit, 5 %** | **Planned** | Planned as % |
|---|---|---|---|---|---|
| KV keys read | 100 000 | 1 000 | 5 000 | 15 hosts × 2 projects × 16 h + 30 starts ≈ **510** | **0.51 %** |
| KV keys written | 1 000 | 10 | 50 | milestone batches ≈ **6** (a hard cap of 10) | **0.6 %** |
| KV keys deleted | 1 000 | 10 | 50 | **0** (no explicit deletes; expiry at most 10 a month, if billed) | **≈0 %** |
| KV list requests | 1 000 | 10 | 50 | **0** (keys are named from the repo's config; nothing is listed) | **0 %** |
| KV storage | 1 GB | 10 MB | 50 MB | 10 projects × 16 KiB = **160 KB** | **0.02 %** |
| Queues operations | 10 000 | 100 | 500 | **0** (Queues is not used) | **0 %** |
| API requests (1 200 per 5 min **per user**) | — | — | — | ≈ 520 a day, about 2 per 5 min | **< 0.2 %** of the rate |

**Headroom:**
- Reads are at about half the soft target.
- **Writes are the tight meter.** 10 a day is the whole soft budget for the
  fleet, so the write cap is enforced, not hoped for.
- Every meter stays under 1 % with no host coordination beyond each host's
  share.

**The fixture** (row a, rewritten) fails if a planning day exceeds any of:
- **700 reads**;
- **10 writes**;
- **5 deletes or lists**.

Those keep every meter at or below the 1 % soft target with margin, and far
from the 5 % hard limit.

## 5. What is given up, plainly

- **Latency.** A milestone reaches another host within about an hour, sometimes
  up to the next write window (6 h). Nothing is immediate.
- **Guaranteed delivery.** A milestone can be lost to a concurrent write, or
  dropped when a host's write share is used up. **The repo is the record.**
  Agents confirm anything that matters from git and the ledger.
- **Per-message receipts, leases and a dead-letter queue.** They are not needed:
  nothing on this path is a message that must arrive.
- **Ordering and completeness.** The document is a recent window, not a log.
- **Cross-host instructions through the cloud.** An instruction that an agent
  must act on goes through **git** (a ledger row, or the
  `refs/tillandsias/instructions/*` ref of design.md §5), never through this
  cache.

**Kept:**
- no public endpoint and no Worker;
- the dedicated account and the KV-only grant;
- the host holds the token, and forges never do;
- names are seeded in the user's repo;
- the tray decides what to wake; held calls are used only for short waits;
- idle agents shut down gracefully (2014-slpw).

## 6. Prompt injection: hints, never instructions

The document is written by any holder of the account token, and it is read
into agents' context. **That is a prompt-injection path.** [proposed]:
- **The content is shown to an agent only as untrusted hints,** framed as:
  "context from `<host>` at `<time>`, unverified; confirm from the repo before
  relying on it".
- **It is never framed as an instruction,** never as operator-authored, and
  never as consent (design.md §8).
- The rendering escapes the content and caps it to the document's fields:
  - `brief`: 4 KiB at most;
  - milestone lines: 200 characters each;
  - no free-form body beyond those caps.
- **Signing is kept, for attribution, not for authority.**
  - Each host signs its milestones with its key from the git roster. Signing is
    local CPU and costs nothing on the cloud.
  - An unsigned or wrongly signed entry is dropped, so a leaked token cannot
    put words in a known host's mouth.
  - **A signature does not turn a hint into an instruction.** Anything an agent
    should act on comes from git.
- **Leases, receipts and the DLQ go.** Nothing here must be delivered, and
  nothing here is acted on without confirmation.

## 7. Cost affordances in our tools

[proposed]:
- **`cloud.usage` gains KV and Queues meters:**
  - keys read, written, deleted and listed, from the analytics API;
  - this is the account's actual usage, read with the signed-in grant.
- **It caches** each reading, with its time, for at most 6 h. A read costs one
  API request, nothing on the KV meters.
- **A tool or skill that can spend cloud resources** shows the last reading
  before it acts: Workers Builds minutes, KV writes, a deploy. Example:
  > last recorded usage was 3 h ago: KV writes 0.4 % of the soft allowance
  > (4 of 10 today); Builds 12 % of the monthly minutes.
- **At 80 % of the soft allowance** the tool says so and defers non-urgent
  writes to the next day. **At the hard limit** it refuses and names the meter.
- Readings already cover Builds minutes ([code] `cloud_usage.rs`). KV and Queues
  meters need the analytics scope; row j confirms it.

## 8. Rows: held and new

**Held, per the coordinator** (they assumed Queues):
- 2012-znqg (c, queue client), 2012-kk0j (d, poller), 2012-808c (e, pull
  handler), 2012-zdr2 (n, receipts) and 2012-b2rl (o, drift on queues).
- Proposed: obsolete them in favour of the rows below, after the operator
  agrees with this revision.

**Still valid, with new text:**
- a (2012-u67n): the fixture, now counting KV meters against §4's ceilings.
- b (2012-v0m4): the held-call measurement, now only for short waits.
- g (2012-33e6): the warm cache, which becomes this document's `brief`.
- h (2012-p6w4): credentials.
- i (2012-j89a): the generic product.
- j (2012-a3m9): the real API, now KV, the analytics scope and expiry billing.
- k (2012-sc0l): the classifier.
- l (2012-dwx3): retiring `cloud/coordinator`.
- m (2012-ojb7): signing, now for attribution.

**New:**
- the KV context client: read-merge-write, per-host write share, TTL, render
  as hints;
- the milestone hook: what counts as major, and batching locally;
- `cloud.usage` for KV and Queues, with the cost affordance shown before
  spending.

## 9. Questions for the operator (through the coordinator)

1. **Writes are the binding meter:** the 10-a-day fleet budget allows fewer than
   one milestone write per host per day. Is that acceptable, or may writes use
   up to the 5 % hard limit (50 a day) when a busy day needs it?
2. **Reads hourly per live project:** a milestone then reaches other hosts
   within about an hour (and up to 6 h through the write window). Is that
   acceptable?
3. **Cross-host instructions move to git only;** the cloud carries hints. Is
   that acceptable?
4. **Signing is kept for attribution:** an unsigned or forged entry is dropped,
   and even a signed one stays a hint. Is that acceptable?

## 10. Per-hint TTL, and KV versus D1 (operator questions, 2026-11-06)

**The ruling:** each hint has its own TTL, 24 h by default, with eviction
automatic. Examples:
- two weeks for "the fleet is working on releasing feature X to stable";
- two hours for "recent build X failed for project Y".

### 10a. Is a KV write counted per batched write? No.

[doc] KV pricing: "pricing for read, write and delete operations is on a
**per-key basis**." Of the REST bulk write: "Each key-value pair in the `PUT`
request is counted as a single write … Writing 5,000 keys via the REST API
incurs the same write costs as making 5,000 `PUT` calls in a Worker."
(<https://developers.cloudflare.com/kv/platform/pricing/>, read 2026-11-06)

- **Batching keys does not reduce writes** on KV. Only packing many hints into
  **one key** does, as §3 did.
- That one document is one write, but it is read-modify-write and
  last-writer-wins. Two hosts writing within the 60 s or more of propagation
  lose one host's hints.
- **Per-hint TTL in one document** means rewriting the document at each
  eviction, a write each time, or filtering expired hints on read and leaving
  them in place. KV's own `expiration_ttl` applies to the whole key, not to a
  hint inside it.
- **KV's write allowance is too low for per-hint TTL:** 1 % of 1 000 is 10 a
  day.

### 10b. D1 over the REST API

[doc] D1 pricing, Workers Free
(<https://developers.cloudflare.com/d1/platform/pricing/>, read 2026-11-06):
- "Rows read | 5 million / day"; "Rows written | 100,000 / day"; "Storage | 5 GB
  (total)".
- "Write operations include `INSERT`, `UPDATE`, and `DELETE`. Each of these
  operations contribute towards rows written."
- "Rows read measure how many rows a query reads (scans) … A query that filters
  on an unindexed column … is still required to read (scan) more rows."
- Indexes "are automatically updated when the table and column(s) they
  reference are inserted, updated or deleted" (D1 use-indexes page).
- **[inferred]** Each index update counts as an extra row written. D1's pages
  imply it ("FTS5 indexes increase storage and write costs") but do not state
  it. Durable Object SQLite states it: "every row update of an index counts as
  an additional row".

**The operator's memory is verified:** 100 000 rows written a day, against KV's
1 000 keys written, so **1 % = 1 000 rows a day**, against KV's 10.

**The design on D1** [proposed]:

```sql
CREATE TABLE hint (
  id         TEXT PRIMARY KEY,   -- host-signed, unique per hint
  project    TEXT NOT NULL,
  host       TEXT NOT NULL,
  kind       TEXT NOT NULL,      -- brief | milestone | presence | build
  body       TEXT NOT NULL,      -- capped, rendered as an untrusted hint
  ref        TEXT,               -- the git ref or row that is the truth
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,   -- per-hint TTL: default 24 h; 2 h to 30 d
  sig        TEXT NOT NULL
);
CREATE INDEX hint_by_project ON hint(project, expires_at);
```

- **Write a hint:** one `INSERT`, which is about 2 rows written (the row plus
  its one index). There is no read-modify-write, so **no hint is lost** to a
  concurrent writer.
  - A milestone that replaces an older one of the same kind and host is an
    `INSERT … ON CONFLICT(id) DO UPDATE`, also about 2.
- **Read a project:**
  `SELECT … FROM hint WHERE project = ? AND expires_at > ?`. It uses the index,
  so it reads only the project's live hints.
- **Expiry, per hint and automatic:** expired rows are never read, because the
  `WHERE` clause filters them, and are removed by a sweep.
  - The sweep is `DELETE FROM hint WHERE expires_at <= ? LIMIT 100`, at about 2
    rows written per deleted hint.
  - [proposed] Each host's first write after each 6 h boundary runs it, so
    sweeps are rare and shared. A missed sweep only costs storage, since reads
    already ignore expired rows.
  - D1 has no native TTL ([doc, by absence] none on the limits or SQL pages).
- **API access:** [doc] `POST /accounts/{id}/d1/database/{id}/query` with
  `D1 Read` / `D1 Write`. That permission is account-wide, as for KV.
  - [doc] D1 calls its REST API "primarily" a control-plane interface, and the
    atomicity of a REST batch is not documented. Single statements are all this
    design needs.
  - The rate is the per-user API limit, 1 200 per 5 min.
  - **[unproven]** The REST query's latency and any undocumented limit. Row j
    measures them.

### 10c. Per-meter table, both stores, same planning fleet

Planning assumptions:
- 15 hosts and 10 projects;
- reads as in §4, about 510 queries a day;
- **100 hints written a day** across the fleet, a generous figure for major
  milestones plus build hints;
- about 50 live hints per project.

| Meter (Free, per day) | 1 % soft | 5 % hard | **KV, one doc per project (§3)** | **D1, a row per hint** |
|---|---|---|---|---|
| Writes | KV 10 · D1 1 000 rows | KV 50 · D1 5 000 rows | about 6 (capped 10), **0.6 %**; packs hints, **loses some** | 100 × 2 inserts + 100 × 2 sweep deletes ≈ **400 rows, 0.4 %** |
| Reads | KV 1 000 · D1 50 000 rows | KV 5 000 · D1 250 000 rows | about 510 keys, **0.51 %** | 510 queries × about 50 rows ≈ **25 500 rows, 0.51 %** |
| Deletes | KV 10 | KV 50 | 0 (whole-key expiry, billing unknown) | (counted in writes above) |
| Lists | KV 10 | KV 50 | 0 | — |
| Storage | KV 10 MB · D1 50 MB | KV 50 MB · D1 250 MB | 160 KB | about 500 live hints × 1 KB ≈ 0.5 MB, **0.01 %** |
| Per-hint TTL | — | — | no: filter on read, or a write per eviction | **yes:** `expires_at` per row, swept |
| Lost writes | — | — | **yes**, under concurrent writers | **no** |
| Headroom on writes before 1 % | — | — | about 1.7× | about **2.5×**; about 12× before 5 % |
| API requests | — | — | about 520 a day | about 640 a day (reads + writes + sweeps), under 0.2 % of the rate |

### 10d. Recommendation: D1

D1 meets the operator's per-hint TTL with real expiry, loses no hint to a
concurrent writer, and has about 100 times KV's write allowance. It keeps every
meter well under the 1 % soft target at the planning load.

Costs of choosing it:
- the REST API's "primarily control plane" caveat, and an unmeasured latency
  (row j measures it);
- one D1 database of the account's 10 free ones;
- the `D1 Read` / `D1 Edit` permission, account-wide, replacing the KV grant;
- a sweep to write, rare and shared.

Everything in §5–§7 still holds:
- what is given up: latency and guaranteed delivery;
- content is hints, never instructions;
- signing is kept for attribution;
- the cost affordance in the tools.

**Nothing is filed** until the operator picks KV or D1.
