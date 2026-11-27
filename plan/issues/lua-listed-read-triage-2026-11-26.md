# 2417-jzhh: pcall(fs.read) triage, 2026-11-26

@trace order:2417-jzhh, order:2416-pscn

A checker that wraps each read of a LISTED file in `pcall(fs.read)` and drops the failure can say ok over files it never read. doris showed this on check-podman-sync-budgets (2416-pscn). This table classifies every `pcall(fs.read` site on trunk (180 sites, 143 files, at origin/linux-next when filed).

**Classes**

- **A**: leave as is. Either the failure is already reported (emit, refuse, blocked, could-not-run, or collected and printed), or it is a single read of an optional or probed file outside any listing loop. Single reads are outside this sweep.
- **B**: fix. A file came from a listing (walk, ls-files, a manifest list), and a failed read is dropped. Fix as 2416-pscn does: read every listed file once, and block with exit 2, naming each file that could not be read.
- **B-fixture**: the same shape in a `test-*` census arm, which walks the tree for a needle and skips a read failure. This is fixed last, in its own batch.

**Measured on darwin** (tillandsias-plan script run): `fs.read` of a non-UTF-8 file SUCCEEDS (lossy). A failure is therefore always a genuinely unreadable file (ENOENT, EACCES), never "binary". That is why check-ca-path-literals:55 is B despite its comment.

**Method**: a script found each site, its enclosing `for … do` loop, and whether the next six lines report the failure. Every in-loop site was then read by hand. The overrides are the eight rows whose reasons differ from the defaults.

Batch 1 is done: scripts/lua/test-listed-read-blocks-batch1.lua (gate step 962), red 8/8 first. check-centicolon-ratchet:71 and check-cheatsheet-source-anchors:72 moved to A while it was built (they fail safe).
The B-fixture batch is done: the ten census arms read through common.listed_read.reader (test-listed-read-reader.lua, gate step 945). Over the real tree with one chmod 000 probe in scripts/lua, all ten said ok on trunk and all ten block naming it with the fix.

## Batches (8–10 checkers per PR, each red first on a planted unreadable listed file)

- batch 1:
  - `scripts/lua/census-litmus-pipes.lua`
  - `scripts/lua/check-all-fragments-intact.lua`
  - `scripts/lua/check-backgrounded-jobs-redirect-stderr.lua`
  - `scripts/lua/check-ca-path-literals.lua`
  - `scripts/lua/check-cheatsheet-frontmatter.lua`
  - `scripts/lua/check-cheatsheet-refs.lua`
  - `scripts/lua/check-cheatsheet-source-anchors.lua`
  - `scripts/lua/check-enclave-ca-not-host-trusted.lua`
- batch 2:
  - `scripts/lua/check-enclave-expect-none-is-fixture-only.lua`
  - `scripts/lua/check-enclave-membership-documented.lua`
  - `scripts/lua/check-exec-argv-vector-workarounds.lua`
  - `scripts/lua/check-forge-image-no-secrets.lua`
  - `scripts/lua/check-forge-skill-browser-claims-match-image.lua`
  - `scripts/lua/check-fragment-keys-are-read.lua`
  - `scripts/lua/check-fragment-status-loss.lua`
  - `scripts/lua/check-framing-raw-decodes.lua`
  - `scripts/lua/check-grep-patterns-compile.lua`
- batch 3:
  - `scripts/lua/check-guest-unit-hardening.lua`
  - `scripts/lua/check-image-pins.lua`
  - `scripts/lua/check-jq-multiline-capture-strips-cr.lua`
  - `scripts/lua/check-launch-artifacts-untracked.lua`
  - `scripts/lua/check-litmus-expression-pinning-added.lua`
  - `scripts/lua/check-litmus-grep-escapes.lua`
  - `scripts/lua/check-litmus-steps-can-fail.lua`
  - `scripts/lua/check-nix-cache-installer-compatible.lua`
  - `scripts/lua/check-no-base64-script-injection.lua`
- batch 4:
  - `scripts/lua/check-no-host-browser-launch.lua`
  - `scripts/lua/check-no-spawn-in-if-not.lua`
  - `scripts/lua/check-plan-ledger-readers.lua`
  - `scripts/lua/local-delegate-ladder.lua`
  - `scripts/lua/check-portability-idioms.lua`
  - `scripts/lua/check-proxy-permissive-port-routing.lua`
  - `scripts/lua/check-requirement-ids.lua`
  - `scripts/lua/check-secure-wire-single-reader.lua`
  - `scripts/lua/check-smoke-agent-prompt-is-minimal.lua`
- batch 5:
  - `scripts/lua/check-source-slice-bounds.lua`
  - `scripts/lua/check-spec-registry-status.lua`
  - `scripts/lua/check-state-root-literals.lua`
  - `scripts/lua/check-terminology.lua`
  - `scripts/lua/check-unique-bin-names.lua`
  - `scripts/lua/check-windows-tray-clippy.lua`
  - `scripts/lua/check-wsl-exe-single-constructor.lua`
  - `scripts/lua/check-wt-reparse-workarounds-deleted.lua`
  - `scripts/lua/litmus-decide.lua`
- batch 6: the B-fixture rows.
- (check-podman-sync-budgets.lua is fixed by 2416-pscn, work/2416-pscn.)
- last: the guard. It refuses a new dropped `pcall(fs.read)` in a listing loop unless the line carries an `optional-read:` reason.

## Every site

| site | class | reason |
|---|---|---|
| `crates/tillandsias-plan/hooks/post-checkout.lua:23` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `crates/tillandsias-plan/hooks/post-commit.lua:19` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `crates/tillandsias-plan/hooks/post-merge.lua:19` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `crates/tillandsias-plan/hooks/pre-commit.lua:23` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `crates/tillandsias-plan/hooks/pre-push.lua:43` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/audit-guard-activation.lua:136` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/build-device-catalogue.lua:49` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/build-device-catalogue.lua:460` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/build-stack-ledger.lua:56` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/census-litmus-pipes.lua:59` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/census-litmus-reachability.lua:29` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/census-litmus-reachability.lua:53` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/centicolon-extract.lua:229` | A | an unreadable spec is collected as missing and reported |
| `scripts/lua/centicolon-grade-observed.lua:43` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/centicolon-grade-static.lua:112` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/centicolon-grade-static.lua:134` | A | an unreadable file is a parse error and reported |
| `scripts/lua/check-all-fragments-intact.lua:110` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-approved-ux-strings.lua:43` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-audio-studio-bundle.lua:76` | A | could_not_run on an unreadable file |
| `scripts/lua/check-backgrounded-jobs-redirect-stderr.lua:77` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-bare-mktemp.lua:40` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-bash-dialect.lua:87` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-ca-bind-migration.lua:40` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-ca-path-literals.lua:55` | B | its comment says binary files fail to read, but fs.read returns them (measured); a failure is a real unreadable file and is dropped |
| `scripts/lua/check-carried-obligations.lua:108` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-carried-obligations.lua:382` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-carried-obligations.lua:529` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-centicolon-ratchet.lua:44` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-centicolon-ratchet.lua:71` | A | fails safe: an unread file counts as not containing the needle, so the row is reported as vanished (a warning), never ok; advisory checker |
| `scripts/lua/check-centicolon-ratchet.lua:80` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-centicolon-ratchet.lua:94` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-cheatsheet-frontmatter.lua:95` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-cheatsheet-refs.lua:70` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-cheatsheet-refs.lua:90` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-cheatsheet-source-anchors.lua:72` | A | fails safe: an unread candidate means the order is reported declared nowhere (a violation), never ok |
| `scripts/lua/check-cheatsheet-source-anchors.lua:86` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-cheatsheet-source-anchors.lua:91` | A | an unreadable anchor file is reported as a violation |
| `scripts/lua/check-cheatsheet-sources.lua:46` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-checkout-writers.lua:56` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-claim-protocol-agrees.lua:47` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-embedded-elf-arch.lua:34` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-enclave-ca-not-host-trusted.lua:58` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-enclave-expect-none-is-fixture-only.lua:66` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-enclave-membership-documented.lua:50` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-enclave-membership-documented.lua:67` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-exec-argv-vector-workarounds.lua:46` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-fixture-prunes-checkout.lua:35` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-forge-advertised-toolchains.lua:30` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-forge-constraints-cheatsheet.lua:16` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-forge-constraints-cheatsheet.lua:22` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-forge-image-no-secrets.lua:44` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-forge-image-no-secrets.lua:77` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-forge-skill-browser-claims-match-image.lua:49` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-forge-skill-browser-claims-match-image.lua:96` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-fragment-keys-are-read.lua:122` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-fragment-status-loss.lua:95` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-fragment-ts-skew.lua:84` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-framing-raw-decodes.lua:31` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-framing-raw-decodes.lua:63` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-gate-step-not-also-inline.lua:23` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-grep-patterns-compile.lua:65` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-guest-unit-hardening.lua:30` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-image-pins.lua:118` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-image-pins.lua:171` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-imagegen-tier-sources-ungated.lua:38` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-installer-end-user-output.lua:60` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-installer-end-user-output.lua:113` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-installer-prompts.lua:47` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-installer-prompts.lua:91` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-installer-unstable-warning.lua:84` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-jq-multiline-capture-strips-cr.lua:50` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-launch-artifacts-untracked.lua:76` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-launch-images-table.lua:37` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-ledger-distillation.lua:66` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-litmus-bindings.lua:54` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-litmus-expression-pinning-added.lua:92` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-litmus-expression-pinning-added.lua:157` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-litmus-grep-escapes.lua:105` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-litmus-line-windows.lua:57` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-litmus-steps-can-fail.lua:92` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-macos-stock-binaries.lua:49` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-manifest-dir-env.lua:45` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-model-licence-register.lua:56` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-nix-cache-installer-compatible.lua:36` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-no-base64-script-injection.lua:60` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-no-end-user-brew-instruction.lua:41` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-no-host-browser-launch.lua:117` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-no-spawn-in-if-not.lua:43` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-oom-postmortem.lua:97` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-own-licence-declarations.lua:68` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-plan-ledger-readers.lua:62` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-podman-sync-budgets.lua:62` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-portability-idioms.lua:65` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-portability-idioms.lua:182` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-proxy-permissive-port-routing.lua:41` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-proxy-permissive-port-routing.lua:51` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-purge-clears-vault-credentials.lua:69` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-release-one-cloud-build.lua:37` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-release-one-cloud-build.lua:40` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-release-uploads-gated.lua:20` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-requirement-ids.lua:91` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-research-records.lua:47` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-runtime-secret-mounts.lua:53` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-runtime-secret-mounts.lua:54` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-rust-lints.lua:127` | A | probes each crates/ dir for an optional Cargo.toml; a dir without one is not a crate |
| `scripts/lua/check-secure-wire-single-reader.lua:35` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-shell-ratchet.lua:50` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-smoke-agent-prompt-is-minimal.lua:36` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-source-slice-bounds.lua:102` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-source-slice-bounds.lua:136` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-spec-registry-status.lua:35` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-spec-registry-status.lua:76` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-spec-registry-status.lua:97` | B | an unreadable registered spec is skipped and not counted, so the check passes over it |
| `scripts/lua/check-state-root-literals.lua:42` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-terminology.lua:56` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-terminology.lua:113` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-toolchain-pinned.lua:32` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-tray-refresh-no-polling.lua:8` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-tray-string-corpus-drift.lua:41` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-unique-bin-names.lua:35` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-vault-cli-gate-coverage.lua:29` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-windows-tray-clippy.lua:57` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-workspace-members-used.lua:32` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/check-worktree-add-cleanup.lua:36` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-wsl-exe-single-constructor.lua:24` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/check-wsl-exe-single-constructor.lua:37` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/check-wt-reparse-workarounds-deleted.lua:48` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/litmus-decide.lua:157` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/litmus-decide.lua:171` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/litmus-decide.lua:372` | A | probe: a path that does not read as a file is walked as a directory instead |
| `scripts/lua/litmus-decide.lua:389` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/litmus-run-one.lua:48` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/local-delegate-ladder.lua:99` | B | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/local-delegate.lua:258` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/merge-floor-min.lua:35` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/probe-openspec-change-settled.lua:16` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/source-agreements.lua:23` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-audio-studio-glitches.lua:373` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-awk-float-lc-numeric-signal.lua:48` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-browser-audio-generic-names.lua:66` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-build-sccache-regimes.lua:23` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-builder-installs-follow-their-pins.lua:56` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-chromium-framework-launch.lua:75` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-ci-full-refreshes-stale-plan-binary.lua:25` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-configure-codex.lua:93` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-copilot-vault-auth.lua:95` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-cycle-metrics-mix-label.lua:80` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-door-serial-lua-declaration.lua:196` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-door-serial-lua-declaration.lua:197` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-evidence-bundle-litmus-summary.lua:69` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-exec-transcript-capped-in-every-driver.lua:16` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-exit-pause-host-hold.lua:96` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-exit-pause-host-hold.lua:132` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-expert-accuracy-record-shape.lua:21` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-fleet-msg-mcp.lua:83` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-forge-copilot-harness.lua:120` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-gate-changed-parallel-fixtures.lua:25` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-gate-changed-parallel-fixtures.lua:104` | A | a missing log fails the arm (iso=false) |
| `scripts/lua/test-gate-diff-base-frozen.lua:159` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-git-mirror-seed-failure-surfaced.lua:91` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-harness-host-browser-parity.lua:50` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-host-audio-output-only.lua:93` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-launch-artifacts-untracked.lua:86` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-licence-register-restricted.lua:87` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-licence-register-restricted.lua:101` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-litmus-count-floors.lua:44` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-litmus-empty-spec-refused.lua:59` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-no-end-user-brew-instruction.lua:71` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-ruby-probe-runs.lua:62` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-script-run-ignores-foreign-project-root.lua:37` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-sigpipe-verdict-measured.lua:34` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-slowest-span-marker.lua:61` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-source-slice-bounds.lua:79` | B-fixture | a file from a listing whose read failure is dropped, so the check can pass over a file it never read |
| `scripts/lua/test-studio-node-pins.lua:31` | A | failure is reported (emit/refuse/blocked/could-not-run) |
| `scripts/lua/test-sync-image-cheatsheets-for-commit.lua:38` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-timing-record-carries-reproduced.lua:16` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-timing-supervisor-lost.lua:18` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-timing-supervisor-lost.lua:21` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `scripts/lua/test-uninstall-path-block.lua:23` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
| `skills/find-research/check-research-records.lua:47` | A | single read outside a listing loop: an optional or probed file; outside this sweep |
