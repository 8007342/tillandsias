# Smoke: curl-install e2e — v56.9.21.1 — DAILY channel — macOS / macneo — 2026-09-21

- run_start: `2026-09-21T05:09:32Z`
- evidence_dir: `target/smoke-e2e` (prior run archived under `_archived-20260921t050932z/`)
- host: macneo, macOS 27.0, arm64. Tag at main `2f5f2a90a`; README row read from
  `origin/linux-next` → 1.
- authorisation: `00-authorisation.md`, written **before §1**, since §1 is the
  destructive step on this lane (1286-4437).
- credential preflight: `ok:gh-keyring-push-verified-hook-refused`, no `blocked:`.

## VERDICT: PASS

`smoke:macneo:v56.9.21.1:PASS`

**This lane measures the RELEASE, not the fix.** The Linux parser defect that
superseded v56.9.20.1 never touched the macOS tray (no flag allow-list; dispatch
precedes the fall-through refusal).

## Claims

| claim | verdict | evidence |
|---|---|---|
| (1) `--version` = 56.9.21.1 from `/Applications` | **PASS** | `tillandsias-tray 56.9.21.1 (git 2f5f2a90a, …)`; sha matches the tag |
| (2) reset contract + announcement states OBSERVATION | **PASS** | below |
| (3) the `::` refusal text is gone | **PASS** | checked in the **shipped binary** |
| (4) `--diagnose` exit 2 not read as unknown flag | **PASS** | checked in the unprovisioned window |
| `litmus:macos-vz-orphan-diagnosis` | **COULD NOT RUN** | the fixture does not exist — see below |

### §-level
§1 `install_exit=0` (installer sha256 `926f424af643f30db…`); §2
`ok:e2e-step2-macos:destroyed` rc=0; §3 `PROVISION_RC=0`, `{"status":"provisioned"}`
from a wiped substrate; §3b `DIAG_EXIT=0`, `provisioned=true`.

### Claim (2), both halves

**The announcement states observation.** This host was a sharper test than the
v56.9.20.1 run: all three credentials were already absent, so eight destroyed
lines read `[ABSENT — nothing to do]` and the anchor line read

> `keychain: installation-uuid-v1 [ABSENT BEFORE THIS RESET — nothing to preserve; the next vault will not derive from it (803-49re). This reset neither caused nor repairs that.]`

The pre-F2 code would have printed a reassuring "WILL BE PRESERVED:
installation-uuid-v1" on exactly this host. Full block in `03-announcement.txt`.

**Re-created, not reused** — mtime against `00-run-start.txt`:

| file | verdict |
|---|---|
| `rootfs.img`, `rootfs.qcow2`, `console.log`, `cidata.iso`, `heartbeat.state`, `provision/` | NEW — written during this run |
| `nvram.bin` | pre-dates the run — **PRESERVED** |

`nvram.bin` is the built-in control: if the method were broken and all read NEW,
it would read NEW too. 102 `Downloading Fedora Cloud image` lines corroborate.

### Claim (3) — checked against the artifact, not my source
`strings` on `/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray`:
`not executable::` → **0 occurrences**; `not executable:` → **1**. My source
obviously carries the fix; that proves nothing about the release, which is why
this was asked of the shipped binary.

### Claim (4) — checked in the state that used to red it
Run in the unprovisioned window §2 opens: `DIAG_EXIT=2`, **zero** occurrences of
`unknown flag`, last line `Status: NOT PROVISIONED`. The landed
`cli_unknown_flags` test passes in that same state (2/2). Testing this while
provisioned would have passed for the wrong reason.

### `litmus:macos-vz-orphan-diagnosis` — COULD NOT RUN, and not a pass

Asked to report which of two outcomes I saw. **Neither: the fixture is not in
the tree.** `litmus:macos-vz-orphan-diagnosis` and the verdict string
`image-already-held-by-pid` are absent from **all three refs** — my HEAD,
`origin/linux-next` (`d7834f2d7`), and `origin/osx-next` (`8047a2d8c`, i.e.
including macbookair's re-gate, pulled and rechecked after it landed). No
`openspec/litmus-tests/*orphan*` file exists.

Presumably unpushed on macbookair's host. Recorded rather than silently omitted
because 1205-aipn is on trunk under the title *"a closure citing an orphan
fixture is protection nothing runs"*, and a smoke reporting a verdict for a
fixture that does not exist would be that defect wearing this report's clothes.
No tray was running at the time (checked), so had it existed, the
`unsupported:image-already-held-by-pid` branch would not have been the one taken.

## Findings

### G1 — the installed app vanished again, and this time the window is bounded
`/Applications/Tillandsias.app` was **absent at run_start**, having been
installed and verified **running** (pid 71034, from `/Applications`) by the
v56.9.20.1 smoke about four hours earlier. Second occurrence on this host; the
first had only an inferred starting state.

Checked: not in `~/.Trash`; no `.bak` or staging left in `/Applications`; the
only Tillandsias-adjacent log traffic in the window is `com.apple.cache_delete`
purgeable-space **queries** from a `tillandsias-*` process — a query, not a
removal. **Disk pressure REFUTED**: 305 GiB free, 30% used, and the 268 GB
`rootfs.img` is sparse (2.1 G actual). **No mechanism established**; recorded as
a bounded observation, not a theory. Evidence in `01b-app-vanished.txt`.

### G2 — F3 reproduces across releases
`~/Applications/Tillandsias.app` still holds **56.9.11.1** (git `df944af67`,
built 2026-09-12) after this install, as after the last. The installer writes
`/Applications` and never looks at `~/Applications`. Already on 1315-d4qd.

### G3 — `image_root_source` shipped
`--diagnose --json` now carries `image_root_source = home`. In the v56.9.20.1 run
the field was absent entirely, so a `rootfs_present` reading could not be
attributed to a root. That gap is closed in this cut.

## Exercised / could not reach / did not look at

**Exercised:** claims (1)–(4); announce-before-destroy; the reset's effect on VM
state, caches, host credentials and keychain; a pristine provision from nothing;
the two-location check.

**Could not reach:** `litmus:macos-vz-orphan-diagnosis` (fixture absent from all
refs — see above). The plan binary check, the front door, the operator skills and
the mirror-server half are not reachable from this lane.

**Did not look at:** the guest's internal state after provisioning (no boot
beyond the provision's own status); Vault re-initialisation and the
keychain↔volume resync, which needs a boot — note the vault credentials were
absent at start and remain absent, so nothing re-derived them in this run; the
forge lane.
