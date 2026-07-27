# macOS build findings — 2026-07-27 (terminal-attach@v2 destructive e2e)

- discovered_by: /build-install-and-smoke-test-e2e (macos)
- commit tested: e90634c4 (osx-next; terminal-attach@v2 merge incl. origin/linux-next 62d5b3ec)
- installed: ~/Applications/Tillandsias.app — `tillandsias-tray 0.1.0 (git e90634c4)` (freshness gate PASS)
- evidence: target/build-install-smoke-e2e/<RUN_ID>/ on the macOS builder host (local-only per skill convention)

## PASS

All reached gates green:

1. build (`scripts/build-macos-tray.sh`) exit 0; codesign verify OK; SHA256SUMS present.
2. destructive substrate wipe: 15G `~/Library/Application Support/tillandsias`
   + caches removed, verified gone.
3. cold re-provision (`--provision`): 528MB Fedora Cloud download → convert →
   resize → `rootfs.img` materialized, exit 0, zero error lines;
   `--diagnose --json` exit 0 (provisioned).
4. forge lane: n/a (linux-only lane).

NOT release acceptance: this run does not exercise the live vsock wire, PTY
attach, or menu UX. The mandatory next gate is the user-attended smoke +
in-forge cooperative verification —
plan/issues/bigpickle-macos-terminal-cooperative-debug-2026-07-27.md
(plan/index.yaml order 491, P0). The freshly provisioned substrate on this
host is staged for exactly that attended run (operator launches the tray →
OpenCode lane; BigPickle runs the nine probes from inside).
