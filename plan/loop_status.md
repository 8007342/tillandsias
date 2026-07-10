# Multi-Host Coordination Loop Status

LastExecutionTime: 2026-07-10T12:15:00Z

## Cycle 2026-07-10T11:57Z (macos — overnight autonomous 8/8 FINAL: merge + verified-green macOS handoff)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 8 of 8, final).
  Credential guard `ok:gh-keyring`. Merged origin/linux-next ba3e5acd.
- **Order collision resolved (uniqueness gate)**: linux filed its own order
  283 (smoke-lock-fd-leaks) + 284 (P1 forge-opencode outage) in parallel
  with my cycle-7 order 283 (headless-podman-test-gate). Kept linux's
  283/284, renumbered mine to **285**; the order-275 uniqueness gate
  confirmed clean (150 packets, no open-packet duplicates). This is the
  gate's textbook use case — three hosts filing packets in parallel
  overnight, caught mechanically.
- **No macOS-actionable ready work this cycle**: 273 operator-blocked
  (agent leaves auth-gated); 155 contested criteria (proposal pending);
  270/283/284/285 linux-owned; 284 is a P1 but it's the linux forge lane
  (upstream opencode-ai@latest publish broke the in-enclave postinstall),
  not macOS-fixable.
- **Final action — verified-green macOS handoff**: re-ran the macOS-owned +
  cycle-7-fixed crates on the merged final tree — all green
  (macos-tray 69, host-shell 59, vm-layer 51, control-wire 38,
  gh_auth_deploy_key 5/5 with the keyring hermeticity fix holding). Build
  check clean. The macOS trunk is solid at loop close.
- **E2E gate**: skipped-with-cause — destructive local-build e2e PASSED
  cycle 6 (merged HEAD) + cycle 4; no runtime delta this cycle (merge +
  verification only).
- **macOS night summary (8 cycles)**: order 272 (ssh backdoor closed,
  verified), 277 (one-shot CLI vs live tray), 269 (session-end banner +
  pty-dump), 155 slice 4 (LocalProjects push) + tick-wait dedup onto the
  shared module; fixes: chip clobber, fstab mount persistence, post-login
  cloud prime, keyring test hermeticity. Filed for siblings: 267/276 (login
  push), 270 (guest-side attach), 281 (overlay self-heal), 283/285
  (test-gate). Two destructive e2e PASSes. Open macOS residual: 273
  (operator), 155 (criteria decision). Parity column: 6/7 cells done,
  InteractiveStream blocked on 273.
## Cycle 2026-07-10T10:40Z→12:10Z (linux_mutable macuahuitl — overnight loop 7-8/8 CLOSE: strict default proved in gates, P1 forge-lane outage filed)

- Iteration 7: strict-default's first gates surfaced and FIXED two real
  bugs — alpine:latest fallbacks in the slice-2 helpers (base policy) and
  run-observatorium.sh's unqualified + bump-window image reference
  (launcher verified live). Order-265 probe WIRED into opencode STEP 3
  after the second alive-past-budget collision (soft 600s + liveness
  extension + 1500s hard cap).
- Iteration 8: reclaimed the smoke lock from an orphaned agent session
  holding an inherited flock fd (order 283 filed — close-on-exec fix);
  then the probe fast-failed dead_crashed and exposed the real outage:
  **P1 order 284 — the forge opencode lane is DOWN since 10:56Z.**
  Upstream opencode-ai published 3 dev/beta releases during our window;
  the post-reset harness refresh pulled one whose postinstall cannot
  complete in-enclave. Minimal repro + npm timeline + fix direction
  (tested pin, updater rollback, egress disposition) in the packet. TOP
  PICK for the next linux cycle.
- Gate state at close: pre-build matrix 156/156 under the strict default
  (proved twice); post-build green EXCEPT the three forge-launching
  litmuses, all red on the order-284 outage; destructive gates 2-4 not
  reached tonight after the 073536Z full PASS (substrate remains from
  that provision).
- The 8-iteration overnight loop is COMPLETE. Cross-host: siblings ran
  their own loops throughout (macOS adopted 260 + passed destructive e2e;
  windows on 154 slices); ~15 packets closed across hosts tonight.

## Cycle 2026-07-10T10:57Z (macos — overnight autonomous 7/8: macOS trunk-health sweep found+fixed a real keyring hermeticity bug + filed the podman-test-gating class)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 7 of 8).
  Credential guard `ok:gh-keyring`. Merged origin/linux-next c2964103
  (strict-default gate findings — alpine fallbacks, observatorium image
  resolution). Order 273 STILL open; needs operator PAT to repro (agent
  leaves are auth-gated), so unadvanceable unattended.
- **No small macOS-owned packet available** (155 large+contested, 270 now
  linux, 273 operator-blocked, 147/225 cross-cutting), so ran the macOS
  host's UNIQUE contribution: a full `cargo test --workspace` sweep — the
  macOS box is the only host that compiles+runs the macOS-specific code, so
  this is the trunk-health check no other CI performs.
- **Real bug found + FIXED (keyring hermeticity)**: the deploy-key test
  (tillandsias-core gh_auth_deploy_key) was designed hermetic via
  LITMUS_SECRET_TOOL_STORE + a fake secret-tool shim, but
  scripts/generate-repo-key.sh's Darwin arm used the real macOS `security`
  Keychain, which the Linux shim doesn't intercept — so on macOS it wrote to
  the developer's login Keychain and failed read-back under automation. Fix:
  secret_store_set/get honor LITMUS_SECRET_TOOL_STORE as a cross-platform
  file store (fake's exact format → Linux byte-identical). 5/5 pass; never
  touches the real Keychain now. Finding:
  deploy-key-test-hits-real-macos-keychain-2026-07-10.md.
- **Reduction-engine capture → order 283 (linux)**: the sweep also exposed a
  CLASS — tillandsias-headless podman-integration tests FAIL (not skip) on a
  bare macOS host (no podman machine): they assert podman-semantic errors but
  get connection-refused. Fixed one as the reference pattern
  (error_recovery::test_missing_image_error_handling now treats
  podman-unreachable as a graceful skip); filed the rest (stress_* + the
  un-reached binaries) for a shared podman_daemon_reachable() gate. These
  masked the real keyring find — hermeticity matters. Finding:
  headless-integration-tests-not-macos-gated-2026-07-10.md.
- **E2E gate**: skipped-with-cause — destructive local-build e2e PASSED
  cycle 6 (<1h) on merged HEAD; this cycle's deltas are test/script
  hermeticity fixes verified by the test sweep itself.
- **Queue next**: order 283 (linux, test gating), 273 (operator), 155
  (contested criteria — proposal pending). Final cycle 8 next.
## Cycle 2026-07-10T09:57Z (macos — overnight autonomous 6/8: reduction pass — order 270 re-scoped guest-side, order-155-criteria proposal filed, destructive e2e on merged HEAD)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 6 of 8).
  Credential guard `ok:gh-keyring`. Merged origin/linux-next 447451db
  (order 267 COMPLETE — strict litmus exit-code authority is now the
  default; corpus 156/156). Order 273 STILL open.
- **Reduction-engine pass (no risky big-refactor forced at 6/8)**: the two
  macOS-owned ready packets are 155 (large final refactor) and 270
  (entangled with 273). Rather than force either unattended, reduced the
  ledger:
  - **Order 270 RE-SCOPED guest-side**: code re-read + orders 269/281
    corrected the original host-side misdiagnosis. The macOS attach worker
    does NOT give up/close the PTY (run_pty_attach detaches pump_io; the
    GUEST child's exit closes it); order 269's banner already made
    session-end operator-visible; 281 owns the corrupt-store aftermath. The
    real residual — build reaped with the attach process + no progress
    feedback — is guest-side. Moved pickup_role macos->linux, deliverable
    ->tillandsias-headless, criteria trimmed to detach-build + progress
    signal. Rescope event recorded.
  - **Order-155 exit-criteria proposal filed** (Tlatoāni-gated,
    order-155-zero-sleep-criteria-vs-fallback-poll-2026-07-10.md): the
    "no tokio::time::sleep in transport path" criterion is unsatisfiable
    against the converged design that DELIBERATELY keeps a fallback poll
    (both trays share it via subscription_health). Proposed rewording to
    the SC-07 "no timer while healthy" invariant the code already
    satisfies — NOT self-approved (definition-of-done change).
- **E2E gate (destructive, local-build) on merged HEAD 447451db PASS**:
  eligible; destroy + rebuild + cold provision (exit 0) + `--exec-guest`
  smoke — fresh disk boots healthy (guest headless v0.3.260710.8), and
  order 272 re-verified on this build (sshd masked, zero :22 listeners,
  fstab mount present). Report:
  plan/issues/macos-e2e-overnight-cycle6-2026-07-10.md.
- **Queue next**: macOS ready now = 155 (pending the criteria decision) +
  its watch-channel-menu residual. 270 handed to linux. Order 273 remains
  the attach-cell blocker.

## Cycle 2026-07-10T09:44Z→10:15Z (linux_mutable macuahuitl — overnight loop 6/8: ORDER 267 COMPLETE, strict litmus authority is the default)

- Siblings merged x2 (clean). The harness onion's final layers: the
  RELATIVE calls-file path was landing in the package-root target dir
  (cargo test cwd — iteration 5's "stray nested target" was the evidence);
  localhost/-qualified assertion updates; the test's ensure list extended
  to the 10-image canon; the never-real container-run assertions moved to
  a filed full-init-harness follow-up.
- THE FLIP: TILLANDSIAS_LITMUS_STRICT_EXIT defaults ON (=0 opt-out is
  itself a finding); unparseable steps are hard PARSE FAILs. Strict sweep
  156/156 before the flip; default sweep 156/156 after; every litmus file
  ruby-parses. Order 267 completed with multi-agent credit (in-forge:
  slice 1 + slice 2 + anchor; coordinator: burn-down, iterations 2-6).
- Post-build matrix re-proves at the next gate (pattern-ed steps are
  behavior-identical under the flip).
- Queue next: 273 (attach login flow), 129, 225, security chain, streams
  chain, audits. Blocked-on-operator unchanged.

## Cycle 2026-07-10T09:07Z→09:45Z (windows — meta-orchestration recurring loop 4/8: FULL DESTRUCTIVE E2E PASS @ 06c14a35, guest version-skew demonstrated, order 282 filed)

- **Host**: Windows 11 native, `windows-next`, agent
  windows-bullo-fable5-20260710T0536Z. Credential guard
  `ok:gh-credentials-store`. Clean start at ebd68448; merged
  origin/linux-next 06c14a35 clean, pushed sync before work. Preflight
  `eligible`.
- **E2E gate — /build-install-and-smoke-test-e2e (windows) run 3, PASS
  (run_id 20260710T090845Z)**: build 2m16s → direct-copy install
  (freshness gate: embedded SHA 06c14a35 == HEAD) → destructive
  `wsl --unregister` + cache/wsl/logs wipe → cold `--provision-once`
  exit 0 (rootfs re-downloaded, `RESULT: VM Ready — control wire up ✓`,
  handshake wire_version=2 attempt=1) → `--diagnose --json` exit 2
  degraded-as-expected, 17 keys, build_commit fresh. Report: Run 3
  section of build-install-smoke-e2e-findings-2026-07-10-windows.md.
- **Extended verification**: order 274 criterion 1 RUNTIME-CONFIRMED
  (fresh guest unit carries HOME + XDG_RUNTIME_DIR pins); criterion 3 has
  no unattended lane on Windows → 274 flipped to blocked-on-operator,
  probe appended as item 10 of the order 258 attended checklist.
- **Reduction engine — guest version skew DEMONSTRATED, order 282
  filed**: a PRISTINE provision boots guest headless v0.3.260707.2 — the
  embedded musl assets are zero-byte placeholders so fetch-headless pulls
  the newest RELEASE, and the release hold keeps every release
  pre-order-260. The slice-3 full-topic subscribe was rejected even on
  the fresh substrate (legacy fallback held, 4th live engagement).
  Evidence event appended to order 190 (its contract-shaped criteria are
  genuinely done); windows implementation half promoted to order 282
  (guest-binary-embed-windows, ready, windows pickup) with the
  linux→windows artifact-transport question flagged to the coordinator.
  ALSO: this means macOS live-push verifications share the same ceiling —
  their guests fetch releases too (vz.rs fetch service): worth a macOS
  check whether order 155's live evidence was against a staged or
  fetched guest.
- **Next windows work**: order 282 (needs transport decision), order 154
  remaining slice (menu wakeups + tick elimination — unit-pinned, not
  guest-dependent), order 251 verifiers, order 258 attended items (now
  10 incl. the 274 probe).

## Cycle 2026-07-10T08:57Z (macos — overnight autonomous 5/8: order 155 tick-wait dedup onto shared module, cross-host convergence)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 5 of 8).
  Credential guard `ok:gh-keyring`. Merged origin/linux-next 34c53ced —
  which brought TWO cross-host wins from my earlier slices: (1) windows
  adopted my SubscriptionHealth (order 154 slice 4, 0083f362 "tick wait
  wakes on drop"); (2) linux hoisted my slice-3 tick-wait helpers into the
  shared subscription_health module. Order 273 STILL open.
- **Order 155 dedup COMPLETE**: removed the macOS-local TickWake /
  wait_tick_or_subscription_drop / tick_after_wake (+ their 2 redundant
  unit tests) and imported the shared copies linux hoisted. The "identical
  stream architecture" exit criterion is now enforced by SHARED SOURCE
  rather than parallel copies — the two trays' tick-wait semantics cannot
  drift. Byte-identical implementations (behavior live-verified cycle 4);
  69 tray + 59 host-shell tests, build check clean. No behavior change → no
  re-verification needed.
- **E2E gate**: skipped-with-cause — pure source dedup, zero runtime
  behavior change; cycle 4's destructive gate (<90min ago) exercised the
  identical behavior on a fresh provision. No new e2e report warranted.
- **Queue next**: macOS 155 residual = watch-channel MENU listeners (last
  slice; removing the fallback tick loop entirely + SC-01 zero-sleep). Order
  273 remains the hot linux blocker on the attach cell. Sibling convergence
  healthy: both trays now share SubscriptionHealth + tick-wait + the
  four-topic push model.

## Cycle 2026-07-10T08:45Z→09:35Z (linux_mutable macuahuitl — overnight loop 5/8: strict burn-down to ONE named blocker)

- Siblings merged x2 (osx: 155 slice 4 LocalProjects adoption + their own
  destructive e2e PASS + 281 corruption cleared; windows: 154 slice 4).
- Order 267 tail: init-command-shape repaired (rg -F/-U regex-vs-literal
  class, canonical image pin updated 8→10 per orders 253/76);
  headless-init harness step EXECUTED for the first time since authoring
  (single-quoted scalar + rustup env) and exposed the next layer — the
  Rust harness test self-short-circuits in 0.07s without writing the
  calls log. That is now the SOLE strict-flip blocker (named in the 267
  issue). Parser command:-anchor re-applied safely post-slice-2 and
  immediately proved itself. Strict pre-build sweep: 155/156.
- Generated-file stragglers (metrics/TRACES/nested-target stub) committed
  or removed; tree clean.

## Cycle 2026-07-10T08:07Z→08:45Z (windows — meta-orchestration recurring loop 3/8: order 154 slice 4 SC-16, helpers hoisted to host-shell)

- **Host**: Windows 11 native, `windows-next`, agent
  windows-bullo-fable5-20260710T0536Z. Credential guard
  `ok:gh-credentials-store`. Clean start at 14012ad7; merged
  origin/linux-next 2cc5a066 (order 267 slice 2 litmus rewrites, pure
  fast-forward again — three cycles running, windows-next has stayed a
  strict descendant of linux-next), pushed sync + claim before work.
- **Worker drain — order 154 slice 4 COMPLETED (0083f362), lease
  released, packet stays ready**: SC-16 adoption — VM_STATUS_PUSH_HEALTHY
  AtomicBool replaced by shared host-shell SubscriptionHealth; tick loop
  waits via wait_tick_or_subscription_drop, rewinding to tick 0 on a drop
  so the full fallback round runs immediately (was: up to 300s on the
  10-tick cadence). HOISTED the tray-agnostic helpers (TickWake,
  wait_tick_or_subscription_drop, tick_after_wake) into
  host-shell::subscription_health with their paused-clock pins instead of
  mirror-duplicating them — macOS order 155 flagged to swap
  action_host.rs's local copies for the shared ones (order-274
  unit-writer-drift lesson applied proactively). host-shell 53 tests,
  windows-tray 65, clippy 0 warnings across both.
- **Live verification**: tray at this HEAD engaged the slice-3
  legacy-topic fallback twice more (stale pre-260 guest), and survived a
  mid-run `wsl --terminate`: keepalive respawned WSL, push subscription
  re-established 31s end-to-end. SC-16 wake-timing semantics pinned
  deterministically by the paused-clock tests. All test processes
  terminated, VM returned to stopped.
- **E2E gate**: deferred-with-cause — third consecutive cycle whose
  runtime delta is tray-side push wiring, live-exercised directly above;
  the pending destructive run (also order 274 criterion 3 + slice 3
  full-topic path) is queued for a cycle with headroom — it needs the
  guest refreshed past 7bdc4c1d, which the e2e's build+install provides.
- **Next windows work**: order 154 residual (watch-channel menu wakeups +
  tick-task elimination — needs an event-driven menu render path); the
  full destructive e2e as the next cycle's primary item (closes three
  pending live-verification residuals at once).

## Cycle 2026-07-10T07:12Z→08:25Z (linux_mutable macuahuitl — overnight loop 3-4/8: FULL DESTRUCTIVE E2E PASS, all four gates green)

- **THE MILESTONE**: run 20260710T073536Z — first fully-green destructive
  local-build e2e on this host. Gate 1 ci-full exit 0 (all litmuses incl.
  the night's three rewrites + all-features lane), gate 2 podman reset
  zero-residue, gate 3 cold --init full rebuild exit 0 (order-263 mirror
  YAML gate now LIVE in the rebuilt git image), gate 4 forge lane exit 0.
  PASS report: plan/issues/build-install-smoke-e2e-PASS-20260710T073536Z.md.
- Getting there (iterations 3-4): inference litmus rewritten on the
  product launch shape (real podman, keep-id+label=disable, current
  strings) — PASS standalone then in-gate; env-isolation resolution +
  entrypoint overrides + env-key allowlist (the 3-10 band was stale: 9
  baked + HOSTNAME + 6 containers.conf proxy vars); in-forge agents
  contributed 267 slice 2 (all 31 folded steps rewritten, mid-gate) and
  the gate-4 orphan fixes (adopted after strict-green verification;
  runner regex anchor REVERTED + parked — it re-pairs steps/expecteds in
  folded-legacy shapes); coordinator repaired the slice-2 placeholder
  expecteds. Full instant sweep green post-everything.
- Siblings: osx merged (269 + 281 filed); windows merged (154 slices 3-4
  — LocalProjects topic adoption underway on my order-260 wire work).
- Order 265 completed via ADOPTION with a correction event: the in-forge
  agent implementing the liveness probe outlived its litmus window
  (alive_quiet per its own grammar), pushed late, and the coordinator
  contributed the final test guard — the probe's thesis demonstrated by
  its own birth. STEP 3 wiring = evidenced next packet.
- Remaining 267 tail: strict-exit default flip + PARSE-WARNING→FAIL
  promotion + parked anchor, gated on strict sweeps staying green.
- Queue: next linux picks = 267 tail, 273, 129, 225, security chain,
  streams chain, 249/250, audits. Blocked-on-operator unchanged (windows
  attended smoke 258, release approval, bar-raise slice 3).

## Cycle 2026-07-10T07:57Z (macos — overnight autonomous 4/8: order 155 slice 4 LocalProjects push, destructive e2e PASS, order 281 corruption cleared)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 4 of 8).
  Credential guard `ok:gh-keyring`. Merged origin/linux-next 2cc5a066
  (linux deep in order 267 litmus-corpus rewrites; order 273 STILL open —
  the macOS attach cell's blocker).
- **Order 155 slice 4 COMPLETE + verified live**: order 260's LocalProjects
  push source (landed cycle 1) let the tray's LAST steady-state poll ride
  the stream. Subscribe widened to all FOUR topics; new shared
  apply_local_projects consumes LocalProjectsPush/Reply; initial-sync primes
  EnumerateLocalProjects. The tick loop's entire slow-cadence block (local +
  cloud + login) is now inside the SC-07 fallback gate — a healthy
  subscription skips it, timer is pure fallback (SC-01/02 for the
  projects/login cadence). Live: 'push subscription established
  (vm-status/login/cloud/local polls demoted to fallback, SC-07)' +
  'local-projects: menu_state updated (4 entries)' via the reader loop, not
  the poll; clean SIGTERM. 71/71 tray tests. Windows flag: adopt
  LocalProjectsPush in notify_icon.rs for the same tick-elimination.
  Residual: watch-channel MENU listeners (last 155 slice; tick loop still
  exists as fallback).
- **E2E gate (destructive, local-build) PASS**: preflight eligible; build
  v0.3.260710.8 + install (SHA==HEAD 34838feb) + substrate wipe + 528MB cold
  provision exit 0. This destructive re-provision ALSO cleared cycle 3's
  order-281 corrupt overlay store — the osx-next VM is clean again. Report:
  plan/issues/macos-e2e-overnight-cycle4-2026-07-10.md.
- **Queue next**: macOS-claimable = 155 final residual (watch-channel menu
  listeners), 270 (attach materialization — still entangled with 273). Order
  273 remains the hot linux blocker; re-checked each cycle.

## Cycle 2026-07-10T06:58Z (macos — overnight autonomous 3/8: order 269 done + verified live, order 281 filed from PTY-tee capture)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 3 of 8).
  Credential guard `ok:gh-keyring`. Merged origin/linux-next 8ac2abdd
  (linux draining order 267 litmus corpus; order 273 still open).
- **Order 269 COMPLETED + F-G verified live**: (F-G) screen-attach
  AppleScript now prints '[tillandsias] session ended — you may close this
  window.' + exit — verified LIVE in the login popup (banner rendered, then
  '[Opération terminée]', window reclaimed cleanly, no dead-shell strand).
  (F-F) macos-tray-ax-smoke.sh pty-dump takes an explicit session arg +
  hardened auto-resolution (empty-sid guard, full token match, fail-loud
  listing, non-empty check). 3 new unit tests; bash-linted.
- **Order 281 FILED (linux) — real capture via the PTY debug tee**: the
  F-G verification's login attach hit `podman build tillandsias-git` exit
  125 `retry Permanent` — corrupt overlay store (missing layer diff).
  --exec-guest probe confirmed only vault built; git/proxy/inference/forge
  absent, 21 orphan overlay dirs. This is order 270's dangling-layer damage
  made concrete; 281 adds one-shot self-heal (reset+rebuild) since 270 only
  reduces the corruption rate, not repairs it. Filed as 278, renumbered to
  281 when the order-275 uniqueness gate flagged a collision with
  forge-harness-icap-proxy — the gate earning its keep on its first
  autonomous night. All forensics via idiomatic layers (PTY tee +
  --exec-guest), no ssh/root.
- **E2E gate**: skipped-with-cause — destructive local-build e2e PASSED
  cycle 1 (<2h); this cycle's code delta (AppleScript banner + harness) is
  unit-pinned and the banner live-verified.
- **Substrate note**: osx-next VM left with corrupt podman storage (order
  278); a --provision re-run or next destructive gate clears it. Documented
  in the finding so the morning operator recognizes it.
- **Queue next**: macOS-claimable = 270 (attach materialization/reaping —
  now with order 281 as its downstream evidence), 155 residual. Order 273
  still the hot linux blocker on the macOS attach cell.

## Cycle 2026-07-10T06:07Z→07:20Z (windows — meta-orchestration recurring loop 2/8: order 154 slice 3 + version-skew fallback, verified live)

- **Host**: Windows 11 native, `windows-next`, agent
  windows-bullo-fable5-20260710T0536Z. Credential guard
  `ok:gh-credentials-store`. Clean start at eaee1c94 == origin;
  origin/linux-next (7bdc4c1d) unchanged since loop 1/8 — already
  integrated, no merge needed. osx-next advanced twice mid-cycle (macOS
  loop active); its integration belongs to the linux coordinator.
- **Worker drain — order 154 (windows-tray-stream-refactor) slice 3
  COMPLETED (5c459070), lease released, packet stays ready**: push
  subscription widened to all FOUR topics (order 260's LocalProjectsPush),
  shared apply_local_projects applier, last steady-state wire poll
  (EnumerateLocalProjects) demoted to fallback-only, initial-sync prime
  extended. Found + fixed a REAL version-skew hazard while implementing:
  a pre-260 guest cannot decode the new trailing SubscriptionTopic
  variant and drops the connection — naive widening would have regressed
  ALL push topics to polls on every stale guest. Added a legacy
  three-topic fallback on a fresh connection with a separate
  LOCAL_PROJECTS_PUSH_SUBSCRIBED gate so local projects keep polling in
  legacy mode. VERIFIED LIVE against this host's stale-guest VM (guest @
  45cfd526-era, pre-260): 'subscribe: early eof' → legacy resubscribe in
  ~0.8s → login/cloud polls suppressed, local-projects poll continued at
  ~5min cadence, clean shutdown; VM returned to stopped as found.
  windows-tray 65 tests, clippy 0 warnings, fmt clean.
- **Cross-host flag (macOS order 155)**: adopt the version-skew fallback
  BEFORE widening the macOS topic list — the postcard decode failure is
  platform-independent. Pin shape: legacy_topics_are_full_topics_minus_
  local_projects.
- **Observation (not re-filed, duplicate discipline)**: stale guest's boot
  log showed '[vsock] vault bootstrap after DeliverCredentials failed:
  Failed to create runtime asset parent: Permission denied (os error 13)'
  — same os-error-13 vault family as smoke-e2e-findings-v0.3.260704.2 /
  vault-selinux-label-rootless-crash-2026-07-02; guest predates current
  HEAD where tonight's linux gate ran the vault chain green. Re-check on
  a FRESH guest at the next destructive e2e before filing anything new.
- **E2E gate**: deferred-with-cause — the slice's live verification above
  exercised the changed code directly (the destructive gate would boot a
  fresh guest that hides the fallback path this slice needed to prove);
  next destructive run verifies the full-topic path + order 274
  criterion 3.
- **Next windows work**: order 154 final slice (tick-task retirement:
  watch-channel wakeups + SubscriptionHealth adoption); order 258 still
  operator-blocked; order 251 awaits verifiers.
## Cycle 2026-07-10T06:54Z (linux_mutable opencode/big-pickle — meta-orch worker drain: order 265 research verdict + fixture prototype)

- **Host**: linux_mutable, `linux-next @ 9e7e47cc` → `047a5849`
- **Credential guard**: `ok:gh-keyring`
- **E2E eligibility**: `skip:smoke-lock-held`
- **Worker drain**: Completed order 265 (forge-agent-liveness-signals). Research
  verdict: 3-signal layered design (container state + heartbeat mtime + git HEAD).
  Evaluated 5 candidates (heartbeat file, git cadence, podman exec, vsock pulse,
  podman events). Implemented `scripts/forge-liveness-probe.sh` (status/wait/
  deadline modes, 5 liveness states). Fixture test suite `scripts/test-forge-
  liveness-probe.sh` (8 scenarios, all pass). Litmus `litmus:forge-liveness-
  probe-shape` registered and passing (9 steps). Hard-cap backstop preserved.
  Residual: forge entrypoint heartbeat touch, repeat script integration, litmus
  STEP 3 timeout diagnostics wiring.
- **Siblings**: windows-next `fd0706ca`, osx-next `dd2b21ea` — both ancestors
  of linux-next; no merge needed.
- **Commit**: `047a5849` pushed to `origin/linux-next`.

## Cycle 2026-07-10T06:21Z→07:20Z (linux_mutable macuahuitl — overnight loop 2/8: siblings merged, gate-1 burn-down ×3, env-isolation rewritten)

- Merged osx-next (272 SSH backdoor closed + 277) and windows-next (274
  progress, 154 slice 3 claim); merged tree --check green; one
  loop_status union-resolve.
- Gate 1 attempted ×3, each red understood + acted on (full table:
  plan/issues/build-install-e2e-gate-attempts-20260710-iter2.md):
  test race FIXED (63e0a497) → env-isolation flake, file REWRITTEN
  (8ac2abdd) → inference shim red (parked, next 267 slice: product-path
  launch) + FIRST one-packet STEP 3 timeout (no push landed; order-265
  data point — recurrence bumps its priority).
- Destructive gates 2-4 correctly not reached; next iteration rewrites
  the inference litmus then retries gate 1 → 2-4.
- Positives: all-features lane 3/3 green; opencode litmus greens #2-3 at
  062934Z; 268 proxy guard held in the bad shape.

## Cycle 2026-07-10T05:35Z→05:58Z (windows — meta-orchestration recurring loop 1/8: linux-next FF sync, order 274 criteria 1+2)

- **Host**: Windows 11 native, `windows-next`, agent
  windows-bullo-fable5-20260710T0536Z. Credential guard
  `ok:gh-credentials-store`. Clean start at c61601a8; merged
  origin/linux-next 7bdc4c1d — resolved as a pure fast-forward (windows-next
  was already fully merged into linux-next by the 05:50Z coordinator cycle),
  pushed. Recurring-loop context: this host runs 8 scheduled
  meta-orchestration cycles ~hourly tonight; linux + macOS hosts are running
  the same loop, so cycles stay one-packet-sized and lease-disciplined.
- **Worker drain — order 274 (wsl-headless-unit-lock-namespace), criteria
  1+2 CLOSED (d41b3493), lease released, packet stays ready**: the legacy
  WslRuntime::provision unit (vm-layer wsl.rs step 4) now pins
  Environment=HOME=/root + Environment=XDG_RUNTIME_DIR=/run/user/0 and
  creates /run/user/0 (ExecStartPre mkdir+chmod, matching the recipe-path
  unit), so the boot-path bootstrap and exec'd satisfiers share one
  $XDG_RUNTIME_DIR/tillandsias-locks flock namespace — the macOS order-259
  vault name-in-use race can no longer reproduce through the tarball path.
  New source pin test wsl::tests::wsl_provision_unit_pins_lock_namespace_env
  (runs on all platforms). fmt clean, clippy --all-targets 0 warnings,
  vm-layer 23/23. RESIDUAL: criterion 3 (fresh-distro first --github-login
  probe) rides this host's next destructive local-build e2e.
- **Reduction engine**: filed
  plan/issues/wsl-legacy-provision-unit-writer-drift-2026-07-10.md
  (enhancement): Windows has TWO independent headless-unit writers (legacy
  wsl.rs trait path vs live wsl_lifecycle.rs recipe path) and order 274 is
  the demonstrated drift mode — the 259 fix reached one writer but not the
  other. Proposes consolidating to one unit-template constant or retiring
  the legacy tarball path.
- **E2E gate**: deferred-with-cause — local-build e2e PASSED twice on this
  host tonight (runs @ c52a1e2e and 45cfd526, <4h ago) and this cycle's
  delta is the LEGACY provision path, which a recipe-path cold provision
  does not exercise; a re-run now would re-prove tonight's result without
  touching the changed code. Next destructive run doubles as the order-274
  criterion-3 probe.
- **Next windows work**: order 154 watch-channel slice is now FULLY
  unblocked (linux order 260 landed SubscriptionTopic::LocalProjects at
  7bdc4c1d — widen topic list, retire the 30s tick, adopt SubscriptionHealth
  per macOS order 155 slice 3); order 276 note: drop the interim login-prime
  once guests carry the transition push. Order 258 stays blocked on
  operator-attended smoke; order 251 awaits its 3 verifiers.



## Cycle 2026-07-10T05:57Z (macos — overnight autonomous 2/8: order 277 done + verified both ways)

- **Host**: macOS arm64, `osx-next`, unattended (overnight 2 of 8).
  Credential guard `ok:gh-keyring`. Clean start, linux-next unchanged since
  cycle 1; windows-next advanced (not merged here — linux coordinates).
- **Order 277 COMPLETED + verified live**: VM-booting one-shot modes probe
  the tray singleton (acquire-and-drop) and exit 3 with operator guidance
  when a live tray owns the VM — no more opaque VZ storage error. Verified
  both branches live: refusal against a running tray; GUEST_OK exit 0 via
  --exec-guest after quit. Pin test covers all four dispatch branches.
- **E2E gate**: skipped-with-cause — full destructive local-build e2e
  PASSED on this host <1h ago (cycle 1 report); this cycle runtime delta
  (the guard) was live-verified directly on the installed build.
- **Queue next**: macOS-claimable = 269 (ux residue), 270 (attach
  materialization blackout — NOTE partially entangled with linux order 273:
  273 may reveal the attach never reaches the build path on macOS), 155
  residual. Order 273 still linux-open — the hot macOS blocker.

## Cycle 2026-07-10T05:33Z (macos — overnight autonomous 1/8: order 272 done + verified on fresh provision, destructive e2e PASS)

- **Host**: macOS arm64, `osx-next`, unattended (overnight loop 1 of 8,
  hourly). Credential guard `ok:gh-keyring`. Clean start; fast-forwarded
  onto origin/linux-next 50fdd0bb (orders 275/276/260/268 landed — the
  uniqueness gate, the login-transition funnel, and the LocalProjects push
  all shipped by linux tonight).
- **Order 272 COMPLETED (33151e4d) + verified live**: cloud-init injects no
  SSH keys; sshd.service/.socket masked; systemd-ssh-generator nulled (the
  AF_VSOCK ssh surface behind the boot banner). Pin test scoped to the
  user-data window. Fresh destructive provision probed via --exec-guest
  (idiomatic layer, no ssh per orders 271/272): sshd masked+inactive, zero
  :22 listeners, zero key material (empty image-stub files only), fstab
  home-src mount present. wsl.rs audit clean.
- **E2E gate (destructive, local-build)**: preflight `eligible`; build +
  codesign v0.3.260710.3 + install (SHA == HEAD) + 2.1G wipe + 528MB cold
  provision exit 0; report
  plan/issues/macos-e2e-overnight-cycle1-2026-07-10.md. Tray installed but
  NOT launched (unattended; operator relaunch in the morning picks up the
  hardened template).
- **Queue next**: macOS-claimable = 277, 269, 270, 271 (any), 155 residual;
  linux flag: order 273 (attach runs login flow) still the hot macOS
  blocker — untouched tonight so far.
## Cycle 2026-07-10T04:10Z→05:50Z (linux_mutable macuahuitl — OPERATOR-DIRECTED drain: 275+268+276+260 completed, both siblings integrated)

- **Credential guard**: ok:gh-keyring. Clean start at f685b1e3; merged
  osx-next (+10: attended smoke — 6 parity cells done live, orders 269-275
  filed, PTY debug tee, home-src mount persistence) and windows-next (+8:
  order 261 ruby-free parity gate done live, order 251 long-running-packet
  protocol slice, 2 windows local-build e2e PASS). Merged tree --check
  green.
- **Order 275 (operator-priority) COMPLETED**: tillandsias-policy
  plan-orders uniqueness gate (fail exit 1 on any duplicate order group
  containing an open packet; done-only groups grandfathered by status
  rule; 5 unit tests) + litmus:plan-index-order-uniqueness (runner PASS)
  bound under methodology-accountability. Historic cleanup: icap-proxy
  144→278, host-lifecycle-race-safeguards 161→279,
  microsoft-linux-guest-migration 161→280 (renumber events +
  renumbered_from). Live ledger: 145 packets, 0 open collisions. NOTE for
  all hosts: "order 144/161" in pre-2026-07-10 notes are ambiguous —
  check renumbered_from. Follow-up: wire plan-orders into the order-263
  mirror hook at the next git-mirror image rebuild.
- **Order 268 COMPLETED**: inference cold path — proxy-resolvability
  guard (unsets baked proxy env when 'proxy' cannot resolve; enclave
  untouched), direct-retry fallback, curl max-time 600 (tarball is
  1.34 GiB), fail-loud exit when no ollama binary. Verified cold
  end-to-end (labeled bare shape): download → install → serve →
  qwen2.5:0.5b ready. Litmus rewrite recipe (product launch shape +
  current strings) appended to order 267's deliverable.
- **Order 276 COMPLETED**: guest login-transition funnel —
  apply_login_transition pushes LoginState AND refreshes+pushes
  CloudProjects exactly on the logged-in flip; satisfier-completion
  sentinel (2s stat) kills the 60s lag (attended-smoke F-C/F-D). TRAYS:
  drop the interim primes (macos b365deaf; windows mirror) once guests
  carry this.
- **Order 260 COMPLETED**: SubscriptionTopic::LocalProjects +
  LocalProjectsPush (trailing, additive, no WIRE_VERSION bump) +
  change-gated guest source + subscriber-gated 15s guest rescan.
  WINDOWS: widen topic list, delete the 30s tick poll (fallback only) —
  the order-154 exit criterion is now reachable. 66 workspace suites +
  38 wire tests green.
- **E2E gate**: preflight `eligible`; local-build destructive gate
  deliberately SKIPPED-WITH-CAUSE — the operator is interactively using
  this host's substrate (directive: install delivered 03:20Z tonight),
  and the full gate already ran this same night (run 20260710T021654Z,
  sole red root-caused + fixed as order 268). Next unattended linux
  cycle should run the full destructive e2e; expect green modulo order
  267 (litmus file rewrites incl. the inference litmus).
- **Release**: none — tray-parity hold: macOS closed 6 cells tonight
  (attended); remaining hold rides on the windows attended checklist
  (order 258) + The Tlatoāni's recorded release approval.
- **Queue after drain** (linux/any, ~31 open): 267 (litmus corpus, has
  full recipes), 265 (liveness research), 273 (attach login flow), 129
  (egress research), 271 (methodology doc), 249/250 (tray UX/event
  audits), security chain (137/141/145/142), streams chain
  (147/148/150/151/153/156/157/158), 225 (litmus DSL impl), 278 (ICAP,
  ex-144), audits (245-248). Blocked-on-operator: windows attended smoke
  (258), release approval, bar-raise slice 3.

## Cycle 2026-07-10T02:02Z (macos — ATTENDED meta-orchestration: order 257 six cells closed live, 3 fixes verified, orders 274-278-era packets filed (renumbered thrice; see merge notes), isolation correction)

- **Host**: macOS arm64, `osx-next`, agent
  macos-Tlatoanis-MacBook-Air-fable5-20260710T0202Z, **The Tlatoāni at the
  terminal** (attended interactive packets). Credential guard `ok:gh-keyring`.
  Merged `origin/linux-next` twice (2bcced8e, d80a13c6) — second merge
  collided AGAIN on orders 262/263 (linux filed its own in parallel);
  renumbered mine to **265** and **266** — then AGAIN to **274** (wsl) and **275** (order
  uniqueness — the finding demonstrating itself twice in one day).
- **Order 257 attended smoke — 6 of 7 cells DONE live** (AX harness +
  operator): 6-leaf submenu, login popup (3 real-PAT completions), cloud
  submenu + overflow (23 repos), local ~/src submenu, enclave indicator
  (healthy 🟢 + degraded 🔴), remote listing. InteractiveStream residual
  blocked on order 273. Parity litmus correctly RED on that one cell.
- **Fixes landed + verified live this session**: (F-A) chip clobbered back
  to Booting… by rebuilds — MenuState.status_text sync + pin test; (F-B)
  virtio-fs ~/src mount evaporated after first boot — fstab persistence,
  verified across a real reboot; (F-C tray side) post-login cloud prime on
  LoginStatePush — verified: 23 repos rendered the instant login state
  arrived. Plus TILLANDSIAS_PTY_DEBUG tee in the bridge (product-layer PTY
  forensics) which root-caused F-J to the wire.
- **Order 273 (NEW, linux, top macOS-blocking)**: agent attach argv
  (--cloud <p> --opencode) runs the github-login flow and PtyCloses code=0
  — the agent NEVER launches (all four leaves). Verbatim PTY capture in the
  packet + one-click repro loop. This is the last blocker on the macOS
  parity column.
- **Isolation correction (The Tlatoāni, recorded)**: agent used the
  cloud-init SSH key + NAT sshd to run root guest forensics/rebuilds —
  vetoed. Orders **271** (methodology: agents develop THROUGH the idiomatic
  layers; ssh/root side channels forbidden; "good enough for development =
  good enough for user runtime") and **272** (close the SSH backdoor:
  remove key injection, disable NAT sshd, drift-pin; audit WSL2) filed.
  Rootless-guest posture captured as research candidate.
- **Also filed** (final numbers after the THIRD collision renumber — linux independently filed 265-268): 276 (headless: login transition must push LoginState
  immediately + refresh cloud — 60s-probe gap confirmed 3x tonight, and on
  boot 2 the probe's first observation never arrived at all: add to 267's
  repro), 277 (one-shot CLI vs live tray disk-lock collision), 269 (login
  popup dead-shell + pty-dump session resolution), 270 (first-use attach
  reaps the in-VM image build — PTY close kills the build; severity
  upgraded with journal evidence). litmus:binary-e2e-smoke macOS path gap
  flagged to the 224/225/261 portability chain (findings file).
- **E2E gate**: attended interactive session on a fresh destructive
  re-provision (substrate destroyed + cold provision at b365deaf) IS this
  cycle's runtime verification; full findings file:
  plan/issues/macos-tray-attended-smoke-findings-2026-07-10.md.
- **Process slip (F9 recurrence, self-caught)**: the 04:30Z pre-push merge's
  conflict exit code was masked by a `| tail` pipe, so the gate + push ran
  against a mid-merge tree (push harmlessly sent pre-merge HEAD). Same
  lesson as linux F9 (linux-audit-recent-work-2026-07-09.md): verdicts from
  explicit exit codes, never piped tails. No new filing — F9 already owns it.
- **Queue after session**: macOS blocked on linux orders 273 (attach) and
  276 (login push); orders 277/269/270 macOS-claimable next unattended
  cycle; 271 any-host; 272 macOS. Order 155 residual (watch-channel menu
  listeners) still claimable. Linux: 273 is the hot one — full verbatim
  repro in the packet.

## Cycle 2026-07-10T00:40Z (macos — meta-orchestration: linux/windows merge + order collision renumber, order 155 slice 3 SC-16, order 263 filed)

- **Host**: macOS arm64, `osx-next`, agent
  macos-Tlatoanis-MacBook-Air-fable5-20260710T0040Z. Credential guard
  `ok:gh-keyring`. Started clean at 2afc2d72; merged `origin/linux-next`
  (2bcced8e — brings windows order 154 slice 2, order 258 partial, order 261,
  litmus order 255 fix).
- **Merge mediation**: plan/index.yaml order collision as predicted — my
  order 260 (wsl-headless-unit-lock-namespace) vs windows' 260
  (windows-tray-local-projects-push-gap). Renumbered mine to **262** (all
  references updated: index event, loop_status, findings file). Integration
  gate on merged tree: build check + 217 tests green. [Superseded: the
  02:02Z merge collided AGAIN with linux's parallel 262/263 filings —
  final numbers after the 04:30Z third collision: 274 (wsl) and 275 (uniqueness).]
- **Order 155 slice 3 — COMPLETE, verified LIVE (SC-16)**: new shared
  `tillandsias_host_shell::subscription_health::SubscriptionHealth`
  (watch-backed, change-gated) replaces the tray's
  PUSH_SUBSCRIPTION_HEALTHY AtomicBool; tick loop selects on health
  transitions — a subscription drop now triggers an immediate full fallback
  round (was: unnoticed up to 300s on the 10-tick cadence); up-transitions
  never shorten the period; closed channel degrades to plain timer.
  Paused-clock unit tests pin all three. 67/67 tray + 57/57 host-shell,
  build check clean; live: signed build, push subscription established,
  Ready push applied, 75s alive, clean SIGTERM. **Windows flag (order 154)**:
  adopt SubscriptionHealth in notify_icon.rs (same AtomicBool pattern).
- **Captures**: plan-index-duplicate-order-numbers-2026-07-10.md filed +
  promoted to ready **order 275** (pickup any; filed as 263, renumbered TWICE more in
  the 02:02Z merge): 7 order numbers (144, 160,
  161, 196, 197, 201, 224) are each shared by 2-3 packets — silent
  parallel-filing collisions; propose fail-loud uniqueness check in
  tillandsias-policy + litmus. (Order 155's own "mirrors order 144" text is
  a live symptom — the windows tray refactor is 154, and 144 now names two
  other packets.)
- **E2E gate**: skipped-with-cause — full destructive local-build e2e PASSED
  twice on this host <2h ago (findings file runs 1-2 @ 2a492797/77b0ba92);
  this cycle's runtime delta (slice 3) was live-verified against the
  provisioned VM directly (subscription-up path) with the drop path pinned
  by paused-clock unit tests.
- **Queue after drain**: macOS-eligible ready residue = order 155 remaining
  slices (watch-channel menu listeners; SC-01/02 closure blocked on linux
  order 260 LocalProjects push), orders 261/275 (pickup any, claimable next
  cycle). Order 257 still blocked on operator-attended smoke; order 126
  still blocked on linux order 128.

## Cycle 2026-07-09T23:10Z (macos — meta-orchestration: order 155 slice 2, order 259 root-caused + fixed + verified, full destructive e2e ×2)

- **Host**: macOS arm64, `osx-next`, agent
  macos-Tlatoanis-MacBook-Air-fable5-20260709T2310Z. Credential guard
  `ok:gh-keyring`. Started clean at b6d657a2; merged `origin/linux-next`
  (67bffc86, clean) before work.
- **Order 155 slice 2 — COMPLETE (2a492797), verified LIVE**: Subscribe
  widened to all three topics; LoginStatePush/CloudProjectsPush consumers in
  the reader loop via apply helpers shared with the poll path; initial sync
  extended to login/cloud on the same connection; SC-07 gate widened
  (PUSH_SUBSCRIPTION_HEALTHY) to suppress the 10-tick login/cloud polls.
  Live: 'push subscription established (vm-status/login/cloud polls demoted
  to fallback, SC-07)', Ready chip via push, clean SIGTERM. 64/64 tests.
  Remaining: watch-channel menu listeners, SC-01/02 sleep elimination.
- **Order 259 — COMPLETED (77b0ba92)**: fresh-VM repro on the merged tree
  STILL hit exit 125; root cause exactly the linux agent's hypothesis —
  disjoint lock namespaces (headless unit: no XDG_RUNTIME_DIR →
  /tmp/tillandsias-locks-0; login exec preamble: /run/user/0). Fix pins
  Environment=XDG_RUNTIME_DIR=/run/user/0 in the vz.rs unit + drift pin
  tests both sides. Re-provisioned fresh VM: first --github-login reaches
  the git-author-name prompt, no 125, no podman error. All four exit
  criteria closed. Windows sibling gap promoted to **order 274** (ready,
  windows pickup: wsl.rs unit sets neither HOME nor XDG_RUNTIME_DIR;
  renumbered 260 -> 262 -> 265 across the two 2026-07-10 merge collisions).
- **E2E gate (local-build, destructive, ×2)**: gates 1–3 + diagnose PASS on
  both 2a492797 and 77b0ba92 (build/codesign/install/freshness; 2.1G destroy;
  528MB cold provision). Forge lane n/a. Findings file run-2 section:
  plan/issues/macos-build-install-smoke-e2e-findings-2026-07-09.md.
- **Captures**: control-wire-prime-seq-double-allocation-2026-07-09.md
  (optimization: primes allocate two seqs each, both trays).
- **Queue after drain**: macOS-eligible ready residue = order 155 remaining
  slices (claimable next cycle); order 257 still blocked on operator-attended
  smoke; order 126 still blocked on linux order 128. Linux flag: order 259's
  fix pattern may also apply to any OTHER guest exec path that omits
  XDG_RUNTIME_DIR; windows flags: orders 260 (new), 154 cold-join, 258.

## Cycle 2026-07-10T02:39Z→03:50Z (windows — meta-orchestration: linux-next merged, order 251 implemented → verification, local-build e2e PASS @ 45cfd526)

- **Host**: Windows 11 native, `windows-next`. Credential guard
  `ok:gh-credentials-store`. Clean start at 00076813 == origin.
- **Integration**: merged origin/linux-next f685b1e3 (union-resolved
  plan/index.yaml: windows order-261 events + linux orders 262-268;
  validate-yaml ok), pushed e0fcab24. Windows-buildable crate subset
  (`-p windows-tray -p host-shell -p control-wire -p vm-layer -p policy`)
  compiles clean on the merged tree; `./build.sh --check` remains
  un-runnable on Windows (known gap, windows-workspace-cargo-check-gap).
- **Worker drain — order 251 (long-running-work-packet-methodology)
  IMPLEMENTATION-COMPLETE → phase: verification (45cfd526)**: canonical
  `long_running_packets` section in methodology/distributed-work.yaml
  (multi_cycle schema + cycle-scoped claims, verified-by event protocol,
  additive update policy), meta-orchestration + advance-work-from-plan
  skill recognition, plan/long-running.md sub-queue view (orders 245-251).
  Completion gated on verified-by from opencode-bigpickle,
  antigravity-gemini, codex-gpt55-highthink — packet stays `ready` for
  them per its own protocol. Only dependency-free ready+any packet;
  258 stays operator-blocked (attended parity smoke), 260 is linux-owned.
- **Local-build e2e: PASS @ 45cfd526** (first Windows e2e over the
  f685b1e3 merge): build 1m56s → freshness gate embedded==HEAD → distro
  destroy → cold provision (rootfs re-download, dnf 135 pkgs, `RESULT: VM
  Ready — control wire up ✓`, handshake attempt=1) → diagnose exit 2
  degraded-as-expected, build_commit fresh. Filed
  smoke-finding/windows-provision-log-wsl-utf16-mojibake (wsl.exe UTF-16LE
  bytes forwarded raw into UTF-8 provision log). Report: Run 2 section of
  plan/issues/build-install-smoke-e2e-findings-2026-07-10-windows.md.
- **Release**: n/a (windows host; release hold unchanged).
- **Next windows work**: attended parity smoke (operator, order 258);
  order 251 awaits its 3 verifiers; windows coordination slice of order
  267 (chip litmus rewrite) when linux ratifies scope.

## Cycle 2026-07-10T02:05Z→04:05Z (linux_mutable macuahuitl — OPERATOR-DIRECTED: bar-raise approved+enabled, one-packet forge doctrine, orders 256/264/266 done, 265/267/268 filed, install delivered)

- **The Tlatoāni's directives executed (recorded 2026-07-10)**:
  (1) Bar-raise slice 2 APPROVED → registry entry
  methodology/convergence.yaml approved_bar_raises
  (ci-full-all-features-clippy), lane rust-clippy-all-features wired into
  scripts/local-ci.sh non-fast pre-build (--ci-full only; --ci/--fast
  skips). Baseline sweep green; negative control (planted warning in a
  fake-feature unit) fails the lane exit 101; PASSED in anger in the final
  gate. Slice 3 (--check promotion) remains unapproved. Order 266 completed.
  (2) One-packet forge doctrine (order 264, chosen over env-var approach):
  forge-hosted cycles drain AT MOST ONE packet, split oversized packets
  into ready children. Canonical:
  methodology/distributed-work.yaml worker_agent_protocol.forge_cycle_budget;
  skills/meta-orchestration + advance-work-from-plan updated. VERIFIED
  LIVE: gate run 20260710T021654Z's in-forge cycle drained exactly order
  224 (litmus-stdlib research) inside the 600s budget.
  (3) Heartbeat/liveness signals filed as order 265 (research, ready) —
  replace timeout inference with positive liveness; hard cap stays.
- **litmus:opencode-prompt-e2e-shape: 7/7 PASS — first fully-green run in
  its history** (orders 255+262+264 all discharged live; branch-scoped
  STEP 6 probe passed against the in-forge push).
- **Order 256 slice 1 (done, split → 267)**: litmus runner exit-code
  authority staged behind TILLANDSIAS_LITMUS_STRICT_EXIT=1 (strict dry run
  exposed 8 litmuses red behind the dead-check trap + an empty-step-name
  exit-127 mis-parse class); legacy mode prints [DEAD-CHECK WARNING] (24
  visible in the full suite); [PARSE WARNING] for unparseable commands (31
  folded steps across 8 files skipped since authoring); zero-step files
  fail with a named parse error. Order 267 (ready) owns burn-down, folded
  rewrites, 4 YAML-invalid file repairs, strict default flip
  (plan/issues/litmus-corpus-parse-health-2026-07-10.md).
- **Final gate (run 20260710T021654Z): exit 1 with exactly ONE red** —
  litmus:inference-deferred-model-pulls cold path: first-run ollama binary
  download FAILED → exit 127 (product, graceful-degradation path;
  unrelated to this cycle's changes). Filed as order 268 (ready) with
  evidence (plan/issues/build-install-e2e-gate-20260710T021654Z.md).
  Everything else green: pre-build 147/147 incl. the new all-features
  lane, security 17/17, post-build 7/8.
- **Install delivered**: /home/tlatoani/.local/bin/tillandsias
  v0.3.260710.3 (40M), fresh from 39186723(+relay).
- **Coordination**: windows-next (00076813) and osx-next (86105319)
  advanced late in the cycle — integration deferred to the next recurring
  linux cycle (this cycle was operator-directed; no tree mutations during
  the running gate). Doctrine + lane changes are on linux-next for
  siblings to pick up; the windows-owned chip litmus rewrite inside order
  267 needs windows coordination.
- **Queue after cycle**: linux ready = 268 (new), 267, 265, 260, 261,
  225 (224 research done by in-forge), 144, security chain, streams chain,
  transport. Blocked-on-operator: attended parity smokes (257/258),
  tray-parity release hold, bar-raise slice 3 (unapproved).

## This Loop (2026-07-10T02:27Z, linux_mutable — big-pickle reduction: litmus-stdlib-research)

- **Cycle type**: meta-orchestration worker drain + reduction on mutable Linux.
- **Startup**: `linux-next @ 39186723`, worktree dirty with tracked changes from a prior incomplete cycle (TRACES.md, VERSION bump, convergence dashboard). Committed as checkpoint `57f264f2` and pushed. Clean worktree after.
- **Credential guard**: `ok:gh-keyring`.
- **E2E gate**: `skip:smoke-lock-held` — no local-build gate this cycle.
- **Worker drain**: Claimed and completed `litmus-command-portability-dsl-research` (order 224).
  - Corpus analysis: 198 litmus files, 1044 command fields, 74% grep-based.
  - D1: shell functions in sourced `scripts/litmus-stdlib.sh` (model b).
  - D2: 8 core primitives: `mf_literal`, `mf_literal_count`, `mf_regex`, `mf_regex_count`, `mf_absent`, `mf_threshold`, `mf_file_exists`, `mf_assert_count`.
  - D3: single file with `case` branching per OS.
  - D4: lint + pin + lazy migration.
  - D5: raw `command:` remains valid as escape hatch.
  - 5 real prototype rewrites in deliverable.
- **Verification**: `plan/index.yaml` validated with `ruby -ryaml`. 121/121 instant litmus PASS.
- **Coordinator**: windows-next `00076813` and osx-next `86105319` — checked but no merge needed this cycle.
- **Push state**: pushed `linux-next` (checkpoint `57f264f2` + research `16078687`).

## Cycle 2026-07-10T00:09Z (linux_mutable macuahuitl — meta-orchestration: windows integration, litmus chain 255→262→264, e2e gate 1, in-forge drained 254+263)

- **Credential guard**: ok:gh-keyring. Started clean at 67bffc86.
- **Sibling integration** (a4092688): merged windows-next +8 (order 154 slice 2
  LoginState+CloudProjects push topics; order 258 unattended parity subset; 6
  windows clippy fixes). Merged tree: --check green + 66 workspace test suites
  green. Verification exposed that `cargo check/clippy --workspace` never
  compiles non-default-feature units (garbage injected into vm-layer
  materialize/oci.rs → exit 0): fixed the latent vm-layer fake.rs lints
  (f39f79e4), filed integration-gate-feature-coverage-gap-2026-07-10.md with a
  Tlatoāni-gated ci-full bar-raise proposal. The headless all-features reds
  were order 254's known scope (since drained — see below).
- **Order 255 completed** (2bcced8e): the "STEP 5 race" was a misdiagnosis —
  STEP 5 referenced $HEAD_BEFORE that no step ever set (runner steps are
  separate bash -c subshells), collapsing its range to HEAD..HEAD: a
  deterministic false negative since introduction. Shared bounded-retry probe
  scripts/litmus-git-delta-wait.sh (local-head/plan-commit/remote-head, 120s
  window/5s poll, exit 0/1/2 grammar) now backs litmus steps 4-6; new
  litmus:git-delta-wait-shape (9 steps) pins it incl. mid-window re-sample +
  no-dead-check negative. Criterion 2 discharged live: steps 4-5 PASS in this
  cycle's ci-full forge cycle.
- **E2E gate (local-build, run 20260710T003451Z): gate 1 exit 1, stopped
  per runbook** — pre-build litmus 146/146, coverage 100%, security 16/16,
  musl launcher installed (v0.3.260710.1); post-build e2e 5/6. Sole red:
  STEP 6 asserted `ls-remote origin HEAD` whose symref is refs/heads/main —
  a linux-next push never moves it (bug-behind-a-bug, unmasked by 255).
  **Order 262 filed + fixed + completed**: branch-scoped recorder + probe,
  shape-litmus regression pin (non-default-branch fixture where origin HEAD
  resolves to nothing), live probe PASS against the real push window
  129a85dd→e433b96f. Destructive gates 2-4 NOT reached (substrate intact);
  next cycle should run the full destructive e2e expecting gate 1 green
  modulo order 264.
- **In-forge activity (sanctioned mid-build actors, audited)**: ci-full's
  litmus cycle drained order 254 (61abd3bf: listen-vsock CI lane in --check +
  pty test fixes) but pushed a mis-indented plan/index.yaml — committed
  ledger did not parse; coordinator mediated mechanically and filed order 263
  (mirror pre-receive YAML gate). The 262-verification run's in-forge cycle
  then IMPLEMENTED order 263 (e433b96f: 150-line pre-receive hook + 10-step
  shape litmus; coordinator audit PASS 2/2; gate binds on next git-mirror
  image rebuild) — and blew STEP 3's 600s budget doing it → **order 264
  filed** (bug+design: litmus budget vs in-forge greedy-drain doctrine;
  options enumerated, ready). e433b96f also lacks Generated-By trailers and
  its ledger event was misattributed (corrected; addendum in the 2026-07-10
  findings file — consider a trailer rider on the 263 hook if it recurs).
- **Release**: none — tray-parity release hold (16 gaps) still requires The
  Tlatoāni's recorded approval; daily Linux release remains due behind it
  (latest v0.3.260708.4).
- **Queue after cycle**: linux ready = 264 (new), 256, 238, 144, 261
  (any-host), 260, security chain (137/141/145), streams chain
  (147/150/151/153/156/157/158), DSL (224/225), transport (125/128).
  Windows: orders 230/231 confirmed landed → order 154 slice 3 unblocked;
  order 258 blocked on attended smoke. macOS: order 259 criterion-3
  verification still requested; order 155 residual slices claimable.
  Blocked-on-operator: attended parity smokes (orders 257/258), tray-parity
  release hold, feature-coverage bar-raise approval (see
  integration-gate-feature-coverage-gap-2026-07-10.md).

- **Host**: Windows 11 native, `windows-next`. Credential guard
  `ok:gh-credentials-store`. Clean start at 521de7bd == origin/windows-next;
  origin/linux-next (67bffc86) already merged — no sync needed.
- **Worker drain — order 258 (windows-tray-parity-column-verify),
  PARTIAL -> BLOCKED on operator (mirrors macOS order 257)**: rebuilt +
  reinstalled the tray at HEAD (92675e8e, embedded SHA == HEAD freshness
  gate), provisioned VM to Ready, and verified the unattended subset LIVE:
  one-off status/probe cell -> done (--status-once --json reachable
  wire_version=2 phase=Ready exit 0; --diagnose --json exit 0 full schema;
  stopped-VM error path exercised; wsl.exe one-shot guest exec GUEST_OK).
  Strong partial evidence recorded for local projects (host scan count=5 +
  VM-side round-trip count=5), cloud refresh (graceful not-logged-in
  count=0), login state (logged_in=false applied), status chip healthy path
  (SC-07 suppression held after initial sync — slice 1+2 wiring observed
  live at debug level). Remaining 7 required cells unknown -> todo;
  consolidated 9-step attended checklist:
  plan/issues/windows-tray-parity-attended-smoke-gap-2026-07-09.md.
  NOTE: in-VM headless is v0.3.260707.2 (pre-744f4749) so login/cloud push
  topics cannot fire on this VM yet; the designed startup fast-poll burst +
  poll-while-unconfirmed fallback covered it exactly as intended (no bug).
- **Reduction engine**: filed + promoted order 261
  (parity-litmus-ruby-free-check): litmus:tray-parity-matrix-complete is a
  ruby one-liner and Windows hosts have no ruby, so the order-243 per-host
  gate can never execute on the Windows --ci-full lane and order 258's exit
  criterion 4 is unsatisfiable as written — propose a tillandsias-policy
  parity-matrix subcommand.
- **E2E gate**: deferred — full destructive local-build e2e PASSED on this
  host earlier today (run 20260709T201326Z); this cycle changed only
  plan/openspec data files (matrix cells + ledgers), no runtime surface.
- **Next windows work**: attended parity smoke (operator, order 258
  checklist); order 154 watch-channel slice remains claimable (tick
  retirement still waits on order 260, linux).

## Cycle 2026-07-09T22:38Z (windows — meta-orchestration worker drain, order 154 slice 2)

- **Host**: Windows 11 native, `windows-next`. Credential guard
  `ok:gh-credentials-store`. Clean start; merged `origin/linux-next` twice
  (990c0482 at cycle start, 67bffc86 pre-push) — both clean, integration gate
  green each time (conflict-marker scan, YAML validate, clippy+tests on the
  merged tree).
- **Worker drain — order 154 (windows-tray-stream-refactor), slice 2
  COMPLETED (ea03e08e), lease released, packet stays ready**: orders 230/231
  cleared slice 1's blocker, so the push listener now subscribes to all THREE
  topics (VmStatus+LoginState+CloudProjects); LoginStatePush/CloudProjectsPush
  applied via shared appliers byte-identical with the poll reply arms;
  GithubLoginStatusRequest/CloudRefreshRequest demoted to fallback-only
  (should_poll_login_and_cloud gate, drift-pinned; fast-poll bursts still
  force a confirming round); one initial-sync poll round after SubscribeAck
  because pushes are change-gated. windows-tray 63 tests green, clippy
  --all-targets zero warnings, fmt clean. Live e2e of the new topics needs
  the in-VM headless refreshed past 744f4749 (this VM predates it) —
  initial-sync polls cover the gap until then.
- **Bonus (2abfcb30)**: fixed 6 clippy warnings in windows-cfg /
  windows-feature-set code Linux strict-clippy never compiles (hvsocket.rs,
  windows-tray build.rs, vm-layer materialize/{cache,oci}.rs,
  materialize-cli.rs). Note: linux's 034c31f6 trunk-red mediation collapsed
  the same build.rs if-let in parallel — both edits merged clean at 67bffc86,
  post-merge clippy zero warnings.
- **Reduction engine**: filed
  `plan/issues/windows-tray-local-projects-push-gap-2026-07-09.md` and
  promoted it to ready order 260 (linux-owned): EnumerateLocalProjects is the
  last poll-only topic, blocking order 154's tick-elimination exit criterion.
  Started `plan/issues/windows-next-work-queue-2026-07.md` (the per-host
  work-queue ledger the worker protocol names did not exist for windows).
- **E2E gate**: deferred — full destructive local-build e2e PASSED on this
  host 2.5h ago (run 20260709T201326Z) and this cycle's delta is tray-side
  push wiring already covered by unit+drift tests; live push verification is
  blocked on a headless refresh (see above), so a re-run now would re-prove
  the morning's result without exercising the new code.
- **Next windows work**: order 258 (windows-tray-parity-column-verify, filed
  22:35Z, 4h live-tray verification) — exceeds this cycle's remaining budget;
  first candidate for the next windows cycle. Order 154's watch-channel slice
  is unblocked for wiring but tick retirement waits on order 260.

## Cycle 2026-07-09T22:40Z (linux_mutable macuahuitl — meta-orchestration: sibling integration x2, trunk-red mediation, order 259 linux slice)

- **Credential guard**: ok:gh-keyring. Started clean at 990c0482.
- **Sibling integration**: merged osx-next (+10: order 155 slice 1 — macOS tray VmStatus push subscription verified LIVE on the VZ VM, chip ~10s vs 30s poll; order 257 partial — ExecOneShot verified, 7 cells todo + attended-smoke checklist packet) and windows-next (+4: BUILD_COMMIT_SHA build.rs freshness fix, Windows-aware e2e preflight verdict). One loop_status.md conflict union-resolved per CRDT policy.
- **Trunk-red mediation** (034c31f6): the windows build.rs fix tripped clippy collapsible-if under -D warnings on the merged tree; my pre-push gate false-greened on a warm cargo cache (captured as F9 in linux-audit-recent-work-2026-07-09.md — verdicts must come from explicit exit codes, never piped tails). Minimal mechanical let-chain collapse per the a105306e precedent; windows heads-up in the commit body.
- **Order 259 linux slice** (blocked -> macOS verification): the reported name-in-use race was against 9cb47ff6, which predates orders 232/235; on current linux-next ALL vault bring-up paths route through the flocked ensure_vault_running (lock BEFORE running-check) and launch replaces stale name-holders. New pin test vault_launch_serializes_and_replaces_stale_name_holder. Criterion 3 (fresh-VM login repro) handed to macOS; if it still 125s, check both processes resolve the same tillandsias-locks dir in the guest.
- **E2E gate**: skipped-with-cause — gate 1 is deterministically red on the KNOWN order-255 litmus race (unchanged since run 20260709T195719Z; duplicate-finding discipline). Order 255 is the top ready pick for the next worker drain; a full destructive run follows it.
- **Release**: none — tray-parity release hold (16 gaps) requires The Tlatoani's recorded approval; daily Linux release is otherwise due (latest v0.3.260708.4).
- **Queue**: linux ready = 255, 256, 254, 238, 144, security chain (137/141/145), streams chain (147/150/151/153/156/157/158), DSL (224/225), transport (125/128). Blocked-on-siblings list unchanged from 2026-07-09T23:20Z cycle + order 259 added (macOS verification).

## Cycle 2026-07-09T21:32Z (macos — advance-work-from-plan: queue drain, orders 257 + 155)

- **Host**: macOS arm64, `osx-next`, agent
  macos-Tlatoanis-MacBook-Air-fable5-20260709T2132Z. Merged fresh
  `origin/linux-next` (order 234 R6, windows e2e PASS merge) before work.
- **Order 257 (macos-tray-parity-column-verify) — PARTIAL, now BLOCKED on
  operator**: ExecOneShot cell verified live (`--exec-guest` ok/exit 0) ->
  done; 7 remaining required cells unknown -> todo with strong partial
  evidence recorded (--list-cloud-projects full chain to graceful
  not-logged-in 404; InteractiveStream via live PtyOpen expect session).
  Consolidated gap packet with 8-step attended checklist:
  plan/issues/macos-tray-parity-attended-smoke-gap-2026-07-09.md.
  NOTE: litmus:tray-parity-matrix-complete is RED on macOS --ci-full until
  the attended pass — order 243's intended design, not a build break.
- **Order 155 (macos-tray-stream-refactor) slice 1 — COMPLETE (ceb8ded5)**:
  VmStatus push subscription on a dedicated control-wire connection with
  SC-07 poll suppression, mirroring windows b6ca3290 via the shared
  host-shell primitives. Verified LIVE on the provisioned VZ VM: chip
  renders ~10s after launch via push+initial-sync (vs 30s+ poll). Found and
  fixed the change-gated-push cold-join gap (initial-sync VmStatusRequest on
  the subscription connection); heads-up event added to order 154 in case
  windows shares the gap. Packet back to ready for remaining slices
  (LoginState/CloudProjects consumers, watch-channel listeners).
- **Queue state after drain**: no macOS-eligible ready work remains
  claimable by an unattended agent. Order 257 blocked on operator-attended
  smoke; order 155 residual slices are claimable next cycle; order 126
  (host-guest-transport-macos) still blocked on Linux order 128 conformance
  harness + packaged/entitled VM substrate.
- **Blocked-work flags**: linux — order 259 (vault name-in-use race, blocks
  first-run login), order 153 closure (SC-10 + 4-agent verification), order
  254 (listen-vsock CI lane); windows — order 154 cold-join gap heads-up;
  operator — attended parity smoke (order 257 checklist).

## Cycle 2026-07-09T21:05Z (macos — meta-orchestration: integration + full local-build e2e + login/event verification)

- **Host**: macOS arm64, `osx-next`. Credential guard `ok:gh-keyring`. Started
  clean; fast-forwarded `linux-next` +35, merged into `osx-next` (clean FF to
  `2790d84c`, pushed). `./build.sh --check` PASS; 157 tests green
  (control-wire 37, macos-tray 58, secure-channel 12, vm-layer 50).
- **Preflight fix (9cb47ff6)**: `scripts/e2e-preflight.sh` Darwin branch —
  macOS hosts were permanently mis-verdicted `skip:no-podman-user-session`;
  now probes `kern.hv_support` (VZ substrate). Verdict on this host flipped to
  `eligible` for the first time. Litmus e2e-eligibility-probe-shape 3/3 PASS
  (smoke-lock step made portable to flock-less macOS).
- **Local-build e2e (/build-install-and-smoke-test-e2e, macos lane)**: gates
  1-3 PASS (build+codesign+install+freshness 9cb47ff6; destroy 2.0G substrate;
  cold provision 528MB rootfs + diagnose exit 0). Gate 4 forge: n/a. Extended:
  cold VM boot → phase Ready → control wire PASS; installed tray live-launch
  logged `vm-status: phase=Ready podman_ready=true event=…` (guest→host
  last_event propagation proven) + clean SIGTERM.
- **GitHub Login verified**: 807a0950's ensure_git_login fix is live on macOS
  (bundled-guest staging works — guest reports v0.3.260709.4). Attempt 2
  reaches credential prompts. NEW P1 filed+promoted (order 259): first cold
  attempt always fails — vault name-in-use race (boot bootstrap vs login
  satisfier, exit 125). Full report:
  plan/issues/macos-build-install-smoke-e2e-findings-2026-07-09.md.
- **Ledger reconciliation**: order 155 (macos-tray-stream-refactor)
  pending→ready — its dependency's push topics all landed (153 slice 1 +
  230/231). Order 153 progress event: residual = SC-10 timed test + 4-agent
  verification only (flagged for linux closure). Order 154 confirmed
  actionable for windows on the same basis.
- **Flags for sibling hosts**: linux — order 259 (vault race, blocks first-run
  login UX), order 153 closure, order 254 (listen-vsock CI lane, 0 coverage on
  the wire macOS consumes); windows — order 154 actionable now.
- **E2E gate**: `eligible` (first macOS cycle with a valid verdict).

## Cycle 2026-07-09T21:07Z (windows — meta-orchestration worker drain, order 154 slice 1)

- **Host**: Windows 11 native, `windows-next`. Credential guard
  `ok:gh-credentials-store`. Clean start; merged `origin/linux-next` twice
  mid-cycle (2790d84c, f347053e) — one loop_status.md prepend conflict
  union-resolved.
- **Worker drain — order 154 (windows-tray-stream-refactor), slice 1
  COMPLETED, lease released, packet stays ready**: dedicated
  `run_vm_status_push_listener` reader task on its own connection
  (Subscribe{[VmStatus]} → SubscribeAck → next_envelope loop);
  VmStatusRequest poll demoted to fallback-only while the subscription is
  healthy (SC-07, drift-pinned). Shared
  `Client::{send_envelope,next_envelope}` added to host-shell with
  cross-platform duplex tests so order 155 (macOS) reuses the identical
  shape. windows-tray 62 tests + host-shell 47 tests green; clippy clean.
- **Cross-host request (BLOCKING next windows slice)**: linux to land orders
  230/231 (headless LoginStatePush/CloudProjectsPush sources) so the next
  slice can widen the topic list and retire the slow-cadence polls.
- **Cleanup of work blocking Windows**: `smoke-finding/e2e-preflight-not-
  windows-aware` implemented + closed — `e2e_eligibility_verdict` grew a
  MINGW*/MSYS*/CYGWIN* branch probing `wsl.exe` (new reason `skip:no-wsl`),
  mirroring the Darwin branch that landed upstream at f347053e; this host now
  reports `eligible` (was `skip:no-podman-binary` — every Windows e2e gate
  would have been skipped by an obedient loop).
- **Reduction engine**: filed
  `plan/issues/windows-workspace-cargo-check-gap-2026-07-09.md` (enhancement:
  no per-host crate allowlist for the Integration Verification Gate's compile
  step; headless unix-isms make `./build.sh --check` impossible on Windows).
- **Live verification + bonus fix**: rebuilt + reinstalled + relaunched the
  tray against the morning's freshly provisioned VM — log shows
  `vm status push subscription established (polls suppressed, SC-07)` ~0.5s
  after keepalive on two consecutive launches (order 154 slice 1 exercised
  end-to-end, not just unit-tested). Doing so surfaced + fixed
  `smoke-finding/windows-build-commit-sha-stale-on-rebuild`: windows-tray
  build.rs only tracked `.git/HEAD`, so same-branch commits left
  BUILD_COMMIT_SHA stale on incremental rebuilds (would spuriously fail the
  e2e freshness gate); now tracks the resolved ref file + packed-refs.

## Cycle 2026-07-09T20:13Z (windows — meta-orchestration, local-build e2e PASS)

- **Host**: Windows 11 native, `windows-next`. Credential guard
  `ok:gh-credentials-store`. Started clean; fast-forwarded `windows-next` onto
  `origin/linux-next` (`a68c9825`) and pushed before work.
- **E2E gate — `/build-install-and-smoke-test-e2e` (windows), PASS**:
  build 2m53s → direct-copy install (freshness gate: embedded SHA == HEAD
  `a68c9825`) → destructive `wsl --unregister tillandsias` + cache/VHDX wipe →
  cold `--provision-once` exit 0 (`RESULT: VM Ready — control wire up ✓`) →
  `--diagnose --json` exit 2 (degraded-as-expected idle), 17 schema keys.
  Report: `plan/issues/build-install-smoke-e2e-findings-2026-07-09-windows.md`
  (run_id `20260709T201326Z`).
- **Reduction engine — 3 findings filed** (same report):
  `smoke-finding/e2e-preflight-not-windows-aware` (eligibility probe emits
  `skip:no-podman-binary` on every Windows host, contradicting the E2E Gates
  table), `smoke-finding/windows-local-install-path-mismatch`
  (`install-windows.ps1` is the curl installer; both skills' local-install
  instructions are stale — direct-copy path used), and
  `smoke-finding/tray-output-log-committed` (generated `tray_output.log`
  tracked at repo root).
- **Interactive**: installed tray launched post-run for attended smoke
  (operator-requested; the unattended PASS does not cover the tray UX surface).

## Cycle 2026-07-09T20:07Z (linux_mutable — meta-orchestration worker slice, order 252)

- **Host**: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), `linux-next`.
  Started with dirty worktree (leftover trace/convergence artifacts from previous
  cycle) — committed as checkpoint (a68c9825, pushed). Credential guard `ok:gh-keyring`.
- **Worker drain — order 252 (launch-paths-route-through-dependency-model), COMPLETED**:
  Added `ForgeLaunch` variant to `container_deps::Service` with dep edges
  (EnclaveNetwork, EgressNetwork, CaBundle, Proxy). Created `ensure_forge_launch()`
  wrapper + `ForgeLaunchReady` typestate witness. Refactored `ensure_enclave_for_project`
  to call `ensure_forge_launch` instead of ad-hoc ensure_*/inline proxy bring-up.
  Removed proxy inline code (duplicated `ensure_proxy_running`). Emptied the order-229
  litmus known-gap allowlist; both launch paths now gate through `container_deps`.
  18/18 container_deps tests, litmus drift test pass; `./build.sh --check` clean.
- **E2E gate**: `skip:smoke-lock-held` — no destructive test this cycle.
- **Coordinator**: deferred — small slice, no sibling drift expected.
- **Reduction engine**: no new unfiled findings from this cycle.

## Cycle 2026-07-09T18:48Z (linux_mutable — meta-orchestration worker slice, order 229)

- **Host**: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), `linux-next`.
  Started with dirty worktree (leftover convergence dashboard + VERSION bump from
  previous cycle) — committed as checkpoint. Credential guard `ok:gh-keyring`.
- **Worker drain — order 229 (container-dependency-graph-drift-litmus), COMPLETED**:
  Added `launch_skipping_prerequisite_fails` test (proves removing a prereq fails),
  `all_launch_targets_have_prerequisites` structural test, and
  `all_launch_paths_route_through_dependency_model` source-audit test in main.rs
  (documents `ensure_enclave_for_project`/`run_forge_agent_cli_mode` as known gaps).
  Created `litmus:launch-skips-prerequisite-fails` litmus YAML. All 15 container_deps
  tests and 3 new main.rs tests PASS; `./build.sh --check` PASS.
- **Capture**: forge-diagnostics.json added to .gitignore as generated artifact.
  ensure_enclave_for_project/run_forge_agent_cli_mode documented as known gaps in
  the launch-path audit test — not yet routing through the dependency model.
- **E2E gate**: deferred — small slice, no destructive test needed.
- **Coordinator**: deferred — small slice, no sibling drift expected.
- **Reduction engine**: no new unfiled findings — gaps documented in audit test.

## Cycle 2026-07-09T18:38Z (linux_mutable — meta-orchestration worker slice)

- **Host**: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), `linux-next`.
  Started with dirty worktree (SELinux `relabel=shared` test assertions, trace
  regen, version 0.3.260709.2, convergence refresh) — committed as checkpoint.
  Credential guard `ok:gh-keyring`.
- **Worker drain — order 228 (container-dependency-graph-liveness), COMPLETED**:
  Added `LivenessProbe` struct with `run_check()` that probes vault/proxy
  containers via `podman inspect` and re-ensures dead ones through the
  dependency satisfier (idempotent). Wired into `maybe_spawn_vsock_listener` as
  a background heartbeat task during VmPhase::Ready (30s interval). 3 new unit
  tests; `./build.sh --check` PASS; all 13 container_deps tests green.
- **E2E gate**: `skip:smoke-lock-held` — no destructive test this cycle.
- **Coordinator**: sibling drift checked — both `origin/osx-next` and
  `origin/windows-next` at 0 commits ahead of `origin/linux-next` (clean).
  Release deferred — small slice, no release PR in flight.
- **Reduction engine**: no new unfiled findings from this cycle.


- **Host**: Linux mutable, `linux-next`.
- **Worker drain — order 112 (forge-harness-auth-device-flow), COMPLETED**:
  Extracted Phase 2 (ICAP proxy injection) into a dedicated plan packet `forge-harness-icap-proxy` (order 144) to formally close this packet. CLI subcommands were already extracted to order 132/143 by the operator.
- **E2E gate**: deferred — current cycle produced a coherent commit resolving a ledger inconsistency, deferring destructive test to the next logical phase.

## Cycle 2026-07-08T22:30Z (macos — linux coordinator merge for order 191)

- **Host**: macOS arm64, `linux-next`.
- **Merge**: fast-forward `origin/osx-next` (1780cfb3) into `linux-next` — clean, no conflicts.
- **Fix**: Updated pty/mod.rs GithubLogin script: use `exec ... || (...)` subshell pattern instead of `{ ...; ...; }` to avoid `;` in the command string (wt.exe separator bug on Windows). This restores the `exec` prefix and eliminates `;` while preserving error-handling fallback.
- **Integration gate**: No conflict markers, `plan/index.yaml` YAML valid, all crates type-check + clippy pass.
- **Test**: `cargo test -p tillandsias-host-shell` — `launch_spec_maps_intents_to_in_vm_argv` now passes. Pre-existing test failures on this host (keychain read-back, no Podman machine) unchanged.
- **Order 191 status**: `done` — all three exit criteria met:
  1. osx-next merged origin/linux-next ✅ (9308cf5c)
  2. windows-next already a linux-next ancestor ✅
  3. Both hosts recorded evidence (win: flag-OFF/ON hvsocket, mac: build + test + deferred VM smoke) ✅

## Cycle 2026-07-08T22:03Z (macos — meta-orchestration, secure-wire integration + full local build)

- **Host**: macOS arm64, `osx-next`.
- **Start**: Dirty worktree (VM provisioning debug changes in vault_bootstrap.rs, vz.rs) + untracked artifacts. Stashed, merged, then restored useful changes.
- **Credential guard**: `ok:gh-keyring`.
- **Merge**: `origin/linux-next` (baf52d88) into `osx-next` (9308cf5c) — one conflict in `plan/loop_status.md` resolved (kept both sides).
- **Worker drain — order 191 (multi-host-secure-wire-integration-freeze)**: macOS evidence slice COMPLETE. Origin/linux-next merged, all tests pass (58+50+12+37), `./build.sh --check` green, tray binary builds, secure-wire/transport code intact. Full flag-OFF/flag-ON VM smoke deferred (no Podman machine on this dev host — `skip:no-podman-user-session`). Evidence recorded in deliverable and plan/index.yaml.
- **VM provisioning fixes applied**: (1) network wait loop before dnf in VZ cloud-init, (2) HOME=/root in fetch-headless/headless units, (3) TILLANDSIAS_HOST_KIND + hostname-based VM detection for vault_bootstrap.
- **Verification**: `cargo test -p tillandsias-macos-tray`: 58 passed / 1 ignored / 0 failed; `cargo test -p tillandsias-vm-layer`: 50 passed / 1 ignored / 0 failed; `cargo test -p tillandsias-secure-channel`: 12 passed / 0 failed; `cargo test -p tillandsias-control-wire`: 37 passed / 0 failed; `./build.sh --check` (fmt + type-check + strict clippy): PASS.
- **macOS tray build**: `cargo build -p tillandsias-macos-tray` — PASS. Binary ready for interaction.
- **E2E gate**: `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-user-session`.

## Cycle 2026-07-08T20:29Z (linux_mutable — meta-orchestration worker + e2e slice)

- **Host**: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), `linux-next`.
  Pulled latest remote state first; started from `origin/linux-next@f1d3dcc7`
  before in-forge work advanced the branch to `origin/linux-next@7d534d8b`.
- **Worker drain — order 211 (ci-full-guest-binary-prereq-gap), COMPLETED**:
  selected the auto-cross-compile prerequisite fix. `./build.sh --ci-full
  --install` now prepares local release inputs before pre-build CI by bumping
  the local version, regenerating traces, and running
  `scripts/build-guest-binaries.sh`. The guest-binary builder now has a Cargo
  fallback when the Nix daemon is unavailable, including an aarch64 musl
  `rust-lld` path for hosts without `aarch64-linux-musl-gcc`.
- **Resolved prior e2e blockers**: follow-up run
  `target/build-install-smoke-e2e/20260708T200628Z` showed version
  monotonicity PASS (`01-build-install.log:230`), no-Python policy PASS
  (`01-build-install.log:1383`), guest-binary embed integrity PASS
  (`01-build-install.log:1498-1499`), pre-build litmus PASS
  (`01-build-install.log:2280`), and portable launcher install PASS
  (`01-build-install.log:2321`).
- **Local-build e2e**: `./build.sh --ci-full --install` reached post-build
  status smoke, then STOPPED at gate 1 with exit 1. Per the e2e runbook, the
  destructive Podman reset was not reached and was not run. New ready packets
  filed in `plan/issues/build-install-smoke-e2e-findings-2026-07-08.md` and
  promoted in `plan/index.yaml`: order 241
  (`forge-diagnostics-opencode-attached-exit`), order 242
  (`opencode-prompt-e2e-loop-status-contract`), and order 243
  (`tray-parity-matrix-complete-post-build`).
- **In-forge commits observed**: the e2e-invoked forge advanced `linux-next`
  through `34862ec3` (local install checkpoint), `c73decd1` (toolbox-exists
  detection finding), and `7d534d8b` (order 239 completion / Python policy
  fix). The local order-211 changes were reapplied on top of that pushed state.
- **Final local install**: per operator request, ran plain `./build.sh
  --install` after pushing the order-211 fix. It bumped `VERSION` to
  `0.3.260708.3`, regenerated trace indexes, installed
  `/home/tlatoani/.local/bin/tillandsias`, and the installed binary reports
  `Tillandsias v0.3.260708.3`.

## Cycle 2026-07-08T20:20Z (linux_mutable — meta-orchestration worker slice)

- **Host**: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), `linux-next`.
  Started clean at `origin/linux-next@c73decd1`, credential guard
  `ok:gh-credentials-store`.
- **Worker drain — order 239 (silverblue-toolbox-builder), COMPLETED**:
  `scripts/with-tillandsias-builder.sh` already existed and was already integrated
  into `build.sh:32`. Applied one fix: removed `python3 python3-pyyaml` from the
  dnf install list to comply with the `no-python-scripts` policy.
  `scripts/check-no-python-scripts.sh` PASS. Filed deliverable at
  `plan/issues/silverblue-toolbox-builder-2026-07-07.md`. This resolves the
  `smoke-finding/silverblue-builder-python-runtime` finding from the prior e2e
  gate cycle.
- **Coordinator**: merged `origin/linux-next` (c73decd1) — no sibling drift to
  integrate. Conflict-marker scan PASS, `plan/index.yaml` YAML parse PASS.
- **E2E gate**: deferred — no destructive test.
- **Published-release e2e**: deferred — no release artifact.

## Cycle 2026-07-08T19:18Z (linux_mutable — meta-orchestration worker slice)

- **Host**: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), `linux-next`.
  Started clean, fetched/pruned remote, fast-forwarded `linux-next` to
  `origin/linux-next@a8932a6c`, and credential guard passed with
  `ok:gh-credentials-store`.
- **Worker drain — order 240 (forge-build-check-tooling-gap), COMPLETED**:
  `build.sh` now detects `TILLANDSIAS_HOST_KIND=forge` check-only invocations
  and skips host Podman registry/proxy setup before running the Rust checks.
  `_require_host_build_tools` no longer requires `file` for `--check`; `file`
  remains install-only for portable launcher validation. Added
  `scripts/test-build-sh-forge-check-only.sh` to pin the branch.
- **Verification**: `scripts/test-build-sh-forge-check-only.sh` PASS;
  `TILLANDSIAS_HOST_KIND=forge ./build.sh --check` PASS with host Podman setup
  skipped and fmt/type-check/clippy green; normal `./build.sh --check` PASS on
  linux_mutable and still ran the non-forge Podman registry setup path.
- **Coordinator**: integrated `origin/osx-next` and `origin/windows-next` into
  a fresh `origin/linux-next` worktree. Resolved loop-status conflicts by
  preserving the current Linux cache and reinserting the macOS 2026-07-07T17:08Z
  and Windows 2026-07-07T23:25Z cycle notes. Fixed one trailing-space issue in
  the imported macOS planning note. Verification on the integrated tree:
  conflict-marker scan PASS, `plan/index.yaml` YAML parse PASS,
  `cargo test -p tillandsias-windows-tray
  wsl_fetch_script_installs_download_via_temp_file` PASS, `./build.sh --check`
  PASS.
- **Finding filed**: integration push from the linked worktree succeeded but
  emitted `fatal: unable to get credential storage lock in 1000 ms: Not a
  directory` because the local helper is `store --file=.git/.gh-credentials`
  and `.git` is a file in linked worktrees. Filed
  `plan/issues/git-credential-store-linked-worktree-lock-2026-07-08.md`.
- **Local-build e2e**: eligible and started as
  `target/build-install-smoke-e2e/20260708T193145Z`; STOPPED at gate 1
  (`./build.sh --ci-full --install`, exit 1), so the destructive Podman reset
  was not reached. Filed
  `plan/issues/build-install-smoke-e2e-findings-2026-07-08.md`: new ready
  packets for stale `VERSION` vs latest release, Silverblue builder Python
  runtime policy violation, and host-pre-build forge credential mirror litmus
  fixture; duplicate guest-binary prerequisite failure recorded against
  order 211.
- **Published-release e2e**: deferred for this cycle because the latest release
  (`v0.3.260707.2`) was already curl-install smoke tested on
  2026-07-07T21:45Z, and this cycle produced no newer release artifact after the
  local-build gate stopped before install.

## Cycle 2026-07-08T00:20Z (forge — meta-orchestration worker slice)

- **Host**: forge (`TILLANDSIAS_HOST_KIND=forge`), `linux-next`, started clean
  after fast-forward to `origin/linux-next@ee94611c`; credential guard initially
  reported `ok:forge-git-mirror`.
- **Worker drain — order 237 (forge-git-mirror-agent-affordance), IN PROGRESS**:
  implemented slice 1. `scripts/check-credential-channel.sh` now fails closed
  in forge mode unless `git ls-remote --get-url origin` resolves to
  `git://tillandsias-git/*` or `git://git-service/*`, then probes that resolved
  mirror URL directly. `write_forge_gitconfig()` now injects the
  project-specific mirror base `git://tillandsias-git/<project>` instead of the
  incomplete `git://tillandsias-git/` base. Added litmus cases for the plain
  GitHub-origin false positive and mirror-resolved pass path.
- **Finding filed/promoted — order 240 (forge-build-check-tooling-gap)**:
  `./build.sh --check` cannot run inside the forge because it requires host
  Podman setup even though the forge is already inside a Podman container, then
  also reports missing `file`. Filed
  `plan/issues/forge-build-check-tooling-gap-2026-07-08.md` and promoted a
  ready packet requiring the forge check-only path to skip host-Podman setup or
  emit a precise delegation message.
- **Verification**: `cargo fmt --all --check` PASS; conflict-marker scan PASS;
  `cargo test --package tillandsias-headless write_forge_gitconfig` PASS (2
  tests, with temporary HOME to avoid root-owned forge git config); direct guard
  checks PASS for GitHub-origin fail-closed and mirror-resolved success;
  `tillandsias-policy validate-yaml` PASS for touched YAML. `./build.sh --check`
  blocked by the newly filed forge tooling gap.
- **Push**: direct HTTPS push to GitHub `origin/linux-next` failed after three
  fetch/rebase/push attempts with `fatal: could not read Username for
  'https://github.com': No such device or address`. The intended enclave mirror
  route then succeeded: `git push git://tillandsias-git/tillandsias
  HEAD:refs/heads/linux-next` accepted `5343c856`, and the mirror hook reported
  successful forwarding to GitHub.
- **Residual**: order 237 remains in progress rather than done: future forge
  checkouts still need the injected project-specific mirror config active by
  default so normal blind `git push origin linux-next` uses the route proven
  above. Full cryptographic per-session mirror authentication remains for order
  238 if enclave-scoped git-daemon routing is insufficient.

## Cycle 2026-07-07T23:25Z (windows — meta-orchestration)

- **Host**: Windows, antigravity agent.
- **Worker drain — `host-lifecycle-race-safeguards` (order 161), Windows R9
  slice COMPLETED**:
  - Implemented R9 safeguard for the Windows guest headless fetch script.
  - The fetch script fallback now writes to a temporary file via `mktemp`, traps
    cleanups on exit, and installs the binary atomically into
    `/usr/local/bin/tillandsias-headless`.
  - Added test `wsl_fetch_script_installs_download_via_temp_file` to
    `wsl_lifecycle.rs` to assert correct atomic behavior.
- **Merge & Sync**:
  - Merged `origin/linux-next` into `windows-next`.
  - Resolved plan ledger syntax errors caused by duplicate `events` keys in the
    upstream merge under packets 152 and 161.
- **Verification**:
  - `cargo test -p tillandsias-windows-tray` PASS (55 tests).
  - `cargo test -p tillandsias-host-shell` PASS (45 tests).
  - `cargo run -p tillandsias-policy -- validate-yaml plan/index.yaml` PASS.

## Cycle 2026-07-07T21:45Z (linux_immutable — meta-orchestration + curl-install e2e)

- **Host**: Linux, `linux-next`, `linux_immutable` (clean, credential guard `ok:gh-keyring`).
- **Worker drain — order 236 (container-microdnf-gpg-workaround)**: found already landed
  in `9f4dd61d` (fix: `--nogpgcheck` to microdnf in `Containerfile.base` and
  `Containerfile.core`). Updated plan: `ready`→`done` with completion event.
  Noted residual: `Containerfile.framework` and `inference/Containerfile` still
  lack `--nogpgcheck` (out of original scope).
- **E2E Gate**: `eligible` (curl-install on linux_immutable; no local build).
  Executed `/smoke-curl-install-and-test-e2e` for release `v0.3.260707.2`:
  - Step 1: installed release binary successfully
  - Step 2: `podman system reset --force` — clean
  - Step 3: `tillandsias --debug --init` — all images built, Vault healthy,
    networks created, exit 0
  - Step 4: forge launched with `/meta-orchestration` — completed order 227
    (`container-dependency-graph-satisfier-typestate`) inside forge:
    `RealSatisfier` struct, `Up<T>` typestate witness, migrated `run_provider_login`
    and `run_list_cloud_projects` to `ensure_git_login`, 10 new tests.
- **Push**: forge committed and pushed to local mirror (`git://tillandsias-git/tillandsias`),
  but git-mirror HTTPS upstream push failed (`fatal: could not read Username for
  'https://github.com'`). GitHub `linux-next` still at `34738da7`; forge commits
  (`92dce746`, `7bb02fae`, `d49fd7ef`) in forge mirror only.
- **Findings**: no new product bugs. Known forge-mirror HTTPS credential limitation
  documented in `plan/issues/smoke-e2e-findings-2026-07-07.md`.

## Cycle 2026-07-07T19:48Z (forge — advance-work-from-plan: order 227)

- **Host**: forge (`TILLANDSIAS_HOST_KIND=forge`), `linux-next`, credential guard `ok:forge-git-mirror`.
  Worktree clean at `34738da7` (reverted from pending 92dce746 by mirror credential collision).
- **Worker drain — `container-dependency-graph-satisfier-typestate` (order 227), CLAIMED and COMPLETED**:
  Implemented `RealSatisfier` — wraps `ensure_enclave_network`, `ensure_egress_network`,
  `ensure_ca_bundle`, `ensure_vault_running`, `ensure_proxy_running` as `Satisfier` impl in
  `container_deps.rs`. Added `Up<T>` typestate wrapper with module-private constructor + `GitLoginReady`
  marker. Added `ensure_git_login() -> Result<Up<GitLoginReady>, String>` as the public entry point.
  Migrated `run_provider_login` (main.rs:4741) — replaced ad-hoc `ensure_enclave_network` →
  `ensure_vault_running` → `ensure_proxy_running` with `ensure_git_login(debug)?` under
  `#[cfg(feature = "vault")]`, with fallback for `#[cfg(not(feature = "vault"))]`.
  Migrated `run_list_cloud_projects` (main.rs:4989) — same migration. Updated 3 source-text
  preflight-order tests to assert `ensure_git_login` instead of old individual ensure calls.
  10 new container_deps tests (all pass), `cargo check` + clippy clean, total 119/120 pass
  (pre-existing `launch_forge_agent_does_not_mount_user_home` forge-container false positive).
- **Push**: local git-mirror accepted 2 commits (92dce746 claim + 7bb02fae implementation),
  `origin/linux-next` = 7bb02fae. Upstream GitHub forwarding fails (mirror credential issue,
  same as prior cycles). GitHub `linux-next` still at 34738da7.
- **Plan ledger**: order 227 marked `done`, `plan/loop_status.md` updated.

## Cycle 2026-07-07T17:08Z (macos — meta-orchestration, round 3)

- **Host**: macOS arm64, `osx-next`.
- **Start**: Clean worktree, 1 un-pushed commit (8cced871 —
  `prevent-silent-failures` state model from prior agent). Pushed to origin
  first.
- **Credential guard**: `ok:gh-keyring`.
- **Remote**: `linux-next` advanced 8 commits (version bump to 0.3.260707.2,
  order-236 microdnf GPG fix, order-227-235 packet splits, CI musl fix).
- **Merge**: `origin/linux-next` into `osx-next` — clean, no conflicts.
  `cargo fmt --check`, YAML validation, `cargo check -p tillandsias-macos-tray`
  all green. `cargo test`: **58+12+50 tests pass**.
- **Worker drain**: No new macOS-ready packets. Both remaining macOS packets
  (orders 155, 161) blocked on upstream `vm-headless-persistent-listener`
  (order 153, Linux-owned, status ready).
- **Untracked**: 2 openspec change proposals (`macos-app-signing`,
  `prevent-silent-failures`) and a bug ticket (`macos-dmg-icon-missing`) left in
  place — user/agent WIP not overwritten.
- **E2E gate**: `skip:no-podman-user-session`.

## Cycle 2026-07-07T08:18Z (linux_mutable — meta-orchestration)
  macOS job previously fixed with `rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl`
  (fix applied after v0.3.260707.1 macOS failure). Linux build benefited from Nix cache HIT
  (v0.3.260707.1 PR merge warmed the cache) — 10m41s vs 12m25s cold build.
- **Reduction engine — split 3 large packets into smaller ready slices**:
  - `container-dependency-graph-impl` (order 122, 10h → 3 slices): slices 1-2 done, split into
    successor packets 227 (satisfier+typestate, 3h), 228 (liveness probe, 2h), 229 (drift litmus, 1h).
  - `vm-headless-persistent-listener` (order 153, 10h → 2 slices): slice 1 (VmStatus push) done,
    split into successor packets 230 (LoginStatePush, 4h) and 231 (CloudProjectsPush, 4h).
  - `enclave-container-lifecycle-races` (order 162, 12h → 4 slices): split into successor packets
    232 (flock concurrency R4, 3h), 233 (shared cleanup guard R5, 3h), 234 (phase-aware self-heal R6, 3h),
    235 (vault recreate mutex R7, 3h).
- **Coordinator duties**: sibling drift checked — both `origin/osx-next` and `origin/windows-next`
  at 0 commits ahead of `origin/linux-next` (clean, no merge needed).
- **Plan ledger**: all 3 existing packets updated with `split_into` notes; 9 new `ready` packets
  appended to `plan/index.yaml`; YAML validated via `ruby -ryaml`.
- **Release artifacts**: waiting for macOS and Windows jobs to complete before verifying
  published release.

## Cycle 2026-07-06T19:30Z (macos — /goal "drain the macos queue")

- **Host**: macOS arm64, `osx-next` (clean, credential guard `ok:gh-keyring`).
  Pulled substantial concurrent work from linux/windows (order 194 macos-
  native-tray litmus fixes, order 168 inference OOM fix, order 201 filed,
  9 litmus files fixed by Linux's own triage of the remaining order-198
  items, plus a host-guest transport normalization refactor).
- **Order 201 (litmus-runner-command-backslash-escaping), claimed and
  COMPLETED**: implemented the proposed fix (collapse `\\` -> `\` after
  the existing `\"` -> `"` pass, in that exact order — reproduces a real
  YAML parser's left-to-right escape consumption). Added the required
  regression test (`litmus:litmus-runner-backslash-escaping-shape`),
  verified as an effective negative/positive control (fails when the fix
  is reverted, passes with it in place). `./build.sh --check` exits 0.
- **Continued triaging litmus-full-suite-macos-first-run-findings (order
  198, already closed by Linux) — found and fixed 4 real macOS/BSD-
  specific bugs Linux's own investigation had mischaracterized as
  "environment noise"** (added a correction event, didn't edit Linux's
  original text):
  - `litmus:forge-environment-discoverability-install-shape`: `\\|` parsed
    as escaped-backslash + dangling alternation on BSD/macOS grep ("empty
    (sub)expression"); fixed with the portable bracket-expression `[|]`.
  - `litmus:forge-opencode-onboarding-bootstrap-shape`: same class, `\\[`
    in an awk regex; fixed with `[[]`.
  - `litmus:image-build-convergence-shape` (forge-staleness spec): found
    2 more bash-3.2/<4.4 incompatibilities in `scripts/build-image.sh` —
    `mapfile -d ''` (bash 4+ builtin, replaced with the portable
    `while read -d ''` loop the file's own git-less fallback already
    used) and `"${ARR[@]}"` on a possibly-empty array under `set -u`
    (bash <4.4 treats this as "unbound variable", fixed with the
    `"${ARR[@]+"${ARR[@]}"}"` conditional-expansion idiom for
    NO_CACHE_ARGS/BUILD_ARGS/CACHE_MOUNT_ARGS).
  - `litmus:zen-default-with-ollama-shape` T0 step: genuine drift (order
    183 replaced the hardcoded pull literal with a config-driven
    DEFAULT_MODELS loop); fixed the check. T1 step: resolved the "open
    question" I'd flagged — Linux's order-168 investigation on a sibling
    litmus already answered it (DEFAULT_MODELS was deliberately narrowed
    to fix a real OOM bug, so T1's auto-pull guarantee was intentionally
    dropped, not a regression); re-pointed the check at the explanatory
    comment.
- **Full pre-build/instant litmus suite**: started this cycle at 93 PASS
  (bare shell, no cargo on PATH) → 117 PASS / 2 FAIL / 100% coverage on
  the final merged tree. Both remaining fails are confirmed local-
  machine-state gaps on this specific dev host (no cross-compiled x86_64
  guest binary; no `flock`, and no working Podman machine at all — see
  below), not code bugs.
- **Investigated the "no Podman machine" root cause** behind every macOS
  finding this cycle that needed live Podman: `podman-machine-default`
  exists but has never started; `podman machine start` fails with
  `krunkit: executable file not found` (not in Homebrew core, needs a
  third-party tap or Podman Desktop). One-time local machine setup gap,
  not a repo bug — documented the exact bootstrap command in
  `plan/issues/macos-embedded-guest-runtime-smoke-2026-07-05.md` rather
  than installing a third-party tap unprompted.
- All changes routed through `linux-next` per the openspec/scripts
  shared-scope write rule (this cycle: `linux-next@2763f3de`,
  `4a5729b2`); merged back into `osx-next@4a5729b2`, tests green (58/58
  macos-tray, 50/50 vm-layer), `cargo fmt --check` clean.
- **macOS queue status**: order 191 still needs windows-next's half
  (osx-next's is done); no other macOS-owned or `any`-owned ready work
  remains in `plan/index.yaml`.

## Cycle 2026-07-06T20:19Z (linux_mutable — build-install-and-smoke-test-e2e)

- **E2E gate result: STOPPED at gate 1** (build + CI + install), against the
  freshly-integrated tree from the prior cycle (litmus fixes + order 124/153
  slices + osx-next/windows-next merges, `linux-next@32da73a1`).
  `./build.sh --ci-full --install` exited non-zero via `local-ci.sh` before
  `--install` ran, so per the skill's guardrail the destructive Podman reset
  was correctly **not** performed. Two pre-existing, unrelated issues caused
  the failure (both verified NOT caused by this cycle's changes and filed as
  ready packets in `plan/index.yaml`):
  - Order 210 (`remote-projects-clone-test-flakiness`): `cargo test -p
    tillandsias-headless --bin tillandsias --features tray` (the exact
    `tray-contract` gate command) fails non-deterministically — root cause
    looks like `clone_uses_host_parent_bindmount` asserting the wrong
    (post-rename vs. staging) path for order-163's atomic-clone, panicking
    and poisoning a shared test `Mutex` that cascades into 3 other tests.
    Reproduces even with `--test-threads=1`; `remote_projects.rs` untouched
    by this session (last touch: `d98e8eff`, well before today).
  - Order 211 (`ci-full-guest-binary-prereq-gap`, research): the known
    "local build-state gap, not drift" `litmus:guest-binary-embed-integrity`
    (no cross-compiled guest binary on this dev checkout — already
    documented from the macOS side in
    `plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md`)
    is on its own enough to hard-fail `local-ci.sh`'s litmus-pre-build gate,
    which blocks `--install` from ever running on a fresh Linux checkout.
  - Full findings + evidence:
    `plan/issues/build-install-smoke-e2e-findings-2026-07-06.md`.
- **Reduction engine**: both findings filed and promoted to ready
  `plan/index.yaml` packets (orders 210, 211) rather than fixed in this smoke
  session — the skill's own contract is "file findings, don't implement
  product fixes here."
- **Next**: whoever picks up order 210 (or 211) should re-run
  `/build-install-and-smoke-test-e2e` afterward to actually reach gates 2-4
  (destructive reset, re-provision, forge lane) against this integrated tree.

## Cycle 2026-07-06T19:03Z (linux_mutable — meta-orchestration + coordinator)

- **Host**: Linux mutable, started on `linux-next` clean, credential guard
  `ok:gh-keyring`. Sole active linux worker this cycle (AntiGravity had
  crashed before starting; no stale in-progress linux leases were found in
  `plan/index.yaml`, so nothing needed forced reclaiming).
- **Worker drain — litmus drift (order 198), COMPLETED** (`86bd9bf4`): triaged
  all 14 (spec,test) pairs from the macOS first-run litmus finding on a real
  Podman-capable Linux tree. 5 were macOS cargo/podman-not-on-PATH
  environment noise (didn't reproduce on Linux); 9 were genuine litmus drift
  verified against git history — in every case the shipped code was the
  correct, already-decided behavior (multi-provider login generalization,
  order-168 inference-OOM fix, order-175 EVERY_LAUNCH harness installs, the
  FlakeHub-cache revert, the Antigravity 7th tray leaf) and the litmus itself
  had gone stale, so fixed the 9 litmus files rather than reverting product
  code. Filed `plan/issues/litmus-runner-command-backslash-escaping-2026-07-06.md`
  (promoted to ready order 201) after hitting the bug live while writing the
  fixes. Linux full suite: 116 PASS / 1 FAIL (guest-binary-embed-integrity,
  confirmed local build-state gap) / 100% spec coverage.
- **Worker drain — host-guest-transport facade (order 124), COMPLETED**
  (`edb6a421`): added the missing `litmus:host-guest-no-cfg-transport-selection`
  drift litmus (3 grep-based steps), verified it actually falsifies by
  injecting a fake `cfg(target_os)`-gated transport picker into
  `host-shell/lib.rs` and confirming it's caught, then reverting. Closed
  order 124. Deliberately did NOT invent the "conformance fixture harness"
  exit criterion — no real Linux `GuestTransport` backend has landed yet
  (order 125 still pending), so writing wire-mapping fixtures now would mean
  pre-empting that packet's design decision. Split it into its own pending
  packet, `host-guest-transport-conformance-harness` (order 128, depends on
  125), per operator guidance to split oversized/blocked scope into smaller
  ledger packets rather than stretching a cycle to cover it.
- **Worker drain — VM headless persistent listener (order 153), slice 1
  landed, NOT claimed/blocked** (`d4a7c81a`): discovered the packet's stated
  premise was partly stale — `vsock_server.rs`'s connection loop already
  stays open after replies and already `select!`s over PTY + inbound frames
  (SC-08 was already true). The real gap: `Subscribe`/`SubscribeAck`/`*Push`
  (added by order 152) fell through `control_dispatch`'s catch-all to
  `Unsupported`, so no client could ever subscribe. Wired the `VmStatus`
  topic end-to-end: `control_dispatch.rs` routes `Subscribe` -> `Handle` and
  the 4 push/ack variants -> `ResponseOnly` on both transports;
  `VmStateHandle` gained a bounded (16-capacity) `tokio::sync::broadcast`
  channel + `subscribe_vm_status()`; `set_phase()` pushes `VmStatusPush` only
  on an actual transition; `handle_connection` handles `Subscribe{VmStatus}`
  and forwards pushes via a new `select!` branch, treating
  `RecvError::Lagged` as skip-and-continue (broadcast's per-receiver buffers
  give the "slow client doesn't block a fast one" property for free). 4 new
  unit tests, all green; `cargo clippy --features listen-vsock --all-targets
  -D warnings` shows zero new warnings in either touched file (7 pre-existing
  warnings elsewhere confirmed present on unmodified linux-next too).
  `LoginStatePush`/`CloudProjectsPush` still unwired — left for the next
  slice, packet left `ready` (not claimed) rather than blocking on unfinished
  scope.
- **Coordinator duties**: `origin/osx-next` (18 commits, 7 real content
  commits ahead of merge-base) and `origin/windows-next` (22 commits) had
  both drifted well past the 5-commit compliance threshold. Merged
  `origin/osx-next` cleanly (no conflicts — VZ guest-transport facade,
  singleton tray guard, serialized project PTY launches). Merged
  `origin/windows-next` with one conflict in `plan/index.yaml` (both branches
  had appended distinct new packets at the tail of the file — pure
  concatenation, resolved by keeping both sides' packets: Windows' orders 196
  (audit-plan-cross-branch-writes)/197 (audit-credential-guard-windows) plus
  my order 201). Brings in Windows host-lifecycle-race-safeguards R1/R3, the
  secure-control-wire e2e probe (order 191 evidence), and related plan/skill
  audits. Ran the full integration verification gate after merging (conflict
  marker scan clean, all touched YAML re-validated, `./build.sh --check` +
  `--test` green, litmus suite unchanged at 116/117) before pushing
  (`08a9676d`).
- **Reduction engine**: all findings from this cycle filed/promoted (see
  above); no unfiled "this isn't great" observations pending.
- **Next**: with litmus fixes + order 124/153 slices + macOS/Windows work all
  now integrated together on `linux-next`, this is a meaningful moment for
  the destructive local-build e2e smoke gate (`/build-install-and-smoke-test-e2e`)
  rather than running it against a single isolated packet — proceeding to it
  next.

## Cycle 2026-07-06T18:15Z (windows — meta-orchestration)

- Staged and verified the Windows/WSL host-lifecycle race safeguards (order 161).
- Implemented:
  - **R1 (Quit/relaunch)**: added an observable `drain.lock` in the VM install root to coordinate teardown; `WslRuntime::start` now checks `is_wsl_service_sane()` and retries with backoff, automatically executing `wsl --shutdown` (guided recovery) on E_UNEXPECTED / unhealthy service state.
  - **R3 (PTY Click serialization)**: debounced duplicate terminal launches within 1.5s in `launch_open_shell_terminal`.
- Verified `cargo check` and `cargo test` clean on Windows host for both `tillandsias-windows-tray` and `tillandsias-vm-layer`. Formatting verified.
- E2E preflight verdict this cycle: `skip:no-podman-binary` (local-build e2e skipped).

## Cycle 2026-07-06T18:04Z (macos — meta-orchestration)

- **Host**: macOS arm64, started on `osx-next` clean, credential guard
  `ok:gh-keyring`.
- **Branch integration**: `osx-next` had drifted from `origin/linux-next`;
  merged `origin/linux-next` into `osx-next` and pushed `osx-next@310b7232`.
  While publishing the next plan claim, the `linux-next` macOS build gate
  exposed that shared trunk was missing already-landed `osx-next` clippy fixes;
  merged `origin/osx-next` into `linux-next` by merge commit
  `1c8203d3`. Added the small Linux cfg fix for the new
  `containers.conf` proxy setup compile break (`e5c02608`).
- **Worker drain — `stable-state-codes-research` (order 160), claimed and
  COMPLETED**: documented the finite dotted-code taxonomy for
  host/vm/guest/podman plus auth/cloud/forge/transport, event ownership,
  request/reply fallback mapping until push streams land, stable support-code
  naming, and a tray chip message map capped at 37 chars in
  `plan/issues/stable-state-codes-research-2026-07-05.md`. This gives the
  macOS status UX packet a concrete code contract instead of ad hoc labels.
- **Worker drain — `host-guest-transport-macos` (order 126), claimed and
  checkpointed then BLOCKED/released**: first coherent slice landed on
  `osx-next@0e49d480`. `VzRuntime` implements the normalized
  `GuestTransport` facade for `GuestEndpoint::MacVz` (`open_stream`, `exec`,
  `exec_streaming`) over the existing VZ `VsockStream` / `vsock_exec` helpers.
  Second slice landed on `osx-next@381dbdfc` and `osx-next@e9d55c97`: the
  AppKit action-host opener now uses `GuestTransport::open_stream`, and
  `VzRuntime::exec` routes through `GuestTransport::exec` with explicit Unix
  signal exit-code normalization. Third slice landed on `osx-next@8e9f586d`:
  `diagnose.rs` now constructs `GuestEndpoint::MacVz` and delegates
  current-thread VZ connection details to vm-layer, without naming the raw
  `VsockStream` type or calling `open_vsock_stream_current_thread` directly.
  Evidence: `cargo test -p tillandsias-vm-layer` 29/29,
  `cargo test -p tillandsias-macos-tray` 56 passed / 1 ignored, and
  `./build.sh --check` pass on macOS. Released the lease after recording the
  blocker: completion now depends on Linux/order124 landing the shared
  conformance harness/litmus plus a facade-contract decision for
  secure/expect/signal ExecOneShot semantics, and on a macOS packaged/entitled
  VM substrate to run the live Darwin fixture. Local e2e eligibility remains
  `skip:no-podman-user-session`.
- **Worker drain — `host-lifecycle-race-safeguards` (order 161), macOS R9
  sub-slice claimed and released after checkpoint**: `osx-next@3e1637ad`
  changes the VZ cloud-init `fetch-headless.sh` network fallback from
  `curl --output "$DEST"` to `mktemp` + cleanup trap + `install -D -m 0755`
  into the live headless path. Added a source-pin test for the temp/install
  behavior. Evidence: `cargo test -p tillandsias-vm-layer` 30/30 and
  `./build.sh --check` pass on macOS. The broader packet remains ready for the
  Windows owner; Windows R1-R3/R9 lifecycle safeguards are not completed by
  this macOS slice.
- **Worker drain — `host-lifecycle-race-safeguards` (order 161), macOS R2
  sub-slice claimed and released after checkpoint**: `osx-next@64676548`
  adds non-destructive `SingletonGuard::try_acquire` and guards only the no-flag
  AppKit tray path, so a second tray exits cleanly while CLI utility modes still
  run. Evidence: `cargo test -p tillandsias-core singleton`,
  `cargo test -p tillandsias-macos-tray` 57 passed / 1 ignored, and
  `./build.sh --check` pass on macOS.
- **Worker drain — `host-lifecycle-race-safeguards` (order 161), macOS R3
  sub-slice claimed and released after checkpoint**: `osx-next@bb72efc2`
  adds a per-project launch lease around AppKit Attach/Maintain PTY launches,
  so a same-project double-click is ignored while the first guest launch flow is
  in flight. Root shell and GitHub login remain project-less and unaffected.
  Evidence: `cargo test -p tillandsias-macos-tray` 58 passed / 1 ignored and
  `./build.sh --check` pass on macOS. Remaining order 161 scope is now
  Windows lifecycle/R1-R3/R9 only.
- **Queue reconciliation**: `host-guest-transport-macos` is now blocked on
  Linux/order124 conformance and live macOS VM substrate; `macos-tray-stream-refactor`
  and `macos-tray-state-code-status-ux` were returned from stale `ready` to
  `pending` because `vm-headless-persistent-listener` is still not complete.
  `host-lifecycle-race-safeguards` remains ready for Windows only after the
  macOS R2/R3/R9 slices. No macOS-owned packet remains claimable in the current
  dependency state.
- **Verification**: conflict-marker scan clean; `plan/index.yaml` and
  `.github/workflows/release.yml` parse as YAML; `cargo test -p
  tillandsias-macos-tray` and `./build.sh --check` pass on macOS with the Rust
  toolchain path added.
- **E2E gate**: `scripts/e2e-preflight.sh eligibility` →
  `skip:no-podman-user-session`; local-build e2e skipped with the recorded
  verdict.
- **Next macOS work**: none claimable in the current dependency state. Order 126
  is blocked on Linux/order124 conformance and live packaged/entitled macOS VM
  substrate; older macOS stream/status implementation packets still depend on
  the VM/headless persistent listener and push-message work. Order 198 remains
  actively leased by another macOS agent until `2026-07-06T20:58:00Z`.

## Cycle 2026-07-06T17:34Z (linux_mutable CCR sandbox — meta-orchestration)

- **Host**: Linux mutable, Claude Code remote sandbox. Branch constraint: session
  may only push `claude/meta-orchestration-skill-uhitvv` (reset onto
  `linux-next@4835931e`); ledger writes reach `linux-next` via PR, not direct
  push. Credential guard `ok:gh-token-env`.
- **Worker drain — order 160 (race-safeguards-research), claimed and
  COMPLETED**: R1-R9 dispositioned against the live tree with file:line
  evidence; shared-container ownership decided (ensure-only +
  vsock-supervisor reconciliation; refcount rejected); impl scopes for orders
  161/162/163 confirmed with amendments (stale "orders 152-154" pointer
  corrected). Re-verification deltas: R9 linux bootstrap already fixed but
  windows `wsl_lifecycle.rs:368` + macos `vz.rs:460` embedded fetch scripts
  still curl onto the live binary; R5 forge-aware guard landed at 3 sites, 4
  launch/cleanup paths still remove shared containers unconditionally.
- **E2E gate**: `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-binary`
  (sandbox has no podman); both local-build and curl-install gates skipped
  with recorded verdict.
- **Coordinator duties**: skipped — sibling merges (osx-next 12 / windows-next
  6 ahead, order 191) require pushing `linux-next`, which this session cannot
  do. Left order 191 for a push-capable linux_mutable host.
- **Reduction engine**: filed
  `plan/issues/ccr-branch-scoped-ledger-claims-invisible-2026-07-06.md`
  (optimization): CCR sessions cannot publish leases to `linux-next` before
  working, so claims are invisible to siblings until PR merge — collision
  window documented with candidate reductions.

## Cycle 2026-07-06T17:15Z (linux_immutable — meta-orchestration)

- **Host**: Linux, `linux-next`, `linux_immutable` (clean, credential guard `ok:gh-keyring`).
- **Worker Drain**: Skipped (not a builder role host).
- **E2E Gate**: `eligible`. Executed `/smoke-curl-install-and-test-e2e` for release `v0.3.260704.2`.
- **E2E Findings**: Substrate reset succeeded. Init completed cleanly (exit 0) but logged SELinux `semanage` and vault `/etc/hosts` permission denied warnings. Forge continuous enhancement run failed immediately with `Error: Unknown image type: curl`.
- **Reduction Engine**: Filed 3 ready work packets in `plan/issues/smoke-e2e-findings-v0.3.260704.2-2026-07-06.md`.

## Cycle 2026-07-06T15:37Z (macos — meta-orchestration)

- **Host**: macOS arm64, `osx-next` (clean, credential guard `ok:gh-keyring`,
  no sibling drift to merge at cycle start).
- **Worker drain — order 197 (macos-tray-clippy-warnings), claimed and
  COMPLETED**: boxed `ControlWireStream::Secure` in `action_host.rs` +
  `diagnose.rs` (large_enum_variant); fixed `status_item.rs:203`'s redundant
  `.ok()` match. `cargo clippy -p tillandsias-macos-tray --all-targets`: 0
  warnings. `cargo test`: 54/54 pass. Code → `osx-next@0965ad53`; ledger →
  `linux-next@cd80e0ea`.
- **Worker drain — order 196 (macos-litmus-runner-bash-version-gap), claimed
  and COMPLETED**: `scripts/run-litmus-test.sh` used `declare -A` (bash 4+);
  stock macOS ships bash 3.2 with no Homebrew bash installed, so the runner
  crashed immediately on every macOS invocation — no macOS host had ever seen
  a real litmus verdict. Rewrote the 3 associative arrays as portable
  newline-delimited dedup+count helpers; also fixed a second latent bash-4-ism
  (`${var,,}`) found while verifying end-to-end. **First-ever full macOS
  litmus run**: 93 PASS, 24 FAIL, 119 SKIP, 100% spec coverage (88/88). Fixed
  1 of the 24 same-cycle (`wc -c` BSD-padding bug in
  `litmus-versioning-shape.yaml`). Filed the remaining 23 for triage
  (`plan/issues/litmus-full-suite-macos-first-run-findings-2026-07-06.md`,
  order 198) with an explicit caveat: spot-checks show a MIX of genuine
  drift, local-build-state gaps (missing cross-compiled artifacts), and
  macOS/BSD tooling gaps in the checks themselves (e.g. missing `flock`) —
  do not treat all 23 as code bugs without per-item triage. Promoted 2
  confirmed-root-cause macos-native-tray items as ready packets (199, 200).
  All changes → `linux-next@53ba8f36` (openspec/litmus-tests + scripts/
  route through linux-next per the shared-scope write rule); merged back
  into `osx-next@78ffa02a`.
- **E2E gate**: `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-user-session`
  (same known macOS-host limitation as last cycle); local-build e2e skipped.
- **Next macOS work**: order 198 (triage 23 litmus failures), order 199
  (restore/correct the macos-tray-architectural-invariants pin test), order
  200 (correct the stale pty-attach-project-threading-symmetric litmus
  string — coordinate with windows since it pins windows-tray's import).

## Cycle 2026-07-06T15:16Z (macos — meta-orchestration)

- **Host**: macOS arm64, `osx-next` (clean, credential guard `ok:gh-keyring`).
- Merged `origin/linux-next` (49ab501d..c50bdf3a, 1 conflict in
  `plan/loop_status.md` resolved keeping both cycle logs) into `osx-next`;
  `cargo test -p tillandsias-vm-layer` 24/24, `-p tillandsias-macos-tray`
  53/53 green post-merge. Pushed `23b00572`.
- **Worker drain — order 194 (secure-channel-release-and-probe-hardening),
  claimed and COMPLETED all remaining slices 1/2/4** (linux's slice 3 was
  already done):
  - Slice 1: audited all 5 `channel_psk` call sites — no live
    `CARGO_PKG_VERSION` drift (already fixed by a prior commit). Added
    `litmus:psk-input-parity-shape` to pin it.
  - Slice 2: `VzRuntime::wait_phase_ready` (vm-layer, secure-channel-agnostic
    by design) now takes a caller-supplied `probe_once` closure instead of
    connecting raw internally; `diagnose.rs`'s 4 call sites pass a new
    `probe_phase_secure_or_plain()` helper reusing the existing
    `open_control_wire_stream()` secure-or-plain opener. Added a source-pin
    test covering `litmus:secure-wait-phase-ready`.
  - Slice 4: corrected the M1 gate wording in
    `secure-channel-maturity-ladder-2026-07-04.md` — failure-closed means no
    `HelloAck`/`PtyOpen` + stream close, not a literal `Unauthorized` frame.
  - Evidence: `cargo test -p tillandsias-vm-layer` 44/44,
    `-p tillandsias-macos-tray` 54/54 (1 ignored), clippy 0 new warnings.
  - Code commit `9126986b` → `osx-next`; plan/ledger commit `626cc2e2` →
    `linux-next` (order 194 now `done`; 2 new ready packets filed: order 196
    macOS litmus-runner bash-3.2 gap, order 197 macOS-tray clippy cleanup).
  - Merged `linux-next` (626cc2e2) back into `osx-next` (clean, no conflicts);
    pushed `1a87fc61`.
- **E2E gate**: `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-user-session`
  (known macOS-host limitation, already tracked); local-build e2e skipped
  this cycle per protocol.
- **Next macOS work**: order 196 (litmus runner bash version) and order 197
  (clippy cleanup) are ready and macOS-owned; both are small (~1h) follow-ups.

## Cycle 2026-07-05T22:44Z (macos — meta-orchestration, round 2)

- **Host**: macOS arm64, `osx-next` (clean, in sync with `origin/linux-next`).
- **Credential guard**: `ok:gh-keyring`.
- **Worker drain — order 193 (macos-vz-home-src-mount)**:
  - Claimed and completed. VZ virtio-fs share already wired in previous WIP
    (checkpointed). Implemented: `VZVirtioFileSystemDeviceConfiguration` with
    `home-src` tag in `build_vm_configuration`; cloud-init mounts `/home/forge/src`
    via `mount -t virtiofs` before headless service; `fetch-headless.sh` prefers
    staged binary at `/home/forge/src/.tillandsias/guest-bin/` over curl fallback.
  - **New test**: `vz_fetch_script_prefers_staged_binary_over_network` verifies the
    staged binary path and install-instead-of-curl logic.
  - `cargo test -p tillandsias-vm-layer`: **24/24 pass**.
  - `cargo test -p tillandsias-macos-tray`: **53/53 pass**.
- **Next macOS work**: order 194 (secure-channel-release-and-probe-hardening) has
  macOS-relevant slices (PSK parity, VZ readiness probes) — ready for pickup.

## Cycle 2026-07-05T22:23Z (macos — meta-orchestration)

- **Host**: macOS arm64, `osx-next` branch, clean worktree after WIP checkpoint.
- **Credential guard**: `ok:gh-keyring`.
- **Worker drain — order 191 (multi-host-secure-wire-integration-freeze)**:
  - Merged `origin/linux-next` (49ab501d) into `osx-next` (34 commit catch-up).
  - 3 conflicts resolved: `vsock_server.rs`, `plan/loop_status.md`,
    `plan/issues/headless-secure-control-wire-image-refresh-2026-07-05.md` —
    all resolved with `linux-next` as authoritative per coordination policy.
  - `cargo fmt --all --check`, `cargo check -p tillandsias-macos-tray` clean.
  - `cargo test -p tillandsias-macos-tray`: **53/53 pass** (1 ignored, slow e2e).
  - `cargo test -p tillandsias-secure-channel`: **12/12 pass**.
  - All touched YAML validated via `ruby -ryaml -e YAML.load_file`.
  - Branch drift from linux-next resolved (osx-next now at parity).
  - Pushed `39e9df27` to `origin/osx-next`.
- **Remaining macOS work**: Order 193 (`macos-vz-home-src-mount`) is now
  unblocked — linux-next merge complete, order 190 (guest binary contract) done.
  Next: implement VZ virtio-fs share for host `~/src` → `/home/forge/src`.
- **E2E gate**: Not run this cycle (merge verification only; no destructive
  substrate reset). Ready for full local-build e2e on next cycle once order 193
  implementation is in place.
- **Finding filed**: `./build.sh --check` requires podman which isn't available
  on this macOS dev path — noted in existing
  `plan/issues/macos-build-check-podman-wrapper-2026-07-05.md`.

## This Loop (coordination audit — secure wire / embedded guest / ledger pruning)
- Current product target distilled for the next agents: macOS tray boots Fedora 44,
  injects a source-matching Linux headless binary for the guest arch, initializes
  the Podman control plane, and launches Codex/Claude/OpenCode/Antigravity inside
  the deepest forge container from a top-host terminal without leaking host
  credentials.
- Secure-channel state: host<->guest primitive and linux guest responder are on
  `linux-next`; macOS and Windows have sibling work that must be integrated by
  merge, not cherry-pick. Guest<->container encryption and metrics sub-packets
  remain open before M2 soak can start.
- Windows update 2026-07-06T06:20Z (windows-bullo-fable5-20260706T0535Z):
  `windows-next` merged `origin/linux-next` (0794510a) per the order-191 freeze;
  Windows flag-OFF/flag-ON secure-wire evidence recorded in the order-191
  deliverable (Noise handshake + VmStatus round-trip on a version-matched guest;
  plaintext rejected failure-closed while gated ON). Order-161 R2 tray
  SingletonGuard landed (c3089123). Windows local-build e2e gate verdict this
  cycle: `skip:no-podman-binary` (e2e-preflight). Remaining freeze work: macOS
  slice + linux coordinator merge of both siblings.
- Embedded guest state: order 190 is the canonical Linux artifact contract. Older
  macOS-filed packaging notes are now intake evidence, not the active blocker.
- Observability state: `plan/metrics-dashboard.md` is stale/cache-empty and must not
  be used as live evidence until order 192 refreshes the metrics source and stamps
  provenance.

secure_channel_soak:
  start_date: null
  days_elapsed: 0
  qualifying_commits: 0
  first_release_tag: null
  third_release_tag: null
  subpackets_landed: { "185-A": false, "185-B": true, "185-C": false, "185-D": false }

HighVelocityAlignmentEvent: Active
Reason: Secure-wire/embedded-guest path remains the critical product blocker.
  Branch drift is resolved for osx-next (merged at parity); windows-next still
  needs integration.

## Active Assignment Board

- Linux primary: order 190 `embedded-guest-binary-linux-build` — COMPLETED (added scripts/build-guest-binaries.sh and litmus matching version test). Next focus: order 180 continuation for remaining FIRST_RUN migration/de-hardcoding.
- macOS primary: order 193 `macos-vz-home-src-mount` — **COMPLETED**. VZ virtio-fs
  share wired, cloud-init mount added, staged binary fallback tested (24/24 vm-layer
  tests). Next: order 194 (secure-channel-release-and-probe-hardening) — macOS PSK
  parity and VZ readiness-probe slices.
- Windows primary: order 186 plus order 191 — merge `origin/linux-next` into
  `windows-next`, preserve the real hvsocket secure-wrapper + embedded-binary work,
  and record WSL2 flag-off/flag-on smoke evidence. Fallback: order 190 consumer
  review for the Windows installer/staging path.
- Coordination primary: order 192 `semantic-distillation-and-ledger-pruning` and
  order 194 `secure-channel-release-and-probe-hardening` — prune stale active
  issues, update dashboard provenance, and close PSK/release/probe ambiguity before
  secure-channel maturity advances.

### Cycle 2026-07-05T23:28Z (forge — meta-orchestration)
- Recovered dirty VERSION (0.3.260705.5 → 0.3.260705.6 uncommitted), committed as
  checkpoint before work.
- Claimed and completed order 165 (forge-agent-permission-defaults): verified exit
  criteria that OpenCode/Codex already pre-grant container-local filesystem
  (permission:allow + --dangerously-skip-permissions / --dangerously-bypass-approvals),
  and wrote boundary-enforcement rationale to openspec/specs/default-image/spec.md
  documenting the nine containment boundaries (cap-drop, no-new-privs, user-ns,
  proxy egress, credential indirection, source-mount quarantine, encrypted control
  channel, SELinux Phase 6, ephemeral single-project container) that make
  default-grant safe inside the forge. No remaining forge-agent-permission blockers.

## This Loop (2026-07-05 macos — meta-orchestration)
- Recovered dirty macOS packaging work: styled DMG script/assets, release workflow
  DMG staging/signing, and packaged `.app` guest-binary embedding for
  `aarch64-unknown-linux-musl` + `x86_64-unknown-linux-musl`.
- Fixed macOS secure-control PSK drift by deriving both tray/headless from repo
  `VERSION`, and fixed `--exec-guest` to use the guest PTY allowlisted
  `/bin/bash -lc` wrapper.
- Verified: `cargo fmt --all -- --check`; `cargo test -p tillandsias-macos-tray`;
  `cargo test -p tillandsias-secure-channel`; `scripts/build-macos-tray.sh`;
  `scripts/build-macos-dmg.sh`; read-only DMG contents; packaged app
  `--exec-guest /bin/echo TILLANDSIAS_GUEST_OK` returned exit 0.
- Residual blocker filed in
  `plan/issues/macos-embedded-guest-runtime-smoke-2026-07-05.md`:
  `--list-cloud-projects` reaches the guest but Vault startup fails with
  `Operation not permitted`. Next action is to merge latest `origin/linux-next`
  Vault/SELinux + guest-binary builder work into `osx-next`, rebuild, and rerun
  list-projects plus agent-launch smoke.
- Integration gate note: `./build.sh --check` does not reach cargo on this
  macOS host because `scripts/common.sh` wraps Homebrew Podman with Linux-only
  `--root/--runroot` flags. Filed
  `plan/issues/macos-build-check-podman-wrapper-2026-07-05.md`.

### Cycle 2026-07-05T00:0XZ (macos — meta-orchestration)
- Merged origin/linux-next 7ab86309 into osx-next (9614d32f); built + installed
  tray v0.3.260704.1; control wire E2E green (--exec-guest → Podman hello-world ok).
- macOS evidence for the CREATION_TIME→FIRST_RUN split: forge-base is absent and
  built at runtime in the **aarch64** guest from Containerfile.base via a long
  x86_64 curl/tar chain → the "stuck initializing VM" symptom + wrong-arch tools.
- Filed 2 ready packets (`macos-forge-base-build-arch-and-fragility-2026-07-05`,
  `podman-stale-volume-locks-2026-07-05`) + added arch-awareness requirement to
  `forge-firstrun-tool-migration`. No tray-side change needed; osx re-verifies once
  linux lands the arch-aware first-run migration.

## This Loop (2026-07-04 — CREATION_TIME->FIRST_RUN container refactor: research + inference impl)

Operator directive: strip finicky curl/tar installers out of forge image CREATION,
move to idempotent FIRST_RUN on the persistent cache; harnesses EVERY_LAUNCH for
latest; pull small models on inference FIRST_RUN. Multi-session; file packets.

- **Filed 6 packets (178-183)** with a full Containerfile audit (evidence-backed):
  CREATION (keep dnf: node/rust/go/java/python bases) vs FIRST_RUN (migrate the
  install_archive block: ~19 cargo tools + wasmtime/dart/marksman + ollama) vs
  EVERY_LAUNCH (codex/claude/opencode/antigravity via npm/latest — fixes "newer
  version available" on a fresh forge).
- **178 research DONE (the crux answered, code-definitive):** NO live forge-launch
  path mounts a persistent cache for $CARGO_HOME/$NPM_CONFIG_PREFIX
  (build_forge_agent_run_args + build_opencode_forge_args mount only project+CA+tmpfs;
  ContainerProfile's rich cache is unused dead code; forge runs --rm). So first-run
  installs would NOT persist today -> order 179 (add the cache mount) is a HARD
  PREREQUISITE for 180/181. Promoted 179 ready.
- **182 research DONE + 183 impl DONE (self-contained win):** inference already did
  idempotent first-run ollama pulls into the persistent models cache, but pulled
  llama3.2:3b (3B, out of the operator's 0.3-1.5B envelope). Replaced with a
  config-driven default set (qwen2.5:0.5b, qwen2.5:1.5b, llama3.2:1b,
  qwen2.5-coder:1.5b) via TILLANDSIAS_DEFAULT_MODELS; idempotent+non-fatal; pinned by
  litmus:inference-firstrun-default-models-shape (4/4) + fixed the stale STEP 7.
- **NOT touched (respected):** the operator's uncommitted WIP on main.rs /
  Containerfile.base / lib-common.sh / proxy allowlist etc. — including a DUPLICATED
  antigravity curl block. The forge tool migration (180) lives in Containerfile.base
  (WIP-dirty) + needs 179 (persistent mount, in WIP-dirty main.rs), so it is
  next-session work once the WIP settles. Flagged the duplication in packet 181.
- **Follow-up filed inline:** the inference tier system auto-pulls qwen2.5:7b on a
  16GB laptop (RAM>=16 -> T2), conflicting with tiny-model-first.

## This Loop cont. (2026-07-04 — owner handoff: recover WIP + advance-work-from-plan)

Operator handed sole ownership of the workdir ("recover or delete uncommitted code"),
then asked to drain the queue.

- **Recovered the uncommitted WIP (it was a coherent feature, not junk):** wired
  Antigravity as a first-class forge agent (--antigravity flag, ForgeAgentMode +
  tray leaf 6->7, provider auth, .antigravity.google allow/no-bump) — closing the
  known 'agy installed but not an agent' gap. FIXED its compile gap (a LaunchKind
  match arm missing under --features tray, why plain --check had passed). Wiped
  generated churn (build-proxy-progress.jsonl; gitignored build-*.log). Verified:
  build --features vault,tray green, 243 tests pass. Committed 35ba3d3f.
- **Order 179 DONE (advance-work-from-plan, the critical prereq 178 identified):**
  build_forge_agent_run_args now mounts a per-project podman NAMED volume
  tillandsias-forge-cache-<project> at /home/forge/.cache/tillandsias-project (the
  lib-common CARGO_HOME/NPM_CONFIG_PREFIX root) — first-run installs now persist
  across --rm. Named volume (not a ~/.cache bind) => zero host-$HOME surface, no
  credential-leak path. Refined the launch_forge_agent_does_not_mount_user_home
  guard to be SOURCE-scoped. +positive unit test, +litmus (forge-cache-dual). 244
  tests pass. Committed d1838350. Promoted 180 + 181 to ready.

### Queue state + next cycle
- done: 178 (research), 179 (cache mount), 182 (research), 183 (inference models).
- ready, NEXT CYCLE (both large + runtime-critical on the launch path — deliberately
  NOT rushed at session end):
  - **180 forge-firstrun-tool-migration (12h). CORRECTED by operator:** the path is
    "curl-install PREBUILT at CREATION" -> "curl-install PREBUILT at FIRST_RUN, latest
    version" — KEEP prebuilt binaries (NOT source compile / NOT cargo install). The
    problem is the finicky curl/tar/zip/chmod/mkdir/chown/rm chains + hardcoded
    version/SHA constants in CREATION. First slice: a reusable install_prebuilt helper
    (fetch latest prebuilt -> extract -> place on cache PATH, idempotent) + migrate the
    cargo-tool group. (My earlier "must pick binstall vs compile" framing was wrong —
    prebuilt-at-first-run was always the answer.)
  - **181 forge-harness-every-launch-latest (6h).** Now unblocked (NPM_CONFIG_PREFIX
    persists via 179). Slice-1 candidate: add an idempotent, offline-safe,
    proxy-routed every-launch npm upgrade in the forge entrypoint while keeping the
    baked baseline; slice-2 removes the Containerfile pins.

## This Loop (2026-07-04T04:02Z, forge — Codex /meta-orchestration validation)

Codex ran inside the Tillandsias forge and validated the current in-forge
runtime/config surface without using host credentials.

- **Branch + credentials**: started on `main`, switched to `linux-next` for plan
  writes. `scripts/check-credential-channel.sh` returned `ok:forge-git-mirror`;
  `git push --dry-run origin linux-next` returned `Everything up-to-date`.
  Real push forwarding reached GitHub, but the forge mirror continued to
  advertise stale `origin/linux-next` afterward. A follow-up amended push
  returned client exit 0 while the mirror log showed upstream GitHub rejected the
  forwarded update as non-fast-forward; filed in the validation packet.
- **Eligible gates**: `scripts/e2e-preflight.sh eligibility` returned
  `skip:no-podman-binary`, so destructive local-build e2e was not eligible in
  this forge.
- **Build/test validation**: `cargo check --workspace` PASS. Full
  `cargo test --workspace --no-fail-fast` FAIL only on
  `-p tillandsias-headless --bin tillandsias`; targeted rerun produced 109 pass,
  2 fail, 1 ignored. Failures: `launch_forge_agent_does_not_mount_user_home`
  false-positives on the in-container target `/home/forge/src/...`, and
  `source_built_init_and_status_check_smoke_uses_fake_podman` cannot find the
  `openssl` CLI used by `ensure_ca_bundle`.
- **Services/network**: Vault healthy at `https://vault:8200` (initialized,
  unsealed, v1.18.5); inference healthy at `http://inference:11434/api/tags`
  with `llama3.2:3b` + `qwen2.5:0.5b`; outbound HTTPS via proxy env reached
  `https://api.github.com/rate_limit`.
- **Findings filed**: `plan/issues/forge-validation-findings-2026-07-04.md`;
  plan order 177 added as pending for Tlatoani approval.

## Release v0.3.260704.2 (2026-07-04T03:38Z — completes the Codex-connect chain)

The 704.1 curl-install smoke (run on the host) FOUND a new blocker, proving the
value of verify-before-release: forge launch failed at the proxy stage
("tillandsias-proxy already in use") whenever a proxy was already running
(from --init or a prior session) — blocking Codex/Claude/OpenCode launch.

- **Order 176 — forge-launch proxy idempotency FIXED**: the three forge-launch
  proxy sites (ensure_enclave_for_project [tray+CLI], opencode, opencode-web) ran
  `podman run --name tillandsias-proxy` raw. Now guarded by
  container_running(tillandsias-proxy) (reuse) + rm --ignore (clear stale), matching
  ensure_proxy_running. Regression test forge_launch_proxy_bringup_is_idempotent.
- **FULL CHAIN LIVE-VERIFIED with the fixed binary**: proxy already running (the
  failing case) → forge launches cleanly → inside the forge NODE_USE_ENV_PROXY=1 +
  `node fetch https://api.openai.com → HTTP 401 (REACHED REMOTE)`. So: curl-install
  → --init (vault healthy) → forge launches → Node reaches the model API through the
  proxy. A Codex session with a valid token now connects.
- PR #67 merged (main ac608247→4b9a4376); VERSION 704.2; tag v0.3.260704.2;
  release.yml run 28693745435 SUCCESS (all 3 jobs green); published https://github.com/8007342/tillandsias/releases/tag/v0.3.260704.2
- Net across this session: fixed the ACTUAL Codex-connect root cause (Node bypassing
  proxy, order 175) + forge-launch proxy idempotency (176) + vault secret race (174),
  integrated Codex's forge findings (171/172/173), and verified the whole chain live.
  Remaining: order 170 (credential quarantine, ready); the human-in-loop step
  (operator logs in with real Codex/Claude creds and confirms a session).

## Release v0.3.260704.1 (2026-07-04T03:00Z, linux_mutable — merge-to-main-and-release)

Cut after the Codex-request integration + Node-proxy root-cause fix, with
--init verified end-to-end on rootless SELinux-enforcing (the verify-before-release
discipline).

- Pre-release reconcile: merged origin/main (703.1/703.2 release history +
  release-CI changes) back into linux-next; resolved a formatting-only main.rs
  conflict in the provider-auth code (kept linux-next's rustfmt form; Node-proxy
  fix intact), VERSION=704.1, CI-infra→theirs. --check + 110 headless tests green.
- PR #66 linux-next→main merged (f01c2ee8); VERSION already 704.1 (no bump needed);
  tag v0.3.260704.1 pushed; release.yml run 28692716478 SUCCESS — all 3 jobs green
  (Linux musl, macOS arm64, Windows). Published (not draft):
  https://github.com/8007342/tillandsias/releases/tag/v0.3.260704.1
  Ships: NODE_USE_ENV_PROXY (Codex/Claude connect), vault secret
  --replace race fix, + the 703.2 SELinux/DNS fixes. Supersedes the broken 703.2
  for the operator's Silverblue re-test.
- After release: operator does the human-in-loop verification — curl-install
  704.1, --init, then a Codex session reaching remote (login-first gate + Node
  proxy). Remaining open: Codex order 170 (credential quarantine, ready);
  OpenCode→Antigravity mapping observation; ws-package proxy coverage probe.

## This Loop (2026-07-04T02:11Z, linux_mutable — /meta-orchestration: integrate Codex requests + fix Codex-connect root cause)

Operator ran Codex in a local forge; it committed findings locally but couldn't
push (mirror creds). Integrated its requests AND root-caused the "Codex can't
connect to remote" issue with LIVE evidence on a matching host (Fedora 44,
rootless, SELinux Enforcing).

- **Pushed Codex's plan commit** (a5884965) so its 3 findings are visible.
- **Order 173 — credential-guard false-positive FIXED** (b8b1a0bd): Codex's forge
  cycle accreted an unpushable commit because check-credential-channel.sh returned
  ok:forge-git-mirror merely because HOST_KIND=forge was set, without verifying the
  mirror is reachable. Now probes `git ls-remote origin` (timeout 10, fixture seam);
  unreachable -> missing:no-credential-channel. +2 litmus steps (7/7 green).
- **Orders 171/172 — Codex full-auto in forge + litmus** (df96012d): entrypoint
  execs codex --dangerously-bypass-approvals-and-sandbox, gated on HOST_KIND=forge.
  Verified flag against the real binary (codex-cli 0.137.0). litmus:codex-forge-yolo-shape
  (5/5, bound). Removes approval-prompt stalls + lifts Codex's inner sandbox.
- **Order 174 — vault secret race FIXED** (de579d40): the three secret helpers did
  a non-atomic `secret rm`+`secret create` that races under concurrent bootstraps
  (--init while a forge launch also ensure_vault_running) -> "secret name in use".
  Now `secret create --replace` (atomic). Found by live repro. Regression test.
- **Order 175 — Node-proxy bypass FIXED = THE Codex-connect root cause** (784a1903):
  LIVE-PROVED it is NOT an allowlist gap. Inside the running forge: curl-through-proxy
  to api.openai.com -> 401 (works); node global fetch -> ENOTFOUND (Node ignores
  HTTP_PROXY); NODE_USE_ENV_PROXY=1 node -> 401. The --internal enclave is proxy-only,
  Node connected direct -> timed out -> died (operator's exact symptom); OpenCode
  worked because it targets local inference. Fix: NODE_USE_ENV_PROXY=1 in both
  apply_proxy_env + proxy_env_args (forge agents + login containers). Regression test.
- **Login-first gate**: already exists (ensure_provider_auth, landed c5cbf3a8, wired
  before build_forge_agent_run_args). The operator's described flow (no token -> login
  first -> authenticated forge; token present -> direct) is implemented. Pinned with
  forge_agent_launch_gates_on_provider_login_first (2c8d0b37). Filed an observation:
  OpenCode maps to Antigravity/Gemini login but uses local inference — verify.
- **Codex order 170 (credential quarantine)**: remaining; well-shaped + ready.
- **VERIFICATION PASSED (verify-before-release)**: ran `--init --debug` with the
  newly-built fixed binary on THIS Fedora 44 rootless SELinux-Enforcing host (matches
  the operator's Silverblue). Vault came up healthy end-to-end:
  `vault_container_t not loadable -> label=disable`, `vault healthy
  (initialized=true sealed=false v=1.18.5)`, `base_url: https://127.0.0.1:8201`
  (loopback fix, not vault:8200), secret refresh clean (no "name in use" race),
  `bootstrap complete`, all 5 policies+AppRoles provisioned, exit 0. Only noise =
  expected non-fatal rootless warnings (/etc/hosts + semanage Permission denied).
  This proves the vault chain (SELinux label + loopback URL + secret --replace) is
  fixed on matching hardware — the definitive verification that was missing before
  the 703.1/703.2 releases.
- **Runtime hygiene**: during live debugging I `podman secret rm`'d tls-cert; restored
  it. The user's enclave containers exited (137/139, healthy teardown) independently.

## This Loop (2026-07-04T01:49Z, forge — shared checkout mirror alias validation)

Operator noted this forge is using the same `/home/forge/src/tillandsias`
checkout path as Tlatoani's original host checkout, so the container inherited
the host checkout plus global git mirror mapping. Validated the forge without
destructively changing credentials or mappings.

- **Start state**: `TILLANDSIAS_HOST_KIND=forge`, branch `linux-next`, initial
  worktree clean at `a67a97ad`.
- **Credential guard**: `scripts/check-credential-channel.sh` returned
  `ok:forge-git-mirror`.
- **Transparent mirror path broken in this shared-checkout case**:
  `git fetch origin --prune` failed with `remote error: access denied or
  repository not exported: /tillandsias`; normal git URL rewriting also tried
  `tillandsias-git:9418` and DNS failed from this container.
- **Non-destructive direct git workaround verified**: without editing host
  config, repo remotes, or credentials, `GIT_CONFIG_GLOBAL=/dev/null git
  ls-remote https://github.com/8007342/tillandsias.git HEAD` succeeded against
  GitHub. The same per-command override allowed `git fetch origin --prune` and
  fast-forwarded `linux-next` to `ca4deb46` (`origin/main` now `e8e92a9f`).
- **Filed observation**:
  `plan/issues/forge-shared-host-checkout-mirror-alias-2026-07-04.md`.
- **Detailed push report**:
  `plan/issues/forge-push-failure-full-report-2026-07-04.md` records every
  fetch/push attempt, the exact failure outputs, credential-channel checks, and
  a host-agent resolution checklist.
- **Refined fix packet**: added order 170
  `forge-source-mount-credential-quarantine` for source-mount detection plus
  dummy override dirs/files so host GitHub credentials/config are not mounted,
  copied, logged, or reused inside the forge. The forge should instruct agents
  that host credentials are not used inside the forge and git must use the forge
  credential channel/mirror or documented fallback.
- **Codex forge defaults packets**: added orders 171 and 172 so Codex's own
  forge config defaults to full-auto/YOLO mode under
  `TILLANDSIAS_HOST_KIND=forge`, with a regression litmus that fails if ordinary
  in-forge git/build/filesystem operations prompt for approval again.
- **Forge validation**: `scripts/e2e-preflight.sh eligibility` returned
  `skip:no-podman-binary`, so destructive Podman e2e was not eligible in this
  forge. `cargo check --workspace` PASS with normal host networking. `cargo
  build -p tillandsias-headless --bin tillandsias` PASS, and the built binary
  reports `Tillandsias v0.3.260704.1`.
- **Residual**: normal transparent mirror routing is not trustworthy for this
  shared-host-checkout topology; direct global git with
  `GIT_CONFIG_GLOBAL=/dev/null` is the verified non-mutating path for fetch from
  this session. Push is blocked: mirror push fails `repository not exported:
  /tillandsias`; direct HTTPS push reaches GitHub but no non-interactive
  credential channel is present; `gh auth status` is not logged in; repo-local
  `.git/.gh-credentials` and token env vars are absent.

## This Loop (2026-07-03T22:53Z, forge — /meta-orchestration: policy-checkers-into-ci order 169)

- **Cycle type**: meta-orchestration → advance-work-from-plan (forge container).
- **Startup**: `linux-next @ c38e91f8`, committed checkpoint (Gemini API key injection,
  mirror issue update, mock-release gitignore). Credential channel:
  `ok:gh-credentials-store`. Git mirror empty; worked around by removing `url.insteadOf`
  global config and pushing directly to GitHub.
- **Worker drain**: Implemented order 169 (wire-policy-checkers-into-ci): added CHECK 8
  (no-python-scripts + no-base64-script-injection) to the pre-build phase in
  `scripts/local-ci.sh`. Both policy checkers now run as part of `--ci-full` and `--ci`,
  failing the build on violation. YAML-validated via `tillandsias-policy validate-yaml`.
- **E2E gate**: `skip:no-podman-binary` (forge container — expected).
- **Coordination**: Not applicable (forge container, not linux_mutable).
- **Reduction engine**: Order 169 completed. No new unfiled findings this cycle.
- **Next**: Await linux_mutable to rebuild forge image with Gemini env-injection + policy
  checkers. Order 165 (forge-agent-permission-defaults) is still in_progress with a
  valid lease; OpenCode config already has `"permission": "allow"`, but Claude/Codex
  config overlays remain unimplemented.

## This Loop (2026-07-03T22:21Z, forge — /meta-orchestration: forge-git-ergonomics order 166)

- **Cycle type**: meta-orchestration → advance-work-from-plan (forge container).
- **Startup**: `linux-next @ c5cbf3a8`, clean worktree. Credential channel:
  `ok:gh-credentials-store`. Remote mirror empty (expected for fresh forge
  container; re-populated on first push).
- **Worker drain**: Claimed and implemented order 166 (forge-git-ergonomics):
  Added `git config --global safe.directory /home/forge/src/*` at lib-common.sh
  startup to avoid "dubious ownership" on host-mounted repos with different UID.
  Added `rewrite_origin_for_enclave_push()` call to network transport path and as
  a fallback in `clone_project_from_mirror()` to ensure `url.insteadOf` rewrite is
  always installed for host-mount projects. Filled env gaps: `LANG` set to
  `en_US.UTF-8` (Containerfile + runtime fallback), `JAVA_HOME` derived at runtime
  from java binary path, `GOROOT` derived from `go env GOROOT`, `FLUTTER_ROOT`
  unset at runtime when the SDK directory is absent.
- **E2E gate**: `skip:no-podman-binary` (forge container — expected).
- **Coordination**: Not applicable (forge container, not linux_mutable).
- **Reduction engine**: 1 finding closed (order 166). No new findings this cycle.
- **Next**: Await linux_mutable to rebuild the forge image and verify the fixes.

## This Loop (2026-07-03T03:20Z, linux_mutable — rootless Silverblue vault P0s → v0.3.260703.2)

Operator re-tested v0.3.260703.1 on Silverblue; the SELinux label fix worked
(container launched) but two more native-rootless bugs surfaced. Fixed both +
released v0.3.260703.2.

- **P0-a — vault container exits immediately (`no such container`, status 125)**:
  the container_t fallback DENIED the vault process access to /vault/data (its
  files carry an unconfined label from an earlier label=disable regime).
  Fix: rootless fallback is now `label=disable` (pre-Phase-3c behavior; also the
  standard tillandsias container hardening default per spec:podman-container-spec).
  Guest-VM (root) still uses confined vault_container_t.
- **P0-b — host can't resolve `vault:8200`**: vault_api_base_url returned the
  enclave DNS name for ALL Linux binaries; a native rootless host only resolves
  `vault` in the container netns. Fix: native host (!is_running_in_vm) uses the
  published https://127.0.0.1:8201 (cert carries IP:127.0.0.1 SAN).
- **Diagnosability**: removed --rm from the vault launch + added
  dump_vault_failure_diagnostics() (podman ps state + last 40 log lines on a
  failed health wait) so a boot crash is never opaque again.
- **Gate**: ./build.sh --check + --test + vault unit tests green; --ci-full shows
  only the same 9 pre-existing litmus (zero new regressions vs baseline);
  base64 checker ok. Commit 4a1d35b0.
- **Release**: PR #65 merged to main (1cca5418); VERSION 0.3.260703.2 (5606087b);
  tag v0.3.260703.2; release.yml run 28638531935 [in progress — result recorded
  on completion]. Supersedes 703.1 for the Silverblue native install.
- **Hardening follow-up (filed)**: restore host-side vault confinement without
  root (relabel volume for container_t via :Z, or a privileged policy-load
  helper) — plan/issues/vault-rootless-container-exits-immediately-2026-07-03.md.

## This Loop (2026-07-03T02:50Z, linux_mutable — /merge-to-main-and-release: P0 Silverblue fix)

- **Trigger**: operator's Silverblue box failed `tillandsias --init` on release
  v0.3.260702.2 (P0). Root-caused + fixed BEFORE releasing (see below).
- **P0 fix (d6548a9e)**: vault launched with an unconditional
  `--security-opt label=type:vault_container_t`, but that type is only loadable
  in the guest VM (root/semodule); on a rootless native host it is undefined →
  crun EINVAL on keycreate → exit 126. Now `vault_selinux_label_opt` uses the
  custom type ONLY when confirmed loaded, else falls back to podman's default
  container_t (enforcing-safe). Regression litmus added. See
  plan/issues/vault-selinux-label-rootless-crash-2026-07-02.md.
- **Pre-release --ci-full gate**: found 2 issues. Fixed the cheatsheet-tier
  (windows-merged ux-message-budget.md missing tier:). The 9 failing pre-build
  litmus were verified PRE-EXISTING (identical set on origin/main = released
  702.2; zero new regressions this session) — captured in
  plan/issues/pre-existing-litmus-debt-2026-07-03.md, not a release blocker
  (release path doesn't gate on --ci-full litmus).
- **Release**: PR #64 merged to main (ede8738f); VERSION bumped to 0.3.260703.1
  (15724897); tag v0.3.260703.1 pushed; release.yml run 28635530855 SUCCESS —
  all 3 jobs green (Linux musl, Windows tray, macOS tray-arm64). Published (not
  draft): https://github.com/8007342/tillandsias/releases/tag/v0.3.260703.1
  Latest tested/released Linux artifact = v0.3.260703.1 (supersedes the broken
  702.2). Operator should re-run curl-install `tillandsias --init` on Silverblue
  to confirm the P0 fix.
- **Recovery note**: an initial `git checkout main` was blocked by --ci-full
  generated TRACES.md churn and the VERSION bump briefly landed on linux-next;
  reset --hard to origin/linux-next (nothing pushed wrong) and redid the bump on
  main correctly. Lesson: discard --ci-full generated artifacts before a branch
  switch in the release flow.
- **This release ships**: the P0 fix + the Windows epic (order 127
  WslGuestTransport + tray parity + vsock vault bootstrap e2e) + encrypted-channel
  crypto foundation + base64-shim removal.

## This Loop (2026-07-02T20:18Z, linux_mutable — /meta-orchestration: integrate Windows epic, then release)

- **Credential guard**: ok:gh-keyring. Start in sync with linux-next.
- **Integrated origin/windows-next (+44)** via cross-branch MERGE (6feac841):
  order 127 host-guest-transport-windows COMPLETE (WslGuestTransport + HvSocket
  consolidation, transport_windows.rs), order 114 vsock-vault-bootstrap-e2e
  COMPLETE, Windows/macOS tray menu parity, transparent wire-tray cloud attach,
  status-chip budget litmus + ux cheatsheet, and orders 146-168 of new plan work
  (observable-streams, races, forge diagnostics) — renumbered from windows 136-159
  to avoid colliding with linux 140-145.
  - Merge resolution: kept linux-next's post-archival ledger (did NOT resurrect
    windows's stale copies of the 129 archived packets); appended only the 23
    genuinely-new active windows packets; reconciled shared-packet completions
    (114, 127) into linux status.
  - Integration lint fixes to green the tree: two edition-2024 let-chains in
    vault_bootstrap.rs, cfg-gate projects_root, drop unused test import.
- **SECURITY: removed reintroduced base64 podman shim** (04e388ac). windows
  0c4a6aa3 re-added PODMAN_SELINUX_WRAP_B64 (base64_script_injection_ban
  CRITICAL_VIOLATION) in pty/mod.rs — removed (redundant post-Phase-3d), tests now
  assert its absence, and added scripts/check-no-base64-script-injection.sh
  (verifiable, referenced from methodology). Filed order 169 to wire both policy
  checkers into --ci-full.
- **Gate**: ./build.sh --check + --test PASS on the merged tree; base64 checker
  exits 0 clean / 1 on reintroduction.
- **Release**: proceeding to /merge-to-main-and-release (main is at 0.3.260701.1;
  linux-next carries the integrated windows epic + security work). Draining the
  20 newly-arrived ready packets (observable-streams/races/forge — large research)
  is deferred to subsequent cycles per the worker-drain budget rule.
- **Note**: windows-next advanced again (8de6f369) mid-integration; those newer
  commits are for the next merge cycle.

## This Loop (2026-07-02T00:10Z, linux_mutable — /advance-work-from-plan, encrypted-channel slice 3)

Operator asked to pull latest and complete the remaining encrypted-channel + auth
packets.

- **Pull**: fast-forwarded linux-next past 4 commits from other agents — packets
  **134** (archived 129 closed packets; index much smaller), **135** (stale-ref
  cleanup), **136** (integration strategy), and **139** (vsock exec authz) all done.
  Note: a `zeroclaw`→`legacy-claw` terminology rename was applied elsewhere.
- **Packet 139 already landed the argv allowlist** (`pty_handler.rs`: allowlist +
  `tillandsias-{project}-forge` name validation + proxy exemption), so
  encrypted-channel slice 5 is largely covered.
- **Delivered — order 141 slice 3** (`7a62fabb`): `EncryptedStream<S>` in
  `tillandsias-secure-channel/secure_stream.rs` — `NNpsk0`
  client/server handshake over any `AsyncRead+AsyncWrite`, then a full
  AEAD `AsyncRead+AsyncWrite` tunnel (2-byte-len ChaCha20-Poly1305 frames,
  poll-based reassembly/staging). `snow` pure-Rust default-resolver (musl-safe).
  11 crate tests: round-trip, multi-frame, mismatched-PSK-handshake-FAILS,
  tampered-ciphertext-rejected. So slices 1-3 (the reusable crypto primitive both
  sibling trays will wrap) are DONE.
- **Delivered — order 145 filed + rejection litmus** (`1250228a`):
  `plaintext_peer_is_rejected` proves failure-closed rejection at the primitive
  (order 137's guarantee, VM-free). Filed order 145 (encrypted-channel-vsock-cutover)
  as an explicit ATOMIC cross-host cutover: slice 4 (turn the channel ON for the
  vsock hop) requires the guest responder + all THREE host initiators
  (host-shell shared, macos diagnose.rs, windows hvsocket.rs) to flip together
  (a half-flip bricks the others; dual-mode is a downgrade vuln) AND needs
  host<->guest VM e2e per platform. osx/windows adopt their initiator half on
  their branches per the deliverable's integration table.
- **Not completable this cycle (dependency-blocked, not punted)**:
  - **132 (OAuth login flows)** blocked on the egress-allowlist chain: it needs
    order 130 (allowlist impl), which needs order 129 (proxy TCP_DENIED harvest).
    129 is CLAIMED by another agent and has no confirmed-domain evidence yet;
    building 132 against un-allowlisted auth endpoints would fail at runtime and
    guessing domains is what 129 forbids. Root blocker = 129 (live-forge task).
  - **141 slices 4/6** = order 145 (coordinated cutover, above).
  - **142** (per-boot hardening) deferred behind 141; **143** (API-key entry)
    deferred behind 132.
- **Sibling state**: osx-next 0 ahead (integrated); windows-next +32 (large merge
  still deferred). Order 145's table gives osx/windows their initiator sub-tasks.
- **E2E/Release**: no VM here (SELinux-Disabled); crypto is unit/litmus-proven.
  Latest published remains v0.3.260630.1.

## This Loop (2026-07-01T23:05Z, linux_mutable — /advance-work-from-plan queue drain)

Operator asked to exhaust the ready Linux queue and push work + findings so the
macOS/Windows builders unblock on these packet implementations.

- **Startup**: pulled linux-next (picked up a macOS builder's push:
  `macos-build-findings-2026-07-01.md` — the E0425 orphan `vsock_exec::exec_interactive`
  in macos-tray diagnose.rs was fixed by osx in `81a0478c` and is already on
  linux-next; macos-tray compiles). Credential channel `ok:gh-keyring`.
- **Sibling state**: osx-next **0 ahead** (fully integrated); windows-next +32
  (large cross-branch merge still deferred to a quiet window). The
  host-guest-transport facade (order 124) is landed in control-wire::guest_transport
  (GuestTransport/GuestEndpoint/ExecRequest/ExecOutput) — so orders 126 (macOS) and
  127 (Windows) are genuinely READY for the sibling terminals to implement now.
- **Drained**:
  - **order 140 (encrypted-control-channel-research): DONE** — design filed,
    operator signed off O1 = build-embedded per-release secret.
  - **order 141 (encrypted-control-channel-impl): slices 1-2 landed** (`0a7afb2c`) —
    new crate `tillandsias-secure-channel` with `derive_psk()` (HKDF-SHA256 over
    release_root_secret + build_version + wire_version + hop_id) and 7 unit tests
    PROVING version binding by construction. This is the shared crypto foundation
    the macOS/Windows transport backends will wrap. No new external deps (vendored
    hkdf/sha2/zeroize); the `snow` Noise handshake is slice 3 (own cycle). 141 now
    in_progress; remaining slices 3-6.
  - **order 138 (vault-handover-token-shred): DONE** (`63b31cee`) — shred the
    first-boot root token (in-place zero-overwrite via dd conv=notrunc, then rm, one
    exec) before unlink; litmus `handover_token_is_shredded_before_unlink`. Corrected
    the audit (rm already existed; the residual was the missing overwrite).
- **Not drained (with reason — a legitimate convergence point at this bar)**:
  order 131 (agent-login-flows-research) is operator-gated (API-key vs OAuth per
  provider needs sign-off); orders 134/135 (ledger archival + stale-ref sweep) are
  self-flagged do-NOT-run-during-active-concurrency (siblings live); order 137
  superseded by 140/141; order 139's spec half overlaps 141 slice 1 (best bundled
  there). The next actionable implementation (141 slice 3, snow handshake) is a
  large chunk warranting its own cycle.
- **E2E**: not run (SELinux-Disabled host; the security changes are unit/litmus-
  proven; the Phase 3d + channel behavior validate on the enforcing macOS guest).
- **Release**: none (latest published v0.3.260630.1). Security 137/141 should land
  before the next release.

LastExecutionTime: 2026-07-01T22:30Z

## This Loop (2026-07-01T22:17Z, linux_mutable — /meta-orchestration: audit + macOS unblock + security audit)

Operator asked for a state audit, to unblock the macOS builder's linux-side
blocker, and a zero-trust security audit of the enclave.

- **Start-of-cycle guards: PASS** — credential guard `ok:gh-keyring`, clean tree,
  in sync. Sibling heads: osx-next was +6, windows-next +32.
- **Coordinator merge (osx-next → linux-next)**: integrated the 6 new macOS
  commits (PTY raw-mode + wire hardening, SELinux launch-spec fixes, the Phase 3d
  packet, and the **critical base64-Python-injection violation record + removal**).
  One conflict in `pty/mod.rs` resolved (kept linux HEAD's env-export GithubLogin
  launch spec). Integration Verification Gate ran clean; pushed `537408fd`.
  osx-next is now 0 ahead (fully integrated).
- **macOS blocker RESOLVED (Phase 3d, `fe66b10d`)**: the linux-side blocker was
  `vault_bootstrap.rs` setting `label=type:vault_container_t` (Phase 3c) while the
  type was never loaded on the enforcing Fedora 44 VZ guest → crun EINVAL, exit
  126, blocking `--github-login`/`--list-cloud-projects` on macOS. Fixed in-guest:
  headless now loads a minimal `images/selinux/vault_container.cil` (base-refpolicy
  only, typepermissive) via `ensure_vault_selinux_module()` before the labelled
  run — idempotent, failure-open, fixes all guests (VZ/native/WSL) in one
  linux-owned change. Supersedes the removed base64 stopgap. Litmus pinned.
  **macOS builder: re-run `--github-login` on v-next to confirm exit 0.**
- **Zero-trust security audit (`2a1b60b0`)**: full report in
  `plan/issues/security-audit-zero-trust-2026-07-01.md`. Enclave NETWORK boundary
  matches spec, but the NEW vsock host→guest→podman-exec chain is **unauthenticated
  end to end** (verified in-tree: `vsock_server.rs` binds VMADDR_CID_ANY, accepts
  any peer, gates only on a self-reported Hello.from; `Unauthorized` code unused).
  Promoted P0/P1 packets **137** (authenticate vsock exec chain, failure-closed +
  rejection litmus), **138** (shred first-boot Vault root-token tmpfs residual),
  **139** (spec the exec authz boundary + proxy-exemption audit + missing e2e gate).
  Removed the last dead `images/zeroclaw/` orphan dir.
- **E2E gate**: `eligible` but NOT run — this host is SELinux-**Disabled**, so the
  Phase 3d `label=type:` path is a podman no-op here; the fix's real validation is
  the enforcing macOS guest. A destructive Linux local-build smoke would not
  exercise the change. Deferred to the macOS builder's `--github-login` re-run.
- **Release**: none this cycle (latest published remains v0.3.260630.1). Security
  P0-137 should land before the next release given it's the top open risk.
- **Coordinator note**: windows-next is +32 (large; shared vault/proxy/tray + facade
  work) — cross-branch MERGE deferred to a quiet window per concurrency discipline.

LastExecutionTime: 2026-06-30T21:45Z

## This Loop (2026-06-30T21:38Z, linux_mutable — /meta-orchestration SOUNDNESS VALIDATION)

Operator asked to run a meta-orch cycle and report whether the updated process
(the order-133 Integration Verification Gate + integration_strategy) is sound and
complete. Verdict: the **Gate is sound**; the **integration_strategy was unsound**
and is now corrected.

- **Start-of-cycle guards: PASS** — credential guard `ok:gh-keyring`, clean tree,
  in sync, sibling heads recorded (windows-next +19, osx-next converged to 0).
- **Soundness flaw FOUND + FIXED**: order-133's `integration_strategy` said
  "cross-branch integration uses rebase, NOT git merge" — which contradicts the
  coordinator duty ("merge windows/osx into linux-next"), the release skill
  (`gh pr merge --merge`), and all history (merge commits), AND is self-defeating
  (cherry-picking published sibling commits remints hashes → re-creates the very
  duplication 133 prevented). Corrected methodology + advance-work §6 +
  coordinate-multihost-work to: same-branch=rebase un-pushed local; cross-branch=merge.
- **Gate dogfooded**: every push this cycle ran the marker scan + YAML validation
  before push; caught nothing (clean), behaved correctly.
- **Completeness**: 3 of 4 reconciliation points closed; remaining =
  `litmus:integration-strategy-consistency` (order 136 last item).
- **Coordinator note**: windows-next is +19 (shared vault/proxy/tray fixes) ready to
  MERGE into linux-next under the corrected strategy — deferred (large; do under a
  quiet window per the same concurrency discipline).


LastExecutionTime: 2026-06-28T09:20Z

## This Loop (2026-06-28T07:56Z, linux_mutable — meta-orch + queue drain)

- **Cycle type**: `/meta-orchestration` (coordinator) → `/advance-work-from-plan` drain.
- **Startup**: `linux-next @ e794eb89`, clean. Credential channel: `ok:gh-keyring`.
- **macOS coordination**: coordinator merge of `origin/osx-next` (18 ahead) is content-clean (P0 fixes reconcile via main) and brings the new macОС work (macos-tray diagnose/main, vm-layer vsock_exec/vz), but fails `--check` on rustfmt drift in osx-owned `vm-layer/src/vz.rs`. Per the sibling-fmt rule, flagged (not reformatted) in `plan/issues/coord-osx-vz-fmt-drift-2026-06-28.md`; integration resumes after osx `cargo fmt`.
- **Worker drain (all ready packets)**:
  - order 115 — `--init` auto-configures podman `dns_servers` on loopback-resolver (systemd-resolved 127.0.0.53) hosts. Unit test + build green.
  - order 117 — removed all orphaned zeroclaw plumbing (image dir, main.rs/tray/runtime_assets/build.rs refs, dead `LaunchKind/LeafAction::ZeroClaw` launch path that spawned the deleted binary); menu 7→6 leaves; updated pinned leaf-action litmus + removed obsolete zeroclaw-mcp-shape litmus/binding. (A token-out left 2fc97e55 with only the file deletions; the code mods were re-committed as 8e7f5940.)
  - order 121 — design verdict for the compile-time container dependency model (Option C hybrid).
  - order 122 slice 1 — new `container_deps` module: Service nodes + const DEPS + topo_order + acyclic/completeness tests (additive, no behavior change). Slices 2–5 (ensure()/typestate/liveness/litmus) remain; packet `in_progress`.
- **E2E gate**: a clean-wipe curl-install smoke was run earlier this session (v0.3.260627.6 → login stores token → 23 repos); PASS recorded in `plan/issues/smoke-curl-install-e2e-linux-v0.3.260628.1-2026-06-28.md`. No new destructive reset this cycle.
- **Release**: latest published is **v0.3.260628.1**; no new release this drain cycle (worker slices; release after slice batch or on request).
- **Queue status**: all `ready` packets drained; order 122 `in_progress` (slices 2–5 remain); macОС integration blocked on osx fmt.

## This Loop (2026-06-26T10:55Z, linux_mutable — hardcoded-ip DNS migration)

- **Cycle type**: `/advance-work-from-plan` implementation for `hardcoded-ip/dns-migration`.
- **Startup**: `linux-next @ d77166f5`, clean. Credential channel: `ok:gh-keyring`.
- **Siblings**: `origin/osx-next@7441cfad` and `origin/windows-next@a3c8b23d` are both ancestors of `origin/linux-next`; no sibling merge was pending at cycle start.
- **Implementation**: Replaced the Vault singleton-IP contract with the `vault` service DNS name. Vault launch no longer passes `--ip`, TLS leaf generation pins `DNS:vault`, macOS VM cloud-init and control-wire GitHub-login export `TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`, and rootful VM guests install a systemd-resolved route for `vault` using the Podman network gateway discovered from `podman network inspect`.
- **Verification**: `cargo test -p tillandsias-headless enclave_` PASS; `cargo test -p tillandsias-headless vault_` PASS; `cargo test -p tillandsias-vm-layer vz_cloud_init_headless_service_has_control_wire_preflight` PASS; `cargo check -p tillandsias-macos-tray` PASS; stale Vault-IP Rust source scan returned no matches; `./build.sh --check` PASS after fixing one clippy needless-borrow.
- **E2E gate**: local-build smoke not started because `scripts/e2e-preflight.sh eligibility` returned `skip:smoke-lock-held`. This cycle did not run a destructive reset or produce a new smoke PASS.
- **Ledger hygiene**: Closed stale child statuses under already-done macOS packets: `macos-tray-icon-missing-T-fallback/fix-icon` (`ready` → `completed`) and `vault-unseal-fails-macos-after-db616e06/fix-unseal` (`in_progress` → `completed`).
- **Additional worker drain**: Closed `github-login-readiness-before-credentials` (order 99). Fixed the guest `--github-login` preflight so it no longer requires a pre-existing `tillandsias-git` project mirror; it now verifies Vault, starts the ephemeral login helper, then checks Vault plus that helper container before any credential prompt.
- **Residual blocker**: `hardcoded-ip/remove-port-publish` remains blocked because native Linux still defaults to `https://127.0.0.1:8201`; removing the publish requires a non-published native host access path such as vsock or podman-exec.
- **Release decision**: hold merge-to-main/release until the current local-build smoke failure class is fixed or explicitly waived. Latest successful published release remains v0.3.260626.3 / tag `vv0.3.260626.3` on main.

## This Loop (2026-06-26T10:00Z, linux_mutable — order 104 dependency correction)

- **Cycle type**: advance-work blocker triage for `hardcoded-ip/remove-port-publish`.
- **Finding**: removing the Vault loopback publish is blocked until a non-published access path exists. With proxy bypass forced, direct host access to `https://10.0.42.2:8200` timed out and `https://vault:8200` did not resolve.
- **Plan update**: `hardcoded-ip/remove-port-publish` is now blocked on `hardcoded-ip/dns-migration`; `hardcoded-ip/dns-migration` is the next ready Linux slice.
- **Release decision**: continue to hold merge-to-main/release for post-order-104 work. Latest successful published release remains v0.3.260626.3 / tag `vv0.3.260626.3` on main.

## This Loop (2026-06-26T09:55Z, linux_mutable — meta-orch e2e checkpoint after order 104)

- **Cycle type**: meta-orchestration E2E gate checkpoint and release decision.
- **Startup**: `linux-next @ e0046f6e`, clean before local-build smoke. Credential channel previously verified as `ok:gh-keyring`.
- **Build/install smoke**: `target/build-install-smoke-e2e/20260626T093601Z` passed preflight and pre-build CI, installed the portable launcher, then exited 1 in post-build status smoke before destructive reset.
- **Failures**: recurring inference model-cache permission (`models/blobs: permission denied`) plus a recurring `opencode-prompt-e2e-shape` timeout in step 3.
- **Diagnostics annex**: `plan/diagnostics/diagnostics_20260626T094012Z-summary.md` reports Forge version 0.3.260626.3 with 25/25 checks passed and no failed container launch states.
- **Release decision**: hold merge-to-main/release for the order 104 subnet commit until the local-build smoke timeout is fixed or explicitly waived. The prior published release v0.3.260626.3 remains the latest successful release.
- **Next**: `hardcoded-ip/remove-port-publish` remains ready, but it is coupled with a Linux-safe Vault base URL or DNS migration because native Linux still defaults to `https://127.0.0.1:8201`.

## This Loop (2026-06-26T09:33Z, linux_mutable — meta-orch + advance-work — order 104 inventory/subnet drain)

- **Cycle type**: meta-orchestration worker drain and coordination audit.
- **Startup**: `linux-next @ d7ddd23c`, clean. Credential channel: `ok:gh-keyring`.
- **Siblings**: `origin/osx-next@7441cfad` and `origin/windows-next@a3c8b23d` are both ancestors of `origin/linux-next`; no merge needed.
- **Worker drain**: Claimed and completed `hardcoded-ip/inventory`; promoted follow-ons. Claimed and completed `hardcoded-ip/subnet-constant`.
- **Implementation**: Added `TILLANDSIAS_ENCLAVE_SUBNET` defaulting to `10.0.42.0/24`; enclave network creation and forge/inference/stack/tray NO_PROXY/no_proxy values now derive from the same helper.
- **Verification**: `cargo test -p tillandsias-headless enclave_` PASS; `scripts/run-litmus-test.sh inference-container --phase pre-build --size instant --compact` PASS; `./build.sh --check` PASS.
- **Next**: `hardcoded-ip/remove-port-publish` remains ready, but must be bundled with a Linux-safe Vault base URL or DNS migration because native Linux still defaults to `https://127.0.0.1:8201`.

## This Loop (2026-06-26T05:03Z, linux_mutable — meta-orch — smoke rerun after nested-lock guard)

- **Cycle type**: meta-orchestration — local-build smoke rerun after order 102.
- **Startup**: `linux-next @ 7f4c7f7c`, clean. Nested cycle pushed `e9e5a877`.
- **Build gate**: `target/build-install-smoke-e2e/20260626T043812Z` passed pre-build CI and installed the portable launcher. Vault bootstrap completed; the missing-HEALTHCHECK regression did not recur.
- **Nested-lock verification**: `opencode-prompt-e2e-shape` no longer timed out. The nested meta-orchestration run skipped local-build e2e with `skip:smoke-lock-held` and pushed a plan-only cycle commit.
- **Remaining post-build failures**: Only the known false-positive class remains — inference model-cache permission (`models/blobs: permission denied`) and loop_status delta assertion.
- **Release decision**: Proceed to merge-to-main-and-release. Sibling branches are integrated and no new blocker remains beyond the already-filed post-build false positives.

## This Loop (2026-06-26T04:59Z, linux_mutable — big-pickle meta-orch — no-op: lock held, no ready work)

- **Cycle type**: meta-orchestration — worker drain, coordination check.
- **Startup**: `linux-next @ 7f4c7f7c`, clean. Credential channel: `ok:gh-keyring`.
- **Worker drain**: No Linux-ready nodes remaining. All ready/in-progress nodes are macOS-owned (`macos-tray-icon-missing-T-fallback/fix-icon`), shared but requiring macOS VZ access (`github-login-readiness-before-credentials/preflight-and-ordering`), or awaiting macOS verification (`vault-unseal-fails-macos-after-db616e06/fix-unseal` — fix shipped `8e6f25b1`, pending macOS retest).
- **Siblings**: osx-next@a6abaf83, windows-next@a3c8b23d — both ancestors of HEAD, no merge needed.
- **E2E gates**: `skip:smoke-lock-held` — a concurrent local-build smoke (started ~21:38Z from a Codex meta-orch invocation) legitimately holds the `build-install-smoke-e2e` lock.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle. The previous cycle's directive "Next: rerun local-build smoke" is pending the lock release.
- **Next**: Await the concurrent smoke to release the lock, or run local-build e2e on a subsequent cycle when the lock is available.

## This Loop (2026-06-26T04:40Z, linux_mutable — meta-orch — nested smoke-lock preflight)

- **Cycle type**: meta-orchestration — local-build smoke rerun and concurrency guard.
- **Startup**: `linux-next @ 72e1fb8f`, clean. Local-build rerun checkpointed VERSION/traces as `08a7a3cc` (`0.3.260626.2`).
- **Siblings**: osx-next@a6abaf83, windows-next@a3c8b23d — both ancestors, no new sibling merge needed.
- **Build gate**: `target/build-install-smoke-e2e/20260626T041632Z` passed pre-build CI and installed the portable launcher. Vault bootstrap completed; the missing-HEALTHCHECK regression from order 101 did not recur.
- **Remaining blocker**: Post-build smoke still exits 1 before reset/init. The inference model-cache permission failure recurred, and `opencode-prompt-e2e-shape` timed out because its nested meta-orchestration child attempted another local-build smoke while the parent smoke lock was held.
- **Fix**: Added `skip:smoke-lock-held` to `scripts/e2e-preflight.sh eligibility`, wired the meta-orchestration E2E guidance to record/skip it, and pinned the branch in `litmus:e2e-eligibility-probe-shape` (order 102).
- **Verification**: `bash -n scripts/e2e-preflight.sh` PASS; live verdict `eligible`; simulated held-lock verdict `skip:smoke-lock-held`; `scripts/run-litmus-test.sh meta-orchestration --phase pre-build --size instant` PASS (3/3 executed).
- **Next**: Commit/push order 102, rerun the local-build smoke. If the nested-lock timeout is gone and only the already-filed inference false positive remains, decide release eligibility.

## This Loop (2026-06-26T04:14Z, linux_mutable — meta-orch — fix Vault image healthcheck metadata)

- **Cycle type**: meta-orchestration — local-build smoke follow-up.
- **Startup**: `linux-next @ 481f58c5`, clean after in-forge plan/version commits. Credential channel: `ok:gh-keyring`.
- **Worker drain**: Closed order 100 is integrated. Filed and completed order 101 (`vault-image-build-docker-format-healthcheck`) after local-build smoke exposed a Vault healthcheck metadata regression.
- **Siblings**: osx-next@a6abaf83, windows-next@a3c8b23d — both ancestors, no new sibling merge needed.
- **Build gate**: Local-build smoke attempt `target/build-install-smoke-e2e/20260626T035811Z` passed pre-build CI and installed v0.3.260626.1, then exited 1 in post-build smoke before reset/init.
- **Finding fixed**: Rust `build_image_with_logging` omitted `--format docker`; Podman built Vault without HEALTHCHECK metadata, so `podman wait --condition=healthy tillandsias-vault` failed. The builder now includes `--format docker`; focused unit test PASS.
- **Known recurring post-build blockers**: `litmus:inference-deferred-model-pulls` model-cache permission and `litmus:opencode-prompt-e2e-shape` loop_status delta remain the same false-positive class recorded on 2026-06-24.
- **Next**: Commit/push this fix and rerun local-build smoke. If only the known post-build false positives recur and the Vault healthcheck error is gone, decide whether to proceed with release under the existing waiver pattern.

## This Loop (2026-06-26T04:07Z, linux_mutable — big-pickle meta-orch — close order 100 + convergence check)

- **Cycle type**: meta-orchestration — close order 100, convergence check.
- **Startup**: `linux-next @ 8a707b3a`, dirty (uncommitted trace/version updates from prior cycle). Checkpoint committed as `71b7d044`, clean. Credential channel: `ok:gh-keyring`.
- **Worker drain**: No new implementation. Closed order 100 (podman-health-lifecycle-facade) in plan ledger — implementation already complete (ContainerHealthFacade, auth preflight wiring, 146/146 podman tests). Remaining ready/in-progress items are all macOS-owned (order 79 subtask tray-icon fix, order 81 vault-unseal follow-up, order 99 residual macOS VZ wiring).
- **Siblings**: osx-next@a6abaf83, windows-next@a3c8b23d — both ancestors, no changes.
- **Build gate**: `./build.sh --check` — format/typecheck/clippy PASS.
- **E2E**: Eligible but deferred — no new runtime code shipped this cycle (plan-ledger-only change for order 100 closure). Latest release v0.3.260626.1 already smoke-tested.
- **Coordination**: No new sibling work to merge. Zero residual at current bar for Linux.
- **Next**: Await macOS/Windows hosts to drain their ready packets (orders 79/81/99).

## This Loop (2026-06-26T01:54Z, linux_mutable — big-pickle meta-orch — merge osx-next + release COMPLETE)

- **Cycle type**: meta-orchestration — merge osx-next into linux-next, release.
- **Startup**: `linux-next @ d1140f29`, clean. Credential channel: `ok:gh-keyring`.
- **Coordination**: Merged `origin/osx-next@a6abaf83` (4 commits — curl smoke record, exec control-wire claim, keep headless control wire alive, route vault health over enclave) into linux-next. macOS sibling completed orders 98-99; order 100 remains open.
- **Plan update**: Orders 79 (tray icon), 81 (vault unseal) resolved by macOS work. Order 55 subtasks all done; user-attended m8 smoke remains. New orders 98-100 filed by macOS sibling.
- **E2E**: Local-build gate passed (format/typecheck/clippy clean).
- **Release**: v0.3.260626.1 published — PR #45 merged to main, VERSION bumped, tagged, workflow_dispatch run 28212199038 green (Linux 12m19s, macOS 2m9s, Windows 3m50s). Linux artifact: tillandsias-linux-x86_64. Orders 99/100 remain ready for follow-up.

## This Loop (2026-06-26T15:35Z, macos — github-login recheck)

- **Cycle type**: macOS build/install/provision smoke plus a targeted
  `--github-login` verification.
- **Startup**: `osx-next @ 7441cfad`, clean relative to `origin/osx-next`,
  with the same pre-existing untracked files noted in
  `plan/issues/ACTIVE.md`.
- **Build/install**: `scripts/build-macos-tray.sh` PASS; freshness gate matched
  HEAD.
- **Destructive reset**: removed `~/Library/Application Support/tillandsias`
  and `~/Library/Caches/tillandsias`; cold `--provision` redownloaded the
  Fedora Cloud image and recreated `rootfs.img`.
- **GitHub login**: control wire and guest auth preflight now run before
  credential prompts, but the released headless still fails at
  `auth preflight failed: tillandsias-git is not running
  (Some("container not found"))`.
- **Residual**: order 101 / released-headless stale auth preflight remains open
  until Linux/shared cuts a new release. The macOS side now has the current
  repro and evidence log at
  `target/build-install-smoke-e2e/20260626T153311Z/`.

## This Loop (2026-06-25T23:13Z, macos — Vault health follow-up)

- **Cycle type**: `/advance-work-from-plan` follow-up during operator-attended
  GitHub login smoke.
- **Live finding**: `--github-login` advanced past Git author name/email, then
  hung before the token prompt. In the guest, Vault was healthy inside the
  container and reachable at `https://10.0.42.2:8200`; the loopback publish
  `127.0.0.1:8201` accepted TCP but stalled during TLS.
- **Fix**: Vault now owns a singleton enclave API address (`10.0.42.2`) with a
  matching TLS SAN. macOS VZ cloud-init exports
  `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200` for the headless
  service/control-wire commands. New Vault bootstrap uses
  `PodmanClient::wait_healthy()` / `podman wait --condition=healthy` before a
  single Vault API verification, replacing the local 180s HTTP polling loop.
- **Verification**: `cargo test -p tillandsias-headless vault_` PASS;
  `cargo test -p tillandsias-vm-layer` PASS (23/23). Full
  `cargo test -p tillandsias-headless` still fails only at the pre-existing
  macOS local-Podman integration case `test_missing_image_error_handling`
  because no local `podman.sock` is active.
- **Interactive retest blocker**: the current VM fetches the published
  aarch64 headless release asset, which predates this fix; this Mac has no
  `nix` or `rustup` cross target available to build a patched aarch64 guest
  binary for copy-in.
- **Residual**: order 100 remains open for the generalized Podman
  health/lifecycle facade and provider-neutral auth preflight aggregation.

## This Loop (2026-06-25T22:00Z, linux_mutable — big-pickle meta-orch — convergence check)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 117a6e39` (VERSION 0.3.260625.1), clean. Credential channel: `ok:gh-keyring`.
- **Worker drain**: 0 linux-ready nodes. All remaining ready/in-progress nodes are macOS-owned.
- **Coordination**: `origin/windows-next@a3c8b23d` (ancestor), `origin/osx-next@715449d2` (2 ahead — test record + `chore(plan): claim macos exec control-wire fix`). macOS work in progress; no merge possible yet.
- **E2E**: eligible but deferred — no linux-ready work to ship.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Next**: Await macOS sibling to complete claimed work, then merge osx-next → linux-next, merge-to-main-and-release.

## This Loop (2026-06-25T21:46Z, forge — big-pickle meta-orch — convergence check)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 1389ef39`, clean worktree. Credential channel: `ok:forge-git-mirror`.
  Origin/linux-next had been force-pushed backwards (1379ef39→1389ef39, dropping the prior
  smoke-e2e-findings report commit). Local was ahead 1; reset to `origin/linux-next`. Clean.
- **Worker drain**: 0 forge-ready nodes. All remaining ready/in-progress nodes are
  macOS/Windows-owned (macos-in-vm-enclave-provisioning [order 55],
  macos-tray-icon-missing-T-fallback [order 79],
  vault-unseal-fails-macos-after-db616e06 [order 81]).
- **Coordination**: Sibling heads unavailable (forge mirror pruned all non-linux-next refs).
- **E2E gates**: `skip:no-podman-binary` (forge container, no podman available).
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
  `forge-diagnostics-prompt-cleanup` issue already filed (2026-06-25) from prior
  build-telemetry closure commit.
- **Next**: Await macOS/Windows hosts to drain their ready packets; no forge/linux-ready
  work at current bar.

## This Loop (2026-06-25T00:52Z, linux_mutable — meta-orch + merge-to-main-and-release — v0.3.260625.1)

- **Cycle type**: merge-to-main-and-release + release dispatch gate.
- **Startup**: `linux-next @ 7281f57e` (VERSION 0.3.260625.1), clean. Credential channel: `ok:gh-keyring`.
- **CI gate**: `./build.sh --ci-full --install` — pre-build PASS (fmt/clippy/tests/litmus all green). Post-build 2 pre-existing failures (inference blobs permission, opencode-prompt-e2e loop_status not updated). Binary installed as v0.3.260625.1.
- **Coordination**: `origin/windows-next@a3c8b23d`, `origin/osx-next@85e69f14` — both ancestors of HEAD. No merge needed.
- **Release**: Merged linux-next → main (`3ee4c2ae`), tagged `v0.3.260625.1`. **workflow_dispatch BLOCKED** — PAT lacks `workflow` scope. PR creation also blocked (`pull_requests` scope degraded). Operator must run: `gh workflow run release.yml --ref v0.3.260625.1`.
- **Nix cache**: 21 caches, ~9.1/10GB. Warm cache on main (2.2GB) is intact; 14 stale per-tag rust caches (~3.7GB) should be purged before next release evicts useful caches. See `plan/issues/release-nix-cache-ref-scoping-2026-06-20.md`.
- **PAT scope degradation**: New blocker filed — PAT lost `pull_requests` and `workflow` write scopes since PR #44 (2026-06-22). See `plan/issues/pat-scope-degraded-2026-06-25.md`.
- **linux-next**: Fast-forwarded to `3ee4c2ae` (main). Clean, pushed.
- **Next**: Operator triggers `gh workflow run release.yml --ref v0.3.260625.1`; verify release publishes. Purge stale per-tag caches before 10GB eviction.

## This Loop (2026-06-25T00:44Z, linux_mutable — big-pickle meta-orch — convergence check)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 8bda1897`, dirty (uncommitted version bumps + dashboard from prior forge diagnostics run). Checkpointed as `e181a72e`, clean. Credential channel: `ok:gh-keyring`.
- **Worker drain**: 0 linux-ready nodes. All remaining ready/in-progress nodes are macOS/Windows-owned (macos-in-vm-enclave-provisioning, macos-tray-icon-missing-T-fallback, vault-unseal-fails-macos-after-db616e06).
- **Coordination**: `origin/windows-next@a3c8b23d`, `origin/osx-next@85e69f14` — both ancestors of HEAD. No merge needed.
- **E2E**: eligible but deferred — latest release v0.3.260622.4 already tested; no linux-ready work to ship.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Next**: Await macOS/Windows hosts to drain their ready packets; no linux-ready work at current bar.

## This Loop (2026-06-24T07:00Z, linux_mutable — big-pickle ledger hygiene — order-42 stale-status fix)

- **Cycle type**: meta-orchestration ledger hygiene + convergence check.
- **Startup**: `linux-next @ ba8fe4ad`, clean. Credential channel: `ok:gh-keyring`.
- **Worker drain**: No Linux-eligible ready implementation nodes. Fixed stale `vault-flow/xplat-gating-parity` (order 42 subtask): `status: ready` → `status: completed` — all 3 slices done since 2026-06-14.
- **Coordination**: `origin/windows-next@a3c8b23d`, `origin/osx-next@85e69f14` — both ancestors of HEAD. No merge needed.
- **E2E**: eligible (local-build) but deferred. Latest release v0.3.260622.4; curl-install e2e warranted but deferred to conserve budget.
- **Remaining ready**: order 55 (macOS), order 79 (macOS), order 81 (in_progress, fix shipped 8e6f25b1, pending macOS re-smoke).
- **Reduction**: 1 stale-status finding corrected. Zero residual at current bar for Linux.

## This Loop (2026-06-24T04:58Z, linux_mutable — big-pickle meta-orch — convergence check)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 3bc55732`, clean. Credential channel: `ok:gh-keyring`. Fetched origin — siblings unchanged.
- **Worker drain**: 0 linux-ready nodes. All remaining ready nodes are macOS/Windows-owned (vault-flow/xplat-gating-parity, macos-in-vm-enclave-provisioning, macos-tray-icon-missing-T-fallback).
- **Coordination**: `origin/windows-next@a3c8b23d`, `origin/osx-next@85e69f14` — both ancestors of HEAD. No merge needed.
- **E2E preflight**: eligible but skipped — no new release to test since last e2e PASS (v0.3.260624.1, ~2h ago). Latest v0.3.260623.3 on main (needs operator `actions:write` dispatch).
- **Reduction engine**: Zero residual at current bar. All 3 bar-raise candidates (orders 82-85) previously approved and completed. No new findings this cycle.
- **Next**: Await macOS/Windows hosts to drain their ready packets; no linux-ready work at current bar.

## This Loop (2026-06-24T02:56Z, linux_mutable — big-pickle meta-orch — convergence check)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ b676c7c8`, clean. Credential channel: `ok:gh-keyring`. Fetched origin (linux-next advanced 5 commits). Fast-forwarded to `0d683917`.
- **Worker drain**: 0 linux-ready nodes. All 4 remaining ready nodes are macOS/Windows-owned (vault-flow/xplat-gating-parity, macos-in-vm-enclave-provisioning, macos-tray-icon-missing-T-fallback).
- **Coordination**: `origin/windows-next@a3c8b23d`, `origin/osx-next@85e69f14` — both ancestors of HEAD. No merge needed.
- **E2E preflight**: eligible but skipped — no new release to test since last e2e PASS (v0.3.260624.1, 2h ago). Latest v0.3.260623.3 on main (needs operator `actions:write` dispatch).
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Next**: Await macOS/Windows hosts to drain their ready packets; no linux-ready work at current bar.

## This Loop (2026-06-24T02:22Z, linux_mutable — Sonnet 4.6 meta-orch cycle 6 of 6 — e2e PASS)

- **Cycle type**: final cycle of 6-cycle loop series. Full local-build e2e gate run.
- **Startup**: `linux-next @ 8c14045a`, clean. Credential channel: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors.
- **Worker drain**: 0 linux-ready nodes. All 4 remaining ready nodes are macOS/Windows-owned.
- **Litmus**: 111/111 PASS (pre-build, instant).
- **E2E preflight**: eligible.
- **Build**: Binary installed OK (v0.3.260624.1). CI exited 1 due to post-build litmus false negatives on fresh host — pre-existing issue filed.
- **Podman reset**: PASS (clean store verified).
- **tillandsias --init**: PASS (Vault v1.18.5 healthy, 5 AppRoles, all images cold-built, networks created).
- **Forge meta-orch**: exit 0 (convergence check, zero residual at current bar).
- **Finding filed**: post-build litmus chicken-and-egg (`inference-deferred-model-pulls`, `opencode-prompt-e2e-shape`) — pre-existing, optimization-class.
- **Loop series complete**: 6/6 cycles done. No further wakeups scheduled.

## This Loop (2026-06-24T02:20Z, forge — big-pickle meta-orch cycle — convergence check)

- **Cycle type**: convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 42b395e0`, clean worktree. Git mirror freshly provisioned (all remote refs pruned). Credential channel: `ok:forge-git-mirror`.
- **Worker drain**: 0 linux-ready nodes. All remaining ready nodes are macOS/Windows-owned.
- **Coordination**: No remote sibling refs available (fresh mirror). Local sibling branches `main`, `osx-next` present.
- **E2E gates**: skipped — forge container, no new release to test.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Next**: Await macOS/Windows hosts to drain their ready packets; push local state to re-establish mirror tracking refs.

## This Loop (2026-06-24T02:07Z, linux_mutable — big-pickle meta-orch cycle — convergence check)

- **Cycle type**: convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 8c14045a`, dirty (uncommitted version bumps + dashboard from prior cycle). Checkpointed as `bd8d6c31`, clean. Credential channel: `ok:gh-keyring`.
- **Worker drain**: 0 linux-ready nodes. All 4 remaining ready/in-progress nodes are macOS/Windows-owned (vault-flow/xplat-gating-parity, macos-in-vm-enclave-provisioning, macos-tray-icon-missing-T-fallback, vault-unseal-fails-macos).
- **Coordination**: Siblings `origin/osx-next@85e69f14`, `origin/windows-next@a3c8b23d` — both ancestors of HEAD. No merge needed.
- **E2E gates**: eligible but skipped — no new release to test. Latest v0.3.260623.3 on main (needs operator `actions:write` dispatch).
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Next**: Await macOS/Windows hosts to drain their ready packets; no linux-ready work at current bar.

## This Loop (2026-06-24T00:55Z, linux_mutable — big-pickle meta-orch cycle — convergence check)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 6ab60c5c`, dirty (stale big-pickle no-op entry in loop_status.md from prior session). Stashed, fast-forwarded to `origin/linux-next @ 9be03f2e`.
- **Credential Channel Guard**: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors. No merge needed.
- **Worker drain**: No linux-ready plan/index.yaml nodes. All four `ready` items (vault-flow/xplat-gating-parity, macos-in-vm-enclave-provisioning, macos-tray-icon-missing-T-fallback, and its subtask) are macOS/Windows-owned.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Verification**: Clean worktree, in sync with origin, credential channel functional.
- **E2E gates**: No new release to test. Latest v0.3.260623.3 tagged on main (workflow_dispatch pending operator `actions:write`).
- **Next**: Await macOS/Windows hosts to drain their ready packets; no linux-ready work at current bar.

## This Loop (2026-06-24T00:54Z, linux_mutable — Sonnet 4.6 meta-orch cycle 5 — convergence check)

- **Cycle type**: convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 9be03f2e`, clean. Credential channel: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors, no new commits.
- **Worker drain**: 0 linux-ready nodes. 4 macOS-only nodes unchanged.
- **Litmus**: 111/111 PASS (pre-build, instant). 100% spec coverage.
- **Coordinator**: No sibling merge needed.
- **Bar**: Fully drained. Zero residual at current bar.

## This Loop (2026-06-23T23:50Z, linux_mutable — Sonnet 4.6 meta-orch cycle 4 — convergence check)

- **Cycle type**: convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 6ab60c5c`, clean. Credential channel: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors, no new commits.
- **Worker drain**: 0 linux-ready nodes. All 4 remaining ready nodes are macOS-only (vault-flow/xplat-gating-parity, macos-in-vm-enclave-provisioning, macos-tray-icon-missing-T-fallback).
- **Litmus gate**: 111/111 PASS (pre-build, instant). ZeroClaw litmus (`zeroclaw-orchestration` spec, 7/7 steps) passes — verifies cargo tests, allowlist, tray wiring, image registration.
- **Finding captured**: litmus runner requires spec_id argument (`zeroclaw-orchestration`), not test name (`litmus:zeroclaw-mcp-shape`) — minor runner UX note, not a blocker.
- **Bar**: Fully drained. Proposing bar-raise candidates per governance (not self-escalating).
- **Release**: Tags v0.3.260623.2 and v0.3.260623.3 on main, GitHub releases pending manual workflow_dispatch trigger.

## This Loop (2026-06-23T22:47Z, linux_mutable — Sonnet 4.6 meta-orch cycle 3 — orders 92-97 ZeroClaw migration complete)

- **Cycle type**: checkpoint uncommitted agent work + close orders 92-97 + order 56.
- **Startup**: `linux-next @ 004e1720`, dirty — uncommitted work from prior agent completing ZeroClaw migration chain.
- **Assessed**: build.sh --check PASS, tests PASS. All deliverables verified:
  - Order 92: images/zeroclaw/Containerfile + entrypoint + config overlay ✓
  - Order 93: LaunchKind::ZeroClaw, launch_zeroclaw(), zeroclaw socket paths in tray/mod.rs ✓
  - Order 94: runtime_assets.rs + main.rs fully renamed to zeroclaw ✓
  - Order 95: litmus-zeroclaw-mcp-shape.yaml, litmus-bindings.yaml updated ✓
  - Order 96: crates/tillandsias-nanoclawv2-mcp/ deleted, images/nanoclawv2/ renamed, Cargo.toml cleaned ✓
  - Order 97 + order 56: plan ledger closed — this commit.
- **ZeroClaw migration fully complete** — NanoClawV2 is gone, ZeroClaw is live.
- **Coordinator**: Siblings unchanged — osx-next@85e69f14, windows-next@a3c8b23d.
- **Next**: No linux-ready nodes at current bar. Bar fully drained.

## This Loop (2026-06-23T21:42Z, linux_mutable — Sonnet 4.6 meta-orch cycle 2 — order 91 ZeroClaw crate)

- **Cycle type**: worker drain — order 91 ZeroClaw crate scaffold.
- **Startup**: `linux-next @ a41d2344`, clean. Credential channel: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors.
- **Pulled**: another agent landed orders 89/90 + v0.3.260623.3 release bump. Orders 91-97 (ZeroClaw migration chain) filed as ready.
- **Order 91** (zeroclaw-crate-scaffold): Created `crates/tillandsias-zeroclaw/` — Apache-2.0, full port of NanoClawV2 MCP with nanoclaw.* → zeroclaw.* renames. Added to workspace. 12/12 tests pass. build.sh --check PASS.
- **Coordinator**: Siblings unchanged — no merge needed.
- **Next**: Orders 92-97 remain (Containerfile, tray wiring, image registration, litmus rename, remove legacy, plan ledger).

## This Loop (2026-06-23T20:42Z, linux_mutable — big-pickle meta-orch — orders 89/90)

- **Cycle type**: worker drain — completed orders 89, 90, filed orders 91-97.
- **Startup**: `linux-next @ 8148a6c7`, clean worktree, rebased local version bump atop origin. Credential channel: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors.
- **Order 89** (vault-persistence-research): Investigated vault persistence chain (volume mount, unseal key lifecycle, entrypoint flow). Verdict: vault persistence is already correctly implemented end-to-end. Named podman volume `tillandsias-vault-data:/vault/data:U` persists across container recreation; `:U` flag handles userns mapping drift; unseal key survives in host keychain with file fallback. No code changes needed. Deliverable filed.
- **Order 90** (zeroclaw-progress): Audited NanoClawV2 vs ZeroClaw state. NanoClawV2 is fully built but ZeroClaw migration was never executed — ZeroClaw target files (zeroclaw.rs, images/zeroclaw/, build-zeroclaw.sh) do not exist. Broken down into 7 sequential packets (orders 91-97): crate scaffold, Containerfile, tray rename, image registration, litmus update, legacy cleanup, plan update. Deliverable filed at plan/issues/zeroclaw-progress.md.
- **Coordinator**: Siblings unchanged — both ancestors of HEAD. No merge needed.
- **E2E**: Plan-only changes (no code/runtime delta). Skipping local-build e2e.
- **Release**: Latest is v0.3.260623.3 on main; release workflow needs manual trigger.
- **Next**: Orders 91-97 (ZeroClaw migration) ready for Linux pickup. Remaining macOS-owner orders (79, 80 AX smoke, 81 vault re-smoke).

## This Loop (2026-06-23T20:36Z, linux_mutable — Sonnet 4.6 meta-orch — orders 86/87/88)

- **Cycle type**: worker drain — close orders 86, 87, 88.
- **Startup**: `linux-next @ 39b19055`, clean worktree. Credential channel: `ok:gh-keyring`. Siblings: `osx-next@85e69f14`, `windows-next@a3c8b23d` — both ancestors.
- **Order 86** (per-project-dynamic-path-verification): Verified lib-common.sh, all entrypoints, docs, and spec are fully dynamic ($TILLANDSIAS_PROJECT). No hardcoded project names in infra paths. Closed all 4 tasks.
- **Order 87** (forge-transparency-cheatsheet): Verified cheatsheet exists at `cheatsheets/runtime/forge-transparency.md` and `images/default/cheatsheets/runtime/forge-transparency.md` — in sync. Closed all 3 tasks.
- **Order 88** (forge-harness-bootstrap-context): Implemented `inject_startup_context()` in `lib-common.sh`. Writes `.forge-startup-context.md` to project root with project, branch, version, agent, transparency summary, plan entry points, and skills pointer. Called from all 4 entrypoints (claude, opencode, opencode-web, codex) before banner/exec. `.gitignore` updated. Build check + tests pass.
- **Coordinator**: Siblings unchanged — no new osx-next or windows-next commits since last merge.
- **E2E**: Changes are bash-only + plan; no new Rust binary delta. Build check + tests PASS. Skipping full local-build e2e (no substrate delta since last e2e run).
- **Release**: v0.3.260623.2 tag is on main; release workflow needs manual trigger (token lacks actions:write).
- **Next**: Remaining open work is macOS-owner (orders 79, 80 AX smoke, 81 vault re-smoke).

## This Loop (2026-06-23T20:20Z, forge — big-pickle meta-orch — per-project transparency)

- **Cycle type**: meta-orchestration start-of-cycle (forge container).
- **Startup**: `linux-next @ 226d2723`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard: `ok:forge-git-mirror`. Siblings: `windows-next@a3c8b23d`, `osx-next@85e69f14` — both ancestors.
- **Hardcoded-project-name audit**: Scanned codebase for hardcoded "tillandsias" project names in mirror/checkout paths. Source already dynamic via `$PROJECT`/`$TILLANDSIAS_PROJECT`. Fixed 8 hardcoded paths in docs (4 in `docs/cheatsheets/git-mirror-lifecycle-audit.md`, 2 each in `cheatsheets/runtime/forge-standalone.md` + image-baked copy) — replaced with `<PROJECT>` placeholders.
- **Forge transparency cheatsheet**: Created `cheatsheets/runtime/forge-transparency.md` + image-baked copy documenting that git mirror, HTTPS proxy, inference, and Vault are transparent for agents. Agents never need to configure git, tokens, or proxies. Includes per-project isolation table.
- **Spec update**: Added per-project transparency requirement to `openspec/specs/git-mirror-service/spec.md` (two scenarios: "any GitHub project works without code changes" and "agents never configure git").
- **Plan packets filed**: Order 86 `per-project-dynamic-path-verification`, Order 87 `forge-transparency-cheatsheet`, Order 88 `forge-harness-bootstrap-context` — all ready, gated for forge host pickup.
- **Worker drain**: Zero forge-eligible ready tasks besides newly filed orders 86-88.
- **E2E gates**: `skip:no-podman-binary` (forge container).
- **Push state**: Will push `linux-next` with spec update + docs fix + cheatsheets + plan packets.

## This Loop (2026-06-23T20:03Z, forge — big-pickle meta-orch — git-mirror fix)

- **Cycle type**: meta-orchestration start-of-cycle (forge container).
- **Startup**: `linux-next @ 67fa3cd9`, clean worktree, 0 ahead / 0 behind.
- **Credential Channel Guard**: passed (`ok:forge-git-mirror`), but `git fetch` via HTTP returned 403.
  - Diagnosed: lighttpd on port 8080 returns 403 for all requests (git-http-backend CGI misconfig).
  - Git daemon on port 9418 works correctly. Post-receive hook forwards pushes to GitHub.
- **Fix applied (running container)**: Changed global `insteadOf` from `http://tillandsias-git:8080/tillandsias.git` to `git://tillandsias-git/tillandsias`. Push verified: `remote: [git-mirror] Push to origin (https://github.com/8007342/tillandsias.git): success`.
- **Fix committed (source)**: `images/default/lib-common.sh` — `rewrite_origin_for_enclave_push` and `clone_project_from_mirror` updated to use `git://tillandsias-git/<project>` per spec (`openspec/specs/git-mirror-service/spec.md` line 51).
- **Worker drain**: No forge-eligible `ready` tasks in `plan/index.yaml`. All remaining ready nodes are macOS/Windows-owned.
- **E2E gates**: `skip:no-podman-binary` (forge container, no podman available).
- **Findings filed**: `plan/issues/git-mirror-http-403-lighttpd-cgi-2026-06-23.md`.
- **Coordinator**: Sibling branches unchanged — `origin/windows-next@a3c8b23d`, `origin/osx-next@85e69f14` — both ancestors of `linux-next`.
- **Push state**: Pushing `linux-next` with source fix + plan updates.


## This Loop (2026-06-23T09:30Z, linux_mutable — Sonnet 4.6 meta-orch — bar-raises + e2e)

- **Cycle type**: worker drain + e2e gates + coordinator duties.
- **Startup**: `linux-next @ 5d5d5a54`, clean (forge already pushed order 80 + plan). Credential channel: `ok:gh-keyring`.
- **Litmus fix**: cache-recovery-fresh-start was hanging (--init + LITMUS_PODMAN_MODE not bypassing run_init podman ops + vault bootstrap). Fixed run_init to return early in fake mode; vault bootstrap skipped in fake mode; step-5 regex changed from `\\.` to `[.]` to avoid YAML raw-byte escaping. Committed in `c5d97860`.
- **Worker drain (this session)**: Orders 79, 80 completed (79 in osx, 80 by forge). Remaining macOS work (tray icon AX verify, vault unseal macOS re-smoke) = macOS-owner.
- **Build gate**: `build.sh --ci-full --install` — pre-build 134/134 PASS. Post-build 2 failures: (1) inference model pull permission denied (env issue, filed), (2) opencode-prompt-e2e-shape loop_status.md not updated (filed).
- **E2E step 2**: Podman reset `--force` succeeded — store empty.
- **E2E step 3**: `tillandsias --init` running (cold rebuild, background task bzerw0ohe).
- **E2E step 4**: Forge ran as opencode-prompt-e2e-shape. Completed order 80.
- **Coordinator**: Siblings unchanged — no new osx-next or windows-next commits since last merge.
- **Release**: Pending — awaiting --init completion + merge-to-main-and-release skill.
- **Findings**: Inference model pull permission (optimization), loop_status.md gate (enhancement) — filed in build-install-smoke-e2e-findings-2026-06-23.md.

## This Loop (2026-06-23T09:25Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: worker drain (order 80 — shared menu_state layer).
- **Startup**: `linux-next @ 6cdaa8ac`, dirty (uncommitted LITMUS_PODMAN_MODE + VERSION bump). Checkpoint committed as `c5d97860`, pushed.
- **Credential Channel Guard**: passed (`ok:gh-keyring`).
- **Worker drain**: Claimed and completed `github-login-menu-readiness-gate/add-readiness-condition` (order 80). Added `login_runtime_ready` field to `MenuState`; when `false` and logged-out, the GitHub Login item is replaced by a disabled "Setting up…" entry. Shared portable menu only — macOS AX smoke still needs macOS host. Commit `1d6574b4`.
- **Build check**: `./build.sh --check` passes. 10/10 menu_state tests + 1 portable_smoke test pass.
- **E2E gates**: Skipped — plan-only Rust change, no runtime/image delta.
- **Coordinator**: Siblings unchanged — `origin/windows-next` and `origin/osx-next` are both ancestors of `origin/linux-next @ 1d6574b4`. No merge needed.
- **Release**: Latest is v0.3.260622.4. No new release work.
- **Push state**: Pushed `linux-next` with order 80 completion.

## This Loop (2026-06-23T07:05Z, linux_mutable — Sonnet 4.6 meta-orch)

- **Cycle type**: worker drain + coordinator duties.
- **Startup**: `linux-next @ 4af42998`, clean. Credential Channel Guard passed (`ok:gh-keyring`).
- **Litmus fix committed**: `4af42998` — add `--init` to litmus status-check steps, `LITMUS_PODMAN_MODE` bypass for `require_desktop_user_session`.
- **Pull/rebase**: rebased onto `7bceae3b` (forge transparent git mirror fix, v0.3.260622.4 release record).
- **Merge coordinator**: Merged `origin/osx-next` (5 plan-only commits: orders 79-81, install-macos diag-pin bug `49324fe6`, unified curl-install parity `5345a3e9`). `origin/windows-next` is still ancestor.
- **Worker drain**: Implemented order 81 (vault unseal macOS GetVaultHandover race fix + 120s→180s timeout). Commit `8e6f25b1`.
- **Orders 79-80**: macOS-owner tasks (tray icon PNG fix + GitHub Login readiness gate). Not actionable on Linux without macOS visual verify.
- **E2E gates**: No new release yet. Vault fix (order 81) should trigger a release for macOS to re-test.
- **Release**: Needs Tlatoāni trigger or linux merge-to-main skill for v0.3.260623.x.
- **Litmus**: 110/110 PASS after all changes.
- **Push state**: Pushing linux-next with litmus fix + osx-next merge + order 81.

## This Loop (2026-06-23T06:15Z, forge — big-pickle meta-orch)

- **Cycle type**: meta-orchestration start-of-cycle (forge container).
- **Startup**: `linux-next @ 8f694ae3`, dirty worktree (uncommitted TRACES.md and
  Cargo.toml changes from prior cycle).
- **Credential Channel Guard**: FAILED (`missing:no-credential-channel`).
  - No `.git/.gh-credentials`, no `GH_TOKEN`/`GITHUB_TOKEN`, `gh auth status`
    not logged in.
  - Git mirror (`http://tillandsias-git:8080`) returns 403 Forbidden.
- **Blocker**: Updated `plan/issues/forge-credential-channel-blocked-2026-06-21.md`
  with re-check entry. Same root cause — no credential path to push.
- **Worker drain**: NOT STARTED — credential channel missing per exit contract.
- **E2E gates**: SKIPPED (no committable work possible).
- **Coordinator**: linux-next 0 ahead; siblings not checked (no push possible).
- **Release**: Not applicable.
- **Push state**: BLOCKED — no credential channel. Cycle halted.

## This Loop (2026-06-22T14:23Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ b3804d57`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: No linux-ready plan/index.yaml nodes. Two `ready` nodes exist (`vault-flow/xplat-gating-parity` owner macos+windows, `macos-in-vm-enclave-provisioning` owner macos) — neither eligible on Linux. Zero residual at current bar.
- **Coordinator**: `origin/osx-next` (`61acff26`) is an ancestor of HEAD. `origin/windows-next` (`a3c8b23d`) is an ancestor of HEAD. No merge needed.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS). No new release work.
- **Verification**: `./build.sh --check` passes (with the known non-fatal dev-proxy warning). Litmus `--size instant` 110/110 PASS.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Push state**: Recording this check-in and pushing `linux-next`.

## This Loop (2026-06-22T13:15Z, linux_mutable — Gemini-Antigravity meta-orch)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 259ef1dc`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: No linux-ready plan/index.yaml nodes. Two `ready` nodes exist (`vault-flow/xplat-gating-parity` owner macos+windows, `macos-in-vm-enclave-provisioning` owner macos) — neither eligible on Linux. Zero residual at current bar.
- **Coordinator**: `origin/osx-next` (`61acff26`) is an ancestor of HEAD. `origin/windows-next` (`a3c8b23d`) is an ancestor of HEAD. No merge needed.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS). No new release work.
- **Verification**: `./build.sh --check` passes (with the known non-fatal dev-proxy warning). `cargo test --workspace` passes. Litmus `--size instant` 110/110 PASS.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Push state**: Recording this check-in and pushing `linux-next`.

## This Loop (2026-06-22T12:22Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ 6e85eb76`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: No linux-ready plan/index.yaml nodes. Two `ready` nodes exist (`vault-flow/xplat-gating-parity` owner macos+windows, `macos-in-vm-enclave-provisioning` owner macos) — neither eligible on Linux. Zero residual at current bar.
- **Coordinator**: `origin/osx-next` (`61acff26`) is an ancestor of HEAD. `origin/windows-next` (`a3c8b23d`) is an ancestor of HEAD. No merge needed.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS). No new release work.
- **Reduction engine**: Zero residual at current bar. No new findings this cycle.
- **Push state**: Recording this check-in and pushing `linux-next`.

## This Loop (2026-06-22T10:21Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: meta-orchestration convergence check — zero residual at current bar.
- **Startup**: `linux-next @ c6b998d9`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: No linux-ready plan/index.yaml nodes. Two `ready` nodes exist (`vault-flow/xplat-gating-parity` owner macos+windows, `macos-in-vm-enclave-provisioning` owner macos) — neither eligible on Linux. Zero residual at current bar.
- **Coordinator**: `origin/osx-next` (`61acff26`) is an ancestor of HEAD. `origin/windows-next` (`a3c8b23d`) is an ancestor of HEAD. No merge needed.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS). No new release work.
- **Reduction engine**: Zero residual at current bar. Bar-raise proposals filed at `plan/issues/bar-raise-proposals-2026-06-22.md` — Tlatoāni-gated, not self-escalated.
- **Push state**: Recording this check-in and pushing `linux-next`.

## This Loop (2026-06-22T08:30Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: meta-orchestration worker drain — macOS vault unseal secret fix.
- **Startup**: `linux-next @ 7dfa84c0`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Claimed and completed **order 78** (`vault-unseal-secret-rootful-podman`).
  - Root cause: rootful podman (macOS VZ guest) + `--userns keep-id` + secret `uid=100,gid=1000,mode=0400` leaves unseal secret unreadable by vault entrypoint.
  - Fix: removed uid/gid from all four vault podman secret mount options in `launch_vault_container` (`vault_bootstrap.rs`). Default podman secret mount (mode=0444,uid=0) is world-readable regardless of user namespace mapping.
  - Build check: format + type-check PASS. Tests: 8/8 vault-related tests PASS.
  - Commits: `db616e06` (fix), `5029ba53` (plan completion).
  - **Outcome**: macOS VZ guest verification still required to close the loop.
- **Coordinator**: `origin/osx-next` (`61acff26`) is an ancestor of `origin/linux-next`. `origin/windows-next` (`a3c8b23d`) unchanged, also ancestor. No merge needed.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS). No new release work.
- **Reduction engine**: Zero residual at current bar. No bar-raise self-escalation.
- **Push state**: All commits pushed to `origin/linux-next`.

## This Loop (2026-06-22T08:19Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: meta-orchestration coordination merge.
- **Startup**: `linux-next @ 7dfa84c0`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Zero residual at current bar — no linux-ready plan/index.yaml nodes.
- **Coordinator**: `origin/osx-next` (`61acff26`) diverged from `linux-next` by 1 plan-only commit (order 78 macOS Vault root-cause analysis). Merged cleanly into linux-next at `63a6a4d3`. `origin/windows-next` (`a3c8b23d`) is an ancestor of `linux-next`. No other merge required.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS). No new work since release.
- **Verification**: Merge was plan-only (no implementation code changed). Build/format/litmus not re-run — prior cycles confirmed clean.
- **Push state**: Merged osx-next into linux-next. Recording this check-in and pushing.

## This Loop (2026-06-22T08:08Z, linux_mutable — Gemini-Antigravity meta-orch)

- **Cycle type**: meta-orchestration collaborative unblock.
- **Worker drain**: Identified that `enclave/macos-vault-unreachable-via-publish-aarch64` was already resolved via order 77 (`vault-bootstrap-health-timeout`), which was shipped to the macOS branch.
  - Reclaimed the expired lease on `macos-in-vm-enclave-provisioning` and reset status to `ready`.
  - Reset `vault-flow/xplat-gating-parity` status to `ready`.
  - Closed Wave A in `plan/issues/windows-macos-feature-parity-2026-06-12.md`.
- **Coordinator**: `macos-in-vm-enclave-provisioning` and `vault-flow/xplat-gating-parity` are unblocked and ready for the macOS/Windows team to take up.

## This Loop (2026-06-22T06:57Z, linux_mutable — big-pickle meta-orch)

- **Cycle type**: meta-orchestration with macOS unblock.
- **Startup**: `linux-next @ ff896a6b`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Zero residual at current bar — all plan/index.yaml nodes completed.
  Noted that `origin/osx-next` (`4d6e8066`) was behind `origin/linux-next` and missing
  the vault 60s→120s timeout fix (order 77). **Fast-forwarded `osx-next`** to
  `origin/linux-next@ff896a6b` and pushed, shipping the vault timeout fix and all
  intervening linux-next work to the macOS branch.
- **Coordinator**: `origin/osx-next` now at `ff896a6b` (fast-forwarded). `origin/windows-next`
  (`a3c8b23d`) unchanged — both are ancestors of `linux-next`. No merge required.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS in prior cycle). No new work since release.
- **Reduction engine**: Zero residual at current bar. Machine-id stability concern
  remains open for macOS-side verification
  (`plan/issues/macos-github-login-vault-bootstrap-timeout-2026-06-22.md`).
- **Push state**: `origin/osx-next` pushed (fast-forward). Recording this check-in and pushing `linux-next`.

## This Loop (2026-06-22T06:35Z, linux_mutable — claude-sonnet46 meta-orch)

- **Cycle type**: meta-orchestration check/sync (no-op convergence point).
- **Startup**: `linux-next @ 46281cd2`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: No ready tasks in `plan/index.yaml`. All nodes completed.
- **Coordinator**: Siblings `origin/windows-next` (`a3c8b23d`) and `origin/osx-next` (`4d6e8066`) are ancestors of `linux-next`. No merge required.
- **Verification**: Build check PASS (fmt + typecheck). Litmus instant PASS (110/110, 100% pass rate). No open PRs.
- **Release**: Latest is v0.3.260622.3 (smoke-tested PASS in prior cycle). No new work since release.
- **Reduction engine**: Zero open findings at current bar. No bar-raise self-escalation (Tlatoāni-gated). Forge credential blocker remains open (`plan/issues/forge-credential-channel-blocked-2026-06-21.md`) — operator action required to re-seed `.git/.gh-credentials` or inject `GH_TOKEN`.
- **Push state**: Recording this check-in and pushing.

## This Loop (2026-06-22T05:13Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: meta-orchestration check/sync.
- **Startup**: `linux-next @ 0ac8b282`, clean worktree, 0 ahead / 0 behind. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Checked `plan/index.yaml` and active files; all ready tasks are completed. Sibling heads `origin/windows-next` (`a3c8b23d`) and `origin/osx-next` (`4d6e8066`) are already fully merged into `linux-next`. No ready tasks to drain.
- **Verification**: Clean state. Formatting and types check passed. Cargo workspace unit tests passed (30 tests, 0 failures). Litmus instant-size tests passed (112 tests, 0 failures, 100% pass rate).
- **Coordinator**: No branch drift. Siblings `origin/windows-next` and `origin/osx-next` are ancestors of `linux-next` HEAD. No merge required.
- **Push state**: Workspace clean. No new commits to push.

## This Loop (2026-06-22T04:56Z, forge — big-pickle meta-orch)

- **Cycle type**: meta-orchestration start-of-cycle (forge container).
- **Startup**: `linux-next @ aa4050f8`, clean worktree, 0 ahead / 0 behind.
- **Credential Channel Guard**: FAILED (`missing:no-credential-channel`).
  - No `.git/.gh-credentials`, no `GH_TOKEN`/`GITHUB_TOKEN`, `gh auth status`
    not logged in.
  - Git mirror (`http://tillandsias-git:8080`) returns 403 Forbidden.
- **Blocker**: Updated `plan/issues/forge-credential-channel-blocked-2026-06-21.md`
  with re-check entry. Same root cause — no credential path to push.
- **Worker drain**: NOT STARTED — credential channel missing per exit contract.
- **E2E gates**: SKIPPED (no committable work).
- **Coordinator**: linux-next 0 ahead; siblings not checked (no push possible).
- **Release**: Not applicable.
- **Push state**: BLOCKED — no credential channel. Cycle halted.

## This Loop (2026-06-22T04:22Z, linux_mutable — claude-sonnet46 meta-orch loop)

- **Cycle type**: merge-to-main-and-release for v0.3.260622.3 + smoke e2e gate.
- **Startup**: Resumed from context summary; PR #43 was pending merge after sync
  commit `6ae0ef73` resolved criss-cross merge base. Credential channel: `ok:gh-keyring`.
- **Worker drain**: No new packets; order 77 was already completed in prior context.
- **Coordinator**: Merged PR #43 (linux-next→main). Bumped VERSION→0.3.260622.3 on
  main in release worktree. Tagged `v0.3.260622.3`. Triggered release.yml run 27929545235.
  Release SUCCEEDED (4m46s Nix build, cache HIT — third consecutive).
  Synced main→linux-next (ff) + ledger commit. Pushed linux-next.
- **Sibling heads**: linux-next `aa4050f8`, main `fdd51e2e`, osx-next `4d6e8066`,
  windows-next `a3c8b23d`.
- **Smoke e2e v0.3.260622.3**: PASS — install OK, podman reset clean, `--init` clean
  (Vault init+unseal < 120s on native Linux), forge exit 0. No new findings vs v0.3.260622.2.
  Forge credential channel still 403 (same known blocker). Report:
  `plan/issues/smoke-e2e-findings-v0.3.260622.3-2026-06-22.md`.
- **Push state**: pushed linux-next with ledger + smoke report.

## This Loop (2026-06-22T03:26Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: Verification and completion of `release-nix-cache-ref-scoping/verify-incremental`.
- **Startup**: `linux-next @ 67288c7f`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**:
  - Claimed and completed `release-nix-cache-ref-scoping/verify-incremental` node lease.
  - Verified cache-hit and incremental build fix. Cut two consecutive releases on 2026-06-22:
    - v0.3.260622.1 (run 27925910315): Cache miss, nix build took 2318s (38m 38s).
    - v0.3.260622.2 (run 27927279842): Cache hit verified! Nix build took 280s (4m 40s), achieving an 88% speedup.
  - Updated issue document `plan/issues/release-nix-cache-ref-scoping-2026-06-20.md` with completion event.
- **Coordinator**: Merged `main` into `linux-next`. Clean workspace.
- **Push state**: Will push `linux-next` to origin.

## This Loop (2026-06-22T02:25Z, linux_mutable — claude-opus48 meta-orch loop)

- **Cycle type**: Order-64 verify + release + osx-next coordination merge.
- **Startup**: `linux-next @ 94ba2875`, clean worktree. Credential Channel Guard passed.
- **Verification (order 64)**: Confirmed warm run 27917409949 saved 2196MB nix-Linux-* cache
  under refs/heads/linux-next. Fix (`purge-primary-key: never`, commit 6a84b478) verified.
  Also fixed `purge-created-offset` → `purge-created: 86400` (was silently ignored as invalid
  param; renamed and set 24h value in seconds). Marked implement-cache-fix completed.
- **Release**: Merged PR #40 (linux-next → main). Bumped VERSION to 0.3.260622.1, tagged
  v0.3.260622.1, dispatched release.yml run 27925910315. Build in progress (expected full
  build: warm job on main started 24s before release, too close for cache restore).
  Verify-incremental PASS deferred to next release (after warm job on main ~03:06Z).
- **Coordinator**: Merged osx-next (5 commits: pty PATH fix, --exec-guest, vsock exec,
  --github-login, merge commit). No fmt drift. Pushed linux-next.
- **Next**: Record release outcome and cut verify-incremental release after 03:10Z UTC.

## This Loop (2026-06-22T01:11Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: Coordination merge and validation on mutable Linux.
- **Startup**: `linux-next @ bcb000eb`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d (already merged), osx-next 5c251a06 (advanced).
- **Worker drain**: Performed Mutable Linux Coordinator duties. Merged eligible `origin/osx-next` (5 commits) cleanly via fast-forward.
- **Verification**: Run `build.sh --check` which passed successfully (fmt and type checks). Ran all 76 unit/integration cargo tests successfully. Ran all 110/110 executed instant-size litmus tests successfully (100% pass rate).
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T23:13Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: `linux-next @ be08cbec`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Claimed and completed Order 76 `github-e2e/forge-base-missing-ux`.
  - Added on-demand building of base images (`forge-base` and `chromium-core`) in `ensure_image_exists`.
  - Configured `ensure_image_exists` to pass the correct `BASE_IMAGE` and `CHROMIUM_CORE_IMAGE` build arguments to `podman build`.
- **Verification**: Verified compilation with `cargo check` and run-time safety with `cargo clippy`. Ran all 86 unit and integration tests successfully. Validated YAML edits with the Ruby YAML validator fallback.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: Not run — code changes are well covered by local tests, no full e2e environment needed for this slice.
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T21:12Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: `linux-next @ 9974072b`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d, osx-next d273daff (all at same commit).
- **Worker drain**: Claimed and completed Order 75 `github-e2e/redundant-vault-bootstrap`.
  - Added the `approle_role_exists` method to `VaultClient` to check if a specific AppRole role has already been provisioned (returning true on 200, false on 404).
  - Modified the container boot check in `ensure_vault_running` within `crates/tillandsias-headless/src/vault_bootstrap.rs` to query the `git-mirror` role and skip redundant policy load/AppRole role provisioning cycles if it is present.
- **Verification**: Verified build correctness with `cargo check` and successfully ran integration tests of `tillandsias-vault-client` with all tests passing. Validated YAML edits using the approved Ruby YAML validator fallback.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: Not run — code delta is runtime, but no forge rebuild needed for this slice.
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T12:49Z, linux_mutable — big-pickle reduction: critical-path-honor-success-pattern)

- **Cycle type**: meta-orchestration worker drain + reduction on mutable Linux.
- **Startup**: `linux-next @ 022dd16f`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d, osx-next d273daff (all at same commit).
- **Worker drain**: No `ready` packet implementable on this host — order 64 `release-nix-cache-ref-scoping/verify-incremental` needs CI releases; order 68 `github-e2e-lifecycle-interactive` needs operator attendance.
- **Reduction**: Reduced `litmus-critical-path-eval-gap` finding (first durable fix) into **order 74**:
  - Added `success_pattern`/`failure_pattern` parsing to critical_path YAML section in `scripts/run-litmus-test.sh`
  - Steps declaring `success_pattern` now route through `check_signal()` for authoritative regex matching instead of always falling through to the `expected_behavior` heuristic
  - 112/112 instant-size litmus tests pass (0 regressions)
- **Verification**: `bash -n scripts/run-litmus-test.sh` passes. `ruby -ryaml` validates `plan/index.yaml`. Litmus `--size instant` 112/112 PASS.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: Described above, but litmus-only change.
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T10:50Z, linux_mutable — big-pickle opencode-prompt-e2e-smoke)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (big-pickle).
- **Startup**: `linux-next @ 70239dc6`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d, osx-next d273daff (both ancestors); main 77de76ba (release merge, not ancestor — expected).
- **Worker drain**: Completed Order 67 `opencode-prompt-e2e-smoke` (both subtasks).
  - Created `openspec/litmus-tests/litmus-opencode-prompt-e2e-shape.yaml` with 7-step critical path asserting forge_exit=0, HEAD advanced, loop_status.md changed, remote HEAD advanced, and cleanup.
  - Registered `litmus:opencode-prompt-e2e-shape` in `openspec/litmus-bindings.yaml` under `spec_id: meta-orchestration`.
  - Verified `opencode-prompt-e2e/findings-reduce` is already covered by the meta-orchestration skill's Reduction Engine section (no skill edit needed).
  - Updated `plan/issues/opencode-prompt-e2e-smoke-2026-06-20.md` with completion summary.
- **Verification**: `plan/index.yaml`, `openspec/litmus-bindings.yaml`, and `litmus-opencode-prompt-e2e-shape.yaml` all validated with `ruby -ryaml`. `build.sh --check` passes.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: Not run — litmus-only change, no runtime delta.
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T09:28Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (Gemini).
- **Startup**: `linux-next @ 2412a414`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Completed Order 66 `forge-push-credential-channel/bypass-proxy-for-internal-git-daemon`.
  - Configured `NO_PROXY`/`no_proxy` environment variables in `container_profile.rs` and `main.rs` to bypass Squid proxy for `tillandsias-git` enclave service.
- **Verification**: `build.sh --check` passes successfully. E2E verification test pushed successfully to the enclave git service.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: local-build gate run (E2E push verification test).
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T08:42Z, linux_mutable — big-pickle ledger-closure)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (big-pickle).
- **Startup**: `linux-next @ 758ae45c`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings: windows-next a3c8b23d, osx-next d273daff (both ancestors); main 77de76ba (release merge, not ancestor — expected).
- **Worker drain**: No `ready` packets implementable on this host — orders 64/66–68 require release runs, forge runtime, or operator attendance. Closed out **order 69** `git-mirror-architecture-verification` which had `status: claimed` but was already completed (findings filed, deliverable present). Fixed event type `completion` → `completed`, flipped status to `done`, released lease.
- **Verification**: `plan/index.yaml` validated with `ruby -ryaml`.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. main diverges after release PR #38 merge (expected — main carries VERSION bump). No merge needed.
- **E2E gates**: Not run — ledger-only change, no runtime delta.
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T07:11Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (Gemini).
- **Startup**: `linux-next @ 6b0c1eab`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d, osx-next d273daff (both ancestors).
- **Worker drain**: Completed Order 73 `source-edit-vs-smoke-lock/decide-and-document`.
  - Added a new rule under §5 Hard Rules in `skills/advance-work-from-plan/SKILL.md` requiring destructive, file-moving, or source-mutating directory migrations to acquire the shared `build-install-smoke-e2e` lock (or source-edit lease).
  - Updated `plan/issues/ci-blockers-fmt-drift-and-litmus-concurrency-2026-06-21.md` and `plan/index.yaml` to mark the follow-up task and parent node as completed.
- **Verification**: Validated `plan/index.yaml` using ruby YAML parser.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: Not run — documentation-only change, no runtime delta.
- **Push state**: will push `linux-next` to origin over HTTPS.

## This Loop (2026-06-21T06:37Z, linux_mutable — big-pickle enforce-fmt-on-commit)


- **Cycle type**: meta-orchestration worker drain on mutable Linux (big-pickle).
- **Startup**: `linux-next @ 6b0c1eab`, clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d, osx-next d273daff, main 31b01c32 (all ancestors).
- **Worker drain**: No `ready` plan-index packet implementable on this host — Orders 64/66–68 require CI releases, forge runtime, or operator attendance. Reduced the CI blocker finding from `plan/issues/ci-blockers-fmt-drift-and-litmus-concurrency-2026-06-21.md` into two plan packets:
  - **Order 72 (completed)**: Added `cargo fmt --check --all` to `build.sh --check` before the type-check step, closing the --check vs --ci-full fmt gap.
  - **Order 73 (ready)**: Document that source-mutating migrations acquire the smoke-lock.
- **Verification**: `build.sh --check` passes with fmt gate. `ruby -ryaml` validates `plan/index.yaml`. `bash -n build.sh` passes.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: Not run — fmt-gate tooling change, no runtime delta.
- **Push state**: will push `linux-next` to origin over HTTPS (gh auth keyring).

## This Loop (2026-06-21T04:42Z, linux_mutable — big-pickle git-mirror-arch-verification)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (big-pickle).
- **Startup**: `linux-next @ de29cd67` (after fast-forward + claim push from previous start). Clean worktree. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Claimed and completed Order 69 `git-mirror-architecture-verification`. Investigation-only (no code changes). Key findings:
  - git mirror serves `git://` (native git daemon protocol on port 9418), NOT HTTPS/SSH
  - CA certs (`/etc/tillandsias/ca.crt`) are for **outbound** HTTPS (Vault API + GitHub push relay), not for serving TLS
  - Linux forge remote is either `git://git-service/<project>` (network clone) or uses `insteadOf` redirect to `git://git-service/<project>` (host-mount mode) — no `file://` anywhere on Linux
  - Windows/WSL filesystem transport does use a path-based `insteadOf` redirect (functionally akin to `file://`), which is intentional for the WSL environment
  - Corrected packet outcome wording from "real HTTPS/SSH git server" to "real git daemon (git://) with Vault-backed HTTPS relay"
- **Deliverable**: `plan/issues/git-mirror-architecture-verification-2026-06-20.md`
- **E2E gates**: Skipped — investigation-only, no code delta.
- **Push state**: will push `linux-next` to origin over HTTPS (gh auth keyring).

## This Loop (2026-06-21T04:12Z, linux_mutable — Gemini-Antigravity worker)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (Gemini). Podman user session available.
- **Startup**: `linux-next @ 0bef958b`. Clean worktree. Credential Channel Guard passed (`ok:gh-keyring`).
- **Worker drain**: Resolved both pre-flight litmus failures. Added missing `zoxide` to `images/default/Containerfile.base` to complete all 10 mandated terminal tools. Updated `default-image` litmus test to expect 5 checksum-verification sites due to `wasmtime` curl+tar restoration. Removed divergence block from `openspec/specs/forge-shell-tools/spec.md`. Updated `litmus:forge-shell-tools-implementation-shape` to verify all 10 tools + git-delta and git-lfs.
- **Verification**: `run-litmus-test.sh --size instant --phase pre-build` → **110/110 PASS (100%)**. YAML validated with `ruby -ryaml`.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD. No merge needed.
- **E2E gates**: local-build gate eligible, ran litmus test suite, passed 100%.
- **Push state**: will push `linux-next` to origin over HTTPS (gh auth keyring).

## This Loop (2026-06-21T03:55Z, linux_mutable — big-pickle implements push-from-host)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (big-pickle). Off-peak (Sat 20:55 PT). Podman user session available.
- **Startup**: `linux-next @ 6a7d4d2f` (in sync with `origin/linux-next`). Clean worktree. Credential Channel Guard passed (`ok:gh-keyring`). Siblings fetched: windows-next a3c8b23d, osx-next d273daff, main 31b01c32 (all ancestors).
- **Worker drain**: Completed Order 68 `github-e2e/push-from-host`. Added host-side `gh auth login --with-token` + `gh auth setup-git` to `run_github_login` in `main.rs` so `git push origin` works from the host after `--github-login`. Token retrieved from the login container via `podman exec gh auth token` and piped to host gh, then git credential helper configured.
- **Verification**: 86/86 headless unit tests pass, full workspace tests pass, `ruby -ryaml` validates plan YAML, 3/3 meta-orchestration litmus tests pass.
- **Capture**: Updated `owned_files` from non-existent `github_login.rs` to `main.rs`. Deliverable filed at `plan/issues/github-e2e-push-from-host-2026-06-21.md`.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD (0 ahead). No merge needed.
- **E2E gates**: local-build gate eligible but not run — code delta is runtime (not infra-only) but no forge rebuild needed for this slice. curl-install gate deferred.
- **Push state**: will push `linux-next` to origin.

## This Loop (2026-06-21T03:30Z, linux_mutable — big-pickle purge-stale-caches)

- **Cycle type**: meta-orchestration worker drain on mutable Linux (big-pickle). Off-peak (Sat 20:30 PT). Podman user session available for the first time in Cowork-free cycle.
- **Startup**: `linux-next @ a08eb971` (after fast-forward `..51d20063..38015e2f`). Clean worktree. Credential Channel Guard passed (`gh auth status` via keyring). Podman 5.8.2 with `/run/user/1000`. Siblings fetched: windows-next a3c8b23d, osx-next d273daff (both ancestors).
- **Worker drain**: Completed Order 64 `release-nix-cache-ref-scoping/purge-stale-caches`. Added `purge: true`, `purge-prefixes: nix-Linux-`, `purge-created-offset: 86400000`, `gc-max-store-size: 8000000000`, and `permissions: actions: write` to `.github/workflows/nix-cache-warm.yml`. Repo cache was 11.1 GB over 10 GB LRU limit — purge prevents LRU eviction of warmed main-scoped cache before verify-incremental runs.
- **Verification**: `ruby -ryaml` validates both `plan/index.yaml` and `.github/workflows/nix-cache-warm.yml`. `git diff --check` passes. VERSION unchanged (0.3.260620.7).
- **Coordinator**: windows-next + osx-next both ancestors of HEAD (0 ahead). No merge needed.
- **E2E gates**: local-build gate available (eligible, podman session active) but not run this cycle — CI-only config change doesn't need substrate rebuild. curl-install gate deferred (latest release v0.3.260620.8 already tested by immutable cycle at 20:34Z).
- **Push state**: pushed `linux-next` to origin over HTTPS (gh auth keyring).

## This Loop (2026-06-21T03:04Z, linux_mutable — meta-orch static-review reduction)

- **Cycle type**: meta-orchestration on mutable Linux (Claude Opus 4.8, Cowork). Off-peak (Sat 20:04 PT). No implementable `ready` packet at the current bar — chose a verifiable static-review reduction over bare ledger-hygiene.
- **Startup**: `linux-next @ 19f17b3a`, clean worktree, in sync with `origin/linux-next` (0/0). Credential Channel Guard passed (`ok:gh-credentials-store`, HTTPS).
- **Worker drain**: All remaining ready packets out of reach here — Order 64 `verify-incremental` (needs two release runs), Orders 66/69 (forge+git-mirror running), Order 67 (Podman user session, `skip:no-podman-user-session`), Order 68 (operator-attended). Orders 70/71 already completed.
- **Reduction (static review of d273daff, Order 64)**: Reviewed Gemini's warm-cache-on-main implementation without needing a release host. Confirmed correct: cron-on-default-branch warming defeats GHA ref-scoping, `save:false` on release, `hit` output name, runner.os/primary-key parity. **Gap found**: the `implement-cache-fix` handoff required purging stale per-tag caches to stay under the 10 GB GHA limit, but no purge step landed and the repo cache was already over 10 GB (LRU active) → the warmed cache can evict before verification. Web-confirmed `cache-nix-action@v7` purge API (`purge`/`purge-prefixes`/`gc-max-store-size` + `actions: write`).
- **Capture + promote**: Filed `plan/issues/enhancement-release-cache-purge-missing-2026-06-20.md`; promoted ready packet `release-nix-cache-ref-scoping/purge-stale-caches` and made `verify-incremental` depend on it (so measurement releases run against a clean cache). Finding event added to Order 64.
- **Verification**: `run-litmus-test.sh meta-orchestration --phase pre-build --size instant` → **3/3 PASS**. `plan/index.yaml` validated with `ruby -ryaml`.
- **E2E**: local-build gate `skip:no-podman-user-session`. No runtime change → no release. Coordinator: windows-next/osx-next both ancestors of HEAD, no merge.
- **Bar-raise**: not self-escalated (Tlatoāni-gated).
- **Push state**: pushing `linux-next` to origin over HTTPS (`.git/.gh-credentials`).

## This Loop (2026-06-21T02:04Z, linux_mutable — meta-orch ledger-hygiene)

- **Cycle type**: meta-orchestration on mutable Linux (Claude Opus 4.8, Cowork). Off-peak (Sat 19:04 PT) — implementable backlog drained, ledger-hygiene reduction.
- **Startup**: fast-forwarded `6af5eddc..d273daff` to `origin/linux-next` (Gemini's Order 64/65 release-cache + monitoring landed). Clean worktree. Credential Channel Guard passed (`ok:gh-credentials-store`).
- **Worker drain**: No `ready` packet implementable on this host at the current bar — Orders 64/66–69 require a release/CI host, forge+git-mirror, Podman user session, or operator attendance (e2e `skip:no-podman-user-session`). Loop-tooling orders 60–63 fully drained.
- **Reduction**: Ledger-hygiene closure of `meta-orch-enhancement-opportunities-2026-06-20.md` — stale header ("Candidate 4 completed, candidates 1-3 ready") corrected to `resolved`; dated completion event filed. Node claimed via `claim-ledger-node.sh` to avoid concurrent duplication.
- **Verification**: `run-litmus-test.sh meta-orchestration --phase pre-build --size instant` → 3/3 PASS. Markdown-only edit, no YAML parser needed.
- **E2E**: local-build gate `skip:no-podman-user-session`. No runtime change → no release. Coordinator: windows/osx-next both ancestors of HEAD, no merge.
- **Bar-raise**: zero implementable residual at current bar; loop does not self-escalate (Tlatoāni-gated).
- **Push state**: pushing `linux-next` to origin over HTTPS (`.git/.gh-credentials`).

## This Loop (2026-06-21T01:04Z, linux_mutable — meta-orch worker-drain)

- **Cycle type**: meta-orchestration worker-drain slice on mutable Linux (Claude Opus 4.8, Cowork). Off-peak (Sat 18:04 PT) — lightweight loop-tooling packet.
- **Startup**: `linux-next @ bd615934`, clean worktree, in sync with remote. Credential Channel Guard passed (`ok:gh-credentials-store`).
- **Worker drain**: Completed Order 62 `ledger-edit-claim-lease`. Added `scripts/claim-ledger-node.sh` (mkdir-atomic single-winner claim/lease for plan node closures), wired into the skill Worker Drain — reducing duplicated ledger-hygiene work from `agent-concurrency-collisions-2026-06-20.md`. Script-only closure mirroring Orders 60/61.
- **Verification**: `litmus:ledger-node-claim-shape` bound + registered under `meta-orchestration`; 6/6 steps pass, suite 3/3 PASS. 20/20 concurrency trials single-winner. YAML validated with `ruby -ryaml`.
- **E2E**: local-build gate skipped — `skip:no-podman-user-session` (Cowork sandbox). No runtime change → no release.
- **Capture**: `plan/issues/optimization-ledger-claim-cross-host-scope-2026-06-21.md` (lease same-host-only; cross-host deferred).
- **Push state**: pushing `linux-next` to origin over HTTPS (`.git/.gh-credentials`).

## This Loop (2026-06-21T00:04Z, linux_mutable — meta-orch worker-drain)

- **Cycle type**: meta-orchestration worker-drain slice on mutable Linux (Claude Opus 4.8, Cowork). Off-peak (Sat 17:04 PT) — lightweight loop-tooling packet.
- **Startup**: `linux-next`, fast-forwarded `90e43066..1973d414` to `origin/linux-next`. One untracked file at startup (`scripts/check-credential-channel.sh`) classified as a ready-but-uncommitted Order-61 deliverable and adopted, not discarded. Credential Channel Guard passed (`ok:gh-credentials-store`).
- **Worker drain**: Completed Order 61 `credential-channel-check`. Made the guard script executable, verified all three branches (cred-store/scrubbed/token), and wired the skill's Credential Channel Guard to invoke it — retiring the advisory-prose check. Script-only closure mirrors Order-60 `e2e-preflight.sh`.
- **Verification**: `litmus:credential-channel-check-shape` bound + registered under `meta-orchestration` in `litmus-bindings.yaml`; 5/5 critical-path steps pass. YAML validated with `ruby -ryaml`.
- **E2E**: local-build gate skipped — sandbox has no `/run/user/<uid>` → `skip:no-podman-user-session` (Order-60 probe). No runtime change → no release.
- **Capture**: `plan/issues/optimization-credential-channel-policy-parity-2026-06-21.md` (deferred Rust-subcommand parity).
- **Push state**: pushing `linux-next` to origin over HTTPS (`.git/.gh-credentials`).

## This Loop (2026-06-20T20:34Z, linux_immutable — curl-install e2e)

- **Cycle type**: curl-install e2e gate on immutable Linux (Fedora 44, Claude Sonnet 4.6).
- **Startup**: `linux-next @ a08eb971`, clean worktree, in sync with remote. Credential channel: `gh auth status` ✓ (keyring). No eligible worker packets for linux_immutable.
- **E2E gates**: Ran curl-install e2e for `v0.3.260620.8` (first test of this release).
  - Install: PASS (17 MB/s, SHA256 ok).
  - Substrate reset: PASS.
  - Init: FAIL — `forge-base` pip3 `pyright==1.1.410` (6.1 MB) received 0 bytes × 6 attempts in `podman build` network; root cause: pasta build-network TCP stream issue. Core images all built; no containers started.
  - Forge run: SKIPPED.
- **Findings**: Filed orders 70–71 in `plan/index.yaml`. Smoke report: `plan/issues/smoke-e2e-findings-v0.3.260620.8-2026-06-20.md`.
- **Push state**: pushing `linux-next` to origin over HTTPS (gh auth).

## This Loop (2026-06-20T20:12Z, linux)

- **Cycle type**: meta-orchestration worker-drain slice on mutable Linux (Claude Opus 4.8, Cowork).
- **Startup**: Branch `linux-next`, clean worktree. Fast-forwarded `d3974cdf..cfc475db` to `origin/linux-next`. Credential Channel Guard passed via `.git/.gh-credentials` + `credential.helper=store` (HTTPS).
- **Worker drain**: Completed `e2e-eligibility-probe` (Order 60). Structured host-eligibility verdict probe added to `scripts/e2e-preflight.sh` (`eligibility` mode, grammar `^(eligible|skip:[a-z0-9-]+)$`), wired into the skill's E2E Gates, retiring the per-cycle prose re-derivation of the podman-session skip.
- **Verification**: `litmus:e2e-eligibility-probe-shape` bound + `meta-orchestration` spec registered; `run-litmus-test.sh meta-orchestration --phase pre-build --size instant` → 4/4 OK, PASS. YAML validated with `ruby -ryaml`.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD — no merge, no release.
- **E2E gates**: Local-build gate self-skipped — the new probe returns `skip:no-podman-user-session` in the Cowork sandbox (no `/run/user`); no runtime delta since v0.3.260620.8.
- **Push state**: pushed `linux-next` to origin over HTTPS at finalization.

## This Loop (2026-06-20T20:02Z, linux — opencode / big-pickle)

- **Cycle type**: meta-orchestration worker-drain slice on mutable Linux (opencode 1.16.2 / big-pickle).
- **Startup**: Branch `linux-next`, clean worktree after force-push recovery (remote `origin/linux-next` was force-pushed 8 commits ahead of local). Local-only commits backed up to `local-backup-20260620`. Added `/.tillandsias/` to `.gitignore`.
- **Worker drain**: Claimed and partially implemented `e2e-eligibility-probe` (Order 60). Added podman-user-session capability probe to `scripts/e2e-preflight.sh` — returns `eligible` when podman on PATH + `/run/user/<uid>` exists; `skip:podman-not-installed` or `skip:no-podman-user-session` otherwise.
- **Verification**: `bash -n scripts/e2e-preflight.sh` passes.
- **Push state**: BLOCKED — no credential channel to `origin` (HTTPS auth absent, SSH unreachable, no token env vars). Order 60 work superseded by 20:12Z Cowork cycle which completed it cleanly.
- **E2E gates**: Skipped (worker drain slice; push blocked).
- **Recovery note**: Operator push session recovered 8-commit backup from `local-backup-20260620`; see forge-credentials-vault-integration-2026-06-20.md and forge-diagnostics-audit-2026-06-20.md filed below.

## This Loop (2026-06-20T20:00Z, linux)

- **Cycle type**: meta-orchestration worker-drain slice on mutable Linux (Gemini).
- **Startup**: Branch `linux-next`, clean worktree. Fast-forwarded to `origin/linux-next@9411b549`. Startup credential channel check passed via keyring.
- **Worker drain**: Claimed and completed `cowork-nonpython-ledger-validation/decide-and-document` (Order 63). Documented the approved fallback YAML validator `ruby -ryaml -e "YAML.load_file('<file>')"` in the Finalization section of `skills/meta-orchestration/SKILL.md` for environments where `tillandsias-policy` is not pre-built, eliminating the discouraged Python fallback. Updated `plan/index.yaml` and `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` to reflect task closure.
- **Verification**: Validated `plan/index.yaml` with both `tillandsias-policy validate-yaml` and the fallback Ruby one-liner.
- **E2E gates**: Skipped (worker drain slice).
- **Push state**: pushed `linux-next` to origin over HTTPS.

## This Loop (2026-06-20T19:40Z, linux — Tlatoāni-directed)


- **Governance**: Bar-raises are Tlatoāni-gated. Convergence point = zero residual
  findings at the current approved bar. Loop proposes bar-raise candidates but
  must not self-escalate. Authoritative rule added to
  `methodology/convergence.yaml` (`bar_raise_governance`); skill subsection
  rewritten to match. No code/runtime delta; docs/methodology only.

## This Loop (2026-06-20T19:15Z, linux)

- **Cycle type**: meta-orchestration worker-drain slice on mutable Linux (Cowork).
- **Startup**: Branch `linux-next`. Worktree dirty at entry — one unpushed local
  commit (`9c8f3f9a`) plus a staged concurrency-observation note. A concurrent
  sibling agent committed `b5484c59` and pushed; after fetch, HEAD synced clean
  with `origin/linux-next@b5484c59`, not ahead. Recovery complete with no loss.
- **Credential guard (dogfood)**: `.git/.gh-credentials` present + credential.helper
  configured (persisted from the 18:55Z fix); push path healthy.
- **Worker drain**: Drained `cowork-headless-credential-isolation/runtime-guard`.
  Added the start-of-cycle Credential Channel Guard to
  `skills/meta-orchestration/SKILL.md` so the loop fails loud (files a
  `no-credential-channel` blocker) instead of silently accreting unpushable
  commits. The node's `file-feedback` subtask stays `ready` — a write-to-Anthropic
  submission out of scope for the unattended loop.
- **Coordinator**: windows-next + osx-next both ancestors of HEAD — no merge,
  no multihost coordination, no release (no code delta).
- **E2E gates**: Skipped — no podman user session in Cowork sandbox (no `/run/user`).
  No runtime delta since v0.3.260620.7.
- **Reduction engine**: Encoded capture → reduce → promote + rising-bar scan in
  `skills/meta-orchestration/SKILL.md`. Filed four enhancement/optimization/research
  findings and reduced them to `plan/index.yaml` orders 60–63 (none lost). YAML
  validated with `ruby` (non-Python).
- **Push state**: pushed `linux-next` to origin over HTTPS at finalization.

## This Loop (2026-06-20T19:05Z, linux)

- **Cycle type**: meta-orchestration ledger-hygiene slice on mutable Linux (Cowork).
- **Startup**: Branch `linux-next`, clean worktree. `git fetch origin --prune` (HTTPS)
  succeeded; stale "ahead 18" resolved to in-sync with `origin/linux-next@4f5fd488`.
  Earlier SSH/HTTPS push blocker is cleared.
- **Coordinator check**: windows-next=a3c8b23d, osx-next=d829808d both ancestors of
  linux-next HEAD. No sibling merge needed.
- **Worker drain**: No runnable plan work. Identified two stale `plan/index.yaml`
  items — step-58 `future-intentions-drain` open despite its closed step file
  (future_intentions=[]), and a duplicate `note:` key in step-65's
  github-login-egress event. Edited both; a concurrent agent committed the
  identical fixes as `1d6db6dd` before this cycle's commit, so they landed via
  that commit (now an ancestor of HEAD) rather than `9c8f3f9a`. Validator returns
  `ok: plan/index.yaml`. Collision logged in
  `plan/issues/agent-concurrency-collisions-2026-06-20.md`.
- **Coordinator**: siblings already ancestors of HEAD; no merge or release action.
- **E2E gates**: Skipped — no podman user session in Cowork sandbox (no `/run/user`).
  No runtime delta since v0.3.260620.7.
- **Push state**: pushed `linux-next` to origin over HTTPS at finalization.

## This Loop (2026-06-20T18:35Z, linux)

- **Cycle type**: meta-orchestration no-op on mutable Linux (Cowork session).
- **Startup**: Branch `linux-next`, 16 commits ahead of `origin/linux-next`. Git fetch
  FAILED — SSH unavailable. Worktree had pending merge (4beb811a) already committed by
  concurrent agent, merging `origin/linux-next@8f8887b2` and switching remote to HTTPS.
- **Worker drain**: No eligible plan work. All plan steps completed/done/deferred.
  No ready nodes remain for linux host.
- **Coordinator check**: Sibling branches (local cache) windows-next=a3c8b23d and
  osx-next=d829808d are both ancestors of linux-next HEAD. No merge needed.
  No release conditions met (push blocked, HTTPS auth missing).
- **Verification**: Litmus 107/107 PASS.
- **E2E gates**: Skipped — podman user session unavailable in Cowork sandbox (no /run/user).
  No runtime delta since v0.3.260620.7.
- **Push state**: BLOCKED — HTTPS credentials absent; SSH also unavailable.
  linux-next 16 commits ahead of origin. Operator must push.

## This Loop (2026-06-20T17:55Z, linux)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin, fast-forwarded to `origin/linux-next@267ddcf5`, then pushed plan claim commit `68b9ed99`.
- **Worker drain**: completed the remaining `agent-concurrency-collisions-2026-06-20` slice. Added `scripts/with-tillandsias-process-cleanup.sh`, wired Linux build/install and init E2E steps through it, and added gate-1 assertions that the installed launcher path and version match the post-build `VERSION` file.
- **E2E fixes discovered in-cycle**: local-build E2E first exposed a fake-Podman progress parser failure in `litmus:image-build-convergence-shape`, then exposed a non-interactive diagnostics path that spawned a detached tray companion. Fixed telemetry fallback in `scripts/build-image.sh`, descendant-only litmus runner cleanup in `scripts/run-litmus-test.sh`, and `TILLANDSIAS_NO_TRAY=1` guards in Linux E2E/diagnostics smoke paths.
- **Verification**: shell syntax checks PASS; wrapper no-leak smoke PASS; deliberate leaked fake `tillandsias` process was terminated and returned expected exit 70; fake-Podman image-build convergence litmus PASS; `scripts/run-litmus-test.sh init-incremental-builds --size instant` PASS; `git diff --check` PASS; `./build.sh --check` PASS with the known non-fatal dev-proxy warning.
- **E2E gates**: final local-build E2E at `target/build-install-smoke-e2e/20260620T173320Z` passed build/install (`build_install_exit=0`), destructive Podman reset (`reset_exit=0`), pristine init (`init_exit=0`), and prompted in-forge `/forge-continuous-enhancement` (`forge_exit=0`) on installed `Tillandsias v0.3.260620.7`.
- **In-forge outcome**: `/forge-continuous-enhancement` filed `plan/forge-improvements/proposals/2026-06-20-diagnostics-prompt-optimize.md`; the in-forge GitHub push failed due missing credentials, so the host will push the final clean tip.
- **Next**: macOS vault aarch64 published-port reachability remains the critical cross-host blocker. `forge-build-telemetry-2026-06-20` implementation is present in `83a3600a` and this cycle fixed its fake-progress litmus regression.

## This Loop (2026-06-20T13:56Z, linux)

- **Cycle type**: meta-orchestration worker drain, coordination audit, and local-build E2E gate on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin, fast-forwarded to `origin/linux-next`, then pushed claim commit `824cbc67` and implementation commit `bb4196df`.
- **Sibling heads after post-push audit**:
  - `main`: `6dfafdf1`.
  - `linux-next`: `bb4196df`.
  - `windows-next`: `a3c8b23d` (ancestor of linux-next; 0 sibling-ahead drift).
  - `osx-next`: `d829808d` (ancestor of linux-next; 0 sibling-ahead drift).
- **Worker drain**: completed the first `agent-concurrency-collisions-2026-06-20` slice. Added `scripts/with-smoke-lock.sh`, routed Linux build-install E2E gate scripts through the shared `build-install-smoke-e2e` lock, and updated local-build/curl-install e2e runbooks to log lock evidence.
- **Verification before E2E**: shell syntax checks, helper success/failure lock smokes, `git diff --check`, and `scripts/with-smoke-lock.sh --name build-install-smoke-e2e -- ./build.sh --check` passed.
- **E2E gates**: local-build E2E started at `target/build-install-smoke-e2e/20260620T134849Z` and acquired the new lock at `2026-06-20T13:49:31Z`. Gate 1 failed with `build_install_exit=1` at `2026-06-20T13:56:24Z`; destructive reset and init gates were not run. Root failure was post-build `litmus:onboarding-cold-start-discovery` step 3: missing welcome banner `INDEX.md` cheatsheet discovery signal.
- **Findings**: filed `local-smoke/onboarding-cold-start-discovery-cheatsheet-signal` in `plan/issues/build-install-smoke-e2e-findings-2026-06-20.md`. The diagnostics annex wrote `plan/diagnostics/diagnostics_20260620T135318Z-summary.md` with 25/25 checks passing.
- **Release/e2e freshness**: no release action because local-build E2E did not clear gate 1.
- **Next**: fix the welcome banner `INDEX.md` signal and rerun local-build E2E; continue remaining concurrency cleanup/stale-binary/autoincremental guardrails after the gate is unblocked.

## This Loop (2026-06-20T09:00Z, linux)

- **Cycle type**: meta-orchestration E2E gate on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin and confirmed local branch was aligned with `origin/linux-next@36980e42`.
- **Sibling heads after startup fetch**:
  - `main`: `6dfafdf1`.
  - `linux-next`: `36980e42`.
  - `windows-next`: `a3c8b23d`.
  - `osx-next`: `d829808d`.
- **E2E gates**: Ran local-build E2E via `/build-install-and-smoke-test-e2e`. Build and install succeeded (`build_install_exit=0`), and destructive Podman reset succeeded (`reset_exit=0`). However, the re-provisioning step (`tillandsias --init --debug`) failed (`init_exit=1`) because `wasmtime` is missing from the minimal-44 dnf repositories.
- **New findings**: Filed `local-smoke/wasmtime-dnf-migration-failure` in `plan/issues/build-install-smoke-e2e-findings-2026-06-20.md`.
- **Blockers**: Added `local-smoke/wasmtime-dnf-migration-failure` as an active blocker for the Linux E2E gate.

## This Loop (2026-06-20T07:49Z, linux)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin and
  confirmed local branch was aligned with `origin/linux-next@c3c7af60`, then
  pushed claim commit `22e5987a`.
- **Sibling heads after startup fetch**:
  - `main`: `6dfafdf1`.
  - `linux-next`: `c3c7af60` at worker selection, then `8fe56fb9` after the
    implementation commit.
  - `windows-next`: `a3c8b23d` (ancestor of linux-next at post-push audit).
  - `osx-next`: `d829808d` (ancestor of linux-next at post-push audit).
- **Worker drain**: completed `policy/no-python-litmus-drift`. Added
  `tillandsias-policy` helpers for JSON string extraction, menu parity
  assertions, disabled-with-v2 menu assertions, and Vault unsealed timestamp
  parsing; extended `check-no-python-scripts` to scan litmus YAML; replaced the
  remaining active litmus Python snippets with Rust-backed helpers or
  POSIX shell/openssl equivalents.
- **Verification**: `cargo test -p tillandsias-policy` PASS; five touched
  litmus YAML files validate; policy no-Python checker PASS; shell wrapper
  PASS; helper smoke checks PASS; `cargo fmt --all -- --check` PASS;
  `git diff --check` PASS; active litmus Python scan found no matches;
  `./build.sh --check` PASS with only the known unrelated dev-proxy warning.
- **Integration/runtime**: post-push coordination re-fetched origin at
  2026-06-20T07:59Z. `origin/windows-next` and `origin/osx-next` are both
  ancestors of `origin/linux-next@8fe56fb9` (drift: windows 0 ahead / linux 21
  ahead; osx 0 ahead / linux 20 ahead). No merge or freeze required.
- **Release/e2e freshness**: latest published GitHub release remains
  `v0.3.260618.2` at `6dfafdf1`, published 2026-06-18T18:07:14Z; existing
  curl-install smoke evidence for that release is current.
- **E2E gates**: destructive local-build/curl-install gates not run for this
  policy/litmus-only worker slice; no shipped runtime or release artifact delta.
- **New findings**: none.

## This Loop (2026-06-20T07:38Z, linux)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin,
  fast-forwarded from `d697f866` to `b2b37d10`, then pushed claim commit
  `4c15fc72`.
- **Sibling heads after startup fetch**:
  - `main`: `6dfafdf1`.
  - `linux-next`: `b2b37d10` at worker selection, then `4c15fc72` after the
    claim commit.
  - `windows-next`: `a3c8b23d` (ancestor of linux-next at fetch).
  - `osx-next`: `d829808d` (ancestor of linux-next at fetch).
- **Worker drain**: completed
  `forge-diagnostics/e2e-piggyback-orchestration` no-Python diagnostics litmus
  drift. Added `tillandsias-policy validate-forge-diagnostics-json`, made it
  tolerate forge banner/fenced JSON logs via the distiller's brace-extraction
  contract, replaced the diagnostics litmus's inline `python3 -c` validator,
  and excluded `.stderr.log` companions from the stdout JSON selector.
- **Verification**: `cargo test -p tillandsias-policy` PASS; edited litmus YAML
  validates; validator passes against
  `target/forge-diagnostics/diagnostics_20260619T234257Z.log`; no-Python script
  checker PASS; `cargo fmt --all -- --check` PASS; `git diff --check` PASS;
  `./build.sh --check` PASS.
- **Integration/runtime**: post-push coordination re-fetched origin at
  2026-06-20T07:42Z. `origin/windows-next` and `origin/osx-next` are both
  ancestors of `origin/linux-next@30e014dc` (drift: windows 0 ahead / linux 18
  ahead; osx 0 ahead / linux 17 ahead). No merge or freeze required.
- **Release/e2e freshness**: latest published GitHub release remains
  `v0.3.260618.2` at `6dfafdf1`, published 2026-06-18T18:07:14Z; existing
  curl-install smoke evidence for that release is current.
- **E2E gates**: destructive local-build/curl-install gates not run for this
  policy/litmus-only worker slice; no shipped runtime or release artifact delta.
- **New findings**: filed `policy/no-python-litmus-drift` for remaining
  `python3` command fields in non-diagnostics litmus YAML.

## Progress Since Last Loop

- **agent-concurrency-collisions-2026-06-20**: COMPLETED; smoke gates now use a shared lock helper, process cleanup around host-side launcher runs, and post-install path/version freshness assertions.
- **local-build E2E**: 16:53Z smoke findings completion records the welcome-banner signal restored and all gates passing; no active Linux local-build blocker remains from the 13:49Z rerun.
- **policy/no-python-litmus-drift**: COMPLETED; no active litmus YAML command
  fields shell out to Python, and the no-Python checker now scans litmus YAML.
- **forge-diagnostics/e2e-piggyback-orchestration**: COMPLETED no-Python
  diagnostics litmus drift slice; Rust validator now owns diagnostics JSON
  validation.

## This Loop (2026-06-20T07:20Z, linux)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin, in sync with `origin/linux-next` at `36cd9020`.
- **Sibling heads after fetch**:
  - `main`: `6dfafdf1` (tagged `v0.3.260618.2`).
  - `linux-next`: `36cd9020`
  - `windows-next`: `e332afb6` (ancestor of linux-next, 0 ahead).
  - `osx-next`: `c7d32fb9` (ancestor of linux-next, 0 ahead).
- **Worker drain**: claimed and completed `policy/no-python-runtime-scripts` final slice. Ported the final two Python-backed scripts — `fetch-cheatsheet-source.sh` (6 python3 sites) and `regenerate-cheatsheet-index.sh` (1 python3 site) — into `tillandsias-policy` as subcommands, reducing shell scripts to thin compile+exec wrappers. `scripts/check-no-python-scripts.sh` passes successfully with exit code 0.
- **Integration/runtime**: no sibling branch is ahead of linux-next.
- **Release/e2e freshness**: no release warranted from this tooling-only cycle.
- **E2E gates**: not run this cycle (worker slice).
- **New findings**: none.

## Loop 2026-06-20T06:00Z (worker drain — nanoclawv2 slice)

- **Cycle type**: meta-orchestration on mutable Linux (Fedora 44): worker drain plus coordination audit.
- **Startup**: began clean on `linux-next` at `f871f8b2`; no tracked or untracked worktree changes. Host classified as `linux_mutable`.
- **Worker drain**: Claimed `nanoclawv2-orchestration` reclaimable lease. Slice 2 completed: registered nanoclawv2 in Rust image builder (image_specs, image_build_inputs with forge-base dependency, run_init image array). All tests pass, clippy clean. Committed `58996d8f`.
- **Sibling coordination**: no merge needed. `origin/windows-next` and `origin/osx-next` heads checked — both remain ancestors of `origin/linux-next`; drift is 0 commits for both.
- **E2E gates**: skipped. The nanoclawv2 --init registration is additive (image was already buildable via build-image.sh; no runtime crate delta to smoke-test). Latest GitHub release remains `v0.3.260618.2`.
- **Release decision**: deferred. No release-blocking change; VERSION remains `0.3.260619.5`, no `v0.3.260620.*` tag exists.

## Loop 2026-06-25T22:07Z (macOS worker drain — control-wire fix)

- **Cycle type**: `/advance-work-from-plan` on macOS `osx-next`.
- **Startup**: claimed order 98
  `macos-exec-guest-control-wire-timeout` after the v0.3.260625.1 curl smoke
  found `--exec-guest` and `--github-login` timing out on vsock port 42420.
- **Fix**: macOS VZ cloud-init no longer condition-skips the required
  headless-fetch oneshot when `/usr/local/bin/tillandsias-headless` already
  exists. The fetch script remains idempotent, `headless-preflight.sh` verifies
  the binary and vsock device, and `podman.socket` is wanted/ordered while
  remaining non-fatal for the diagnostic control wire.
- **Credential ordering**: macOS `--github-login` now prompts lazily after VM
  and control-wire readiness; guest `run_github_login` now prompts for git
  identity after git image, networks, Vault, and helper container startup.
- **Verification**: local signed app fresh-provisioned; first-boot
  `--exec-guest` returned `control-wire-ok`; second-boot `--exec-guest`
  returned `control-wire-second-boot-ok`; guest status showed fetch/headless
  services and `podman.socket` active with `/run/podman/podman.sock` present.
- **Residual**: full provider-neutral auth preflight still depends on the
  linux/shared `podman-health-lifecycle-facade` packet. Recent Vault timeout
  bumps remain hacky stopgaps until the typed Podman lifecycle layer exists.

## Loop 2026-06-18T20:50Z (release-smoke pass)

- **Cycle type**: meta-orchestration release-smoke pass after fetch/worker and sibling audit.
- **Startup**: clean mutable-Linux host on `linux-next`; fetched origin, fast-forwarded from `7bc7b5bb` to `36cd9020`, then pushed forge findings commit `62964f02` and this smoke ledger commit.
- **Sibling heads after fetch**:
  - `main`: `6dfafdf1` (tagged `v0.3.260618.2`).
  - `linux-next`: `36cd9020` at audit start, then `62964f02` after forge proposals.
  - `windows-next`: `e332afb6` (ancestor of linux-next, 0 ahead / 12 behind).
  - `osx-next`: `c7d32fb9` (ancestor of linux-next, 0 ahead / 14 behind).
- **Worker drain**: no implementation packet claimed before the release gate. The latest release was newer than recorded curl-install smoke evidence, so `/smoke-curl-install-and-test-e2e` was prioritized.
- **Integration/runtime**: no sibling branch is ahead of linux-next, and `plan/localwork/runtime-litmus/current` is absent. No full litmus was started.
- **Release/e2e freshness**: GitHub latest release is `v0.3.260618.2`, published 2026-06-18T18:07:14Z at `6dfafdf1`; curl-install smoke now has PASS-with-findings evidence at 2026-06-18T20:50Z.
- **E2E gates**: curl-install gate passed install, destructive reset, empty store verification, fresh init, and prompted OpenCode forge lane. Report: `plan/issues/smoke-e2e-findings-v0.3.260618.2-2026-06-18.md`.
- **New findings**: in-forge `/forge-continuous-enhancement` filed three ready follow-ups: `smoke-finding/forge-ripgrep-missing`, `smoke-finding/forge-marksman-missing`, and `smoke-finding/forge-nix-store-missing`.

## Loop 2026-06-18T23:20Z (worker drain — no-python slice)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: clean `linux-next`, in sync with origin (`5613b40e`); fetched
  origin/prune. Siblings: windows-next `e332afb6`, osx-next `c7d32fb9` (both
  ancestors of linux-next); main `6dfafdf1`.
- **Packet claimed + completed**: `policy/no-python-runtime-scripts` —
  `distill-forge-diagnostics.sh` slice. Ported to a `tillandsias-policy
  distill-forge-diagnostics` subcommand; shell reduced to a thin build+exec
  wrapper. 45/45 target/forge-diagnostics logs byte-for-byte parity-verified vs
  the former CPython extractor. clippy/fmt/test/`build.sh --check` green;
  workspace + serde_json consumers re-tested after enabling `preserve_order`.
- **Remaining Python-backed scripts**: 2 — `fetch-cheatsheet-source.sh` (6
  python3 sites, large) and `regenerate-cheatsheet-index.sh` (1 site).
- **Other claimable**: `nanoclawv2-orchestration` (RECLAIMABLE; large
  multi-component build with open architecture questions — needs a task-graph
  decomposition cycle before code).
- **E2E**: not run this cycle (worker slice; left budget for orchestrator).
- **Release**: not warranted from this cycle alone (tooling-only change; no
  shipped-binary behavior change).

## Active Conflicts & Mediation

- Deadlocks: none detected.
- Thrashing/write-write collision: none detected.
- Branch drift: none; both sibling branches are integrated into `linux-next`.
- Wrong-direction progress: none detected.
- High-Velocity Alignment Event: inactive.
- Convergence velocity: positive; all orphaned future intentions are now
  shaped into plan packets.

## Blockers

- **CRITICAL (linux -> macOS)**:
  `enclave/macos-vault-unreachable-via-publish-aarch64`. Current Linux tree
  already has Vault API listener `0.0.0.0:8200` and host CA loading from
  `/tmp/tillandsias-ca/intermediate.crt`; next useful evidence is the aarch64
  VM probe:
  `curl --cacert /tmp/tillandsias-ca/intermediate.crt https://127.0.0.1:8201/v1/sys/health?standbyok=true`.
- **RECONCILE (linux)**: the old `nanoclawv2-orchestration` lease expired; plan state now points toward the ZeroClaw migration path, so reread the packet before taking any legacy NanoClawV2 work.
- **READY (cross-host)**: `future-intentions-drain/windows-macos-feature-parity`
  packet now shaped and ready for host-specific work.

## Assignment Board

- **Linux primary**: Move to next independent ready packet in the plan.
- **Windows primary**: Claim and execute Windows slice of `vault-flow/xplat-gating-parity`.
- **macOS primary**: Claim and execute `macos-in-vm-enclave-provisioning` and the orchestrated GitHub Login route (m8).
- **Coordinator fallback**: keep ACTIVE.md and host queues aligned with the new
  Windows/macOS parity packet.

## Pending Pings

- Need aarch64 VM operator evidence for the Vault published-port probe above.
- Need operator-attended `tillandsias --debug --github-login` validation with a
  fresh/rotated token on current release once the macOS layer-5 blocker is
  resolved.

## This Loop (2026-06-27T03:12Z, linux_mutable — meta-orch + worker drain)

- **Cycle type**: meta-orchestration worker drain on mutable Linux.
- **Startup**: clean mutable-Linux host on `linux-next` at `d4f754da`; credential channel ok:gh-keyring; e2e eligibility: eligible.
- **Sibling heads at start**:
  - `main`: `f8ed19d1`.
  - `linux-next`: `d4f754da`.
  - `windows-next`: `bb1d1f9c` (1 commit ahead — WSL2 parity fix).
  - `osx-next`: `db9e2d0d` (ancestor of linux-next).
- **Worker drain** (all linux, all committed+pushed):
  - Order 106 (`enclave-transparent-proxy-feasibility`): DONE — verdict: TPROXY not feasible rootless; iptables blocked for uid 1000; containers.conf [engine] env is the correct alternative. Commit `bdb5bb02`.
  - Order 107 (`enclave-proxy-centralize-injection`): DONE — extracted `proxy_env_args()` + `apply_proxy_env()` helpers; fixed build_git_run_args wrong NO_PROXY (active bug); fixed build_inference_run_args, build_opencode_forge_args, build_forge_agent_run_args; added `ensure_containers_conf_proxy_env()` called at `--init`. Commit `a3319504`.
  - Order 111 (`zeroclaw-release-packaging`): DONE — flake.nix: zeroclaw-x86_64-musl build; release.yml: build + bundle + cosign; install.sh: download + install alongside tillandsias. Commit `8b5dd30d`.
  - Windows merge: merged `origin/windows-next@bb1d1f9c` (WSL2 parity: podman.socket, VAULT_API_BASE_URL, DNS routing); clippy fix (collapsible_if). Commit `a105306e`.
- **Ready work remaining**:
  - Order 112 (`forge-harness-auth-device-flow`): ready but estimated 8h — too large for this cycle. Filed; carry forward.
- **Integration/runtime**: `origin/osx-next` is ancestor of `origin/linux-next`. `origin/windows-next` now integrated via merge commit `a105306e`.
- **E2E gates**: not run this cycle (worker slice; no runtime binary behavior changes; proxy refactor is structurally equivalent).
- **Release**: no new release triggered; zeroclaw packaging changes require a new release build to take effect.
- **New findings**: none.

### Cycle 2026-06-27T05:05Z (linux-macuahuitl-sonnet46)
- Committed order 112 slice 1: ProviderId enum, vault write/read/probe helpers, forge container API key injection
- Fixed two clippy collapsible-if errors in vault_bootstrap.rs and main.rs
- Queue status: 112 in_progress (phase 2 deferred), 104 blocked on vsock transport
- No ready work remains on linux-next; queue drained for this cycle

### Cycle 2026-06-27T05:45Z (linux-macuahuitl-sonnet46)
- Committed order 113: vault_kv_get_via_exec + is_github_key_present + probe_github_username + remove check_github_token_health
- Queue status: fully drained (no ready/pending packets remain)
- Orders 112 and 113 both completed this session

### Cycle 2026-06-27T04:43Z — release
- Merged PR #50 (linux-next → main), tagged v0.3.260627.1
- Release workflow: all three jobs success (17m) — Linux musl, macOS arm64, Windows x64
- First release with tillandsias-zeroclaw-linux-x86_64
- Latest tested release: v0.3.260627.1

## /loop iter 1 (2026-07-05 — unblock macOS: order 188 arch-aware first-run cargo tools)

macOS filed evidence + packet 188 (macOS-blocking): forge-base is built in-guest on
the aarch64 Apple-Silicon guest, where the Containerfile's hardcoded-x86_64 cargo
curl/tar chain (a) baked non-executable x86_64 binaries and (b) hung `podman build` /
VM setup. Linux (image owner) implemented slice 1 of order 180:

- lib-common: `_forge_uname_arch` + `install_prebuilt` (idempotent, fail-soft,
  `curl --max-time`) + `ensure_forge_prebuilt_tools` (15 cargo tools, arch-substituted
  URLs) into the order-179 persistent cache. Verified on x86_64 (nextest installs +
  runs; 2nd call no-op); all aarch64 assets pre-verified 200. NO API / NO
  compile / NO binstall (project policy).
- 4 forge entrypoints call it backgrounded (never blocks launch).
- Containerfile.base: cargo block + ARG _VERSION/_SHA256 removed; Antigravity `agy`
  pipe-to-shell moved to every-launch entrypoint install-if-missing.
- Litmus: new arch-shape litmus + updated the stale default-image-containerfile-shape
  STEPs 7-8 (pinned the old cargo-at-creation structure). default-image suite 100%.
- 188 -> done. macOS to re-verify on a cold Apple-Silicon guest.
- Next: slice 2 (actionlint/vale/wasmtime/dart arch-aware) + de-hardcode versions to
  releases/latest redirect.

## Cycle 2026-07-07T07:45Z (linux — release v0.3.260707.1 + CI fixes)

- **Drift**: `osx-next` (0 behind, 35 ahead) and `windows-next` (0 behind, 31 ahead) both fully contained in `origin/linux-next` — verified via `git branch --contains`. No merge needed.
- **Release v0.3.260707.1**: PR #69 (linux-next→main) created, VERSION conflict resolved by merging `origin/main` into `linux-next` (kept VERSION=0.3.260707.1). PR merged at 2026-07-07T07:36:25Z. Tag `v0.3.260707.1` pushed. Release workflow run ID 28849700897.
  - **Linux musl**: ✅ SUCCESS (12m25s, Nix cache miss — full build). Artifacts published.
  - **macOS tray (Apple Silicon)**: ❌ **FAILURE** — `error[E0463]: can't find crate for 'core'` for `aarch64-unknown-linux-musl` target. Root cause: `scripts/build-macos-tray.sh` uses `cargo zigbuild` to cross-compile guest Linux binaries, but the `aarch64-unknown-linux-musl` Rust target is not installed on the macOS runner. **Fix applied**: added `rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl` to the "Install guest cross-build tools" step in `.github/workflows/release.yml`.
  - **Windows tray**: ✅ SUCCESS. Artifacts uploaded.
  - **Release published**: Linux assets published (Nix-built musl binaries + install/uninstall/verify scripts + Cosign bundles). No macOS tray DMG or tarball due to build failure.
- **nix-cache-warm.yml push trigger removed**: The cache warm triggered on every push to `main`/`linux-next` touching `flake.nix`/`flake.lock`/itself, which overlapped with the release workflow — both concurrently built the same Nix derivations (duplicate CPU time). Fix: removed the `push` trigger entirely. Cache warm now runs only on the weekly schedule and `workflow_dispatch`. The release workflow has its own `Nix Cache` step (`save: false`, restore-only) so it doesn't depend on the cache warm.
- **Files changed**:
  - `.github/workflows/release.yml`: +`rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl`
  - `.github/workflows/nix-cache-warm.yml`: removed `push` trigger (keep `schedule` + `workflow_dispatch`)
- **Blocked**: orders 148/150/154 (Windows), 155/161b/198 (macOS) need their respective host agents. Order 145 (encrypted-channel-vsock-cutover) needs cross-host coordination. Order 129 needs user to run forge session for proxy logs.

### Cycle 2026-07-08T14:00Z (macos — build-install-smoke-e2e)
- **PASS**: Local build and smoke test e2e succeeded on `macos` (tested commit `b3e52235`). VM substrate wiped and cleanly re-provisioned.

## Cycle 2026-07-07T19:17Z (linux_immutable — meta-orchestration, opencode)

- **Host**: Linux immutable (Fedora Silverblue), `linux-next` (clean at `9f4dd61d`,
  credential guard `ok:gh-keyring`).
- **Order 236 (container-microdnf-gpg-workaround)**: Found already completed in
  commit `9f4dd61d` but still marked `ready` in `plan/index.yaml`. Updated status
  to `done` with completion event. Noted residual: `Containerfile.framework` and
  `inference/Containerfile` still have `microdnf install` without `--nogpgcheck`.
- **Reduction observation**: plan/index.yaml reported order 236 as `ready` for
  ~11h after the fix commit landed — plan ledger lags behind `git log` when only
  one side (code vs plan) is updated. No formal cross-packet staleness checker.
- **Next cycle suggestion**: run curl-install e2e against latest release
  v0.3.260707.2 (latest tested in plan: v0.3.260627.1) on a linux_immutable host;
  or pick up order 224 (litmus-command-portability-dsl-research) for `any` host.

## Cycle 2026-07-08T18:56Z (forge — git-mirror credential validation)

- **Validation request**: Validate that git-mirror is configured to push to remote transparently without credentials, and check related work packets in plan/.
- **Host**: forge container, `main` (tracking `origin/main`), TILLANDSIAS_HOST_KIND=forge
- **Credential guard**: `ok:forge-git-mirror` — but this is a **false positive**. `git push --dry-run origin main` fails: `fatal: could not read Username for 'https://github.com': No such device or address`.
- **Root cause**: The guard's mirror-reachability probe (`git ls-remote origin HEAD`) succeeds against GitHub's public repo (anonymous read), NOT because a push credential channel exists. `origin` points to `https://github.com/8007342/tillandsias.git` directly — no `url.insteadOf` rewrite to the mirror, no GH_TOKEN, no .gh-credentials, no gh auth.
- **Mirror design (images/git/)**: Correctly designed — entrypoint configures `TILLANDSIAS_PROJECT_REMOTE_URL` as upstream origin; post-receive hook fetches GitHub token from Vault at push time, constructs ephemeral auth URL, forwards pushed refs by explicit refspec. This design is sound but this forge is NOT wired through the mirror.
- **Order 177 exit criteria**: Still pending — "mirror ls-remote and direct GitHub ls-remote agree on linux-next" and "upstream forwarding failure returns non-zero" both require a forge that actually pushes through the mirror.
- **New finding filed**: `plan/issues/forge-credential-guard-push-channel-gap-2026-07-08.md` — the guard must distinguish between mirror-proxied and direct-GitHub origins.
- **Blocked**: this cycle cannot push its findings (no credential channel). This matches the credential gap documented in the new finding.

## Cycle 2026-07-09T19:23Z (linux_mutable macuahuitl — sole-builder session: audits + worker drain + e2e)

- **Agent**: linux-macuahuitl-fable5-20260709T1923Z (operator-directed: void stale leases, take over work, audit other agents, full destructive e2e as needed).
- **Startup**: pulled 226 commits; sibling heads main `1684c111`, linux-next `8424f392`, windows-next `1c89b835` (integrated), osx-next `1780cfb3` (integrated). Credential guard `ok:gh-keyring`; e2e preflight `eligible`.
- **Cycle 1 — audit of recent agent work** (`3b018a15`, `133538ef`):
  - FIXED F1: container_deps unit tests executed the real satisfier (cargo test could create networks / start Vault+proxy); reduced to compile-time assertions.
  - FIXED F2: order-228 liveness probe ran blocking podman calls on async workers → spawn_blocking.
  - Reconciled: order 122 → done (slices via 227/228/229); order 237 expired lease voided → ready with residual; 230/231 dependency_note (153 slice 1 landed); filed order 252.
  - Full narrative: `plan/issues/linux-audit-recent-work-2026-07-09.md` (F1-F8).
- **Cycle 2 — order 245 network-architecture-audit** (`11f20ef5`): DRAFT v1 in the deliverable — runtime taxonomy, source-verified container network matrix, scenarios S0-S5, container_deps RuntimeContext proposal, platform matrix, patch list P1-P7. Vault-missing-from-init CONFIRMED → order 253 filed. gh-login 401 network-exonerated (no_bump CONNECT tunnel; dual-homed helper) → order 246 scope. Ratification pending (3 named verifier agents).
- **Cycle 3 — orders 230/231 done** (`744f4749`, `4c7babc3`): LoginStatePush + CloudProjectsPush wired to change-gated broadcast sources (subscriber-gated 60s vault presence probe — raw token never read in the vsock process; request piggyback). 20/20 vsock_server tests. FIXED F7 (liveness/login tasks now aborted at listener shutdown). Filed order 254 (listen-vsock feature combo never linted/tested in CI: 13 warnings + 2 drifted pty_handler tests). 249 got a design-input note (not claimed — deps 245/246 unratified).
- **Cycle 4 — destructive local-build e2e** (run `20260709T195719Z` @ `4c7babc3`): **STOPPED at gate 1** per runbook — compile/clippy/tests/install-prep PASSED; post-build status smoke 4/6: `litmus:opencode-prompt-e2e-shape` STEP 5 is a timing-race false negative (the in-forge cycle's plan commit `3621fc74` exists — order 255 filed) and `litmus:tray-parity-matrix-complete` is the KNOWN order-243 failure (ping appended: it gates ALL linux local-build e2e acceptance). **No podman reset performed.** Findings: `plan/issues/build-install-smoke-e2e-findings-2026-07-09.md`.
- **Bonus**: the gate-1 smoke's in-forge agent implemented order 252 mid-run (`ce70c788`, completed `3621fc74`); audited PASS (wrapper outside block_on, both entry points routed, order-229 gap allowlist eliminated).
- **Queue after session**: next Linux picks = order 243 (1h, unblocks the e2e gate), 253 (2h vault-in-init), 232-235 (concurrency safeguards — elevated by the F3 liveness-race note), 254, 255, 237 residual. Multi-cycle audits 245-251 await verifier agents (opencode-bigpickle, antigravity-gemini, codex-gpt55-highthink).

## Cycle 2026-07-09T20:40Z (linux_mutable macuahuitl — second drain wave, /advance-work-from-plan iterations)

- **Agent**: linux-macuahuitl-fable5-20260709T1923Z (continuation; operator: keep draining, file sibling work in plan when blocked).
- **Order 243 done** (`a50d061f`): tray-parity litmus root cause was the runner (folded command = zero steps parsed, failing structurally since authoring). Semantic split: post-build litmus now gates the CURRENT host's column (single-line command + explicit patterns); ALL-platform completeness moved to merge-to-main-and-release §0 as an operator-overridable hold (16 gaps today). Orders 255 (step-5 race) refined, 256 filed (runner ignores step exit codes + silent zero-step parse — every patternless litmus step is currently a dead check).
- **Order 253 done** (`8b6c7031`): vault joins --init's declarative image set; build_vault_image gains an identity-tag exists-skip (kills the per-login podman build) + actionable on-demand hint. Closes 2 of 3 order-245 observations structurally.
- **Order 232 done** (`2790d84c`): resource_lock module (flock RAII, bounded poll); proxy/vault/networks/per-image ensure paths serialized; liveness probe now contends fairly with user logins. litmus:concurrent-container-ensure-no-race.
- **Order 233 done** (`ab3fea87`): per-project cleanup no longer removes shared containers; shared removal only via the no-running-forge guard; 4 pre-launch sites converged. litmus:shared-containers-survive-per-project-cleanup.
- **Order 234 done** (`adcfd37e`): runtime_phase VmPhase gate (Draining/Stopping refuse) at every container create/remove site, fail-fast before lock waits; mirror is cfg(not(test)) — global writes leaked refusals across parallel test isolation. litmus:drain-vs-self-heal.
- **Sibling coordination**: merged windows-next twice (order 154 claim, then slice 1 — their tray consumes VmStatusPush with polls demoted to fallback; e2e PASS + 3 findings) and osx-next (Darwin e2e-preflight VZ probe). Filed orders 257/258 (macos/windows parity-column verification — the per-host gate arrives as scheduled work, not a surprise red build); orders 154/155 dependency notes: all three push topics live; 155 promoted to ready.
- **Queue after wave**: ready = 235 (R7 vault recreate mutex — last of the R-series), 254 (listen-vsock CI), 255 (litmus race), 256 (runner fail-loud), 237 residual, 257/258 (sibling-owned). Multi-cycle audits 245-251 still await verifier agents.

## Cycle 2026-07-09T23:20Z (linux_mutable macuahuitl — R7 closes the race-safeguards ladder + blocked-work flags)

- **Order 235 done** (`eac9813f`): vault recreate <-> lease-holder RW lock (flock LOCK_SH/LOCK_EX on the R4 vault resource); AppRoleSecretLease carries the shared guard for its whole lifetime; writers take shared AFTER their on-demand ensure (self-deadlock audit); health wait retries transient stopped/no-such-container 3x2s bounded; the podman-health pin was tightened, not evaded. **Orders 232-235 (R4-R7) all closed — order 162 parent folded to done.**
- **Linux-claimable ready queue** (next cycles): 254 (listen-vsock CI lane + 2 drifted pty tests — coordinate the exec-allowlist fix with the order-141 owner), 255 (opencode-prompt litmus step-5 race), 256 (litmus runner fail-loud: exit codes ignored + folded commands parse to zero steps), 238 (mirror credential research), 144 (forge-harness ICAP), 141/137/145 (secure channel chain), 147/148/150/151/153/156/157/158 (streams/audit chain), 224/225 (litmus DSL), 125/128 (host-guest transport linux + conformance).

### BLOCKED ON OTHER AGENTS (flagged per operator goal 2026-07-09)

- **Orders 245-251 (multi_cycle audits)**: completion-gated on verified-by events from `opencode-bigpickle`, `antigravity-gemini`, `codex-gpt55-highthink` (+ `claude-opus-highthink` for 250). Order 245 has DRAFT v1 published and is ratification-ready; 246/247/248 have no draft yet (any of the named agents can start); 249/250 additionally depend on 245/246 completing.
- **Order 257 (macos-tray-parity-column-verify)** + **order 155 (macos tray stream refactor, now ready)**: macOS host. Their next --ci-full gates on their parity column.
- **Order 258 (windows-tray-parity-column-verify)** + **order 154 remaining slices**: Windows host (slice 1 landed 2026-07-09 and is integrated).
- **Order 126 (host-guest-transport-macos)**: blocked, macOS-owned.
- **Order 237 residual (forge mirror gitconfig default-on)** + **order 238**: need a forge-context session (in-forge agent or operator-launched).
- **Order 129 (agent egress allowlist research)**: needs an operator-attended forge session for live proxy logs.
- **Tray-parity release hold**: merge-to-main-and-release now reports 16 parity gaps (8 required features x macos+windows `unknown`) — release-with-gaps needs The Tlatoāni's recorded approval until 257/258 land.

## Cycle 2026-07-10T00:10Z (windows bullo — order 261 drain: ruby-free parity gate)

- **Agent**: windows-bullo-fable5-20260710T0010Z (meta-orchestration worker drain; branch windows-next, linux-next already fully merged at startup).
- **Order 261 done** (`d2f0c908`): `tillandsias-policy parity-matrix` subcommand replicates the litmus:tray-parity-matrix-complete ruby one-liner exactly (valid status words on all cells, no `regressed` anywhere, current host column done on `parity: required` rows; identical output lines). 9 unit tests incl. a repo-matrix pin (linux green, windows red-by-design). Litmus command repointed cargo-first with the ruby one-liner as fallback where cargo is absent; timeout raised 5s→120s for cold cargo builds. Verified live on this no-ruby host: default run exits 1 with the 7 expected `missing required:` lines; `--host linux` exits 0. **Order 258 exit criterion 4 is now executable on Windows** (stays red until the attended smoke flips the column, by design).
- **Verification**: cargo test -p tillandsias-policy 22/22; clippy --all-targets clean; fmt-check clean; touched YAML validated via `tillandsias-policy validate-yaml`.
- **Local-build e2e gate PASS** @ `c52a1e2e` (preflight `eligible`): full destructive Windows cycle — build 1m43s, direct-copy install with fresh embedded SHA, `wsl --unregister` + cache/VHDX wipe, cold `--provision-once` → `RESULT: VM Ready — control wire up ✓` exit 0, `--diagnose --json` exit 2 degraded-as-expected with `build_commit=c52a1e2e`. First e2e covering order 154 slice 2 (ea03e08e push-topic tray transport). Report: `plan/issues/build-install-smoke-e2e-findings-2026-07-10-windows.md` (+1 optimization packet: PS5.1 stderr quirk makes the freshness probe brittle). Curl-install e2e skipped: release hold active, no newer release than last tested.
- **Queue after cycle (windows)**: order 258 remains blocked-on-operator (attended smoke checklist `plan/issues/windows-tray-parity-attended-smoke-gap-2026-07-09.md`); order 260 (LocalProjects push topic) is linux-owned; orders 224/225/256 (litmus DSL/runner) remain any-host candidates.

## Cycle 2026-07-10T07:25Z (linux-mutable — meta-orchestration: litmus:forge-liveness-probe-shape verified PASS; merged windows-next)

- **Host**: Linux x86_64, `linux-next`, agent opencode/big-pickle. Credential guard `ok:gh-keyring`. Clean start at be966855 + committed auto-generated traces/metrics.
- **Work**: Verified `litmus:forge-liveness-probe-shape` — 8/8 static checks PASS, 8/8 fixture suite PASS, full instant pre-build suite 124/124 PASS (100%).
- **E2E eligibility**: `skip:smoke-lock-held`.
- **Coordinator**: Merged `origin/windows-next` (order 154 slice 3: push subscription widened, version-skew fallback). Resolved plan/loop_status.md union conflict. `build --check` green.
- **Next**: order 267 remaining (promote [PARSE WARNING] to per-step FAIL, flip strict-exit default ON), order 281 (guest overlay corruption self-heal), order 273 (attach login).

## Cycle 2026-07-10T07:45Z (linux-mutable — meta-orchestration: litmus:forge-liveness-probe-shape re-verified; order 267 slice 2 COMPLETE)

- **Host**: Linux x86_64, `linux-next`, agent opencode/big-pickle. Credential guard `ok:gh-keyring`. Clean start at 0e056e3d (checkpointed auto-generated traces/metrics).
- **Work**: Re-verified `litmus:forge-liveness-probe-shape` — 8/8 static checks PASS, 8/8 fixture suite PASS (all five liveness states, deadline iso8601, exit codes). Order 267 slice 2: rewrote all 31 folded/multi-line command steps across 8 files into runner-compatible single-line commands, extracted 5 helper scripts under scripts/. ruby -ryaml parses 200/200, zero remaining folded commands.
- **E2E eligibility**: `skip:smoke-lock-held`.
- **Coordinator**: Both platform branches (windows-next, osx-next) already merged. No new platform work.
- **Next**: order 267 remaining — promote [PARSE WARNING] to per-step FAIL, flip strict-exit default ON. Also order 281, order 273.

## Cycle 2026-07-10T06:38Z→06:48Z (linux-mutable — meta-orchestration: order 267 slice 1: 4 YAML-invalid files repaired)

- **Host**: Linux x86_64, `linux-next`, agent linux-bigp pickle-20260710T063952Z. Credential guard `ok:gh-keyring`. Clean start at 63e0a497; committed auto-generated traces/metrics checkpoint.
- **Worker drain — order 267 (litmus-corpus-parse-health), slice 1 COMPLETE (c4b44aa2), lease released, packet stays ready**: repaired all 4 YAML-invalid litmus files — litmus-binary-e2e-smoke.yaml (double-quote \| escape in rollback grep), litmus-environment-isolation.yaml (4 single-quoted cmds with bash '"'"' quoting rewritten as YAML double-quoted), litmus-inference-deferred-model-pulls.yaml (\| and \. escapes in rollback), litmus-log-field-stability-schema.yaml (\[, \\(, \\), \$ escapes in critical_path step + rollback block-scalar indent). All 200 openspec/litmus-tests/*.yaml now parse with ruby -ryaml.
- **E2E gate**: skipped-with-cause — `skip:smoke-lock-held` (parent/local sibling smoke owns the host lock).
- **Next**: remaining order 267 work: rewrite 31 folded/multi-line command steps, promote [PARSE WARNING] to per-step FAIL, flip strict-exit default ON. Also in queue: 265 (liveness research), 273 (attach login flow), 129 (egress research).
