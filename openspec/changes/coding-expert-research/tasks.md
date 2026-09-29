# Tasks — coding-expert-research

Research only. Each task's closure is its packet's `outcome:` token and
the record it writes.

## 1. Dynamic one-time MCP surface via Lua [1505-ga5f, opus]

- [ ] 1.1 A stdio MCP prototype (reusing `tillandsias-browser-mcp`
      `framing`) whose `tools/list` changes after every `tools/call` and
      emits `notifications/tools/list_changed`.
- [ ] 1.2 `coding_expert/mint.lua` under the sandbox: request → surface
      table with nonce, expiry, narrowed schema, affordances; ten fixture
      requests with expected surfaces.
- [ ] 1.3 Measure re-list behaviour on Claude Code, OpenCode and Codex;
      record `outcome:relist-honoured | relist-ignored-static-surface-needed
      | harness-specific` with versions.

## 2. RAG corpus: mirror + eager cheatsheets [1505-k4xs, sonnet]

- [ ] 2.1 Index the `code` domain from `/srv/git/<project>` at the mirror's
      integration HEAD; record the commit in the freshness frame.
- [ ] 2.2 Technology detection and eager cheatsheet loading through the
      license allowlist.
- [ ] 2.3 Measure on one fat and one floor host: index size, build time,
      20-question hit rate, post-commit refresh cost; read 1259-dgaq before
      proposing a delta rebuild. `outcome:eager-fits-floor |
      eager-exceeds-floor | delta-rebuild-viable | delta-rebuild-unviable`.

## 3. Served locally and as a fleet expert [1505-w2kq, sonnet]

- [ ] 3.1 A `coding` domain on `run_grounded` behind the existing endpoint
      (prototype branch, not landed).
- [ ] 3.2 Token budget per call (surface + chunks) and mesh latency p50/p95
      between two joined hosts. `outcome:fleet-latency-acceptable |
      fleet-latency-unacceptable | local-only`.

## 4. Security model [1505-pv3s, opus]

- [ ] 4.1 Threat table (replay, widening, path escape, unsolicited signing,
      cross-project impersonation, chunk injection) with one test per row.
- [ ] 4.2 Decision: HMAC-keyed nonce (key in Vault) or memory-resident
      random; recorded with its reasoning. `outcome:hmac-keyed |
      memory-random`.

## 5. Milestone close [1505-33dh]

- [ ] 5.1 The four outcomes recorded; the implementation change proposed
      with exit criteria that fail on today's tree; this change archived as
      research.
