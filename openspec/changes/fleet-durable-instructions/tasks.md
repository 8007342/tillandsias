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

## 2011-amqd: free-tier queue (free-tier-queue.md §12, revision 5)

- [ ] a. Fixture first: fake Queues and KV REST; empty pull costs a read, late ack, lost ack, expired, poison; budgets
- [ ] b. Measure the wake path in Claude Code and OpenCode
- [ ] c. Queue client: ttl/sent_at refusal, 48 KB cap, batch 1, verified ack, budgets in ops and requests
- [ ] d. Host poller: 5 to 60 min, hourly DLQ
- [ ] e. Inbox handler: outcome table, dedupe window, quarantine
- [ ] f. Wake: deterministic plus the path b proved
- [ ] g. Warm plan cache
- [ ] h. Credentials: forge env-refusal litmus first, Vault host proxy, remove env path
- [ ] i. Generic: [fleet] seeding, create with consent, relay as config, bring your own
- [ ] j. Real API (operator): scope ids, attempts on lease expiry, max_retries 100 + DLQ by GET, refusals
- [ ] k. Optional local classifier, measured
- [ ] l. Retire cloud/coordinator after j
- [ ] m. Signing: per-host keys, roster, verify before inbox
- [ ] n. Receipts and outbox, undelivered at 24 h
- [ ] o. Drift check and revoke-and-rotate runbook
