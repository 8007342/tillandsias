# Smoke: v56.11.23.1, Linux immutable (Silverblue 45), lenovinha

- run_start: 2026-11-24T00:58:41Z
- evidence_dir: target/smoke-e2e (worktree at 2e988bbd7, local to lenovinha)
- forge_lane_outcome: leg 1 (default): FAILED, exit 1 in 36 s, inference could not start, no agent turn. Leg 2 (TILLANDSIAS_NO_LOCAL_INFERENCE=1, its own regime, not a pass of leg 1): agent answered one turn (SMOKE-AGENT-OK); in-forge credential check `blocked:upstream-push-unauthorized`; not a completed cycle.
- signature_verification: cosign:verified:2/2

**Verdict: FAIL** (default lane). Channel: daily, prerelease. Regime: linux-immutable, credential-WARM.

## Steps

| Step | Result |
|---|---|
| Signatures | `tillandsias-linux-x86_64` and `install.sh` verified with cosign v3.1.4 in a container (image digest sha256:0f061548, trusted on first pull); a tampered copy and a wrong identity were both rejected |
| 1 install | exit 0, `Tillandsias v56.11.23.1` |
| 2 podman system reset | exit 0; containers, volumes, images empty |
| 2 clear-vault-host-credentials | NOT RUN: the operator keeps the Vault store and the keychain share |
| 3 init | exit 0, 452 s, 11 images built after run_start, Vault recovered its share and unsealed |
| 3b shutdown | tillandsias-vault 1 s of 10 s grace, exit 0, not OOM (bash / vault / tee) |
| 4 lane, default | FAIL: see 2283-u8m6 |
| 4 lane, no local inference | exit 0 in 69 s; token answered; proxy present in 5 of 5 samples |
| 4c health | vault unsealed, proxy and router up, lane-scoped containers gone |

## Unmeasured

- The cold keychain-volume resync path (credential-warm by design).
- The credential step: no sign-in was started. The stored GitHub token is refused upstream (`REASON=unauthenticated`); it predates this run and was not re-seeded.
- GPU inference, and CPU inference as a fallback: leg 2 had none.
- The tray (not launched).
- Whether the driver upgrade (620.70.06, 2026-11-23) triggered the GPU failure. It is not a regression in the argv: `build_inference_run_args` differs from v56.11.7.1 in the proxy env only. v56.11.7.1's lane was not run, to keep an older Vault bootstrap off the operator's store.

## Ledger claims

No README row for v56.11.23.1 at 2e988bbd7, so no claims could be read: none EXERCISED, none checked. The row is #1454 (macuahuitl-fedora).

## Findings

### Work Packet: smoke-finding/gpu-start-failure-kills-the-lane

- order: 2283-u8m6 (p0, claimed by lenovinha)
- owner_host: linux
- status: in_progress
- evidence: 04-opencode.log (leg 1): `crun: mount_setattr /run/nvidia-persistenced/socket: Operation not permitted: OCI permission denied`
- repro: `podman run --rm --device nvidia.com/gpu=all --security-opt=label=disable --userns=keep-id docker.io/library/alpine:3.22 true` (rc 126); without `--userns=keep-id`, or without the device, rc 0

### Work Packet: smoke-finding/no-readme-ledger-row-v56-11-23-1

- owner_host: any
- status: in_progress (#1454)
- evidence: `NO LEDGER ROW for v56.11.23.1` at 2e988bbd7; the RC was recorded in the work-queue file only
