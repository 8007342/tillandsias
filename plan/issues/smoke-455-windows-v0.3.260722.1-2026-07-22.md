# Order-455 Windows smoke — v0.3.260722.1 (daily): FINDINGS, two P1 host-side defects found AND fixed; PASS record deferred to the next daily

- Date: 2026-07-22 (UTC 2026-07-22T21:30Z-22:03Z)
- Release under test: `v0.3.260722.1` (daily, the v0.4 stability-bundle candidate)
- Host: windows (windows-next @ 58b58322), operator (The Tlatoani) at the terminal
- Flow: full destructive purge (distro + cache + logs + state + Event Log
  source) -> pinned curl-install -> from-scratch provision, per
  /smoke-curl-install-and-test-e2e

## VERDICT: FINDINGS (deliberate non-PASS)

The smoke surfaced two P1 HOST-side defects in the published artifact; the
operator ordered the run terminated mid-reproduction. Both are root-caused
and FIXED on windows-next/linux-next (58b58322); the Windows PASS record
should be taken against the NEXT daily, which will carry the fixes. The
fixed build was e2e-proven locally the same hour (below).

### Finding 1 (P1): saved-file installer runs silently skip download+extract
`plan/issues/windows-installer-encoding-smart-quote-injection-2026-07-22.md`
BOM-less UTF-8 em-dashes parse as CP-1252 smart QUOTES under PS 5.1 — the
script parses into a different program. `irm | iex` unaffected. Smoke
proceeded via a BOM-corrected copy (workaround); repo fix = pure-ASCII
transliteration of all shipped .ps1 + whole-file litmus gate.

### Finding 2 (P1): rootfs download chokes at ~40 KB/s (operator-reported live)
The 66.9 MiB download ran 25+ minutes without completing. Root cause chain:
the tray's tokio runtime is drained by a 100ms SetTimer pump (b56a2064), and
unbuffered tokio::fs writes sent every ~16 KB chunk through a spawn_blocking
write whose completion wake waited for the next pump tick (~4,200 quantized
writes). Fix (58b58322): 4 MiB BufWriter in fetch.rs + a dedicated
multi-thread bg runtime for the whole provisioning/reset task tree (the
100ms-pumped LocalSet keeps only UI-adjacent tasks). Flush discipline keeps
the HTTP Range resume offset truthful on retry paths.

## Fixed-build e2e (same host, same hour — the A/B)

Local build 58b58322 (tray + embedded source-matched vsock guest
0.3.260721.1), FULL wipe including download cache:

| Phase | Published v0.3.260722.1 | Fixed 58b58322 |
|---|---|---|
| Download (66.9 MiB, SHA-verified) | 25+ min, unfinished (terminated) | **2.9 s (~23 MB/s)** |
| Full from-scratch provision -> VM ready | never reached | **72 s total** |

Post-provision state: wire phase=Ready, podman_ready=true,
`.import-complete` marker present, and the windows-260719-4 handshake skew
guard live: `--diagnose` reports `guest_version=0.3.260721` matching the
tray (cosmetic residual: the guest reports MAJOR.MINOR.YYMMDD without the
build component — noted, not filed as a packet).

## Also verified on the published artifact before termination

- `-Purge` full cleanup incl. Event Log source removal (elevated).
- Pinned install resolves + SHA-verifies the daily's zip; `--version`
  passes (via the BOM-corrected script); Event Log source registration on
  install (elevated path).
- windows-260722-1 (WSL-absent runtime setup) shipped in this cycle is NOT
  exercisable on this host (WSL present); live-absent verification still
  rides a WSL-less host smoke, per that packet's exit criterion 5.

## Recommendation for the v0.4 gate

Cut the next daily from linux-next (>= 58b58322), then re-run this smoke on
Windows — expected ~3 minutes end-to-end including install — and record the
PASS naming that build. macOS smoke unaffected by these findings (both
defects are Windows-host-specific).

## Addendum 2026-07-23: full-stack live session — BigPickle meta-orchestration IN a Windows forge

After the mirror first-seed race (windows-260722-7) and one re-attach, the
operator's forge came up on a populated checkout and BigPickle (in-forge
opencode) began a meta-orchestration cycle INSIDE the container — the
complete HOST -> WSL2 VM -> podman GUEST -> forge -> agent chain live on
Windows for the first time.

Performance validation (operator ask, measured live mid-run):
- Host wrapper: tray 15.1 MB RSS, ~5s CPU total across the whole session —
  effectively zero.
- Infra containers (proxy 3.72% + router 0.36% + git 1.08% CPU + vault
  idle-healthy): ~5% CPU, ~250 MB combined.
- Forge container: 269% CPU / 4.06 GB — the agent's own work.
Verdict: HOST/VM boundary overhead is slim-to-none; compute goes to the
agent, matching the Linux-host experience.

Login-state 3-state flip verified live post-reset (menu advanced past
GitHub Login after one login on a healthy vault); the earlier
login-succeeds-but-menu-stuck shape was the windows-260717-2 vault skew
(annotated on that packet), not the login flow.
