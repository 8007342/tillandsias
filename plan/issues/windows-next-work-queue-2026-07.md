# windows-next work queue — 2026-07

One-line outcome ledger per `skills/advance-work-from-plan/SKILL.md` §6.3
(file created 2026-07-09; earlier windows cycle outcomes live in
`plan/loop_status.md` cycle entries).

- 2026-07-09T23:10Z  ea03e08e  order 154 slice 2: LoginState+CloudProjects push topics subscribed, login/cloud polls demoted to fallback-only; filed order 260 (LocalProjects push gap); bonus 2abfcb30 fixed 6 windows-only clippy warnings.
- 2026-07-09T23:35Z  (this commit)  order 258 partial->blocked-on-operator: unattended-verifiable parity subset done LIVE at 92675e8e (one-off probe cell -> done; 7 cells todo + attended checklist packet windows-tray-parity-attended-smoke-gap-2026-07-09.md); filed+promoted order 261 (parity litmus ruby-free check — gate cannot execute on Windows).
- 2026-07-10T00:40Z  d2f0c908  order 261 done: tillandsias-policy parity-matrix subcommand (exact ruby semantics, 9 unit tests, repo-matrix pin), litmus repointed cargo-first/ruby-fallback; verified live ruby-free on this host (windows red-by-design, linux column green). Unblocks order 258 exit criterion 4.
- 2026-07-10T01:05Z  (this commit)  local-build e2e PASS @ c52a1e2e (first e2e covering order 154 slice 2 push topics): build/install/destroy/cold-provision/diagnose all green, control wire up, build_commit fresh; filed smoke-finding/windows-freshness-probe-ps51-stderr-quirk. Report: build-install-smoke-e2e-findings-2026-07-10-windows.md.
- 2026-07-10T03:15Z  (this commit)  order 251 implementation-complete -> phase: verification (multi_cycle; completion gated on 3 verified-by agents): long_running_packets section in distributed-work.yaml (schema, verified-by protocol, additive update policy), meta-orchestration + advance-work skill recognition, plan/long-running.md sub-queue view.
