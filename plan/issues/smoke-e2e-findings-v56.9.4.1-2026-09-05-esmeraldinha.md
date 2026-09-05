# Smoke e2e findings — release v56.9.4.1 — 2026-09-05 — esmeraldinha (windows floor)

- lane: windows / `windows-next`
- host: ESMERALDINHA — Intel N100, 4c/4t, 15.8 GB RAM, Win11 Home 26200, WSL 2.7.12.0
- release under test: `v56.9.4.1` (daily, cut 2026-09-04)
- installed build: `tillandsias-tray 56.9.4.1 (377ba7794)` — matches `origin/main` head
- sibling heads: main 377ba7794 / linux-next bfd1e7a4f / windows-next 565a6524e / osx-next 5cae26c89
- **STATUS: LOCAL-ONLY, NOT PUSHED** — credential still `missing:no-credential-channel`;
  macuahuitl-fedora files these.

## PASS / FAIL

| # | Step | Result | Evidence |
|---|---|---|---|
| 0.2b | Ledger row for the tag readable on this lane | **FAIL** | row absent on `windows-next` and `main`, present on `linux-next`/`osx-next` — **1045-8yyw** |
| 1 | Curl-install published artifact | PASS | `install_exit=0`; sha256 ok `74eb743c…de08f` |
| 1 | Installed version == release tag | PASS | `tillandsias-tray 56.9.4.1 (377ba7794)`, exact-tag assertion |
| 1 | Tray resolves after install | PASS | `01-tray-path.txt` (not on PATH; found at install location, as 1004-vsh2 documents) |
| 2 | `wsl --terminate` + `--unregister tillandsias` | PASS | distro gone; `tillandsias-build` preserved (802-bajv) |
| 2 | Cache/state purge | PASS | `cache/ logs/ state/ wsl/` removed; `wsl-build/` preserved |
| 2 | Host vault credentials cleared (804-ckst) | PASS (runbook verifier FAIL again) | ground truth: both absent; runbook predicate reports both present |
| 2 | `tillandsias-vm-uuid` preserved | PASS | present after reset |
| 3 | §3 block runnable as written | **FAIL** | aborts mid-provision on the tray's stderr — **1043-c73v** |
| 3 | Evidence file truthful after an abort | **FAIL** | stale `provision_exit=0 elapsed_seconds=117` from the prior round survives — **1044-na6u** |
| 3 | Cold provision reaches Ready | PASS (timing unusable) | `provision_exit=0`; see timing note |
| 3 | Fresh rootfs, not a survivor | PASS | vhdx `00:42:20Z` postdates marker `00:39:15Z` |
| 3 | Wire Ready at provision exit (inline) | PASS | `phase=Ready podman_ready=True wire_version=2` |
| 3 | Final `--diagnose` (last step) | PASS | `diagnose_exit=0`, `version=56.9.4.1`, `distro_running=True`, `wire.reachable=True`, `guest_wiring=skipped-version-match` |
| 4 | Forge continuous-enhancement run | NOT APPLICABLE | §4 is still the Linux `tillandsias . --opencode` CLI; no such binary on Windows, and credential-blocked |
| 4b | First-launch egress assertion | NOT APPLICABLE | host-podman assertion; Windows runs podman inside the guest |

**Timing note — no clean cold-provision number this round.** The cold run was
interrupted by 1043-c73v partway through `Installing systemd + podman`, after the full
66 MB rootfs download. The completing run reported 26 s but inherited that
downloaded rootfs and partial install, so it is not a cold figure; a subsequent
warm re-provision took 13 s. The cold reference remains **117 s** from the
v56.9.2.1 round on this host. Do not quote the 26 s.

**`--diagnose` exited 0 here**, against exit 2 in the v56.9.2.1 round. The
difference is that this run was executed inline, so the wire was still up. That
is the block's own "Ready is not durable" note behaving exactly as documented,
and it confirms the guidance is right: assert the state AT provision exit, and do
not re-run `--status-once` later and read its exit 1 as a provision failure. I
hit that trap once by splitting the block across two invocations and did not file
it — the split was mine, not the product's.

## Ledger claims (README row, read from `origin/linux-next`)

**EXERCISED**
- Release assets publish and verify — SHA256SUMS-windows fetched, asset hash matched.
- `--version` carries the release tag — installed tray answers `56.9.4.1 (377ba7794)`, asserted equal.
- **1004-fue3** (the runbook's missing Windows §3, filed from my v56.9.2.1 round) — the block now
  exists and this lane ran it. It is not yet runnable as written here: 1043-c73v and 1044-na6u are defects in it.
  The claim is real but incompletely delivered on this platform.
- **1003-444f** (gate runs every workspace crate's tests) — exercised outside the smoke, by gate 8
  earlier tonight; it is what surfaced the absent `openssl` in `tillandsias-build`.

**NOT APPLICABLE (other platform / other lane)**
- AMD Vulkan placement (520, gfx1152) — no AMD device on this host.
- Linux tray `~/src` row retired (997-e4v2), guest binary staged off `~/src` (1019-ivia).
- Headless shutdown escalation (1019-ba6e / 1020-iicv), `podman rm` enclave health (1004-inkc),
  litmus `[FAIL]` lines (1018-5f5a), local-ci tray-contract serialisation (1021-hf9e) — Linux/CI lanes.
- macOS credential guard (988-7kxf), mac HOME in the guest CA preamble (1002-9xmb).

**CHECKED AFTER THE FACT — 805-r98w, the Windows NPU probe**
I named this as the round's biggest gap and then closed it, so it is recorded here rather than
left in the NOT-CHECKED list. `tillandsias-plan capability-matrix` shows the claim IS delivered,
with a Windows-specific reason string, but **not by this host**:

    host:yolanda    present-unusable: npu/NPU Compute Accelerator Device (wsl2-npu-not-exposed) os_status:OK
    host:macuahuitl present-unusable: npu/Intel NPU (engine-missing)
    host:yoga       present-unusable: npu/AMD XDNA NPU (engine-missing)

esmeraldinha carries no NPU row at all — an N100 has no NPU to see — so this lane cannot exercise
the claim even in principle. Yolanda's row is the one that does, and its `wsl2-npu-not-exposed`
reason is exactly what 805-r98w promises. **NOT APPLICABLE here, verified rather than assumed.**

This host's own rows are `ts:2026-08-23T04:38:31Z` and `ts:2026-08-23T04:29:22Z` — thirteen days
old, predating the release entirely. See the freshness finding below.

**NOT CHECKED — this lane could have looked and did not**
- **1004-xw3q** `tillandsias --ensure-enclave` restore path.
- **830-xsk2** guest vsock relay to host-native services.
- **964-r98h** devices report whether memory is their own; **965-hz3f** tier model warmed at forge start.
- **1001-q3zf** cycle metrics naming repeated/skippable steps — exercised earlier tonight as a metrics
  round, but not as part of this smoke.
- **803-49re** and **759-vceg** — again unwalked. §2 cleared the host vault credentials correctly,
  which is the precondition for the re-auth path, and again no GitHub login was reached because this
  host's credential is revoked. Second consecutive round with this gap; it needs a credentialed run.

## Freshness finding — the capability-row check is green on a thirteen-day-old row

`scripts/check-capability-row.sh` reports `ok` for a row that predates the
release under test. Both read at 2026-09-05T00:45:54Z:

    scripts/check-capability-row.sh  ->  ok:capability-row-reported:esmeraldinha
    tillandsias-plan capability-matrix:
      host:esmeraldinha  locus:in-guest      ...  ts:2026-08-23T04:38:31Z
      host:esmeraldinha  locus:windows-host  ...  ts:2026-08-23T04:29:22Z

This check ran in the morning preamble, answered `ok`, and was believed. The row
it blessed predates v56.9.4.1 by twelve days and predates two WSL rebuilds, an
OS-level `gh` upgrade and tonight's provisioning. The script's header says
850-bif2 exists because five of seven hosts were silent in the matrix, and it
does prompt a *joining* host to publish; what it does not do is notice that a
*published* row has gone stale, which is the state every long-lived host
converges to. `grep -nE 'stale|due:|days|age|ts'` over the script finds no
freshness comparison at all.

The counter-example is in this same repo: `check-daily-maintenance.sh` compares
against today and answers `due:stale:<date>`. The vocabulary exists; this check
does not use it. Next action: add a `due:stale:<ts>` arm keyed on the row's own
`ts` against a freshness window, in that grammar.

Fifth instance today of a check whose verdict is independent of the world, and
the fourth green one — after `ok:gh-credentials-store` on a dead token, the
804-ckst cmdkey verifier true in both directions, and a Monitor liveness arm of
mine that could never fire.

A PASS here means install, reset, provision and wire bring-up are sound on the
Windows floor for v56.9.4.1. It says nothing about the accelerator, enclave or
login claims above.
