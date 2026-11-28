# Smoke e2e findings — v56.11.28.1 — 2026-11-28 — macos — tlatoanis-macbook-air

- run_start: 2026-11-28T08:14:42Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-20261128t081442z/)
- forge_lane_outcome: FAILED before the agent ran: the lane was killed by the vsock exec idle timeout during first-launch image builds (`opencode: vsock_exec: no data from guest for 300s — connection stale`, exit 1 after 691 s). It neither reached the credential guard nor completed a cycle.
- signature_verification: cosign:verified:1/1
- credential_step: unmeasured (the forge lane never reached the guard; the operator has not signed in from the tray this round)

## Run 2026-11-28T08:14Z→08:32Z — **FAIL** (tag v56.11.28.1, platform darwin, regime darwin-arm64)

FAIL v56.11.28.1 macos: install, signature, reset and provision clean; the cold first forge lane died at the 300 s vsock idle timeout while the guest built images (recurrence of 1810-sl5h).

The operator approved this run on their workstation (2026-11-28).

| step | result |
|---|---|
| §0 ledger row | NO LEDGER ROW for v56.11.28.1 (README at the tag tops out at v56.11.23.1). Already reported as finding 1 in the yoga linux report for this tag. |
| §1 curl-install | install_exit=0; /Applications/Tillandsias.app (no ~/Applications fallback); `tillandsias-tray 56.11.28.1 (git 6a242328c, built 2026-11-28T07:08:51Z)`, exact match; it replaced 56.11.24.1 |
| §1s signature | cosign:verified:1/1 on `tillandsias-tray-56.11.28.1-macos-arm64.tar.gz` (sha256 744643e5…6cc0, per SHA256SUMS-macos) |
| §2 reset | the tray was stopped by PID (TERM), then `scripts/e2e-step2-macos.sh` printed `ok:e2e-step2-macos:destroyed` (5.6G VM dir removed, 0 residue). The credential probe read `credential-warm` after the reset: the Keychain share from 2026-11-25 survived the macOS destroy step. |
| §3 provision | provision_exit=0 in 18 s; the fresh rootfs.img postdates the destruction marker; the tray logged "fresh VM disk: forgot the previous Vault share and root token (2094-53uw)". The credential probe then read `credential-cold`. `--diagnose --json`: provisioned=true, rootfs_present=true, version=56.11.28.1 |
| §3b shutdown | not asserted on macOS (the containers are inside the VM). This is the stated gap, not a pass. |
| §4 lane | `--cloud 8007342/tillandsias --opencode --prompt <smoke prompt>`: exit 1 after 691 s, agent_turn=NO-TOKEN, no guard line. The tray log shows "Vault did not unseal within 120s (phase never reached Ready)", then `vsock_exec: no data from guest for 300s`. |
| §4 guest evidence | Read after the lane, with the VM stopped, via `--exec-guest`. vault, proxy, router, git and inference images were built 08:18–08:20Z. There is no forge image: `image-build-forge.log` stops at `Building forge-base, step 3/5: installing system packages`. The provision marker reads complete, with `kernel_reboot_pending=yes`. |
| final diagnose | final_diagnose_exit=0 |
| stale evidence | 0 files older than run_start |
| attest | `attest-smoke.lua --verdict fail:forge-lane-vsock-idle-timeout --regime darwin-arm64`: committed locally as `refs/attest/smoke/darwin/6a242328…` (70f1b371c). Its push is refused by the pre-push hook (2443-r9sm, in progress on yoga), so it gets pushed once that fix lands. |

## Ledger claims

There is no ledger row, so there is nothing to classify (see the yoga report, finding 1).

## Findings

1. **Recurrence of 1810-sl5h** (ready, not a new packet): a cold first forge launch after a full macOS wipe goes silent for 300 s and is killed by the vsock exec idle timeout. The event was appended to the row on 2026-11-28 with this run's evidence. The image builds run in detached helpers that log to `/root/.cache/tillandsias/image-build-*.log`, not to the exec stream, so on a cold guest the stream is silent for longer than the idle timeout while the build is healthy. This blocks the darwin PASS for v56.11.28.1.
2. **Observation, no packet:** the macOS destroy step (`e2e-step2-macos.sh`) leaves the Keychain's `vault-shamir-share-v1`, so the probe reads warm immediately after §2. Provisioning a fresh disk then forgets the share (2094-53uw), and the probe reads cold before the lane. The clean room is reached at §3, not §2. That differs from Linux, where §2 itself clears the credentials (900-z3kv).
