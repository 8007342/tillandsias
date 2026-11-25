# Gate steps whose fixture can skip at exit 0 — 2026-11-25

Order 2343-3ch4. A static reading of each step's STEP_LUA or STEP_SCRIPT file, at the commit that adds this note:
in Lua, `T:skip`, `verdict.skip` or `verdict.emit("skip:…", 0)`; in shell, an `exit 0` within three lines after an
`echo` or `printf` of `skip` or `SKIP`. It is a candidate list. It misses a skip reached through a helper, and it does
not show that a given host reaches the branch.

`skip_exit` is the step's STEP_SKIP_EXIT. Since 2343-3ch4 the gate loop prints such a step as `skip:<file>:declared (…)`
when its last line at column 0 is the skip, whether or not the step declares one.

| step | file | sites | skip_exit |
|---|---|---|---|
| 035-1049-s35z-jq | scripts/test-jq-multiline-capture.sh | 1 | none |
| 045-1004-vsh2 | scripts/test-cmdkey-predicate-discriminates.sh | 1 | none |
| 077-1198-7q95 | scripts/test-expire-claims-reads-the-status-write.sh | 1 | none |
| 105-1073-dqtx | scripts/test-image-usability-check.sh | 4 | none |
| 140-1087-h2z9 | scripts/lua/check-cheatsheet-tiers.lua | 2 | none |
| 175-1087-h2z9 | scripts/lua/test-gate-fast-refusals.lua | 1 | none |
| 271-1437-3pj7 | scripts/test-session-tokens.sh | 1 | none |
| 272-1437-khnx | scripts/test-packet-tier-fields.sh | 1 | none |
| 273-1443-w79y | scripts/test-branch-discipline-verb.sh | 2 | none |
| 277-1446-664f | scripts/lua/test-discipline-derive.lua | 1 | none |
| 282-1458-8y85 | scripts/test-append-vs-origin-fold.sh | 1 | none |
| 285-1235-rfub | scripts/lua/test-native-lint-attested.lua | 1 | none |
| 286-1461-5rm6 | scripts/test-land-queue.sh | 3 | none |
| 288-1470-v67y | scripts/test-refusal-affordance-added.sh | 1 | none |
| 289-1473-scdq | scripts/test-rust-source-pin-added.sh | 1 | none |
| 290-1158-y3ad | scripts/test-lww-channel-consumers.sh | 1 | none |
| 313-1302-7j8p-fixture | scripts/test-gate-step-regimes.sh | 1 | none |
| 315-1176-fn2p | scripts/test-gate-memory-refusal.sh | 1 | 3 |
| 375-1201-hsf9 | scripts/test-a-claim-names-a-workstation.sh | 1 | none |
| 385-1211-q9bm | scripts/lua/test-long-running-view-refuses-at-completion.lua | 1 | none |
| 400-1231-cbie | scripts/lua/test-uninstall-tray-stop-is-macos-only.lua | 1 | none |
| 455-1587-qqzs | scripts/lua/test-awk-float-lc-numeric-signal.lua | 1 | none |
| 468-1631-6w8z | scripts/lua/test-rust-lints.lua | 1 | none |
| 475-831-ezea | scripts/check-carry-forward.sh | 2 | none |
| 478-984-i4k2 | scripts/lua/test-expert-capability-behaviour-skew.lua | 1 | none |
| 480-1395-n7qd | scripts/test-centicolon-extract.sh | 1 | none |
| 490-1395-88tp | scripts/test-centicolon-grade.sh | 1 | none |
| 500-1395-ue3i | scripts/test-centicolon-ratchet.sh | 1 | none |
| 520-1404-4x3r | scripts/lua/test-drain-queue-bare-refuses.lua | 1 | none |
| 560-1434-vm7g | scripts/test-windows-tray-clippy.sh | 1 | none |
| 570-1449-4qqu | scripts/lua/test-installer-reset-probe.lua | 2 | none |
| 575-1459-b5fh | scripts/lua/test-cheatsheet-index-byte-order.lua | 3 | none |
| 580-1257-jxu9 | scripts/lua/test-expert-accuracy-provenance.lua | 1 | none |
| 610-1443-uit6 | scripts/test-mirror-discipline.sh | 1 | none |
| 650-1266-dh2d | scripts/test-plan-fragments-lane-carries-status.sh | 1 | none |
| 720-1310-rec6 | scripts/lua/test-mirror-healthcheck-quiet.lua | 2 | none |
| 730-1512-3afc-live | scripts/lua/check-gate-step-prefix-across-refs.lua | 1 | none |
| 760-1384-bqhy | scripts/test-script-run-verb.sh | 1 | none |
| 790-1560-g5d9 | scripts/lua/test-check-installer-prompts.lua | 1 | none |
| 810-1565-qtuk | scripts/test-installer-provisions-once.sh | 1 | none |
| 820-1567-9fgi | scripts/test-wsl-builder-kill-reaches-guest.sh | 1 | none |
| 828-702-eusw | scripts/lua/check-version-bump-isolation.lua | 1 | none |
| 895-1765-q7rg | scripts/lua/test-gate-step-host-state-retry.lua | 1 | none |
| 902-1834-ujsf | scripts/lua/test-local-delegate-ladder.lua | 1 | none |
| 903-1812-bztj | scripts/lua/test-sccache-long-tmpdir.lua | 1 | none |
| 904-1814-x78v | scripts/test-tellme-routes-to-expert-serve.sh | 2 | none |
| 905-1833-ytbe | scripts/test-local-delegate.sh | 1 | none |
| 909-2257-ba7e | scripts/lua/check-approved-ux-strings.lua | 1 | none |
| 910-1924-dobj | scripts/lua/test-prune-darwin-stale-objects.lua | 1 | none |
| 912-2262-iyyu | scripts/lua/test-builder-installs-follow-their-pins.lua | 1 | none |
| 916-2262-bke7 | scripts/lua/test-release-runbook-tag-order.lua | 1 | none |
| 919-1966-ubsw | scripts/lua/test-gate-step-private-metrics-fallback.lua | 1 | none |
| 955-831-ezea | scripts/lua/check-archiver-ready-set.lua | 1 | none |
| 986-1577-g96z | scripts/lua/check-carried-obligations.lua | 1 | none |
