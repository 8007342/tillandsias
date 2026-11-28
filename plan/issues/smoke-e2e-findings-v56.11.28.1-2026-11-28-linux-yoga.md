# Smoke e2e findings — v56.11.28.1 — 2026-11-28 — linux — yoga

- run_start: see target/smoke-e2e/00-run-start.txt on yoga (run 07:13Z→07:34Z, 2026-11-28)
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS) — the lane brought the enclave up and stopped at the Credential Channel Guard with `blocked:upstream-no-credential`; agent_turn=answered; no `MO-FULL: COMPLETE` marker, and its absence is correct
- signature_verification: cosign:verified:1/1
- credential_step: partial:credential-unmeasured

## Run 2026-11-28T07:13Z→07:34Z — **PASS** (tag v56.11.28.1, platform linux, host yoga-silverblue, regime linux-x86_64)

PASS v56.11.28.1 linux: init clean; forge lane stopped at the credential guard as expected.
Credential step: partial:credential-unmeasured (the §2 reset wiped the Vault; the operator has not yet signed in from the tray).

| step | result |
|---|---|
| §1 curl-install | install_exit=0; `tillandsias --version` = `Tillandsias v56.11.28.1` |
| §1s signature | cosign:verified:1/1 — cosign v3.1.6 (checksum-checked) in the builder toolbox; the verified asset's sha256 `7caeb29fc11f80c85f8443d88f55b3873b72df573025320e4787d52cdee4fe6f` equals the installed binary's and the SHA256SUMS line |
| §2 reset | reset_exit=0, clear_exit=0, empty store, vault-data dir absent, probe `credential-cold` |
| §3 init | init_exit=0 from pristine (~8 min) |
| §3b shutdown | tillandsias-vault elapsed=1s grace=10s exit=0; the only flag was a non-Tillandsias `ollama` container (no inspect after a --rm stop) — not a finding |
| §4 lane | opencode_exit=0, `blocked:upstream-no-credential`, SMOKE-AGENT-OK alone on a line |
| §4b egress | tillandsias-proxy alive alongside the lane |
| §4c health | vault `"sealed":false`; version v56.11.28.1 |
| stale evidence | 0 files older than run_start |

## Ledger claims

NO LEDGER ROW for v56.11.28.1 in README.md (finding 1). Nothing to classify as EXERCISED / NOT APPLICABLE / NOT CHECKED; the coordinator will add the row at promotion.

## Findings

1. **No README ledger row for v56.11.28.1.** Coordinator adds it at promotion.
2. **The smoke attestation push is refused by the pre-push hook.** `scripts/lua/attest-smoke.lua --push` → `refused:attest-smoke:push-failed:refs/attest/smoke/linux/6a242328cd60d32750c92b90da7987790b3e83c6`; `scripts/hooks/pre-push-local-gate.sh` exempts `refs/attest/daily-*/` and `refs/attest/native-lint/` but not `refs/attest/smoke/*`, so it demands a full gate stamp. `git ls-remote origin 'refs/attest/smoke/*'` lists zero refs. The local ref (d2c009ab, a 3-file digest tree) is kept until the fix lands. Coordinator approved a shape-checked exemption (exactly SHA256SUMS, regime.txt, verdict.txt; creation or fast-forward only) as a fix-forward.
3. **The skill's in-toolbox cosign install cannot work on yoga**: `sudo` inside the toolbox needs a password, so §1s reads `could-not-run` by construction until cosign is provided another way.
