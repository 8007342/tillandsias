# Forge OpenCode crash: Bun v1.3.14 segfault (upstream runtime bug), arm64 guest

- **Date:** 2026-07-27
- **Class:** upstream crash (P2 — recurrence watch; not a Tillandsias defect)
- **Area:** forge container harness (OpenCode on Bun), macOS VZ guest (Linux arm64)
- **discovered_by:** operator attended session during order-491 verification;
  stack recovered from the host via Terminal.app scrollback
  (`osascript … history of tab`) after the on-screen text could not be
  copied (leftover mouse-reporting from the uncleanly-died TUI).

## Crash (verbatim, recovered from host scrollback)

```
Bun v1.3.14 (0d9b296a) Linux arm64
Linux Kernel v6.19.10 | glibc v2.43
Args: ".../npm/global/bin/opencode" "--user-agent=opencode/1.18.7" "--use-system-ca" "--"
Features: … spawn(623) … workers_spawned(2) …
Elapsed: 953991ms | User: 220820ms | Sys: 17067ms
RSS: 0.49GB | Peak: 1.47GB | Commit: 0.49GB | Faults: 3566 | Machine: 4.08GB

panic: Segmentation fault at address 0xD0
oh no: Bun has crashed. This indicates a bug in Bun, not your code.
https://bun.report/1.3.14/La10d9b296mwGugogDmw2wqEuyEmyuk9E2msk9E2o1k9E+q408Em7t/8Euvz/8E+1/wqE2vwjB_A2AgN
```

## Context

- OpenCode 1.18.7, ~16-minute in-forge agent session (BigPickle, order 491),
  623 subprocess spawns, mid "Build" task at 7m44s. Not OOM (RSS 0.49GB of
  4.08GB at crash; peak 1.47GB earlier).
- Near-null deref (0xD0) inside the Bun runtime — self-identified as a Bun
  bug. Plausibly load-correlated (heavy spawn churn on arm64).

## What this is NOT

Not a terminal-chain defect: the crash banner rendered intact through
attach-client → vsock → guest PTY, and the lane teardown ran cleanly
afterwards ("no active lane containers; cleaning project + shared stack").
Positive incidental evidence for terminal-attach@v2 under a hard TUI crash.

## Actions

1. Recurrence watch: if this repro rate is >occasional on arm64, pin the
   forge image's opencode/bun to a known-good pair (opencode pre-1.18.7 or
   bun pre-1.3.14) via the npm global install in the forge Containerfile.
2. Report upstream: the bun.report URL above is the redacted trace; file it
   against oven-sh/bun (arm64, spawn-heavy workload) when convenient.
3. In-forge agents: keep the push-early discipline — this crash killed the
   order-491 agent mid-run and its round-1 findings survived ONLY because
   they were already pushed.
