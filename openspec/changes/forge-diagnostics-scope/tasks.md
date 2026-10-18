# Tasks — forge-diagnostics-scope

Row `1779-sq9g`. Each task's closure is a fixture in
`crates/tillandsias-headless/src/mcp_socket.rs` (`forge_diagnostics_scope_fixtures`),
committed red with this change as `#[ignore = "red until 1779-sq9g is implemented"]`.
The implementation removes the ignore. Run red today with:
`cargo test -p tillandsias-headless --bin tillandsias --features tray -- --ignored forge_diagnostics_scope_fixtures`

## 1. The scope

- [ ] 1.1 Every container the host creates for a lane carries the host-set
      label `tillandsias.lane=<project>/<instance>`: the web preview, browser
      windows and their forwarders, toolchain containers.
- [ ] 1.2 `forge_logs {source?, lines?}` on the lane MCP. It lists and reads
      only the lane's forge container and its labelled children, and gives an
      identical `refused:diagnostics-scope:not-in-scope:<source>` for a
      foreign source and a missing one.
      Closure: `a_forge_cannot_read_a_siblings_or_its_childrens_logs` and
      `a_forge_reads_its_own_childrens_logs`.

## 2. Global events

- [ ] 2.1 `forge_diagnostics::GlobalEvent`, a typed enum (`credential.refresh`,
      `gc.reap`, `image.build`). Publishing it fans out to every live lane ring.
- [ ] 2.2 Producers: the GitHub token rotation verdict
      (`vault_bootstrap::github_token_check_before_use` and the scheduler),
      then Cloudflare rotation, the GC reaper and the image ensure verdict.
      Closure: `a_global_event_reaches_every_forge_with_only_allowlisted_fields`.

## 3. The session ring

- [ ] 3.1 One 10K ring per lane, created with the listener and dropped with
      the lane. `forge_events {cursor?}` returns events, cursor, `dropped` and
      `gap`, and lane lifecycle events (launch stage, ensure verdict, start,
      exit with OOM, readiness) are recorded in it. Fixtures to add with the
      implementation: a new lane starts empty; overflow reports `dropped`; a
      stale cursor reports `gap`.

## 4. Reconcile

- [ ] 4.1 `external-logs-layer`: narrow its consumer scenario (a read-only
      mount of every producer role) so no forge sees another lane's children,
      or exclude forges from it. Forge diagnostics never read that mount.
- [ ] 4.2 Live arm: two concurrent forges of one project on one host. Each
      sees only its own preview's logs, and both see one token-refresh event.
