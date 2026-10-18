# Design — forge-diagnostics-scope

## The scope model

A request's scope is computed from two host-held facts and nothing else:

1. **The lane**, `(project, instance)`, from the listener that accepted the
   MCP connection (`LaneIdentity`, order 505). The lane IS the forge: two
   forges of one project are two lanes, and neither sees the other.
2. **The lane label**, `tillandsias.lane=<project>/<instance>`, which the host
   sets when it creates a container for that lane.

| Source | In scope for lane L? |
|---|---|
| L's forge container | yes |
| a container whose host-set `tillandsias.lane` is L | yes |
| a container whose `tillandsias.lane` is another lane, even of the same project | **no** |
| another lane's forge container | **no** |
| a shared container (vault, proxy, router, git mirror, inference) | **no** raw logs; its curated `GlobalEvent`s only |
| a container with no lane label | **no** |

What can never widen scope: a caller-supplied forge id, tenant, project,
container name or label; a log line's content; membership of the same project,
the same network or the same pod. The scope check runs on the host, before any
podman call that reads logs.

**No existence oracle.** A source that does not exist and a source that belongs
to another lane get the same refusal, `refused:diagnostics-scope:not-in-scope:<source>`,
so a forge cannot probe for its siblings' container names.

## The tools

```
forge_logs {source?: string, lines?: 1..500}
  -> {sources: [{name, kind, state}]}                  # no source: what L may read
  -> {source, lines: [..], truncated, bytes}           # a source in scope
  -> error "refused:diagnostics-scope:not-in-scope:<source>"

forge_events {cursor?: u64}
  -> {schema_version, events: [Event], cursor, dropped, gap}
```

`forge_logs` reads on demand (`podman logs --tail`), under the `service_logs`
bounds (500 lines, 64 KiB, 15 s). Nothing it reads is stored. Lines are
returned as data: content is untrusted, and no command, path or URL inside a
line is acted on.

`forge_events` reads L's ring. `cursor` is the last `seq` the caller saw; the
reply carries every event after it. If the cursor is older than the ring's
oldest event, `gap: true`. `dropped` counts the events the ring has discarded
since the lane started. Loss is always reported.

## Events

```
Event = {schema_version, seq, at, scope: "lane" | "global", kind, ...allowlisted}
```

- **Lane events** are the lane's own lifecycle: launch stage, image ensure
  verdict, container start, exit (with code and OOM), readiness. They are
  emitted by the host code that already prints them (the
  `runtime-diagnostics-stream` event formats).
- **Global events** are typed producer facts:

  | kind | fields beyond the envelope |
  |---|---|
  | `credential.refresh` | `service` (github, cloudflare), `outcome` (succeeded, failed) |
  | `gc.reap` | `resource` (container, volume, image), `count` |
  | `image.build` | `image`, `outcome` |

  A `GlobalEvent` is built from a Rust enum, so a field outside the allowlist
  cannot be serialized. No producer turns a raw log line into one. A global
  event goes into the ring of every lane that is live when it is published;
  a lane started later does not receive it (retention is the session).

**Curation fails closed.** Only typed events enter a ring. Raw logs are never
stored: `forge_logs` reads them from podman for an in-scope source at the
moment of the call. There is therefore no transform whose failure could
forward raw data, and nothing for regex redaction to miss.

## Lifetime

One ring per lane, in the process that serves the lane's MCP listener (the
tray or the launching CLI). It is created when the lane's listener starts and
dropped when the lane ends. Its capacity is 10K events, as in
`runtime-diagnostics-stream`; overflow drops the oldest event and increments
`dropped`. Nothing is written to disk. If the ring cannot be served (the
listener process is gone), the tools fail with a named error. Launch is never
blocked on diagnostics, and a missing ring is never reported as healthy.

## Reconciling the related specs

- `runtime-diagnostics-stream`: extended. Its session-only, never-persisted
  10K ring is exactly the retention ruling; this change scopes it per lane and
  exposes it through the lane MCP.
- `log-schema-versioning`: every event carries `schema_version`.
- `log-aggregation`: source, timestamp, severity and trace metadata survive.
  `seq` orders events within one ring only; no global order is invented
  across rings.
- `external-logs-layer`: its consumer view, a read-only mount of every
  producer role's external logs, would show one forge another forge's
  children. Forge diagnostics therefore never come from that mount. Before
  any forge consumes it, that spec's consumer scenario must be narrowed to
  the lane, or forges excluded from it (task 4.1).

## Fixtures (red before the implementation)

Each arm is a cargo test in `mcp_socket.rs` that drives the real lane MCP
dispatch (`serve_mcp_connection`) as two lanes, A and B, over socket pairs,
with a fake podman on `TILLANDSIAS_PODMAN_BIN`. The fake lists A's forge, A's
preview, B's forge and B's preview, with their `tillandsias.lane` labels, and
answers `logs <name>` with `LOG-OF-<name>`. The tests are
`#[ignore = "red until 1779-sq9g is implemented"]` and run with
`cargo test … -- --ignored`. The implementation removes the ignore.

1. `a_forge_cannot_read_a_siblings_or_its_childrens_logs`: A asks for B's
   preview, B's forge, and a name that does not exist. All three get the same
   `not-in-scope` refusal. No `LOG-OF-` of B's reaches A, and A's source list
   names nothing of B's.
2. `a_forge_reads_its_own_childrens_logs`: A lists its sources (its forge and
   its preview) and reads its preview's `LOG-OF-…`.
3. `a_global_event_reaches_every_forge_with_only_allowlisted_fields`: with
   credential canaries in the process environment, a GitHub token rotation is
   reported through the existing check. Both A and B then see one
   `credential.refresh` event. Its keys are within the envelope and the
   allowlist, and no canary appears in either reply.
