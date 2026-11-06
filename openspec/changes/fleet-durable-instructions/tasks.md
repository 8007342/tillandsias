# Tasks — fleet-durable-instructions

Nothing is filed until the operator answers the open questions in
`design.md`. Each task becomes one packet with a test that fails today.

## 1. Coordinator (extends 1825-v37w; deploy stays gated like 1830-hzsc)
- [ ] 1.1 Add `instruction` rows and ops `put`, `take`, `settle`, `release` to
      the Durable Object, with TTL bounds and lease expiry under the existing
      alarm. Add tests under the local Workers pool.
- [ ] 1.2 Add a resume-slot replace-on-put, returning the replaced id.
- [ ] 1.3 Add per-namespace bounds (200 open, 4 KiB bodies) and secret-shaped
      refusal on the server.
- [ ] 1.4 Add a forge-scoped capability: the host proxies forge calls,
      limited to the forge's project and sibling group.

## 2. Client and local transports (extends 1826-gi8e and 1506)
- [ ] 2.1 Add `tillandsias-plan instr put|take|settle|release` and MCP tools.
- [ ] 2.2 Add a lane-bus fallback: an `instruction` envelope in the lane
      Maildir, with lease and settle files.
- [ ] 2.3 Add a git-mirror fallback on `refs/tillandsias/instructions/<role>`,
      reconciled once the coordinator returns.

## 3. Forge
- [ ] 3.1 Every forge start takes the resume slot before the seed prompt, in
      every harness entrypoint.
- [ ] 3.2 Add the `forge.reload` MCP tool: resume write first, refuse on
      failure, then host restart over the control wire, rate-limited.

## 4. Spawn broker
- [ ] 4.1 Add a host-side `agent.spawn` broker with the operator-set limits
      (harness sign-in, model allowlist, project group, depth 1, concurrency,
      lifetime, git identity).
- [ ] 4.2 Add an out-of-band consent token for exceptions (tray or OS-verified
      approval), single-use, validated only by the broker.

## 5. Trust
- [ ] 5.1 Add harness framing for instructions (author and source), with a
      fixture showing that an instruction cannot approve a consent-gated action.

## 2011-amqd: free-tier queue (free-tier-queue.md §11, revision 4)

- [ ] a. Fixture first: fake Queues and KV REST counting every request type and queue operation; budgets; crash-loop host
- [ ] b. Measure the wake path: does a lane notification reach the model in Claude Code and OpenCode, idle and busy
- [ ] c. Queue client: push, pull (batch 1, lease), ack by lease_id, 429 / retry-after, per-host daily budget
- [ ] d. Host poller: per-host queues and -any, 2 to 60 min backoff, resets
- [ ] e. Queue to lane inbox: ack after fsync; dedupe by id
- [ ] f. Wake: deterministic routing plus the path b proved
- [ ] g. Warm plan cache: single writer, KV throttle, freshness
- [ ] h. Credentials: forge env-refusal litmus first, then Vault host proxy, then remove env path
- [ ] i. Generic: [fleet] seeding, create with consent, relay URL as config, bring-your-own client or token
- [ ] j. Real API: scope ids from GET /oauth/scopes, empty-pull cost, refusals, attempts (operator)
- [ ] k. Optional local classifier, measured on a low-end host
- [ ] l. Retire cloud/coordinator after j
