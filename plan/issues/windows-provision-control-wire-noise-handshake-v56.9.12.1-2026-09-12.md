# v56.9.12.1 never reaches Ready on Windows: the control-wire Noise handshake fails deterministically on a cold provision

**Filed:** 2026-09-12 · **Kind:** bug · **Priority:** p1 (the Windows lane of a published release does not work)
**Capability tags:** release, windows, control-wire, provisioning
**Host:** ESMERALDINHA (Intel N100 / 16 GB, Windows 11 26200.9445, WSL 2.7.13.0)
**Tag under test:** v56.9.12.1 (`7ed1327ec`), installed from the published zip, SHA-256 verified by the installer

trace: plan/issues/smoke-e2e-findings-v56.9.12.1-2026-09-12.md (the run this came from)
       skills/smoke-curl-install-and-test-e2e/SKILL.md §3 Windows

## Claim

On a genuinely pristine Windows host, `tillandsias-tray.exe --provision-once`
provisions the guest successfully and then **never completes the control-wire
handshake**. The VM boots; the secure channel does not come up.

```
hvsocket open: secure handshake failed: noise: input error
```

`ready_history: "never-observed-ready"`. The installed release is therefore
unusable on this lane.

## Measured

Two runs, each from a pristine base (distro unregistered, Credential Manager
guest-vault entries cleared, `tillandsias-vm-uuid` preserved):

| run | wall | exit | outcome |
|---|---|---|---|
| cold provision | 280 s | 1 | `noise: input error` |
| retry | 162 s | 1 | `noise: input error` |

Nine backoff attempts per run (delays 1, 2, 4, 8, 16, 30, 30, 30, 30 s), every
one failing with the identical error. Not intermittent.

From `--diagnose --json` (captured LAST, after every mutating step):

```
distro_registered : true
distro_running    : true
ready_history     : never-observed-ready
wire.reachable    : false
wire.error        : hvsocket open: secure handshake failed: noise: input error
guest_version     : null
wsl_platform      : ok
elevated          : true
guest_wiring      : { tray_version: 56.9.12.1,
                      guest_version_before: 56.9.12.1,
                      outcome: "skipped-version-match" }
```

`--status-once --json` independently reports
`control wire unreachable on vsock 42420: secure handshake failed: noise: input error`.

The failure is in the **Noise handshake**, not the transport: the hvsocket
opens, and the peer's first message fails to parse as a valid Noise input. That
points at a key/identity or protocol-version mismatch between tray and guest,
rather than at WSL networking.

## The lead I did not chase

`guest_wiring` reports `guest_version_before: 56.9.12.1` and **skipped** wiring
on a version match — on a guest provisioned seconds earlier from a wiped disk.
If the guest binary embedded in the Windows zip were a placeholder, guest
injection is a documented SILENT no-op (the 1059-ry6t warning text; 1122-xi2f /
1126-w8rq territory), and a guest that is not the one the tray expects is
exactly the shape that produces a Noise input error.

**This is a lead, not a diagnosis. I did not open the zip.** The obvious next
step for whoever picks this up is to confirm the x86_64 guest inside
`tillandsias-tray-56.9.12.1-windows-x64.zip` is a real binary and not a 0-byte
or stale asset, and to compare the guest's wire version against the tray's.

## Exit criteria

- "on a pristine Windows host, `--provision-once` on the tag under test exits 0 and `--status-once --json` reaches `phase: Ready` with `podman_ready: true`; pre-fix result: FAILS (exit 1 twice, never-observed-ready)"
- "`--diagnose --json` reports `wire.reachable: true` and a non-null `guest_version`; pre-fix result: FAILS (false, null)"
- "NEGATIVE CONTROL: a deliberately mismatched or truncated guest still produces a LOUD failure and is never reported as Ready — the fix must not be to relax the handshake"

## Not established

- Whether earlier tags fail the same way on this host. This host's last Windows
  smoke was v56.9.2.1 and its notes record a cold `--provision-once` reaching
  exit 0 in 117 s, so this is plausibly a REGRESSION between v56.9.2.1 and
  v56.9.12.1 — but I did not re-run an old tag to confirm, and that comparison
  is the single most useful next measurement.
- Whether other Windows hosts reproduce. yolanda-windows is the natural second
  data point.
