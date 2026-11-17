# Smoke e2e findings — v56.11.17.2 — macOS — macbookair — 2026-11-17

- run_start: 2026-11-17T05:26:06Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-20261117t052606z/)
- forge_lane_outcome: NOT RUN — the substrate check stopped it: tillandsias-vault crash-loops in the fresh guest (2094-53uw)
- signature_verification: cosign:verified:1/1

**Verdict: FAIL v56.11.17.2 macos: a fresh guest's tillandsias-vault exits 1 on every boot, because the host Keychain delivers a stale Shamir share and unseal fails with HTTP 400 wrong key (2094-53uw).**

| step | result |
|---|---|
| §1 curl-install (install-macos.sh, pinned base) | install_exit=0, /Applications (no fallback) |
| `tillandsias-tray --version` | `tillandsias-tray 56.11.17.2 (git 6f0f31e4e, built 2026-11-17T05:22:42Z)` |
| §1s cosign (tar.gz) | cosign:verified:1/1 |
| §2 e2e-step2-macos.sh | ok:e2e-step2-macos:destroyed (7.8G App Support + 698M Caches), no residue |
| §3 `--provision` | exit 0 in 15 s, rootfs fresh (newer than the destruction marker) |
| §3 `--diagnose --json` | provisioned, rootfs_present, version == 56.11.17.2 all true |
| guest `tillandsias-headless --version` | Tillandsias v56.11.17.2 |
| guest provision marker | provision-start 05:26:59Z, guest-upgrade ok 05:28:18Z, **no completion line** |
| guest `podman ps -a` | `tillandsias-vault Exited (1)`: "unseal request returned HTTP 400: wrong key", "cipher: message authentication failed" |
| host Keychain vault-shamir-share-v1 (metadata only) | cdat 2026-11-01, mdat 2026-11-08: not rewritten by this provision |

## Findings
- **2094-53uw** (p0, macos): the fresh guest's Vault is unsealed with a stale host share and dies. Filed in plan/index.d.
- The README ledger row for v56.11.17.2 is absent (the last README row is v56.10.30.1). The candidate's row is in plan/issues/linux-next-work-queue-2026-05-25.md at 276f99dbd. Not filed as a packet; the README table looks retired in favour of the work queue.

## Ledger claims
- EXERCISED: the install, the signature, the tray version, the guest headless version, and provisioning from pristine.
- NOT CHECKED: the forge lane (§4) and the §3b guest container shutdown, both blocked by the vault failure. No sign-in was attempted.
