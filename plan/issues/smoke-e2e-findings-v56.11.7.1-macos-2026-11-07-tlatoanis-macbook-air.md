# Smoke e2e findings — release v56.11.7.1 — 2026-11-07 — tlatoanis-macbook-air (macOS)

- lane: macos / `osx-next`; host Apple M5, 16 GiB, macOS 27.2.0 at the passing run.
- guest: VZ 8 vCPU / 8 GiB, Fedora 44, kernel 6.19.10-300.fc44.aarch64 (for all three attempts; see correction in 2029-b87w).
- channel: stable candidate v56.11.7.1, installed with the full-reset curl install.

## PASS / FAIL

| # | Step | Verdict | Evidence |
|---|---|---|---|
| 1 | Full-reset curl install + provision | PASS | `provision_exit=0`; the operator signed in to GitHub and Cloudflare themselves |
| 2 | Forge turn, attempt 1 | FAIL | every new guest process segfaulted after the forge build: 2029-b87w; evidence `target/smoke-e2e/evidence-segv-20261107t222652z` |
| 3 | Forge turn, attempt 2 (after wipe + reprovision) | FAIL | guest hung in folio_wait_bit_common / btrfs_file_read_iter, 33 min into the forge build: 2029-b87w; evidence `target/smoke-e2e/evidence-folio-hang-20261107t233139z` |
| 4 | Forge turn, attempt 3 (after a full Mac restart and macOS upgrade) | PASS | the forge agent's six results, quoted below |

macOS PASS v56.11.7.1 smoke e2e, forge turn, attempt 3. Two of three attempts failed, with p0 2029-b87w open; the operator decides whether that clears promotion.

Forge agent results (tillandsias-macbookair-forge, relayed via macuahuitl-fedora), quoted:
1. "version 56.11.7.1, bringup 33.5 s" (clone 8062 ms, require-harness 4099, require-openspec 4216, openspec-pin 15794; total 33454 ms; was 44.1 s)
2. "credential guard `ok:forge-git-mirror`"
3. "mirror fetch rc 0" (`git ls-remote origin HEAD` → 8351a0f3ff45)
4. "no segfaults, fresh processes start fine"
5. "5.6 GB available" (io PSI full avg300 0.76, memory full 0.12)
6. "git status 0.02 s"

## Gaps
- The forge has no dmesg or journalctl, so the segfault check is host-side only: 2032-6cvw.
- forge-quick-intro doesn't name the credential guard script: 2032-vtp2.
