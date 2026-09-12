# Smoke E2E follow-up — `v56.9.11.1` macOS: the DMG path and a `--with-metrics` boot

Follow-up to `plan/issues/smoke-e2e-findings-v56.9.11.1-2026-09-12.md` (landed
`8b9ac62ed`), closing the two gaps that report listed under NOT CHECKED. Run at
the coordinator's direction on `tlatoanis-macbook-air`, darwin 25.6.0, Apple
Silicon, 10 cores / 16 GiB.

Two results, and they are of different kinds:

- **DMG install path: PASS, no finding.** It behaves exactly as documented.
- **`--with-metrics` boot: the guest reaches readiness in 4.66 s and the host
  still times out at 300 s.** This is a second-regime reproduction of
  **`1084-x8ya`**, and it moves that packet's fault line. Filed as an `events:`
  note on `1084-x8ya` rather than as a new packet.

---

## 1 — DMG install path: PASS, no finding

| Check | Result |
|---|---|
| SHA256 vs published `SHA256SUMS-macos` | MATCH `fb8fc64bbdf71254ddb50a8ae29e355f9da584288202f8a11c871aff5019ad52` |
| Layout | standard drag-to-`/Applications` (`Applications` symlink + `Tillandsias.app`) |
| Version of the app INSIDE the DMG | `tillandsias-tray 56.9.11.1 (git f1f7c01bc, built 2026-09-11T22:16:43Z)` — byte-identical claim to the tarball's |
| Signature | `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set` |
| Notarization | **no ticket** — `stapler validate`: "does not have a ticket stapled to it" |
| Gatekeeper `spctl -a -vv` | **rejected** — for the DMG app AND the installed tarball app alike |
| Quarantined copy (simulated Safari download) | rejected, as documented |
| README remedy `xattr -dr com.apple.quarantine` | **works** |
| `codesign --verify --deep --strict` AFTER the remedy | **still valid** — stripping the xattr does not disturb the signature |

**This is not a finding, and the reason is already on the ledger.** Order
`935-6fzk` (2026-08-29) established that `com.apple.quarantine` is applied by
the *downloading application*, not the OS — so `curl`/`tar` never tag, browsers
do. `README.md:27-47` already leads with the curl installer, warns against the
`.dmg` explicitly, and publishes the remedy. Everything measured above confirms
that model **on the actually published v56.9.11.1 artifact**, which is the part
that had not been done. The DMG is the known-friction channel, shipping
knowingly, documented accurately.

### METHOD TRAP for the next runner — a DMG smoke can produce a false all-clear

**A DMG fetched with `curl` carries no `com.apple.quarantine` attribute, so it
installs and launches perfectly — and proves nothing about the operator's
path.** The whole Gatekeeper question only exists for browser downloads. This
run had to set the attribute BY HAND to test the real thing:

```bash
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;$(uuidgen)" /path/to/Tillandsias.app
spctl -a -vv /path/to/Tillandsias.app     # expect: rejected
```

A run that downloads the DMG with `curl`, installs it, sees it launch, and
reports "DMG path PASS" has tested the one variant of that path that was never
in question. Do the hand-tag, or state plainly that the browser path was not
covered.

---

## 2 — `--with-metrics`: a second regime for `1084-x8ya`

### What was measured

Three boots of the **published** `v56.9.11.1` tray against the guest this smoke
cold-provisioned earlier today.

| # | Condition | Guest-side | Host-side |
|---|---|---|---|
| 1 | cold, first boot after provision | containers `healthy` at **t=280.9 s** | `wait_phase_ready` timeout at 300 s, `metrics_status: error:wire-read` |
| 2 | `--exec-guest`, warm | readiness assertion **Finished at t=4.42 s**, vsock listener bound port 42420 | hung indefinitely; killed at ~8 min |
| 3 | warm, **verified-idle host** | readiness **Finished t=4.66 s**; vault bootstrap complete t=12.11 s; liveness re-ensured 2 containers t=16.01 s; guest still alive at t=135.9 s | `elapsed=302 s`, `wait_phase_ready: timeout after 300s (phase never reached Ready)`, `metrics_status: error:wire-read` |

### Boot 1 is CONFOUNDED and is not evidence — my own fault

A full `./build.sh --check` (cargo test) was running concurrently on the same
10 cores while the VM held an 8 vCPU / 8 GiB allocation (the tray logs this
allocation under order `919-jii2`). The 300 s expiry on boot 1 was measured
under CPU contention I created, so it cannot be reported as a product
measurement and is not used below. Recorded rather than deleted because a later
reader finding a 300 s timeout in this host's logs should know which runs were
loaded.

**Boot 3 is the clean one**: no cargo, no rustc, no tray process, confirmed by
process table before starting.

### What boot 3 establishes

**The guest asserts readiness in 4.66 seconds and the host that started it
still declares "phase never reached Ready" 300 seconds later.**

From the host-captured serial console, boot at 02:19:50Z:

```
[    4.611801] systemd[1]: Starting tillandsias-headless-ready.service - Tillandsias control-wire readiness assertion...
[    4.612721] tillandsias-headless[1113]: [tillandsias] vsock listener bound port=42420
[    4.657962] systemd[1]: Finished tillandsias-headless-ready.service - Tillandsias control-wire readiness assertion.
[   12.114401] tillandsias-headless[1113]: [tillandsias-vault] bootstrap complete
[   16.009225] tillandsias-headless[1113]: [liveness] re-ensured 2 container(s): ["tillandsias-vault", "tillandsias-proxy"]
```

The guest was still alive and logging at t=135.9 s. The host call that BOOTED
this VM timed out at 302 s.

So the fault is **not** that the guest fails to become ready, and **not** slow
boot, and — on boot 3 — **not** CPU starvation. It is that the host cannot
OBSERVE a readiness the guest has already asserted. That distinction is exactly
the one `1084-x8ya`'s criterion 2 was written to make, one layer further in:
`1055-e8ie` moved the fault downstream of provisioning; this moves it
downstream of guest readiness.

### A datapoint against the leading hypothesis, stated as a datapoint

`1084-x8ya`'s leading hypothesis — explicitly flagged unproven in the packet —
is version skew: `79e3ca876` made the control wire encrypted by default, and a
host speaking Noise to a guest that predates it presents as `noise: input
error`. The packet notes the running guest's binary is undecidable from the
host.

On this host that specific question has an answer, and it does not favour skew:

```
"guest_binary_bundle_sha256":          "4176b146e012da914929af9ba62f3ab5651eaa1950af72836b38543a33114574",
"guest_binary_staged_sha256":          "4176b146e012da914929af9ba62f3ab5651eaa1950af72836b38543a33114574",
"guest_binary_staged_matches_bundle":  true
```

This guest was **cold-provisioned today from this very release**, whose staged
guest binary matches its bundle — i.e. the provision that created it drew from
a staged binary that is not skewed from the host. The handshake still fails.

**Stated as a constraint, not a refutation.** This lane cannot read the hash of
the binary the guest is actually RUNNING — that is `1084-x8ya` criterion 1, and
it remains unmet here exactly as the packet says. What is established is
narrower and still useful: a guest provisioned from a bundle-matching staged
binary reproduces the failure, so any surviving skew explanation must say how
skew arises when staged and bundle agree at provision time.

### Not reproduced here: the `noise: input error` signature

`1084-x8ya` records `secure control wire handshake failed: noise: input error`
on every poll. **This run did not capture that string.** It is emitted
host-side per poll, and `--diagnose --with-metrics` prints only the final
timeout; the guest-side serial console contains no occurrence. So this report
confirms the packet's SYMPTOM (`wait_phase_ready` 300 s timeout, `--exec-guest`
hanging) on a second host, without confirming its stated MECHANISM. Whoever
takes the packet should capture host-side per-poll output deliberately — it is
not in the default `--diagnose` path.

### Not filed as a new packet

Same symptom, same platform, same `owned_files`, and `1084-x8ya` is
`pickup_role: macos`, p1, unclaimed as of this run. Per the smoke runbook's
de-duplication rule this is an `events:` note on `1084-x8ya`, not a new packet.

### What this host can and cannot contribute next

- **CAN**: capture host-side per-poll wire errors with deliberate logging; re-run
  the warm boot; read anything in the live guest that `--exec-guest` can reach
  when it is not hung.
- **CANNOT**: a true cold first-boot measurement. That needs another destroy +
  re-provision of an operator workstation, and the coordinator has ruled that
  out — the cold number belongs to a host that owns preserved evidence
  (macneo's two checksum-verified guest images) or to a dedicated smoke host.
- **CANNOT**: criterion 1 — identify the running guest's binary. Unmet here, as
  the packet predicts for every host.

---

## Effect on the v56.9.11.1 verdict

**None. The PASS stands on §1-§3 plus the DMG half.** The release installs,
verifies, destroys and re-provisions cleanly on macOS. What this follow-up adds
is that the guest it provisions cannot be reached over the control wire from
this host — a pre-existing p1 defect (`1084-x8ya`, filed 2026-09-05 against an
earlier release) reproduced in a second regime, not a regression introduced by
`v56.9.11.1`.
