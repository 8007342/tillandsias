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
