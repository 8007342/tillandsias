# Local preview core adversarial review — pending fixes and evidence

- **Status**: in_progress; findings attached to existing 1552-238z,
  1552-mqvf and 1552-e3wf, not separate competing implementations
- **Branch**: parent `work/1552-e3wf`; no child source fixes/commit/push
- **Reviewer**: Astra, bounded source review of the uncommitted shared tree
- **Scope**: core lifecycle/main/tray, managed image, canonical contracts;
  parent harness/bindings read-only

## Evidence boundary

Parent relays Sol's 10 unit-test pass, default check and tray clippy. Sol also
reports actual rootless Podman bounded tmpfs-volume proof: 4 MiB filesystem
overflow produced ENOSPC; readonly volume-subpath sibling saw agent edits
without full source-root exposure; writer cgroup shmem measured 4 MiB;
UID 1000 keep-id worked; proof fixtures removed. These are Sol-attributed
results, not Astra reruns. They supersede the earlier absence of any successful
sharing proof, not the pending real forge MCP/TLS/cleanup acceptance. Terra is
still image-smoking and parent is running full gate/test compile.

## Prioritized findings (snapshot; line numbers may move during parent edits)

### B1 — required target is rejected, and its TLS key path would still be wrong

`local_web_preview.rs::validate_components` allows only alphanumeric
and hyphen project bytes. `tillandsias.org` is therefore rejected before every
lifecycle call. Parent harness explicitly expects this project and
`www.tillandsias.org.localhost`. Separately,
`main.rs::generate_dynamic_caddyfile` derives `project_label` with
`subdomain.rsplit('.').next()` for the newly added certificate filenames:
the target would load `org.crt/key`, while `prepare_tls` writes
`tillandsias.org.crt/key`. Fix hostname validation per DNS label while retaining
known-project equality/path safety, and derive preview certificate identity
without dropping project components. Add a target-specific rendered-route test,
not only a generic `proj` success. Owner Sol; blocks actual target.

### B2 — config inspector requires a module absent at that image path

`local_web_preview.rs::CONFIG_INSPECTOR` requires
`/srv/preview/node_modules/wrangler`; image Containerfile installs Wrangler
under `/opt/tillandsias/wrangler/node_modules/wrangler`. It creates only `.mf`
under `/srv/preview/node_modules`. Every Wrangler publish through this inspector
will fail module resolution even if direct image `wrangler dev` smoke passes.
Agree the installed parser path and prove the EXACT inspector invocation
against the built image for assets-only JSONC. Owner Sol/Terra seam.

### B3 — live config changes escape the one-time remote-binding check

`source_mounts` calls the no-network inspector once; the recursive `remote`
check covers the parsed object at that moment. The main preview starts later
on a live config file and watches it. `images/web-wrangler/entrypoint.sh` only
makes a directory and execs Wrangler; it has no config-change guard. An in-place
edit (or race between inspection and runtime parsing) can introduce
`remote:true` after approval. No attempt at exploiting a real remote binding
was run. The code provides no enforcement of the draft's local-only rule across
live edits; lack of Cloudflare token is not such enforcement. Require a runtime
mechanism that refuses/disables remote bindings on every effective config
generation, and test both startup race and post-start edit. Owner Sol/Terra.

### B4 — failed Caddy removal reload can become a false successful stop

`remove_route` writes the registry then calls `strict_reload`. If reload fails,
disk no longer has the route while Caddy can retain it. A second stop sees
unchanged registry length, skips reload and returns `stopped`. The desired
idempotence hides a known stale effective route. Retry/reconcile effective
configuration even after the desired-state row is gone; test first reload
failure then second stop. `watch_source_lifetime` also ignores remove/reload/
volume-rm failures and unconditionally breaks, abandoning cleanup retries.
`cleanup_departed_lane` returns early when container is absent, without removing
its stale route. Owner Sol; blocks cleanup correctness.

### B5 — launch/storage reconciliation is not yet justified in full

`prepare_forge_ram_workspace` changes computed source mode from 0777 to 0700
on the actual volume, not merely an outer private parent; canonical source-root
mode remains 0777. Metadata verification only requires ANY `size=` option,
not equality to expected computed budget. Reuse is keyed by project/instance
name; verify generation and actual mount cap rather than trusting suggestive
labels. Fresh create does use computed cap, and Sol's proof supports the
bounded mechanism itself. Do not call the whole canonical contract verified.

More importantly, existing `ForgeBudget::podman_args` deliberately sets nonzero
`memory.swap.max` and host-tier ceilings, not HOT sum/no-swap. Its module cites
operator ruling on 437, confirmed by
`plan/issues/forge-memory-swap-architecture-design-2026-09-26.md`, sections
"The question" and "The model".
This is PRE-EXISTING authority drift, not newly caused by shared source; forcing
the old small no-swap formula could undo an explicit operator ruling. Parent
must reconcile this before any claim of no-swap equivalence. Astra therefore
does NOT amend `forge-hot-cold-split` to bless current code under the requested
"only if code/proof matches" condition. Owner parent reconciliation/Sol mode
and size validation; no unauthorized budget change proposed.

### B6 — listener failure is cached as success on retry (pre-existing, now relied on)

`tray::start_mcp_socket_server_for_lane` inserts the lane in ACTIVE_LANE_LISTENERS
before create/bind/chmod. A failure returns Err once but leaves the entry; the
next call returns Ok without a listener. New prepare propagates its first error,
but that alone does not meet truthful listener readiness. Registry key also
concatenates project-instance with hyphens (unlike new hashed source tuple).
At minimum roll back failed registration and test retry. Check existing
same-process tray versus CLI-child ownership: unconditionally unlinking a live
socket from another process can steal its endpoint. Owner parent/Terra; cited
pre-existing helper must not be credited as proven by new error propagation.

### B7 — watch limitation has no runtime disclosure yet

Parent accepted individual-file atomic-replacement limitation only with an
explicit reload diagnostic. `result` currently says `watch=true` for Wrangler
and successful publication has empty diagnostic; root config/Worker and static
file mounts can pin old inodes. Draft now records the narrow exception, but
runtime must report affected mounts/reload need; directory watch remains
required. Owner Sol.

### B8 — 30-second readiness is not an actual total bound

`ready_backend` uses a 30-second loop deadline but its synchronous `inspect`
and Podman exec calls each use `OperationKind::Container` default 300 seconds
(`crates/tillandsias-podman/src/backend.rs::OperationKind::default_budget`,
`OperationKind::Container` arm). Source resolution also performs many serial such calls and
resource locks allow 120 seconds each. Parent E2E RPC read timeout is 120 seconds.
A wedged inspect can overrun readiness and outlive the client while publication
later mutates state. Use remaining-deadline budgets for readiness and define a
bounded end-to-end operation/cancellation policy. Owner Sol; inject a stalled
inspect, not only exit-125 fast failures.

## Canonical changes and guard population

Router spec now narrowly permits one additional loopback TLS mapping on the
existing router while preserving HTTP; no admin/service host publication.
Draft preview is not activated. Exact-host SAN construction and 0600 leaf key
publication are present; CA signing key is not included in new router mounts.
No new host trust-store or tray UX mutation was found in reviewed changes.

Actual attach function is `local_web_preview.rs::run_args`, using
`crate::ENCLAVE_NET`. Lua membership guard scans every Rust file under crates
but filters top-level names through `FN_TRIGGER` and `BUILD_LAUNCH`. Added truthful
canonical membership text naming run_args, and explicit guard coverage gap;
did NOT invent `build_local_preview_run_args`. Parent/Sol should rename the
builder and update the scanner-readable entry, or extend/test the guard. The
config inspector is intentionally `--network=none`, not an enclave service.

## Coverage/next actions

Read parent `tests/local_web_preview_e2e.rs`; it usefully covers target URL,
uncached uncommitted asset, repeated publish/reload/stop, type validation,
config non-disclosure and trust-anchor comparison. It does not cover the
above startup/parser-path failures until executed, config remote edits,
atomic-file disclosure, failed stop/reload retry, real forge teardown/restart,
same-project cross-lane isolation or deadline injection. Do not treat the
single ignored opt-in test or compile pass as full acceptance. No harness or
binding edit by Astra.

Next: parent sends B1-B4 and B7-B8 to Sol, B2/B3/B6 to Terra jointly, resolves
B5 authority/mode questions, and closes the membership guard population gap.
Retest changed failure controls, then real forge MCP/TLS/cleanup. All findings
remain open pending readback/evidence; no speculative exploit or runtime result
has been represented as observed success/failure.

## Parent resolution and attributed image evidence — follow-up

Parent resolved B5's memory-policy precedence for this feature: explicit
order-437 ruling and approved
`openspec/changes/forge-swap-backed-memory-ceiling/specs/forge-hot-cold-split/spec.md`
govern the newer implemented positive-swap policy. Preserve existing tier
`ForgeBudget` completely. Do not restore old no-swap/sum formula, provision host
swap, or introduce persistent/disk filesystem source. Draft narrowed accordingly.
Pre-existing stale canonical contradiction remains a spec-sync follow-up under
1552-e3wf; no entire swap-change sync/activation here.

One bounded symbol/mode check still found `local_web_preview.rs::run_args` and
`prepare_forge_ram_workspace` replacing source mode0777 with mode0700. Sol is
implementing rename/mode/exact-cap fixes. No polling or premature source
re-review: authoritative enclave tracked-symbol update and canonical bounded
source-mechanism allowance remain pending coherent fix readback and evidence.
Prior B1-B8 findings are not declared closed by this checkpoint.

Terra actual image smoke, relayed by parent: Alpine failed because workerd
needs glibc; image now uses digest-pinned Debian Node and pinned npm dependencies.
Reported image ID:
`4455412a4a0389e91d35c48b10b844a46af138db486b8e37163468e8a93f8b0a`;
reported digest:
`sha256:7f4aceea80657cb45fe2190ee0f146e65792a566b745d01abc74597ed85df052`.
Assets-only JSONC/no-main served watch V1 to V2 and config request returned 404.
Worker V1 to V2 watcher and restart passed; read-only source/private tmpfs state
tested. Managed image kept. These are Terra-attributed backend smoke results,
not proof of exact core inspector invocation or closure of B2/B3. Earlier
Sol bounded source proof remains attributed as above. Real forge MCP/TLS and
generation cleanup are still pending. No new UI, CA trust or swap authorization.
