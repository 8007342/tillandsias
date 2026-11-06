---
tags: [cloudflare, workers, durable-objects, d1, kv, queues, free-tier, limits, access]
languages: [json]
since: 2026-11-06
last_verified: 2026-11-06
sources:
  - https://developers.cloudflare.com/workers/platform/limits/
  - https://developers.cloudflare.com/durable-objects/platform/pricing/
  - https://developers.cloudflare.com/durable-objects/platform/limits/
  - https://developers.cloudflare.com/d1/platform/limits/
  - https://developers.cloudflare.com/d1/platform/pricing/
  - https://developers.cloudflare.com/kv/platform/pricing/
  - https://developers.cloudflare.com/kv/platform/limits/
  - https://developers.cloudflare.com/kv/concepts/how-kv-works/
  - https://developers.cloudflare.com/kv/api/write-key-value-pairs/
  - https://developers.cloudflare.com/queues/platform/pricing/
  - https://developers.cloudflare.com/queues/platform/limits/
  - https://developers.cloudflare.com/queues/configuration/batching-retries/
  - https://developers.cloudflare.com/workers/configuration/routing/workers-dev/
  - https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/
  - https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/
  - https://developers.cloudflare.com/cloudflare-one/account-limits/
  - https://developers.cloudflare.com/cloudflare-one/setup/
  - https://developers.cloudflare.com/workers/local-development/
  - https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
  - https://developers.cloudflare.com/waf/rate-limiting-rules/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Cloudflare Workers Free plan: storage, queue and access limits

@trace spec:agent-cheatsheets, order:2011-amqd

Use this cheatsheet when choosing where a Worker on the **Free** plan keeps state
(Durable Objects with SQLite, D1, KV, Queues), how much it may do per day, and what
happens at each limit. Every number below was read from the official page on
2026-11-06 (pages dated 2026-10-29 to 2026-10-30). Re-read before relying on a number:
plans change.

## Provenance

Read 2026-11-06 by an agent with `curl` from the `/index.md` form of each page:

- Workers limits: <https://developers.cloudflare.com/workers/platform/limits/>
- Durable Objects pricing and limits: <https://developers.cloudflare.com/durable-objects/platform/pricing/>, <https://developers.cloudflare.com/durable-objects/platform/limits/>
- D1 limits and pricing: <https://developers.cloudflare.com/d1/platform/limits/>, <https://developers.cloudflare.com/d1/platform/pricing/>
- KV pricing, limits, consistency, TTL: <https://developers.cloudflare.com/kv/platform/pricing/>, <https://developers.cloudflare.com/kv/platform/limits/>, <https://developers.cloudflare.com/kv/concepts/how-kv-works/>, <https://developers.cloudflare.com/kv/api/write-key-value-pairs/>
- Queues pricing, limits, retries: <https://developers.cloudflare.com/queues/platform/pricing/>, <https://developers.cloudflare.com/queues/platform/limits/>, <https://developers.cloudflare.com/queues/configuration/batching-retries/>
- workers.dev routing and Access: <https://developers.cloudflare.com/workers/configuration/routing/workers-dev/>, <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/>, <https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/>, <https://developers.cloudflare.com/cloudflare-one/account-limits/>, <https://developers.cloudflare.com/cloudflare-one/setup/>
- Local development: <https://developers.cloudflare.com/workers/local-development/>
- Rate limiting: <https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/>, <https://developers.cloudflare.com/waf/rate-limiting-rules/>

## Quick reference (Free plan, per account, per day unless noted)

| Service | Limit | Quote |
|---|---|---|
| Workers | 100,000 requests/day, reset 00:00 UTC; over it, **Error 1027** | "daily request limit of 100,000 requests, resetting at midnight UTC" |
| Workers | 10 ms CPU per request; over it, Error 1102 | "CPU time per HTTP request – 10 ms" |
| Workers | 50 subrequests per invocation (1,000 to internal services) | "Subrequests per invocation – 50" |
| Durable Objects | SQLite backend only on Free | "Only Durable Objects with SQLite storage backend are available." |
| Durable Objects | 100,000 requests/day, alarms included | "Includes HTTP requests, RPC sessions, WebSocket messages, and alarm invocations" |
| Durable Objects | 13,000 GB-s/day duration | "Duration – 13,000 GB-s / day" |
| Durable Objects | 5M rows read, **100,000 rows written**/day; deletes and each `setAlarm()` count as writes | "Each setAlarm() is billed as a single row written." |
| Durable Objects | 5 GB per account, 10 GB per object, 100 classes | "Storage per account – … 5GB (Free)" |
| D1 | 10 databases × 500 MB, 5 GB per account | "Maximum database size – … 500 MB (Free)" |
| D1 | 5M rows read, 100,000 rows written/day; 50 queries per invocation (a batch is one) | "Queries per Worker invocation – … 50 (Free)" |
| KV | 100,000 reads, **1,000 writes**, 1,000 deletes, 1,000 lists/day | "Keys written – 1,000 / day" |
| KV | eventual: changes may take 60 s or more to propagate; minimum TTL 60 s | "Changes may take up to 60 seconds or more to be visible" |
| Queues | available on Free: 10,000 operations/day; about 3 per delivered message | "it takes 3 operations to deliver a message: 1 write, 1 read, and 1 delete" |
| Queues | retention fixed at 24 h on Free; message max 128 KB; 3 retries then fail (DLQ optional) | "Message retention – 24 hours (non-configurable)" |

## What happens at each limit

- **Workers requests:** Cloudflare answers with its own **Error 1027** page. On a route
  the Worker can be set to fail open (bypassed) or fail closed (the 1027 page). The page
  states **no Retry-After header and no HTTP status**. A client must treat any non-JSON
  or 1027 answer as "out of budget until 00:00 UTC".
- **Durable Objects, D1, KV:** "further operations of that type will fail with an error"
  until 00:00 UTC. The exact error type is not documented on these pages.
- **D1 storage:** new inserts are blocked once a database reaches 500 MB.

## Choosing for a durable message store on Free

- **Durable Objects with SQLite:** one object per queue gives strongly consistent,
  ordered reads and writes, with alarms for TTL sweeps. The tight limit is **100k rows
  written/day**. Every enqueue, ack (a delete or update) and `setAlarm()` is at least one
  row written, so budget about 3 writes per message. Schedule one alarm per sweep, not
  one per message.
- **D1:** the same daily row limits. It is better for cross-queue queries. Every call
  goes Worker to D1, so add the 50-queries-per-invocation cap. It has no alarms of its
  own; use a Cron Trigger, which counts as a Worker request.
- **KV:** at 1,000 writes/day and 60 s or more eventual consistency, it **cannot** be a
  queue store. It is fine for a rarely changing config value.
- **Queues:** about 3,300 messages/day and 24 h retention. It is push-to-consumer with
  retry semantics, not a pull mailbox an agent reads at will. It fits a fan-out pipe, not
  "durable instructions an agent reads when it wakes".

## Access control on Free

- Disable the public URL with `"workers_dev": false`. **Version, Preview and Deployment
  URLs stay enabled.** Protect them with Access or a code check.
- Cloudflare Access can protect a Worker's workers.dev and preview URLs. The Worker
  verifies the `Cf-Access-Jwt-Assertion` JWT against
  `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`.
- Machine clients use service tokens (`CF-Access-Client-Id`, `CF-Access-Client-Secret`).
  The default limit is 50 service tokens.
- Zero Trust Free signup still asks for payment details ("you will not be charged").

## Local development

`wrangler dev` runs workerd/Miniflare locally with bindings simulated ("All resources …
are simulated locally"). KV, D1 and Durable Objects are named. That SQLite-backed DOs
specifically, and running with no login at all, are **implied, not stated**.

## Rate limiting

- The Workers Rate Limiting binding uses periods of 10 or 60 s, approximate and per
  location. The 429 in its examples is returned by **your** code.
- WAF rate limiting rules on Free count by IP only.

## REST access without a Worker (read 2026-11-06)

- **No REST endpoint invokes a Worker or calls a Durable Object:** not found on
  an official page. A Worker with no route runs only from its handlers (fetch,
  scheduled, queue, email, tail, alarm, connect),
  <https://developers.cloudflare.com/workers/runtime-apis/handlers/>.
- **Queues HTTP pull consumer**
  (<https://developers.cloudflare.com/queues/configuration/pull-consumers/>):
  - `POST /accounts/{id}/queues/{queue_id}/messages/pull` with
    `visibility_timeout_ms` and `batch_size`: "`visibility_timeout` (defaults to
    30 second; max 12 hours)", "`batch_size` (defaults to 5; max 100)".
  - `POST …/messages/ack` takes "an array of `lease_id` objects to acknowledge
    and/or retry". "A `lease_id` is no longer valid once this timeout has been
    reached."
  - It is short polling: "Queues does not hold an open connection".
  - It needs `queues#read` and `queues#write`: "A consumer must be able to
    write to a queue to acknowledge messages."
- **Queues push over REST:** `POST /accounts/{account_id}/queues/{queue_id}/messages`
  "Pushes a message to a Queue". Accepted permissions are "`Queues Write`
  `Workers Scripts Write`" (API reference). One older page still says "To send
  and receive messages, you must use a Worker"; the endpoints above contradict
  it.
- **KV over REST:** `PUT …/storage/kv/namespaces/{id}/values/{key}` takes
  `expiration_ttl` ("Must be at least 60"). REST writes count against the
  Free plan: "Writing 5,000 keys via the REST API incurs the same write costs
  as making 5,000 `PUT` calls in a Worker" (KV pricing).
- **D1 over REST:** `POST /accounts/{id}/d1/database/{id}/query`. Multiple
  statements "will be executed as a batch". D1's own guidance says the "REST
  API primarily interacts with the control plane". Whether a REST batch is
  atomic is not stated.
- **API rate limit**
  (<https://developers.cloudflare.com/fundamentals/api/reference/limits/>):
  - "Client API per user/account token | 1200/5 minutes", applied
    "cumulatively regardless of whether the request is made via the
    dashboard, API key, or API token".
  - Over the limit, "all API calls for the next five minutes will be
    blocked, receiving a `HTTP 429`", with a `retry-after` header.
- **Permissions**
  (<https://developers.cloudflare.com/fundamentals/api/reference/permissions/>):
  - The names are "D1 Read/Edit", "Queues Read/Edit" and "Workers KV Storage
    Read/Edit".
  - They are account-scoped. No per-queue or per-namespace scoping is
    documented.
  - No list of OAuth scope names was found on an official page.
- **Workers AI on Free**
  (<https://developers.cloudflare.com/workers-ai/platform/pricing/>):
  - "10,000 Neurons per day at no charge".
  - `@cf/meta/llama-3.2-1b-instruct` costs "2457 neurons per M input tokens".

## Not found on an official page (open)

- How many Access seats Zero Trust Free includes.
- Which plan the Rate Limiting binding needs.
- Whether a daily-limit hit ever carries Retry-After or a real HTTP status.
- Whether the Durable Objects "30 s CPU per request" holds on Free, or the Workers 10 ms
  applies.
- The documented way and limits for a Worker to verify a Cloudflare API token.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):** the pages listed under Provenance above.
- **Archive type:** `single-html`
- **Expected size:** `~1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/developers.cloudflare.com/`
- **License:** see-license-allowlist
- **License URL:** https://developers.cloudflare.com/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
BASE="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/developers.cloudflare.com"
mkdir -p "$BASE"
for p in workers/platform/limits durable-objects/platform/pricing durable-objects/platform/limits \
         durable-objects/api/sqlite-storage-api d1/platform/limits d1/platform/pricing \
         kv/platform/pricing kv/platform/limits queues/platform/pricing queues/platform/limits \
         workers/configuration/routing/workers-dev workers/versions-and-deployments/version-urls; do
  mkdir -p "$BASE/$p"
  curl -fsSL "https://developers.cloudflare.com/$p/index.md" -o "$BASE/$p/index.md"
done
```

### Generation guidelines (after pull)

1. Re-read each pricing and limits page before quoting a number: Free-plan limits change, and this cheatsheet records them as of 2026-11-06.
2. Quotas are per account, so subtract every other Worker on the account before budgeting one.
3. Count rows written from the runtime (`cursor.rowsWritten`), not by hand: index updates, `AUTOINCREMENT` and `setAlarm()` all add rows.
