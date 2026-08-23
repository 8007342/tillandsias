# enhancement: on dual-locus hosts, cycle-preflight rebuilds one locus while the gate tests the other

- Filed: 2026-08-23 (UTC), by windows host **yolanda**, at merged
  `windows-next` head bc6c619d0. Class: enhancement/ (promoted to packet
  **851-cduu** the same cycle).
- Related: 704-zcgi / 783-jdeh (plan-binary-probe path lessons), 843-624y
  (compaction must delete only what it folded), 702-68zj (stale binary red
  gates), scripts/cycle-preflight.sh, scripts/plan-binary-probe.sh,
  scripts/with-wsl2-builder.sh.

## What happened (measured, this cycle)

First `./build.sh --check` after fast-forwarding windows-next 177 commits to
origin/linux-next went red: `compaction-coverage: 6 passed, 17 failed`, with
the fixture fragment vanishing mid-test. Diagnosis:

- On this Windows host, build.sh routes its checks through WSL
  (with-wsl2-builder.sh), where `CARGO_TARGET_DIR` points at the
  distro-native cache `/root/.cache/tillandsias-wsl2-target/tillandsias`.
- plan-binary-probe honours CARGO_TARGET_DIR first (783-jdeh — correctly),
  so the gate's ledger tests resolved
  `/root/.cache/tillandsias-wsl2-target/tillandsias/release/tillandsias-plan`.
- That binary was built 2026-08-16 — six days and one merge behind HEAD —
  because `scripts/cycle-preflight.sh` "rebuilt the instrument" in the
  NATIVE Windows lane (./target/release/tillandsias-plan.exe) only.
  "Rebuilt" was locus-relative and nobody said so.
- The stale binary predates 843-624y: its `compact` ignores `--help`,
  `--dry-run` and unknown arguments, runs unconditionally, and deletes every
  fragment it LOADED, folded or not. The red gate was the ratchet correctly
  catching a destructive stale instrument — but it presented as "HEAD is
  broken", which cost a diagnosis pass.

## The near-miss that makes this worth a packet

During diagnosis, that stale binary was invoked once as
`tillandsias-plan compact --help` with the repo as cwd (via /mnt/c). The
stale CLI treated it as a bare `compact`: it folded and DELETED all 16 live
fragments in plan/index.d/ and rewrote plan/index.yaml — the exact 843-624y
destroyer, live in a host cache, one mistyped invocation from the ledger.
Everything was tracked and unpushed, so `git restore --source=HEAD` recovered
byte-identically (verified clean status; zero loss, nothing pushed). A forge
or an unattended host in the same position would have committed or lost work.

## Fix directions (see packet 851-cduu for exit criteria)

1. cycle-preflight on a dual-locus host must rebuild the instrument in EVERY
   locus the gate executes in (native ./target AND the wsl2-target cache), or
   name in its verdict which locus it rebuilt.
2. resolve_plan_binary already probes by execution; give it (or the callers
   that gate on behaviour) a VINTAGE handshake so a stale binary refuses as
   `stale-plan-binary` instead of failing behaviour fixtures — 702-68zj
   already names conflating those as the failure class.
3. Hermetic fixture reproducing the stale-lane shape, so the distinction
   stays pinned.
