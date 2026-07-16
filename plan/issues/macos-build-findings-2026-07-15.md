# macOS build + smoke findings — 2026-07-15 (coordination-pass cycle)

- host: macOS arm64, branch `osx-next`, agent macos-Tlatoanis-MacBook-Air-fable5-20260715T2314Z
- commit tested: `adc488d8` (linux-next 1380a4e1 merged; order-363 MCP tunnel + hardened litmus runner included)
- installed: `~/Applications/Tillandsias.app` @ `tillandsias-tray 0.1.0 (git adc488d8)`
- gates (per /build-macos-tray SECTION_KIND=ok set, executed directly): codesign deep/strict OK · `--diagnose --json` schema OK (provisioned=true) · 3s-alive OK · clean SIGTERM OK
- darwin workspace gate after merge: `./build.sh --check` PASS; workspace tests PASS
  (171 headless incl. new pins); instant litmus 97% (137/141 — only the 4 known
  Darwin-shape fails) AFTER the two fixes below.

## FINDINGS (filed this cycle)

1. **Litmus runner podman ENV-FAIL preflight wedged darwin (FIXED, adc488d8)** —
   the 1380a4e1 hardening assumed host podman is the substrate; on macOS a
   machineless homebrew podman CLI is normal (podman is VM-internal), so the
   preflight blanket-ENV-FAILed 35 source-shape checks (96%→72%). Preflight is
   now Linux-hosts-only. Residual for the owner (appended context to the
   zombie-cascade evidence trail): the trigger greps the whole test FILE for
   'podman', matching shape tests whose commands never invoke podman — tighten
   to command-level detection.
2. **stress_concurrent_attach_detach is load-flaky on darwin** (52/100 failures
   under full-workspace parallel test load; 3/3 passes standalone and in a later
   full run). See optimization/stress-attach-detach-load-flaky-2026-07-15.md.
3. **Bare `git stash pop` popped a foreign 2026-07-01 stash** during gate
   forensics — conflict aborted the pop, stash preserved, boundary restored via
   reset to the clean startup state. Hazard + hygiene ask filed:
   optimization/shared-checkout-stale-stashes-2026-07-15.md.

## Order-342 fixture evidence (see packet event for the full record)

Dirty throwaway host repo (tracked modification + untracked marker),
hash-snapshotted; in-forge agent (isolated lane) clobbered/committed/
`git clean -fdx`/`rm`'d in ITS checkout (`/home/forge/src/fixture-342` with a
container-local `.git`), and the RO staging probe failed with kernel
"Read-only file system". Host after-run: **HOST-BYTES-IDENTICAL** (tracked
mod + untracked marker intact, .git HEAD/index hashes unchanged).
