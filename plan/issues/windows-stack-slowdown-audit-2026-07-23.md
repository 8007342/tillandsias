# Windows stack slowdown audit — 12 adversarially-verified findings (fat-agent fleet, live measurements)

- Date: 2026-07-23; host: windows (operator report: "codex launches very
  slowly" on a fast network + decent host)
- Method: 4 fat auditors with live read-only guest measurement + 1
  adversarial verifier per finding (23 agents; every number re-derived).
  Full measurements in the workflow transcript; key numbers below.
- Session context: measured against the OPERATOR'S REAL codex launch
  (03:36:49-03:42:38 UTC — 349s click-to-prompt).

## Where the 349s codex launch actually went

| Segment | Cost | Cause |
|---|---|---|
| Teardown + one-shot churn | ~14s | serialized podman one-shots (8 vault exec cycles, old-lane removes) |
| Login container | 50s BLOCKING | re-pulls 136MB @openai/codex npm + runs the FULL harness ensure before the device code shows |
| Clone + container start | ~7s | healthy (100MB pack in 2.7s) |
| **Codex TUI silent stall** | **281s (80%)** | **ephemeral CODEX_HOME: every launch replays codex FIRST-RUN (statsig experiments + model-availability NUX; 90s+120s ab.chatgpt.com tunnels moving <6KB)** |

Egress exonerated: proxy RTTs 96-160ms, all chatgpt.com requests <1.1s.
The network was never the problem — state amnesia was.

## The multipliers

- **Squid ssl_bump rule order makes bumping unreachable → 0% HTTPS cache
  hit rate, ever** (846/846 requests TCP_TUNNEL, 0 certs minted, cache dir
  empty). Every artifact always comes from origin.
- **~1.09GB re-downloaded per lane launch** (claude 273MB dist TWICE
  within 7s — ephemeral launcher symlink defeats the persistent versions/
  cache + self-update on the --version probe; 60MB cargo tools; 136MB
  codex npm in the login one-shot).
- Same 1.44GB ollama tarball tunneled 4x in 20 minutes (5.76GB) — bump
  bug + immutable-URL artifacts not cached.

## Host-side (windows lane) — FIXED this commit

- **GetVaultHandover slept 8x1s on EVERY steady-state wire connection**
  (measured 8.1-8.2s per --status-once, x4 reproducible; the tray start
  paid it TWICE serially => ~17s warm tray-start->attach-clickable).
  Fixed: HANDOVER_DELIVERED flag — only the first request per headless
  process may poll; steady state answers instantly. Guest-side code,
  rides the next daily; hot-injectable if needed.
- Residual tray nicety (doc-only): Subscribe could carry an initial
  VmStatusPush to save the first poll roundtrip.
- Order-418 probe: attach clicks measured CHEAP (141-161ms warm) — the
  probe design is vindicated; but its 60s-timeout=>damaged=>destructive
  reimport rule can nuke a healthy distro during a transient WSL-service
  wedge. Refinement filed in the packet below (windows-260723-1).

## Packets filed (see plan/index.yaml)

- windows-260723-2 codex-lane-state-amnesia (CODEX_HOME persistence +
  login-container slimming) — the 281s + 50s
- windows-260723-3 harness-refresh-not-byte-cheap (short-circuit when
  current + kill the double claude download)
- windows-260723-4 proxy-cache-never-hits (ssl_bump order + artifact
  caching for immutable URLs)
- windows-260723-1 exec-probe-timeout-not-damage (418 refinement)
