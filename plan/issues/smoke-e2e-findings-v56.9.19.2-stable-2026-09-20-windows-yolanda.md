# Smoke: curl-install e2e — v56.9.19.2 STABLE channel — windows / yolanda — 2026-09-20

- run_start: `2026-09-20T09:17:03Z`
- evidence_dir: `target/smoke-e2e` (daily-run evidence archived under `_archived-20260920T021703Z/`)
- channel: **stable**. NO `TILLANDSIAS_VERSION` pin — the installer resolved
  `/releases/latest` itself, which is the thing this one-shot run exists to prove.
- host: yolanda-windows, Windows 11 26200.9457, Ryzen 7, 16 GiB. Branch `windows-next`.
- operator consent: the standing consent given in-session for the destructive
  step, which the operator framed as by-design and anticipated being asked for
  again. Both guest-vault credentials were present this time and were deleted.

## Verdicts

| § | verdict | evidence |
|---|---|---|
| §1 curl-install (stable) | **PASS** | `Channel: stable` → `Resolving latest release...` → `tillandsias-tray-56.9.19.2-windows-x64.zip`; `install_exit=0`; sha256 ok `3ac29ae269140504facd46ba772b76e892c9a87860e63161ebd5f393b4279d4d`; `tillandsias-tray 56.9.19.2 (77aa56588)` bounded-exact |
| §2 destructive reset | **PASS** | tray stopped (pid 18276), `terminate_exit=0`, `unregister_exit=0`, distro gone; BOTH guest-vault credentials present and deleted (`delete_exit=0` each), `tillandsias-vm-uuid` preserved; builder vhdx byte-identical |
| §3 pristine init | **PASS** | COLD `provision_exit=0` in 79s; `phase=Ready podman_ready=True` at t+85s IN THE SAME BLOCK; `diagnose_exit=0`; rootfs 02:19:08 postdates marker 02:17:36; `version`/`guest_version` both 56.9.19.2, `build_commit` 77aa56588, `ready_history=observed-ready` |

PASS entry: v56.9.19.2 installs from the STABLE channel, destroys, and
re-provisions cold. The promoted artifact is reachable from `/releases/latest`.

## What this establishes that the daily run did not

**THE STABLE RESOLUTION ITSELF.** The daily run pinned the tag with
`TILLANDSIAS_VERSION`; this one set nothing, and the installer printed
`Channel: stable` and `Resolving latest release...` before landing on
56.9.19.2. The sha256 is byte-identical to the pinned daily download
(`3ac29ae2…`), so the promotion moved the pointer without changing the artifact
— which is what a promotion is supposed to do and is now measured rather than
assumed.

**COLD READY DURABILITY, which the daily report left UNMEASURED.** Finding 3 of
`smoke-e2e-findings-v56.9.19.2-2026-09-20-windows-yolanda.md` recorded that I
had split §3 across invocations and so could not speak to the state at cold
provision exit. Run as one block here: cold provision exits 0 at 79s and
`--status-once` reads `Ready` / `podman_ready=true` at t+85s, six seconds after
exit. So on this host Ready DOES hold at cold provision exit when measured
without a gap. That closes the gap the earlier report left open, and it means
the earlier exit-1 reading was entirely an artifact of the split.

**A STRONGER §2 THAN THE DAILY RUN.** In the daily run both credentials were
already absent, so the deletion asserted nothing. Here the prior run's Vault
bootstrap had created them: both read present, both deleted, both verified
absent afterwards, with `tillandsias-vm-uuid` preserved. The clean-room
precondition was actually exercised this time.

## 1295-b4i8 — the row's own criterion, demonstrated

The runtime state under `%LOCALAPPDATA%\tillandsias` is, by enumeration:

```
cache/  logs/  state/  wsl/  tray-windows.lock   <- runtime, removed
wsl-build/                                       <- the BUILDER distro, PRESERVED
```

They are SIBLINGS under one parent, which is the whole defect: the obvious
"purge %LOCALAPPDATA%\tillandsias" takes `wsl-build` with them. Purging per
child and excluding `wsl-build` by hand, as 1295-b4i8's remedy prescribes:

- BUILDER BEFORE: 153712852992 bytes, mtime 2026-09-20T02:16:02
- BUILDER AFTER:  153712852992 bytes, mtime 2026-09-20T02:16:02

Byte-identical across a full §1+§2+§3. That is the row's exit criterion met by
the remedy, with one caveat stated plainly: the builder was **Running**
throughout this run, so this demonstrates the remedy works, NOT that the
unpatched runbook is safe when the builder is Stopped. The row's pre-fix result
still needs the Stopped case, and nothing here supersedes it.

## Recorded, not findings

- §1 again ends by launching the tray (pid 18276 running before §2) — fourth
  instance, second on Windows. Unchanged from the daily run and still the
  1286-4437 pre-fix result.
- Cold provision 79s here against 91s cold in the daily run on the same host,
  warm 7s. Same hardware, different cache state; not offered as a comparison.
- §3b and §4 are not this lane's, as before.
