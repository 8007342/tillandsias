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

## Attended confirmation (operator, 2026-07-27, post-provision first launch)

Operator launched the OpenCode lane from the fresh tray (e90634c4 build):
rendering correct at first frame AND live window resize reflows the TUI —
terminal-attach@v2 probes 2 (geometry) and 3 (live SIGWINCH resize)
confirmed attended on the outside. In-forge verification (order 491)
running: BigPickle claimed the DEBUG_PROMPT and is executing the nine
probes from inside the forge.

## Attended confirmation #2 (operator, 2026-07-27, mid-session)

While order-491 in-forge probes run, the operator additionally confirmed on
the OpenCode lane:
- resize STRESS cases all reflow live: restore, maximize, snap-to-side
  (rapid/large SIGWINCH bursts through attach-client → session socket →
  PtyResize — not just gentle drags);
- two-finger scroll pages Terminal.app's OWN scrollback through previous
  OpenCode output (probe 5's enabling condition gone: scroll no longer
  synthesizes arrow-key input — no `^[[A`/`^[[B` bleed observed);
- mouse-click fidelity: clicking the X on OpenCode's providers panel closed
  the panel correctly (mouse-reporting DECSET modes + click coordinates
  survive the raw conduit both ways).
