# Smoke: v56.11.24.1, Linux immutable (Silverblue 45), lenovinha

- run_start: 2026-11-25T00:55:36Z
- evidence_dir: target/smoke-e2e (worktree at 9fc9be94e, local to lenovinha)
- forge_lane_outcome: default lane ran to exit 0 in 120 s; the agent took its one turn, called the credential check and replied; in-forge credential check `blocked:upstream-push-unauthorized`; the agent declined to print the token as its answer; not a completed cycle.
- signature_verification: cosign:verified:2/2

**Verdict: PASS, with the credential step UNMEASURED and one caveat on the agent token (below).** Channel: daily, prerelease. Regime: linux-immutable, credential-WARM. No attestation was pushed (coordinator's instruction).

## Steps

| Step | Result |
|---|---|
| Signatures | `tillandsias-linux-x86_64` and `install.sh` verified with cosign v3.1.4 in a container (index digest sha256:0f061548); a tampered copy and a wrong identity were both rejected |
| 1 install | exit 0, `Tillandsias v56.11.24.1` |
| 2 podman system reset | exit 0; containers, volumes, images empty |
| 2 clear-vault-host-credentials | NOT RUN: the operator keeps the Vault store and the keychain share |
| 3 init | exit 0, 451 s; Vault recovered its share, kept its data and came up healthy |
| 3b shutdown | tillandsias-vault under 1 s of 10 s grace, exit 0, not OOM (bash / vault / tee) |
| 4 lane, default | exit 0 in 120 s; GPU container refused, fell back to CPU by name, lane continued |
| 4b egress | proxy present in 8 of 8 samples |
| 4c health | vault unsealed, proxy and router up, lane-scoped containers gone |

## Claim checked

- #1455 (2283-u8m6): HOLDS. The same `mount_setattr` refusal that ended the v56.11.23.1 lane was met again; the launcher said it runs inference on CPU for this session, the inference container came up, and the lane finished.

## Unmeasured

- The credential step: no sign-in was started. The stored GitHub token is refused upstream (`REASON=unauthenticated`), as on v56.11.23.1.
- The cold keychain-volume resync path (credential-warm by design).
- GPU inference, and whether CPU inference answered a request (the agent uses a hosted model).
- The tray (not launched). Only init's Vault was running for 3b; the proxy and router were not.

## Ledger claims

No README row for v56.11.24.1 at the tag or on linux-next, so no row claims could be read.

## Findings

### Work Packet: smoke-finding/agent-token-grep-matches-a-refusal

- owner_host: any
- status: ready
- evidence: the credential check was blocked, and the agent wrote that it could not append `SMOKE-AGENT-OK` because it would report success; the step's `grep` matched that sentence and printed `agent_turn=answered`
- why: the prompt asks for a token spelling OK after a check that failed, so an honest agent declines, and the grep cannot tell a refusal that names the token from the answer
- next: a neutral token (not OK) and a whole-line match

### Work Packet: smoke-finding/no-readme-ledger-row-v56-11-24-1

- owner_host: any
- status: ready
- evidence: `NO LEDGER ROW` for v56.11.24.1 at 9fc9be94e and on linux-next
