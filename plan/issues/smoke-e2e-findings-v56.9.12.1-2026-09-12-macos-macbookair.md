# Smoke E2E — `v56.9.12.1` (STABLE CANDIDATE), macOS lane, 2026-09-12

**PASS on §1-§3 plus the DMG half**, on `tlatoanis-macbook-air`, darwin 25.6.0,
Apple Silicon, 10 cores / 16 GiB, branch `osx-next`. Curl-install clean,
substrate destroyed with zero residue, cold `--provision` clean,
`--diagnose --json` green. No findings against this release.

**AND ONE THING THE PROMOTION SHOULD WEIGH DELIBERATELY:** on this host the
guest this release provisions **cannot be reached over the control wire**. That
is `1084-x8ya`, a p1 filed 2026-09-05 against an earlier release — not a
regression in `v56.9.12.1` — but it reproduces cleanly here on a guest
cold-provisioned from this very tag, and it is the difference between "the
macOS artifact installs" and "the macOS product works". Detail in §4.

Second destruction of this operator workstation was authorized by the operator
explicitly for this run, after the coordinator asked that it be re-requested
rather than carried over from the `v56.9.11.1` run.

## Regime

- host_id `tlatoanis-macbook-air`, macos, bare-metal, kernel 25.6.0, Apple Silicon
- installed from the PUBLISHED release, not a local `target/` build
- artifacts: `install-macos.sh`, `tillandsias-tray-56.9.12.1-macos-arm64.tar.gz`, `Tillandsias.dmg`
- release run 34668648875, all three jobs success 03:40:51Z

## Steps

| Step | Result | Evidence |
|---|---|---|
| §0 ledger row | FOUND, exact row; names this the STABLE CANDIDATE | `README.md:114` |
| §1 curl-install | PASS `install_exit=0` | `12-install-macos.log` |
| §1 sha256 (tarball) | PASS `a8adb826bf05750679b19ce2bfef0f5051de692ceb2107754a45227a4dab14f8` | same |
| §1 install path | PASS `/Applications`, no `~/Applications` fallback | same |
| §1 exact tag | PASS `tillandsias-tray 56.9.12.1 (git 7ed1327ec, built 2026-09-12T03:28:43Z)` | `12-version.txt` |
| §2 destruction | PASS, zero residue | `12-residue.txt` |
| §3 provision | PASS `provision_exit=0`, cold (full 528 MB Fedora re-download + convert) | `12-provision.log` |
| §3 freshness | PASS — `rootfs.img` postdates the destruction marker | `12-destruction-marker` |
| §3 diagnose | PASS `diagnose_exit=0`; `provisioned`, `rootfs_present`, `version == 56.9.12.1` | `12-diagnose.json` |
| DMG | PASS — see below | — |
| §4 forge lane | NOT APPLICABLE — Linux/Podman only | — |

`guest_binary_staged_matches_bundle: true`; `release_tag: fedora-44`;
`manifest_pin_aarch64_qcow2: 55c60a3b80d3`.

## DMG half — PASS, no finding

| Check | Result |
|---|---|
| sha256 vs `SHA256SUMS-macos` | MATCH `685ae2032a8c0746f4d302b4e1c9c0c493dee34897724c7806b96573bdf57bba` |
| Version inside the DMG | `tillandsias-tray 56.9.12.1 (git 7ed1327ec)` — identical to the tarball's |
| Signature | `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set` |
| Notarization | no stapled ticket |
| Gatekeeper `spctl` | rejected |

Identical to `v56.9.11.1` and exactly what `935-6fzk` describes and
`README.md:27-47` documents: quarantine is applied by the DOWNLOADING
application, so `curl` never trips the wall and a browser does. Not a defect.

**What was NOT re-done this run, stated rather than implied:** the hand-applied
`com.apple.quarantine` test and the `xattr -dr` remedy verification were done
on `v56.9.11.1` (see that tag's follow-up report) and were NOT repeated here.
The signing properties of the two releases' artifacts are identical on every
field checked above, so the mechanism carries over — but this run did not
re-measure it.

**METHOD TRAP, now in the runbook (`469331e0b`):** a DMG fetched with `curl`
carries no `com.apple.quarantine`, so it installs and launches perfectly and
proves nothing about the operator's browser path. Set the attribute by hand or
say the browser path was not covered.

## §4 — the guest is provisioned and unreachable (`1084-x8ya`)

Not a finding against this release. Recorded because a STABLE promotion should
know it, and because this is a **second clean reproduction, on the candidate
itself, on a guest cold-provisioned from it minutes earlier**.

```
elapsed=303s
metrics_status: "error:wire-read"
guest_version: null
[diagnose] metrics read failed: wait_phase_ready: VzRuntime::wait_phase_ready: timeout after 300s (phase never reached Ready)
```

Guest side, same boot, from the host-captured serial console:

```
[   36.267112] headless-ready.sh[1599]: [tillandsias-ready] vsock_listener=bound port=42420
[   36.269274] systemd[1]: Finished tillandsias-headless-ready.service - Tillandsias control-wire readiness assertion.
[   53.817356] tillandsias-headless[1584]: [tillandsias-vault] bootstrap complete
[   63.560914] tillandsias-headless[1584]: [liveness] re-ensured 2 container(s): ["tillandsias-vault", "tillandsias-proxy"]
[  300.498782] systemd[1]: tillandsias-headless-ready.service: Deactivated successfully.
```

**The guest asserted readiness at t=36.3 s and stayed up until the host tore it
down at t=300 s. The host therefore had 264 seconds of a fully-ready guest and
never observed Ready.**

### Load disclosure, and why it does not change the conclusion

A load probe at the start of this measurement counted **2 `cargo`/`rustc`
processes**; they were gone by the end and could not be identified
retrospectively. So this run is **not** certified idle, and it is not described
as such. It does not need to be: CPU contention can make a guest slow to become
ready, and this guest was ready at 36 seconds. Nothing about host load explains
264 seconds of failing to notice. (The `v56.9.11.1` cold boot WAS confounded by
a concurrent `build.sh --check` and was discarded for that reason; this is a
different and weaker caveat on a measurement whose conclusion does not rest on
timing precision.)

### Cross-reference

Consistent with this host's `v56.9.11.1` evidence appended to `1084-x8ya`
(guest ready at 4.66 s on a warm boot; host timed out at 300 s). Two releases,
warm and cold, same result: **the fault is downstream of guest readiness.**
`guest_binary_staged_matches_bundle: true` again, so again a guest provisioned
from a bundle-matching staged binary reproduces it.

**Not reproduced, again:** the `noise: input error` signature `1084-x8ya`
records. It is emitted host-side per poll and is not on the `--diagnose` path.
Symptom confirmed on a second release; mechanism still unconfirmed.

## Ledger claims

### EXERCISED
- **macOS artifact identity and integrity**: sha256 verified against
  `SHA256SUMS-macos` for both the tarball (by the installer) and the DMG (by
  hand); exact-tag asserted on `--version` AND on `--diagnose --json`'s
  `.version`, so this report is attributable to `v56.9.12.1` specifically.
- **Clean-room install + destroy + cold re-provision on macOS**, which is what
  this lane exists to prove.

### NOT APPLICABLE
- **`1122-xi2f` Windows tray placeholder / the Windows rebuild this cut was
  made for** — Windows lane; this release's reason for existing is not
  checkable here.
- **The forge lane (§4)** — Linux/Podman.

### NOT CHECKED
- **Guest liveness beyond readiness.** The guest asserts readiness and boots its
  containers, but no work was executed inside it from this host, because the
  control wire never came up. `guest_version` is `null`.
- **The DMG browser-quarantine path for THIS tag** — see the DMG section; done
  for `v56.9.11.1`, not repeated here.
- **Every gate- and plan-layer claim in the row** (the Windows placeholder
  check, the ledger-write arms, the fixture work). This lane exercised the
  release BINARY.

## Recommendation

This report supports promotion **on the macOS install-and-provision axis**, and
does not support a claim that the macOS product is usable end-to-end. If the
promotion's bar is "the published artifacts install, verify, destroy and
re-provision cleanly on three platforms", macOS meets it. If the bar includes
"a user can then use the thing", `1084-x8ya` stands between this release and
that on macOS, unchanged and unfixed since 2026-09-05. That is a judgement for
the coordinator and the operator, not for this lane; it is stated here so the
choice is made knowingly rather than by reading a green table.
