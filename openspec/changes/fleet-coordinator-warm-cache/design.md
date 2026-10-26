# Design — fleet-coordinator-warm-cache

The operator approved these decisions on 2026-10-23. Every child packet must follow them.

## 1. Trust: personal fleet only

- **Access in front.** Cloudflare Access protects `coordinator.tillandsias.org` on the operator's account.
  - People sign in with an Access login (app or device).
  - Hosts and forges use Access **service tokens**: `CF-Access-Client-Id` and `CF-Access-Client-Secret`.
- **Tokens live client-side.** `--cloudflare-login` creates the tokens (1829-guit), and they are kept only in the vault. They are never written to disk in plaintext.
- **The Worker re-checks every request.** It verifies the `Cf-Access-Jwt-Assertion` JWT against the team domain's public certificates (`/cdn-cgi/access/certs`) and checks that `aud` matches the Access application's AUD tag.
- **No secrets on Cloudflare.** The team domain and AUD tag are plain Worker vars. Nothing secret is stored on Cloudflare.

## 2. Compute: store and return

One Worker routes requests to one SQLite-backed Durable Object. Every request is O(1) work in that object:

- no folding;
- no AI;
- no outbound fetch except the Access certificates (cached).

Storage stays bounded because Durable Object alarms sweep out anything past its TTL.

## 3. Git is the truth; the coordinator is a warm cache

```
forge (creates queue) ──overview put (client-folded)──►
mirror post-receive   ──{ns, head_sha, staleness++ [, overview]}──►  coordinator (DO)
client read           ◄──{overview, synced_sha, synced_at, age_s, might_be_outdated}──
```

How the cache is filled:

- **No server-side folding.** The forge that creates a project's queue pushes an overview it folded itself.
- **The mirror bumps freshness.** The git mirror's `post-receive` hook runs only after the upstream push to GitHub has succeeded. It sends the new head SHA, a staleness bump and, optionally, a refreshed overview. Its credentials come from the vault at hook time.
- **No GitHub webhook.**

`might_be_outdated` is true when either:

- the client's local head is ahead of `synced_sha`; or
- `age_s` is over a threshold (default 15 min).

## 4. Namespaces and queues

- **Keys.** A queue is keyed by the project namespace: the normalised `owner/repo` of the remote, or the directory name if the project has no remote.
- **Join creates.** Joining a namespace that does not exist creates it. The first subscriber creates it.
- **Shared across providers.** Agents from different providers share one queue, the way the logging engine groups by project.
- **Several subscriptions per agent.** An agent subscribes to its own project. It may also subscribe to:
  - declared related-project groups, for example `tillandsias` + `tillandsias.org` + `observatorium.tillandsias.org`, or `tlatoani.net/*`;
  - an opt-in global namespace.
- **No listing.** No endpoint lists or enumerates namespaces. Knowing a name is the only way in, and Access has already gated who gets that far.

## 5. Messages are best effort

Messages carry:

- the sender (Access subject or service-token client id);
- a provider label;
- a TTL: 6 h by default, 24 h at most. A larger value is clamped.

There are no read receipts. Nothing is guaranteed to be read within any time, or at all. The client must not reuse the receipt/ack vocabulary of the lane messaging in `msg_store.rs`.

## 6. Calling discipline

There is no fixed polling. Calls happen on demand:

- at forge start;
- after a push;
- when an agent is idle and looking for work.

A heartbeat runs alongside, under these rules:

- **Interval.** Self-measured, never more than 120 s.
- **Busy backoff.** It backs off (doubles) while the host is busy.
- **Suspended work.** It pauses while a build.sh gate or an agent turn holds the lane marker.

Load is limited in three ways:

- **Client rate limit.** Refuses locally, before any network call.
- **Server rate limit.** Answers 429.
- **Batch endpoint.** One client turn sends one request.

When the coordinator is unreachable or rate-limited, the client answers from the local git fold and labels the answer `source: git-ledger`.

## 7. Claim overlay

- **Short-lived.** A claim overlay has a short TTL (default 10 min).
- **Fast.** Within seconds it hides a ready row from `coord next` on every client.
- **Not authoritative.** It does not change status. The real claim still flips status in git through the normal claim event.
- **Self-cleaning.** An expired overlay disappears, and nothing needs cleaning up.

## 8. Layout and tests

- **Code.** `cloud/coordinator/`, in TypeScript, with `wrangler.toml` (Durable Object binding and migration only: no routes, no custom domain, no secrets).
- **Tests.** Run under `@cloudflare/vitest-pool-workers` or miniflare, locally. No agent deploys.
- **Deploy.** Its own packet (1830-hzsc). It needs the operator's explicit go.

## 9. Free-tier fit

- Requests are small JSON payloads, and each one touches only the Durable Object.
- Expected volume is a few hosts × on-demand calls plus a heartbeat of at most 2 min. That is far below the free-tier request and Durable Object duration limits.
- The batch endpoint and busy backoff are the levers if usage grows.
