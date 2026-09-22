# Smoke: curl-install e2e — v56.9.22.1 — windows / yolanda — 2026-09-22

## CONSENT, quoted verbatim BEFORE §1 is run

Since 1286-4437 every installer performs the destruction inside §1, so a
consent quoted before §2 is quoted after the guest is already gone (1324-emdf).
This run records it first.

From the operator, on this host's channel, 2026-09-21:

> "Yes I approve destructive install. Wipe wsl images and containers as needed.
> Our architecture is idempotent by design so it's intended to work from
> scratch identically from a fresh wipe, a clean install, or from a broken
> state. Full wipe is our preferred way to restore everything on demmand ;)"

And earlier, on the same channel:

> "If the wsl or any of its contents needs to be destructively recreated that
> is by design from our platform, and I approve of it. It'll likely be expected
> later that macuahuitl will ask for a destructive test, wiping and recreating
> the wsl distro and its contents from scratch."

The coordinator's go is not the consent; the above is the operator's own, on
this channel, and the second quote anticipates a repeated destructive test.

## CLAIMS PRE-CLASSIFIED BEFORE THE RUN

Recorded before starting, because **did-not-look is the only bucket nobody
writes down afterwards** (macuahuitl's caution). The ledger row is at trunk
`9a1c8d6e8`; claims are its own.

| claim | bucket, decided in advance |
|---|---|
| Windows installer reports the WSL guest shape, names the known-bad ratio, warns `autoMemoryReclaim` under `[wsl2]` is inert, never writes the user's file (1339-r9xv) | **TO EXERCISE** — the one claim only this lane can reach |
| `cosign` arrives verified or not at all; pin gates EXECUTION, sigstore gates TRUST, as two separate refusals; `could-not-run` rather than a signature failure for a binary that cannot execute (1324-ujvb) | **TO EXERCISE** — the installer verifies on this path |
| Cloud-only project lifecycle: forge host mount and mirror-to-host sync retired; tray cloud list flat with paging behind `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS` (591-x7ws, 1338-x5rq) | **CANNOT REACH** — needs a cloud session this lane does not establish |
| Linux tray puts the project list LAST for gnome-shell inline expansion | **CANNOT REACH** — Linux surface |
| Mirror startup sweep explains a stranded tag (1350-ku7v) | **CANNOT REACH** — mirror lane, not the install lane |
| Report-only census of self-flagged unverified premises (1349-tdpg) | **WILL NOT LOOK** — not reachable from a curl-install |

NOT IN THIS RELEASE, per the row itself, so absent must not be read as broken:
the five-category preflight verdict (1353-ryhq), and the mirror's sync-state
publisher, which is in the tree but not COPYed into the image and has no call
site — so a mirror built from this release publishes nothing. I relayed a
coordinator note that read as "shipped" earlier today and it was corrected;
the row now carries the correct form.

## REGIME

- host: yolanda-windows, Windows 11 26200.9457, Ryzen AI 7 350, 16 logical
  CPUs, 15.16 GiB
- `.wslconfig`: `memory=8GB`, `processors=16`, `[experimental]
  autoMemoryReclaim=gradual`
- host changes since the v56.9.21.1 smoke: none — this is the configuration
  that completed a 112-minute gate through the historical reap band
- channel: daily (prerelease), pinned with `TILLANDSIAS_VERSION=v56.9.22.1`
- **instrument rule for this run**: if any step asks for a Linux-shaped
  instrument, record `could-not-run` and name it. Do NOT substitute silently
  (macneo's busctl finding on macOS).

## Verdicts — PASS

| section | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; `sha256: ok (245757f7...)`; 2m16s by my own clock (15:24:05Z to 15:26:21Z) |
| §1b install-bits diagnose | **PASS** | `version=56.9.22.1 commit=bab36b2af (--diagnose exit 2)` — exit 2 at install time is by design |
| §2 reset (inside §1) | **PASS** | `cleared host-side vault credentials: vault-shamir-share-v1, vault-root-token-v1` with `tillandsias-vm-uuid` preserved; `removed download cache`; `RESULT: VM Ready` |
| §3 provision | **PASS** | distro `tillandsias` Running after; control wire up |
| §3b `--diagnose --json`, run LAST | **PASS** | `version 56.9.22.1`, `guest_version 56.9.22.1`, **exit 0** |

**smoke:yolanda:v56.9.22.1:PASS**

## The claims, against the pre-run classification

**EXERCISED — 1339-r9xv, the one claim only this lane can reach.** The shipped
installer printed the guest-shape report on a real host. Verified on the
PUBLISHED artifact before running: 3 `.wslconfig` references, **0** write paths
to the user's file. The reclaim arm correctly did NOT fire (this host has
`autoMemoryReclaim=gradual`).

**EXERCISED — the credential-clearing path**, for the second consecutive
release. All three credentials were PRESENT beforehand, so the reset had real
work; the two vault ones read PRESENT afterwards as NEW values from the fresh
guest's bootstrap, `tillandsias-vm-uuid` preserved throughout.

**PARTIALLY EXERCISED — 1324-ujvb.** The checksum path ran and passed
(`sha256: ok`). The pin-versus-sigstore split as **two separate refusals** was
not induced — nothing failed, so no refusal was observed. Recorded as partial
rather than claimed.

**CANNOT REACH / WILL NOT LOOK — unchanged from the pre-run classification**:
cloud project lifecycle (needs a cloud session), Linux tray ordering, mirror
startup sweep, the unverified-premises census.

## A DEFECT IN MY OWN SHIPPED CHANGE, found by running it

The warning fired **on this host's measured-good configuration**, and the
recommendation it printed is **byte-identical to the config already in force**:

```
Your WSL2 guest is shaped in a way that has killed builds on a host like this.
  16 vCPUs sharing 8 GiB is about 512 MB per vCPU.
  Measured: ~320 MB per vCPU killed four consecutive builds on a 16-core host.
Recommended .wslconfig for this host:
  [wsl2] memory=8GB processors=16
  [experimental] autoMemoryReclaim=gradual     <- ALREADY SET, byte-identical
```

This host at `memory=8GB`/`processors=16`/`autoMemoryReclaim=gradual`
completed a 112-minute `build.sh --check` through the historical reap band
without a reap. **512 MB per vCPU is the configuration I measured as WORKING**,
and my own installer calls it dangerous and offers the user their current state
as the fix.

Two causes, both mine:
1. **The 700 MB/vCPU threshold was never measured.** I chose it so that 320
   would trip it. It also trips 512, for which I hold positive evidence.
2. **The advice is not compared against the state in force.** A warning that
   recommends a change identical to the current configuration is noise, and
   teaches a user to ignore the next one.

**Why nothing caught it:** the fixture asserts the warning NAMES the ratio with
numbers; it never asserts WHICH configurations trigger it. Seven green arms, a
proven sabotage control, a full gate and a preflight — and none of them ran the
installer against a real host's config. They all read the source. That is
tonight's own lesson (`methodology/arm-blindness.yaml`) landing on the change
that shipped alongside it: **an arm that tests a representation of the subject
says nothing about its behaviour.**

The inverse of the night's other findings, and worth naming as such: those were
guards that COULD NOT REFUSE. This is a guard that REFUSES SOMETHING CORRECT.

## §4 — memory

Sampler detached, verified writing before §1, 24 samples, **0 errors**.
Min available **5,579 MB**, mean 6,188 MB. No approach to the reap band.

**Regime, stated because 1334-d8bh requires it:** uptime **22.5 hours** at
start, NOT a fresh-boot arm, host at 42.5% available when §1 began. Not
comparable to the v56.9.21.1 fresh-boot run without that caveat.

## Recorded, not findings

- 1295-b4i8 invariant holds: builder `ext4.vhdx` is 157427957760 bytes and the
  reset named the child cache path. Size and the log are the evidence; **mtime
  is not**, as the previous report wrongly implied — the builder distro runs
  throughout, so its mtime moves on its own.
