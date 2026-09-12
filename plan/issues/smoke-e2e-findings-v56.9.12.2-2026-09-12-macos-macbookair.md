# Smoke E2E — `v56.9.12.2` (STABLE CANDIDATE), macOS lane, 2026-09-12

**PASS — COLD ARM, and the macOS guest-readiness gap is CLOSED on a published
CI artifact.** Host `tlatoanis-macbook-air`, darwin 25.6.0, Apple Silicon,
10 cores / 16 GiB, branch `osx-next`.

This is the arm the promotion waits on: the substrate was destroyed to zero
residue and cold-provisioned from nothing, using the tray CI built, not a
locally built one. Operator authorized this destruction for this run,
separately, as for every prior one.

## The headline

`1084-x8ya` — a guest that provisioned but was never reachable, p1 since
2026-09-05 — is closed here on the published artifact:

```
elapsed=38s   metrics_exit=0   metrics_status: ok   metrics: PRESENT
```

Guest side, same boot, from the host-captured serial console:

```
[   35.253567] systemd[1]: Starting tillandsias-headless-ready.service …
[   35.287067] headless-ready.sh[1596]: [tillandsias-ready] vsock_listener=bound port=42420
[   35.289363] systemd[1]: Finished tillandsias-headless-ready.service …
```

The guest asserted readiness at t=35.3 s and the host had its metrics at 38 s —
about three seconds later. The metrics block carries data read from INSIDE the
guest (`/var/cache/tillandsias` and `/opt/cheatsheets` on `vda2`, read
173553152 B / write 195870720 B, `sampled_at_unix` 1789221727). That payload
cannot exist unless the host completed the Noise handshake, so it is evidence
of the wire rather than an inference from an exit code.

**Against the same host's two prior releases**, same procedure, same substrate
handling:

| release | guest ready | host result |
|---|---|---|
| v56.9.11.1 (warm) | t=4.66 s | TIMED OUT at 300 s, `error:wire-read` |
| v56.9.12.1 (cold) | t=36.3 s | TIMED OUT at 300 s, `error:wire-read` |
| **v56.9.12.2 (cold, CI tray)** | **t=35.3 s** | **metrics at 38 s, `ok`** |

## Why this run is not a repeat of the earlier proof

The 2026-09-12 proof of the keying fix used a tray built from this checkout
through `scripts/build-macos-tray.sh`. That left exactly one regime uncovered:
the artifact the RELEASE WORKFLOW builds. This run covers it. The installed
tray self-reports `tillandsias-tray 56.9.12.2 (git 8a45bd522, built
2026-09-12T10:39:08Z)` — the tag's bump-merge, i.e. CI's binary, not the local
`2976154d8`. Verified independently from this host before the run that
`git merge-base --is-ancestor b77559aa7 v56.9.12.2` holds, so the published
tray carries the keying fix.

## Steps

| Step | Result | Evidence |
|---|---|---|
| §0 assets | all 7 macOS assets present on the tag | release API |
| §1 curl-install | PASS `install_exit=0` | `30-install.log` |
| §1 sha256 (tarball) | PASS `537619e45cc3fef39daacf0650c45bb674de0d02c8f50a976f784078af90f877` | same |
| §1 install path | PASS `/Applications`, no `~/Applications` fallback | same |
| §1 exact tag | PASS `tillandsias-tray 56.9.12.2 (git 8a45bd522)` | `30-version.txt` |
| §2 destruction | PASS, zero residue — **COLD ARM** | `30-residue.txt` |
| §3 provision | PASS `status: provisioned`, cold (full Fedora re-download) | `30-provision.log` |
| §3 freshness | PASS — `rootfs.img` postdates the destruction marker | `30-destruction-marker` |
| §3 diagnose | PASS `diagnose_exit=0`; `provisioned`, `rootfs_present`, `version` | `30-diagnose.json` |
| §3 readiness | **PASS** `metrics_status: ok`, metrics PRESENT, 38 s | `30-metrics.json` |
| DMG half | PASS — below | — |
| §4 forge lane | NOT APPLICABLE — Linux/Podman | — |

## DMG half — PASS, no finding

sha256 `ec25c57d2338ee82fa3537303e16845f31336a25775d92c270d01a77c3414e69` matches
`SHA256SUMS-macos`; the app inside reports `56.9.12.2 (git 8a45bd522)`,
identical to the tarball's; `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`,
no Team ID, no stapled ticket, `spctl` rejects. Unchanged from v56.9.11.1 and
v56.9.12.1, and exactly what `935-6fzk` describes and `README.md:27-47`
documents — the known-friction channel shipping knowingly, not a defect.

The hand-applied `com.apple.quarantine` test and the `xattr -dr` remedy check
were done on v56.9.11.1 and NOT repeated here; the signing properties are
identical on every field checked. Method trap, now in the runbook: a DMG
fetched with `curl` carries no quarantine flag, so a run that only curls it
tests the one variant that was never in question.

## A procedural miss in this run, recorded because it nearly mattered

The §3 provision was first run OUTSIDE a `bash -c` wrapper, so `${PIPESTATUS[0]}`
expanded empty under zsh and the capture printed `provision_exit=` — a VOID
status, which `test "" -eq 0` would have accepted as success. That is exactly
the defect order `1004-fue3` added the bash guard and the non-empty assertion
for, walked into by the agent running the runbook.

No wrong conclusion was drawn: the void capture was noticed, and the provision
was confirmed from ground truth instead (`{"status":"provisioned"}` in the
output, `rootfs.img` present and postdating the destruction marker), then the
remaining captures were re-run under `bash -c` with the guard, where
`diagnose_exit=0` was captured and asserted non-empty. Recorded because the
runbook's own warning proved correct about a real agent under real conditions,
and because a reader comparing timestamps in `target/smoke-e2e/` would
otherwise find one exit file empty and wonder.

## Ledger claims

### EXERCISED
- **The macOS guest-readiness closure (`1084-x8ya`)** on a CI-built artifact —
  the headline above.
- **Artifact identity and integrity**: sha256 verified for both tarball (by the
  installer) and DMG (by hand); exact tag asserted on `--version` AND on
  `--diagnose --json`'s `.version`.
- **Clean-room install + destroy + cold re-provision** on macOS.

### NOT APPLICABLE
- The forge lane (§4) — Linux/Podman.
- Windows-lane claims in the row.

### NOT CHECKED
- **`guest_version` is still `null`** in `--diagnose`. It is a separate
  population path; the metrics that arrived over the wire are the readiness
  evidence, and this field is not. Unchanged by this release.
- **The DMG browser-quarantine path for THIS tag** — see the DMG section.
- **The malformed-digest hardening (`ede57fcc0`)** is deliberately NOT in this
  tag and therefore untested here. It cannot be reached through
  `scripts/build-macos-tray.sh`, which emits a 64-hex digest; it rides the next
  daily.
- Gate- and plan-layer claims in the row: this lane exercised the BINARY.

## Recommendation

This run supports promotion on the macOS axis without the caveat the previous
two carried. The earlier reports said the artifacts install and provision but
that the product was not usable end to end, because the guest could not be
reached. That is no longer true: on the published v56.9.12.2 tray, a
cold-provisioned guest becomes reachable in under 40 seconds and answers a
metrics read from inside the VM.
