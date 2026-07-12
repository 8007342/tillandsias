# macOS local-build e2e findings — 2026-07-12

- host: macOS arm64 (Tlatoanis-MacBook-Air), branch `osx-next`
- commit tested: `374cb0b8` (osx-next = main `38d33cd8` + linux-next `49041576`
  + windows-next `374cb0b8`, integrated and pushed this cycle)
- installed version: `tillandsias-tray 0.1.0 (git 374cb0b8, built
  2026-07-12T22:06:07Z)`, VERSION `0.3.260712.2`
- discovered_by: /build-install-and-smoke-test-e2e (macos)
- evidence: `target/build-install-smoke-e2e/20260712T220556Z/` (local host)
- context: operator-requested destructive from-scratch reprovision ahead of an
  attended interactive smoke session; autonomous forge work intentionally not
  launched afterward.

## Gate results — PASS (all reached gates)

| Gate | Result |
|---|---|
| 0 preflight (repo root, branch `osx-next`, arm64, build script present) | PASS |
| 1 build (`scripts/build-macos-tray.sh`: release tray + aarch64/x86_64 musl headless, ad-hoc codesign valid, tarball 26.38 MiB) | PASS |
| 1b install to `~/Applications` + freshness (embedded git SHA `374cb0b8` == HEAD) | PASS |
| 2 destroy substrate (2.4G VM dir + 32K cache removed, verified absent) | PASS |
| 3 cold provision (528 MB Fedora rootfs download → convert → resize → `{"status":"provisioned"}`, exit 0) | PASS |
| 3b `--diagnose --json` post-provision | PASS (exit 0, `provisioned: true`, rootfs 250G sparse, pin `55c60a3b80d3`) |
| 4 forge lane | n/a (linux-only lane) |

Tray launched via `open ~/Applications/Tillandsias.app` and confirmed alive
for the operator's attended m8 interactive smoke. Interaction-surface results
(menu UX, PTY attach, project enumeration, live vsock wire under load) are
the attended session's to report — this PASS covers
build + install + destroy + cold-reprovision + diagnose only and is NOT
release acceptance.

No new product defects observed in any reached gate; nothing to de-duplicate
against open `plan/issues/` packets from this run.

## Attended m8 smoke results (same substrate, operator session ~15:10–15:30)

- `--github-login`: PASS — full credentialed login succeeded (screen session
  completed and terminated cleanly).
- First OpenCode lane attach: **FAIL** — lane terminal received zero bytes,
  never recovered. Filed as
  `macos-opencode-first-attach-blank-lane-2026-07-12.md` (P1).
- Maintenance lane (2 min later): PASS — full stack came up (proxy, git
  mirror, forge container) and reached an interactive fish prompt, but was
  near-silent for ~8 minutes; macOS parity evidence appended to
  `windows-attach-silent-forge-base-build-2026-07-12.md`.
- brew direnv shim: **FAIL** — attestation verification requires a GitHub
  API token a pristine guest lacks (egress itself healthy). Filed as
  `brew-shim-attestation-requires-gh-token-2026-07-12.md` (P2).

## Attended smoke, phase 2 (~15:30–16:00): forge lane exercised end-to-end

- OpenCode lane retry: PASS — in-forge agent ("Big Pickle") ran a full
  meta-orchestration cycle; first-attach blank-lane packet updated (race
  confirmed first-attach-only).
- TUI resize never propagates (colors + mouse fine): filed
  `macos-opencode-pty-resize-not-propagated-2026-07-12.md` (P2).
- Forge push channel: agent had no credentials → applied a repo-local
  insteadOf rewrite (its own packets `forge-mirror-insteadof-missing…`,
  `mirror-pre-receive-openspec-yaml-reject…`) which ALSO poisoned host git
  (shared checkout — addendum appended to its packet; host quarantined the
  line). Mirror acked the push but never relayed to GitHub: filed
  `git-mirror-push-false-success-not-relayed-2026-07-12.md` (P1); stranded
  commits re-delivered from the host (`33da90ab` verified on GitHub).
- After closing OpenCode: ALL new lane launches die instantly while the
  original maintenance lane stays live: filed
  `macos-lane-launch-dead-after-opencode-close-2026-07-12.md` (P1).
- Windows P1 hardening audit ask: macOS unit templates grep clean
  (note appended to `headless-podman-events-watcher-rootless-wedge…`).

## Attended smoke, phase 3 (~16:00–16:30): tray relaunch + operator verdict

- Tray relaunch (dist/ bundle): recovers the lane wedge fully — GitHub
  Login PASS first try, project listing PASS, OpenCode lane launches.
  Fresh login WAS required after the VM restart (observation routed to
  `agent-login-flows-vault-2026-07-12.md` scope).
- Resize-not-propagated reproduced on the new session (already filed);
  terminals otherwise behaved correctly.
- In-forge meta-orchestration #2 failed fast on
  `missing:no-credential-channel` and correctly filed a blocker +
  local-only commit (`forge-credential-channel-missing-2026-07-12.md`,
  picked up and pushed by the host this cycle).
- Operator verdict: solid progress validating the macOS e2e architecture;
  git-mirror architecture revamp is due (promoted as order 315); brew
  stays for officially-brew-documented harnesses only (order 316).
