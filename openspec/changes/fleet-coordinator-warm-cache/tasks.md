# Tasks — fleet-coordinator-warm-cache

Packet orders are in brackets. The milestone is `fleet-coordinator-warm-cache-milestone` [1824-58bm]. Each task closes on the fixture named in its packet; write the fixture first and show it failing on today's code.

## 1. Server (no deploy)

- [ ] 1.1 HTTP contract, Durable Object schema, Access JWT verification, queues, overviews, claim overlays, TTL sweeps, rate limit and batch endpoint in `cloud/coordinator/`, all with local vitest/miniflare tests [1825-v37w]

## 2. Credentials

- [ ] 2.1 `--cloudflare-login` creates or reuses the Access service token `tillandsias-<host>` and stores it only in the vault [1829-guit]

## 3. Client

- [ ] 3.1 `tillandsias-plan coord` verbs and an MCP tool, with:
  - client rate limit
  - adaptive heartbeat of at most 2 min, with busy backoff, suspended during gates and agent turns
  - request batching
  - a git-ledger fallback labelled `source: git-ledger`

  [1826-gi8e]

## 4. Keeping it warm

- [ ] 4.1 Mirror post-receive sends the head SHA, a staleness bump and an optional overview after the upstream push succeeds. The push never fails because of it [1827-3rj4]
- [ ] 4.2 Forge start joins the queue, pushes the initial overview if it created the queue, and asks what's next. It does not block on the network [1828-fz7r]

## 5. Deploy (needs the operator's approval)

- [ ] 5.1 Deploy to `coordinator.tillandsias.org` and set up the Access application and policies (operator action) [1830-hzsc]
- [ ] 5.2 Live arm on 1824-58bm, run on two hosts:
  - message round-trip
  - overlay claim hides the row
  - post-push freshness under 60 s
  - an unauthenticated request is refused
