# Cycle 2026-08-10T04:30Z→2026-08-11T14:00Z (macos — operator /loop overnight, hourly meta-orchestration)

Operator mandate: hourly loop until 7am local, standing credential-re-seed
authorization, Apple-Silicon experts research directive, stale-lease
takeover authority. Every iteration synced + merged origin/linux-next and
pushed through the integration gate; osx-next never drifted.

## CLOSED (13 packets / slices)

- **657-3mq5** aarch64-guest-cpu-inference-tuning — the Apple Silicon
  headline: guest exposes i8mm + full SME2 (M4-class, no SVE — the exact
  combo prebuilt linux-arm64 llama.cpp cannot use); native 65s in-guest
  build + Q4_0 online repack = **187 tok/s decode vs ollama's ~71 on the
  SAME hardware (~2.6x, engine gap 2.1x isolated)**, pp 1220 t/s; ollama
  pinned 0.32.6 (regression #13860 ruled out); recipe in the 393 decision
  doc, handed to 657-6s4a.
- **606-vaua** freshness-threshold-and-coverage-truth — canonical 30d
  threshold now owned by methodology; threshold-gated staleness; the
  GNU-only `date -d` bug meant NO stamp could ever go stale on macOS/BSD
  (fixed fleet-wide); fractional coverage 1.0% (10/1034) with delta;
  5-fixture self-test litmus.
- **626-r7kq** tray-sign-in-state (TAKEOVER of Windows' expired lease) —
  their shared-layer Unknown/"Checking your account…" implementation was
  stranded unrecorded; closed with the macOS cfg-test exhaustiveness fix
  (third instance of the cfg-macos-test-invisible-to-implementer class
  this session).
- **401** macos-inference-tier-verification — tier:cpu verdict, cpu-ollama
  measured, Modelfile expert built + answered via /api/create; local
  inference ALIVE on this host for the first time.
- **644-7w89** v0.4.260810.1 curl smoke 5/5 — no regressions vs .2; the
  421 fix confirmed shipped in the published installer same-day.
- **624-q4jj** unstable-channel validation 5/5 — order-455 macOS smoke
  for v0.4.260809.2 explicitly discharged.
- **492** PTY slave retention — Darwin probe PINNED (termios resets on
  last-slave-close; the retention was load-bearing); EOF→PtyClose wired;
  attach client re-raws; live-verified via 598-M6 load legs.
- **606-r42f**, **421**, **627-53gu** — 08-09 drain closures (stranded
  events repaired 08-11).
- **598-kibt** — M1/M2/M3/M4/M6 GREEN incl. the M3 envelope
  byte-identity via Config.Env; ONLY M5's runtime half remains
  (operator-gated: zero-repo GitHub account).
- **245** network-architecture-audit revision obligation — 7-agent
  fact-check, 23/23 stale claims corrected in place; three-agent
  re-verification (NA-01..06) is the remaining completion gate.
- **620-duta** macOS half of criterion 3 — import-surface litmus pins the
  tray to OS-shipped libraries only.

## FIXED FLEET-WIDE (found here, shipped to everyone)

- **628-yd8f**: `--capabilities` missing from is_cli_mode singleton-killed
  the live vsock server (also retro-explains the dead 08-03 image build).
- **635-kagg bring-up**: `podman exec -i` + null stdin hung conmon attach
  at six launcher sites — bring-up went from wedging-forever to 20s +
  fail-loud.
- **freshness date dialect** (in 606-vaua above).

## FILED

657 wave (5 Apple-Silicon experts packets; flagship 657-s6g8 Metal
sidecar: llama-server --api-key on the vmnet gateway behind the enclave
proxy, ~2x decode + 5-10x pp projected); 663-acdw (github-login guest
preflight wedge — blocks 349 and unattended credential re-seed; 6 bounded
diagnosis attempts recorded); 663-69kp (one-shot boot hang, nondeterministic,
paired success/hang datum + console-silent-while-disk-active signature);
627-cx24 (selector priority projection, linux); 635-bhkb (tray --version
never synced).

## CANNOT (recorded visibly)

606-um5s (no nix on this host); 646-qde5 (Windows GUI). Coordinator asks
648-dvzd: all three discharged (ask 1 done 5/5; ask 3 done and
cross-host-corroborated — the coordinator implemented criterion 2 within
hours; ask 2 CANNOT).

## Metrics at close

cycle-metrics: expert_accuracy 19/19 (groundtruth-rung1); experts/mcp/flow
sources absent on this host (no expert harness here yet); verdict at last
mid-cycle run: worktree-dirty (expected, close-out commit). Plan folds
clean (`tillandsias-plan check` green throughout; ledger-integrity gate
respected after one caught miss). ~30 pushes, all through the merge+gate
cadence; zero trunk breaks.
