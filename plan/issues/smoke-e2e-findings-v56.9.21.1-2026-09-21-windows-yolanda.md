# Smoke: curl-install e2e — v56.9.21.1 — windows / yolanda — 2026-09-21

## CONSENT, quoted verbatim BEFORE §1 is run

This ordering is the point, and it is new. Until 1324-emdf the runbook put the
authorisation gate before §2; since 1286-4437 every installer performs the
destruction inside §1, so a consent quoted before §2 is quoted after the guest
is already gone. On this run the consent is recorded before anything is run.

From the operator, on this host's own channel, 2026-09-20:

> "If the wsl or any of its contents needs to be destructively recreated that
> is by design from our platform, and I approve of it. It'll likely be expected
> later that macuahuitl will ask for a destructive test, wiping and recreating
> the wsl distro and its contents from scratch."

The coordinator's relay is not the consent; the above is from the operator
directly, on this channel. It covers the unregister of the `tillandsias`
runtime distro, the clearing of host-side vault credentials, and reprovisioning
from scratch.

## REGIME — stated because 1334-d8bh makes it part of the measurement

A memory figure without its uptime and workload is not a measurement. This run
is a **fresh-boot arm**.

- host: yolanda-windows, Windows 11 26200.9457, AMD Ryzen AI 7 350, 16 logical
  CPUs, 15.16 GiB visible
- **uptime at start: 5.8 min** — first gate-sized run since the restart
- available at start: 9,042 MB (58.2%); nonpaged 863 MB; paged resident ~324 MB
- `.wslconfig`: `memory=8GB`, `processors=16`, `[experimental]
  autoMemoryReclaim=gradual`
- host changes since the last smoke: Recall disabled, DiagTrack disabled,
  AMDRyzenMasterDriverV32 disabled, `autoMemoryReclaim` added, `processors`
  corrected from 4 to 16
- poolmon tag dump at start: `poolsnap-smoke-START.log`; a closing dump follows,
  and the **delta** is the quantity of interest (esme's design, 1334-d8bh)
- sampler: detached `Start-Process`, 5 s interval, writing to a file —
  **verified writing before §1 began**, because a `Start-Job` died with its
  tool call on the v56.9.20.1 run and lost the peak entirely

## Verdicts — PASS

| section | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; `sha256: ok (206ec3a7b69bc58c108f65058e46b7525d0727f108a2ed3602a54d04d4fcdbb3)` matching SHA256SUMS-windows; elapsed 2m34s by my own clock (17:03:07Z → 17:05:41Z), not file metadata |
| §1b install-bits diagnose | **PASS** | `diagnose: version=56.9.21.1 commit=2f5f2a90a (--diagnose exit 2)` — exit 2 at install time is by design, the distro is not yet up; only exit 1 aborts |
| §2 reset (inside §1 since 1286-4437) | **PASS** | announced preserved-then-destroyed before destroying; distro unregistered and recreated; credentials cleared; `removed download cache`; `reset-state: provisioned and ready (exit 0)` |
| §3 provision | **PASS** | `RESULT: VM Ready — control wire up ✓`; distro `tillandsias` Running after |
| §3b diagnose --json, run LAST | **PASS** | `version 56.9.21.1`, `guest_version 56.9.21.1`, **exit 0** — host and guest agree |
| §4 forge lane | not applicable | Linux/Podman lane |

**smoke:yolanda:v56.9.21.1:PASS**

## Claims exercised

**EXERCISED — the credential CLEARING path, which the previous smoke could NOT
reach.** All three credentials were PRESENT beforehand, verified before §1 ran.
The reset logged `cleared host-side vault credentials: vault-shamir-share-v1,
vault-root-token-v1` with `tillandsias-vm-uuid` preserved, and all three read
PRESENT afterwards — the two vault ones being NEW, minted by the fresh guest's
bootstrap. On v56.9.19.2 they were already absent and the path went untested;
this run is the first real proof of it on a published artifact.

**EXERCISED — destroy-and-recreate from scratch.** A pre-existing `tillandsias`
distro was unregistered and a fresh one registered and provisioned to Ready.
The operator's idempotence-by-design claim holds on this lane: a full wipe
restored a working install with no manual step.

**EXERCISED — the exact tray version.** `tillandsias-tray 56.9.21.1 (2f5f2a90a)`,
matching the tag at `main`.

**NOT EXERCISED — my own 1323-5taw fix.** The SHIPPED v56.9.21.1 installer still
carries the OLD `--help` capability probe (0 guarded attempts, 1 `--help`
match), because the fix landed at `731a6f199` after this tag was cut. So this
run exercised the UNSOUND probe, and it passed only because the Windows tray's
allow-list is pinned to its dispatch by a unit test — the property 1323-5taw
called luck rather than design. The fix ships in the next tag.

**NOT LOOKED AT:** the plan binary, the front door, the operator skills and the
mirror lane are not reachable from a curl-install smoke.

## §4 — the memory measurement 1308-9ej7 asked for, captured this time

The v56.9.20.1 run lost both numbers: the sampler was a `Start-Job` that died
with its tool call, and wall time was taken from a log's CreationTime that
Windows file tunnelling had preserved from a previous run (743934 s). Both are
fixed here: a **detached** `Start-Process` sampler writing to a file, verified
writing BEFORE §1 began, and timings from my own clock.

- **27 samples, 0 errors** — the sampler outlived every tool call
- **MIN available 6,934 MB (44.7%)** at 17:05:55Z, during reprovisioning
- mean available 8,449 MB; nonpaged 849 → peak 905 → 896 MB
- **no reap**, under `memory=8GB` / `processors=16` / `autoMemoryReclaim=gradual`

For comparison, the four reaps happened at host free 11.5%–18.3%. This run's
floor was 44.7%, roughly 2.5× the margin at the worst reap.

## A result that complicates 1334-d8bh, reported because it does

The poolmon tag delta across this smoke is **+33.5 MB total**, almost entirely
`EtwB` (+32.0, boot-time tracing). **`File` did not move.**

So a curl-install and provision is NOT the workload that accumulates kernel
file objects. 1334-d8bh's claim that pool grows through a working session rests
on the reboot delta (`File` 605.7 → 5.6 MB) and is NOT demonstrated by this
run — if anything this run shows an install/provision is nearly free in pool
terms. The accumulation must come from the repeated compile and source-tree
churn of gates, which is what esme's agreed workload (`touch
crates/tillandsias-core/src/lib.rs` then `./build.sh --check`) actually
exercises. This is recorded as a limit on my own row rather than left out
because it is inconvenient: the smoke is a poor instrument for that claim.

## Recorded, not findings

- §1 still ends by launching the tray, leaving a process running and the distro
  Running. Unchanged and harmless: the reset already provisioned synchronously
  and exited with its status.
- **The 1295-b4i8 invariant check is weaker than I previously reported it.** The
  builder `ext4.vhdx` is byte-identical in size (156991750144) across this run,
  but its mtime DID advance (Sep 21 10:04) — the builder distro was Running
  throughout, so mtime moves on its own. The previous report cited "mtime
  unchanged" as evidence; that was luck, not a check. Size and the reset's own
  log naming the child cache path are the real evidence; mtime proves nothing
  either way while the distro is running.
