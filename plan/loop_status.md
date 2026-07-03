# Multi-Host Coordination Loop Status

LastExecutionTime: 2026-07-03T03:02Z

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
  (15724897); tag v0.3.260703.1 pushed; release.yml dispatched (run
  28635530855). [build result recorded on completion]
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
