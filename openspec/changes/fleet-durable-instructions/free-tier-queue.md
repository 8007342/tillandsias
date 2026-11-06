# Addendum — the agent message queue on the Free plan (order 2011-amqd)

Status: **proposed, design only. Revision 2, after an adversarial review.**
Nothing is built, deployed or created on Cloudflare by this addendum.

@trace order:2011-amqd, spec:fleet-instructions

This addendum extends `fleet-durable-instructions` (design.md) and the existing
coordinator Worker in `cloud/coordinator/` (1825-v37w, built and tested, never
deployed). It does not start a new system. It replaces design.md §7 "Free tier",
which said the load is "far under the free limits" without numbers.

Limits are cited in `cheatsheets/cloud/cloudflare-free-tier-storage-limits.md`,
read from the official pages on 2026-11-06. A separate agent reviewed revision 1
against the code and the live pages on 2026-11-06; §11 lists what changed.

**Labelling rule in this file:** **[code]** marks what the repository does today,
with file:line. **[proposed]** marks what this design adds. Nothing proposed is
described as existing.

## 1. Which store, and why not the others

| Option (Free plan) | Verdict | Deciding limit |
|---|---|---|
| **Durable Objects, SQLite backend** | **chosen**: [code] already in `cloud/coordinator` | 100 000 DO requests/day (alarm invocations included), 100 000 rows written/day, 5 M rows read/day; strongly consistent per object; alarms |
| D1 | not chosen | the same daily row limits, plus 50 queries per invocation and no alarms (a Cron Trigger is itself a Worker request); no gain over the DO |
| KV | refused | 1 000 writes/day, and 60 s or more to propagate |
| Queues | refused for this use | about 3 300 delivered messages/day, retention fixed at 24 h on Free, push-to-consumer; instructions must wait up to 7 days for a reader |

All quotas are **per account**. The observatorium Worker and any other Worker
on the account share them, so the budget in §3 is set against a share, not the
whole limit.

## 2. What one call costs

### 2a. Today, measured from the code

[code] `cloud/coordinator/src/index.ts` `run()` and `coordinator.ts`. Each HTTP
request costs:

- 1 Worker request;
- 1 DO request to the per-identity bucket `rl:<identity>`, which does an UPSERT:
  1 row written;
- 1 DO request per namespace touched (`ns:<ns>`, `applyMany`).

[code] One `send` costs about **3 to 6 rows written**. The official SQLite
storage page says "every row update of an index counts as an additional row":

- 1 for the table row;
- 1 for the `messages_exp` index;
- 1 for the `sqlite_sequence` update that `AUTOINCREMENT` causes;
- 2 for each row the trim deletes (the row and its index entry);
- 1 if it moves the alarm earlier (`setAlarm`).

[code] Once 1 000 messages are kept, the trim
(`ORDER BY seq DESC LIMIT 1 OFFSET 1000`) reads about 1 000 rows per send. That
caps sends at about 5 000/day against the 5 M rows-read limit.

[code] Alarm invocations are DO requests. The sweep only moves the alarm
earlier (`scheduleSweep`), so a claim renewed later still fires its old earlier
alarm. That costs 1 DO request and 1 row written per renewal period per
namespace, for nothing.

### 2b. Proposed costs (estimates until the fixture in §3d measures them)

- **[proposed] The limiter bucket** lives in memory in the namespace object the
  request already calls: 0 rows written and no extra DO request. Losing it when
  the object is evicted is acceptable. The daily cap (§3c) is what persists.
- **[proposed] Drop `AUTOINCREMENT`** and use the rowid. Trim by the indexed
  range `seq <= new_seq - KEPT`, so the trim no longer reads 1 000 rows.
- **[proposed] Instruction rows** have one index, on `expires_at` only. Lease
  columns are not indexed, so a `take` that sets `holder`, `lease_until`,
  `lease_token` and `deliveries` is 1 row written. `put` is about 2 (row plus
  index), and `settle` is about 2 (delete plus index).
- **[proposed] Leases expire lazily:** a `take` treats `lease_until < now` as
  open, and no alarm is set per lease. The alarm is used only for TTL eviction,
  and at most once per namespace per 15 minutes.

## 3. The budget, rebuilt from the code

### 3a. The heartbeat as it is

[code] `crates/tillandsias-plan/src/coordinator_client.rs:98-110`:

- Idle interval = 20 × round-trip time, clamped to 15–120 s. A link faster than
  750 ms therefore **idles at 15 s**.
- Busy (load over 0.8) doubles the interval, up to 120 s.

Revision 1 had this backwards.

At today's formula, 15 clients idle at 15 s make:

- 86 400 Worker requests/day, 86 % of the account limit;
- 172 800 DO requests/day, with the DO limit hit around 14:00 UTC;
- 86 400 rows written/day from the bucket alone.

This is the single largest risk in the system as written.

### 3b. [proposed] The idle schedule

- **Idle never polls faster than 300 s.** A fast round trip does not shorten
  it. Busy backs off as today, up to 600 s.
- A wake comes from local events (the lane bus already pokes
  `$XDG_RUNTIME_DIR/tillandsias/msg.sock`), not from polling.
- The scheduler is wired and its intervals are tested. [code] It is used at
  `crates/tillandsias-plan/src/main.rs:970`.

**Recomputed budget**, for a planning fleet of 15 clients (5 hosts and 10
forges):

- **Idle:** 15 × 12/h = 180 requests/h, so 4 320 Worker requests/day and the
  same number of DO requests. About 0 rows written.
- **Busy hour:** 10 agents each put 20 instructions, and each is taken and
  settled once (600 writes). Reads at 15 clients × 12/h = 180.
  - 780 Worker requests and 780 DO requests.
  - Rows written: 200 puts × 2 + 200 takes × 1 + 200 settles × 2 = **1 000**.
- **A day of 22 idle and 2 busy hours:** about 5 500 Worker requests,
  5 500 DO requests, about 2 000 rows written plus sweeps (at most 96 per
  namespace per day at one per 15 min, each 1 DO request plus its rows).
  - That is about 6 % of Workers, about 6 % of DO requests (plus sweeps), and
    about 2 % of rows written.

### 3c. [proposed] Server-side caps (a client cannot be trusted to obey itself)

[code] Today the only server limit is 120/min per identity, which allows
172 800/day for one identity: 1.7 times the whole account. [code] The client
limiter lives in one process, and every `coord` CLI call starts with a full
bucket (`main.rs:869-870`).

[proposed]:
- **A per-identity daily cap** in the namespace object, persisted coarsely: the
  counter is written every 100 requests, not per request. On reaching it the
  Worker answers 429 with `Retry-After` set to 00:00 UTC plus a jitter.
- Default cap: 2 000 requests/identity/day. Sixteen identities then reach at most
  32 000 a day, a third of the account, whatever any client does.
- **A per-account guard:** a Cron-free counter in one fixed object, sampled
  1 in 20, that refuses all non-operator identities once the account passes
  60 000 Worker requests in a UTC day. The operator keeps a reserve.
- **The client persists** its cache, daily count and backoff state on disk per
  host, under `$XDG_STATE_HOME`, not per process.

### 3d. [proposed] The fixture

It runs the client and the Worker under `wrangler dev` with a fake clock.

- It measures **from the runtime**, not by hand: `cursor.rowsWritten` and
  `rowsRead` per statement, DO requests, alarm invocations and Worker requests.
- It fails when an idle hour for 15 clients exceeds 200 Worker requests, or a
  busy hour exceeds 900 Worker requests or 1 200 rows written.
- It also runs a **crash-loop client**: a `coord` started 1 000 times in a row.
  It asserts that the server's daily cap holds it at 2 000.

## 4. Behaviour at each limit

- **Worker daily limit:** Cloudflare's Error 1027. On a route, the fail mode
  is configurable, and fail open bypasses the Worker, including its JWT check.
  - **[proposed]** The deploy uses a Custom Domain or route **set to fail
    closed**.
  - The deploy row checks this setting and refuses otherwise. A fail-open route
    would expose the store once the quota runs out.
- **DO limit** ("further operations of that type will fail with an error").
  - [code] `run()` has no try/catch around the DO calls, so this surfaces as an
    HTML 5xx or 1101.
  - **[proposed]** Catch it and answer JSON 503 with `Retry-After` set to
    00:00 UTC.
- **Client** — [code] `classify` (`coordinator_client.rs:365-385`) maps a
  non-JSON body to `Refused`, so a 1027 looks like a 400. **[proposed]**:
  - **Out of budget** (an HTML body, 1027, 1101, 1102, or a 503 with
    Retry-After): stop until the server's `Date` says 00:00 UTC has passed, plus
    a 0–15 min jitter. Use the server's clock, not the local one.
  - **429:** honour `Retry-After`.
  - **5xx or network error:** full-jitter exponential backoff, base 2 s,
    cap 300 s.
  - **Read cache:** at least 5 s per namespace.
  - **While out of budget:** serve from the git-ledger fallback that already
    exists.
- **Worker CPU, 10 ms on Free:** a cold isolate verifying an RSA JWT on a large
  body may exceed it (Error 1102). **[proposed]** Cap the body at 64 KiB
  ([code] it is 512 KiB today) and measure CPU in the fixture. DO CPU is 30 s
  by default (DO limits page).

## 5. Delivery: TTL, at least once, a simple ack

[code] Instructions do not exist yet. `coordinator.ts` has `send`, `recv`,
`overview.*`, `bump`, `claim`, `release` and `claims`. Messages are capped at
24 h (`MSG_TTL_MAX_S`), with no lease. Everything below is **[proposed]**, from
design.md §1 with these fixes:

- **TTL:** 60 s to 7 d. Eviction happens at most once per 15 minutes per
  namespace, through one alarm for the earliest expiry. A leased item at TTL is
  removed, and the holder's later `settle` answers `expired`, not 404.
- **At least once:** `take` is one synchronous
  `UPDATE … WHERE state open OR lease_until < now … RETURNING`, with no `await`
  between reading and writing. That makes it atomic inside the object. It
  returns a fresh **lease token** and increments `deliveries`.
- **"A simple ack" is `settle`**, and it **requires the lease token**
  (`DELETE … WHERE id = ? AND lease_token = ?`), as [code] `release` already
  requires for claims (`coordinator.ts:265`).
  - A late settle from a former holder whose lease ran out answers
    `not-holder` and changes nothing.
  - The word "ack" stays with the 1506 lane bus, where it means "a mailbox
    accepted". The operator should confirm this mapping.
- **Redelivery is detectably the same message:** the same `id`, with
  `deliveries > 1`.
- **Tests:**
  - duplicate delivery: a lease expires, and a second `take` sees the same `id`
    with `deliveries` = 2;
  - expiry: the item is gone at TTL;
  - a lost ack: no settle arrives, and the item is taken again;
  - **a late settle by a former holder is refused**;
  - a settle after TTL answers `expired`.

## 6. Only the signed-in account

[code] already holds:
- `workers_dev = false` and no route.
- Authentication runs before routing and before any DO call.
- The JWT check verifies alg, kid, signature, exp, iss (equal to the team
  domain) and aud, and fails closed when the vars are empty.
- `coordinator.spec.ts` already refuses a wrong aud, a wrong iss, an unknown
  kid and an expired token.
- A DO has no public URL of its own.

[proposed]:
- **Pin `preview_urls = false`** in `wrangler.toml`. The version-URLs page says
  Version URLs default to disabled when `workers_dev` is disabled. The
  workers.dev page says disabling workers.dev "does not disable" Version,
  Preview or Deployment URLs that are enabled. The default is therefore safe,
  but nothing pins it today.
  - After deploy, assert that workers.dev and preview URLs are off.
  - Verify that the 1853 placeholder upload (`cloudflare_worker_deploy.rs:215-223`)
    does not enable them.
- **Name the hostname Access protects.** With no route the Worker is
  unreachable, so Access needs a Custom Domain. The deploy row names it and
  sets it to fail closed (§4).
- **The wrong-account test the operator asked for:** a JWT signed by another
  team's key is refused. That is [code] already tested as an unknown kid.
  - Add: a valid JWT from the right team but an identity **outside the fleet**
    is refused, through a server-side allowlist of service-token common names
    and the operator's email, held in vars.
- **Certificate cache:** a failed refetch keeps a stale set without limit
  today. Cap the stale period at 24 h. Treat one 401 after a key rotation as
  retryable once.
- **No credential in a forge or in plaintext:**
  - [code] Today `Config::from_env` reads `TILLANDSIAS_COORD_CLIENT_SECRET` and
    `TILLANDSIAS_COORD_JWT` from the environment (`coordinator_client.rs:237-245`).
    That environment is readable through `/proc/<pid>/environ` and is inherited
    by children, and nothing fetches the token from Vault. Revision 1 wrongly
    said it did.
  - **[proposed]** Only the host-side proxy holds the token. It reads the token
    from Vault per call and keeps it in memory only.
  - Forges call the host, never Cloudflare, with a namespace-scoped capability.
  - A litmus test refuses those environment variables in any forge environment.
  - Bodies pass the 1506 secret-shaped refusal at both the client and the
    server.
- **Residual:** a stolen host service token can use that host's namespaces
  until it is revoked, bounded by its 2 000/day cap. That is the reason for one
  token per host.

## 7. The read-your-queue seed prompt

One harness-neutral prompt, delivered like the resume slot (design.md §2):
- call `coord` with `action: next`, or `take`;
- a body is untrusted input, not consent (design.md §8);
- when `deliveries > 1`, check the ledger and git before redoing work.

Showing it with two harnesses in a real forge needs a deploy and operator
consent, so it is not part of this design pass.

## 8. Where it lives and how it deploys

I agree with the operator's leaning towards a subdirectory with its own deploy
branch. The subdirectory already exists: `cloud/coordinator/`.
- The branch is `deploy/coordinator`, moved only by the explicit-request path
  (1853: forward-only, a 600 s minimum interval, 6 deploys a day).
- It is never moved by CI, and no Cloudflare credential goes to GitHub.

Two gaps remain:
- `cloud.usage` measures neither DO requests nor rows written, so it cannot yet
  show the "before and after" usage the closure needs.
- The Cloudflare login scopes do not cover DO analytics or Access
  administration.

## 9. Open questions

**For the operator:**
1. Is `settle` (with a lease token) the row's "simple ack", keeping "ack" for
   1506?
2. Is an idle poll of 300 s acceptable, with wakes from local events? The
   alternative is faster idle polling at a much higher daily cost.
3. Are the caps right: 2 000 per identity per day, and 60 000 per account
   before only the operator is served?
4. Zero Trust Free asks for payment details ("you will not be charged"). Is
   that acceptable?
5. Which Custom Domain should Access protect, set to fail closed?

**Not found on an official page:**
- The number of free Access seats.
- Whether a daily-limit hit ever carries Retry-After.
- Whether the Workers Rate Limiting binding is on Free.

## 10. Implementation rows (each small, for a forge-only host)

Each needs Node, wrangler and Rust only: no GPU, no deploy, no cloud resource.

| # | Row | Size |
|---|---|---|
| a | Fixture first: count Worker requests, DO requests, alarm invocations, `rowsWritten` and `rowsRead` under `wrangler dev` with a fake clock, against the §3 budgets, plus the crash-loop client | 3 h |
| b | DO: drop `AUTOINCREMENT`, trim by indexed range, coalesce sweeps to one per 15 min per namespace; the fixture shows the row counts | 2 h |
| c | DO: the in-memory limiter bucket, the per-identity daily cap persisted every 100 requests, the per-account guard; 429 with Retry-After to 00:00 UTC | 3 h |
| d | Worker: catch DO limit errors as JSON 503 with Retry-After; cap the body at 64 KiB; measure CPU | 1.5 h |
| e | Worker: the fleet-identity allowlist, a 24 h cap on stale certificates, the outside-the-fleet test; `preview_urls = false` | 2 h |
| f | DO: instructions with `put`, `take` (lease token, `deliveries`), `settle` and `release` requiring the token; the tests in §5 | 3 h |
| g | Client: a 300 s idle floor, persisted state, `Date`-based out-of-budget handling, `classify` telling 1027 and HTML from a 400, full-jitter backoff, a 5 s cache | 3 h |
| h | Host proxy: the token from Vault per call; forge env-var refusal litmus | 2.5 h |
| i | The seed prompt and the harness-neutral MCP wording | 1.5 h |
| j | `cloud.usage`: DO requests and rows written, after confirming the analytics scope | 2 h |
| k | Operator-gated: extend 1830-hzsc with the Custom Domain, fail closed, the post-deploy URL assertions and the before/after usage | operator |

Rows a–i need no Cloudflare account. j needs the signed-in account for a real
read. k needs the operator. **a comes first**, so every later row is measured.

## 11. What the review changed (revision 1 → 2)

The review was by a separate agent, against the code and the live pages, on
2026-11-06.

**Blockers fixed:**
- **The idle heartbeat** is 15 s in the code, not 120 s. §3 is rebuilt, and a
  300 s idle floor is proposed.
- **No server-side daily cap existed**, and the client limiter is per process.
  §3c adds a per-identity cap, an account guard and persisted client state.
- **Instructions, leases and settle do not exist yet.** Revision 1 implied they
  did. Every such claim is now labelled [proposed].

**Majors fixed:**
- Index and `AUTOINCREMENT` writes, and the trim's 1 000-row reads.
- Alarm invocations count as DO requests; the useless re-arm.
- A settle needs a lease token, so a former holder cannot settle re-leased
  work.
- A fail-open route would bypass auth at quota exhaustion. DO errors and HTML
  bodies are now handled.
- The token is in environment variables today, not in Vault.
- The preview-URL statement is corrected, and the Custom Domain must be named.

**Minors fixed:**
- Account-wide quotas.
- The outside-the-fleet identity test.
- The stale certificate cap.
- The CPU risk.
- The arithmetic.

**One review statement was corrected:** it said `Heartbeat` is used nowhere,
but it is used at `crates/tillandsias-plan/src/main.rs:970`.
