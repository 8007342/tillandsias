# macOS curl-install smoke — v56.9.22.1 — macneo — 2026-09-22

**PASS.** All three sections, on the published artifact, daily channel.

| | |
|---|---|
| host | Tlatoanis-MacBook-Neo (macneo), macOS 27.0, arm64 |
| tag | v56.9.22.1, tag commit `bab36b2af`, prerelease |
| release run | 35737651152 — completed/success, all three jobs, 32 assets |
| ledger row | README.md at `55449e508`, corrected clause at `3e6713b96` |
| consent | the operator's standing pre-authorisation for destructive container/VM reprovisioning, given in this session's opening broadcast. Not the coordinator's routing, which is a request to run a procedure and not consent to destroy a machine. |

    §1 install    exit 0, 294s   channel: pinned <daily url>
                                 sha256: ok (a41638216e6b…)
                                 installed: version=56.9.22.1 pin=55c60a3b80d3
    §2 destroy    exit 0, 426s   after a CORRECT refusal on the first attempt (exit 3)
    §3 diagnose   exit 0         provisioned=true, version=56.9.22.1,
                                 guest_binary_staged_matches_bundle=true,
                                 image_root_source=home

## The destruction is verified by a discriminator, not by presence

After a step that reprovisions, everything is present again, so presence proves
nothing. A marker file was dropped before the reset and every path tested
against it:

    REBUILT   rootfs.img   inode 13949625 -> 13949914   mtime Sep 22 08:37
    SURVIVED  nvram.bin    inode 12877026 unchanged     mtime Sep 20 22:26

The same test says REBUILT for one path and SURVIVED for another, so it
discriminates. `nvram.bin` is the built-in control: it predates even the install.

## Findings

**1. The reset guard is correct and has no non-interactive way out — filed as 1360-jjyx.**
First attempt: exit 3 in 0 seconds, refusing before any announcement or
destruction. Every property is right. But the installer launches the tray, so
§2 meets a live tray *by construction*, and both remedies the message offers are
menu-bar clicks. I proceeded with `pkill -x tillandsias-tray`, the exact-name
matcher `scripts/e2e-step2-macos.sh` already uses, and record here that I left
the paths the message names, because that is the evidence the row rests on.

**2. Signatures unexercised — routed to pirria, who is filing the manifest rows.**
`cosign` is ABSENT on this host and the installer made **no** verification
attempt (no cosign hits in the install log). Separately, `SHA256SUMS-macos`
carries exactly two entries — the tarball and the dmg — so `install-macos.sh`,
the script an operator pipes into bash, is not covered by the manifest the row
names as the anchor, though its cosign bundle is published. The anchored half
*is* real and ran: the installer verified the tarball against the manifest and
printed a digest byte-identical to the published entry.

**3. The sanctioned cold-state probe cannot ask on macOS.**
`scripts/probe-credential-cold-state.sh` → rc=2,
`credential-state:could-not-run:no-busctl (… this is NOT a cold verdict)`. It
reaches for busctl and the Secret Service, which no Mac has. It refuses
correctly and is unusable here, so the §2 evidence block the runbook asks for
carries no information on this lane — recorded rather than omitted. What
established the cold state instead, *with a control*: a nonexistent service
returns rc=44 and `security dump-keychain` reads 115 entries, so the reader
discriminates and is not blocked; all four credential items genuinely absent.

## Recorded as a PASS

The installer prints `channel: pinned <url>`. macneo's own v56.9.19.2 finding
was that it logged `channel: stable` while installing a pinned prerelease. Fixed.
Not a claim in this row; exercised anyway. A fleet that writes down only
failures cannot tell a fixed thing from an unexamined one.

## Known constraint, still true

`kernel_present=false` / `initrd_present=false` on a provisioned host, exactly as
the v56.9.19.2 row records: `provisioned` is defined as `rootfs_present` alone.

## §2b — the row's claims against this lane

The classification was **written before the row landed** and is preserved
unedited beside the result:
`~/tillandsias-smoke-evidence/v56.9.22.1/preclassification-macneo-2026-09-22.md`,
sha256 `7ce36f9c31e34b77cf2d8937c928c1a7aac7482e6abfc401ec4858c1e9789f9c`.

**My main prediction was wrong.** I expected the flat cloud project list
(1338-x5rq) to be what this lane mainly exercised. It is not reachable: the list
and `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS` live in `tillandsias-headless` and
`host-shell`, not in `tillandsias-macos-tray`, and reading the menu needs a GUI
action no unattended run can take.

- **EXERCISED** — 1324-ujvb (manifest half), 1352-vmbc + 1354-apns (preflight
  runs on macOS at all), 1302-7j8p (`ok:gate-step-regimes:94`), 1347-r9g8
  (PRE/POST pair with a stub-busctl control; killed-probe 11/11), and — unplanned
  — 1335-2nzf, because land83 printed `ok:land-adopts-valid-stamp` while
  relaying this host's own branch.
- **COULD NOT REACH** — 1339-r9xv (Windows), 1254-47xd (render node, headless),
  1338-x5rq (headless tray), 1350-ku7v (the corrected row says it publishes
  nothing in this release), and the signature half of 1324-ujvb.
- **DID NOT LOOK AT** — 1349-tdpg, 1354-dw8x, 1337-3tk6, 1321-2ixp, 1351-y98c,
  and the cloud-only lifecycle decision itself.

## 1327-r4zb — the 31-hour app watch, resolved

2051 samples at 60s. Three states, two transitions, and the **inode** is what
makes it readable:

    2026-09-21T05:17:20Z  PRESENT  inode 12826846
    2026-09-22T05:03:05Z  ABSENT   (10h20m)
    2026-09-22T15:23:23Z  PRESENT  inode 13949419  (this smoke)

The inode changed, so the bundle did not reappear — the old one was removed and
a new one written. A presence-only watcher would have shown identical
transitions and could not tell a reinstall from a restoration.

**XProtect checked and eliminated** as the cause of the 05:03:05Z removal: the
log window is silent, nothing names the bundle, and the nearest
`XProtectRemediator` run is 2026-09-22 00:00:10 — two hours *after* — with the
previous one twenty-two hours before. **Decoy warning for the next reader:**
there *is* XProtect activity in that log near the reinstall, the routine 00:00
and 00:02 scheduled scans. The timestamps rule them out; they are written here
so nobody re-derives it. What removed the bundle remains unattributed, and this
report does not supply a cause.

## Evidence

`target/smoke-e2e/` on macneo; durable copies with hashes in
`~/tillandsias-smoke-evidence/v56.9.22.1/`.
