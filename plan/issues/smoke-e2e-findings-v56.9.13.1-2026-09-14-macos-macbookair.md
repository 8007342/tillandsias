# Smoke e2e findings — v56.9.13.1 — 2026-09-14 — macos / tlatoanis-macbook-air

**PASS.** Release `v56.9.13.1` (daily/prerelease channel), macOS lane, Apple M5,
macOS 25.6.0. Curl-install clean, substrate destroyed and asserted gone,
provision from pristine clean, diagnose clean. NO PRODUCT FINDINGS FILED.

Run under standing operator consent for destructive work on this host, granted
2026-09-13 ("we embrace destructive resets; our platform is idempotent and
ephemeral by design"). The destruction was real, not a no-op: 2.3 GB of
`Application Support` plus a sparse `rootfs.img` were removed and their absence
asserted before re-provisioning, and the provision then downloaded the full
528 MB Fedora Cloud image from scratch.

## Steps

| step | result |
|---|---|
| §1 curl-install | `install_exit=0`; `/Applications` (no `~/Applications` fallback); `tillandsias-tray 56.9.13.1 (git 6b8342f3f, built 2026-09-14T02:11:13Z)` — exact tag match |
| §2 destructive reset | tray killed (0 processes); both state dirs removed; `[macos-residue]` empty |
| §3 provision | `provision_exit=0`; full Fedora image download + convert; `rootfs.img` postdates the destruction marker (fresh, not a survivor) |
| §3 diagnose | `diagnose_exit=0`; `provisioned=true`, `rootfs_present=true`, `version == 56.9.13.1` |
| §3b guest-container shutdown | **NOT ASSERTED — stated gap.** The substrate is a Virtualization.framework VM, so the podman stop-and-inspect loop runs inside the guest or not at all. This lane does not assert it today; recorded rather than reported clean. |
| §4 forge lane | **NOT APPLICABLE.** The `--opencode` forge lane is Linux/Podman. |

## Ledger claims

Row read from `origin/linux-next` (see Observation 1).

**EXERCISED**

- *"macOS: `clamp-ca-material.sh` was inert on BSD stat and now clamps
  (1135-z8gn)"* — **VERIFIED BY EXECUTING THE SHIPPED SOURCE.** The released
  commit's copy carries the portable `_mode_of` helper (8 occurrences; the
  `stat -c … || stat -f '%Lp'` line). Its own selftest, run from a checkout at
  the release commit on this BSD-userland host: **rc=0,
  `selftest:clamp-ca-material:6 cases PASS`**. Before the fix the same selftest
  gave rc=1 with five failures and raw `stat: illegal option -- c` on stderr,
  because BSD stat rejects `-c` and every clamp call returned 1 — a CA-material
  permission clamp that could not set a key to 600 or a directory to 700 on any
  Mac. This is the first run of that fix in a published artifact.

**NOT APPLICABLE** (another platform's or another lane's)

- Linux reset clears host-held Vault credentials / credential-cold clean room (900-z3kv)
- Windows stale-binary probe by vocabulary; yolanda's republished row (1172-dyvd)
- Windows zip does not yet carry `tillandsias-headless.exe` (1171-ccf2, known-unfixed in this cut)
- Silverblue akmods depsolve skew probe (1165-g6wx)
- meta-orchestration loop: token counter (1119-6wn6), stale-ready-row pass (1144-jfr5), competing-gate detector (1141-vf9w, 1150-q462), de-slop sweep (829-dkuc) — coordinator/Linux lane
- land-tool push retry after an auth blip (1164-cftu) — exercised by landing, not by this smoke

**NOT CHECKED** (this lane could be thought to cover it and does not)

- *"the accel probe carries `name_source` (1137-rgfm)"* — **not reachable from
  the released macOS artifacts.** The probe lives in the headless binary, which
  ships only as `aarch64/x86_64-unknown-linux-musl` guest builds; no darwin-host
  headless binary is published, and the macOS tray's `--diagnose --json` surface
  does not carry the field (keys enumerated; `name_source` absent). Checkable
  only from a source checkout, which is not what this lane tests.
- capability-row guard age/remedy behaviour (1154-8ywc, 1165-xkjh) — not
  exercised; this lane took no capability-row action.
- Browser enclave host-network default (1118-dwgx) — not exercised.
- The env-var/salvage/compaction/dead-env cluster (1146-z8ux, 1146-8j7i,
  1148-3439, 1156-eif4, 1157-ghmi, 1158-y3ad, 1166-99mk…1169-zw44) — ledger and
  Linux-side machinery; not reachable from a macOS install smoke.

## Observations (measured, not filed as defects)

1. **The release's README row is on `origin/linux-next` but not on
   `origin/main`, where the tag sits.** Checked whether this was normal before
   calling it anything: every previous release's row IS on main
   (v56.9.12.2, v56.9.12.1, v56.9.11.1 all `main=1`), and only v56.9.13.1 reads
   `main=0 linux-next=1`. So the append step ran and the row reaches main at the
   next trunk→main merge; this is the expected interval, not a miss. Recorded
   because a reader on the default branch during that window sees a README
   describing every release except the newest one they just installed. Not filed
   — the mechanism demonstrably works.

2. **The installer reports `channel: stable` while installing a prerelease.**
   Cosmetic and correct in effect: the smoke pins `TILLANDSIAS_RELEASE_BASE` to
   the exact daily, which is what the runbook prescribes, and the pin wins. The
   banner is describing the default channel rather than the resolved one. Noted
   in case it confuses an operator reading install output during a daily smoke.

3. **The installer launches the tray on completion.** Expected ("Provisioning
   runs in the background on first launch"), but it means §2 must kill it before
   destroying state, which this run did. Worth knowing for anyone scripting the
   lane.

## Not checked, and why it is stated

The §3b and §4 rows above are gaps in this lane, not passes. A report that
listed only what it exercised would read as though the run covered everything
the release claimed.
