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
