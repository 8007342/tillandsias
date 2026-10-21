# E2E smoke — v56.10.20.1 (daily) — linux / lenovinha — 2026-10-20

- run_start: 2026-10-20T23:58:48Z
- evidence_dir: target/smoke-e2e (on lenovinha; earlier runs archived under _archived-<ts>/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS). The lane brought the enclave up and stopped at `blocked:upstream-no-credential`. Nothing was claimed or pushed, the host tree is clean, and no `MO-FULL:` marker was emitted. See the finding below about the local commit the agent made.
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: PASS v56.10.20.1 (signatures unverified: cosign-absent).** Init clean. The forge lane stopped at the credential guard, as expected.

Host: lenovinha, Fedora 44 (kernel 7.2.11), 13 GiB RAM, wired 1GbE. Operator authorised the destructive run on 2026-10-20. Trunk at run: linux-next 52e44509a, main f0e61287e, windows-next b38f71052, osx-next 49731c152.

## Steps

| step | result |
|---|---|
| download | asset sha256 `3795a86f…9eb345` matches SHA256SUMS; the binary prints `Tillandsias v56.10.20.1` |
| §1 install.sh (pinned to the tag) | install_exit=0; `tillandsias --version` = v56.10.20.1 |
| §2 podman reset + credential clear | reset_exit=0, clear_exit=0 (`ok:clear-vault-credentials`, installation-uuid preserved); store empty (0 containers / 0 volumes / 0 images); vault-data dir absent; probe verdict `credential-cold` |
| §3 `--debug --init` | init_exit=0; no panic, `Error:`, MAC-failure or SIGSEGV lines in 4682 log lines |
| §3b shutdown | only tillandsias-vault was running after init: elapsed 0s of 10s grace, exit 0, no OOM |
| §4 forge lane | opencode_exit=0; guard line present; agent watch issued no verdict |
| §4b egress | tillandsias-proxy was alive alongside the lane (all 6 containers up) |
| §4c health | router/proxy/vault Up; Vault `initialized:true, sealed:false`; version v56.10.20.1 |

## 1118-fqfk slice 2a live check: credentials at rest after the upgrade

`scripts/lua/check-credentials-at-rest.lua` (trunk 52e44509a) prints names only:

- **2a sites are clean.** There is no Shamir share, root token or fallback copy, and no podman-secret plaintext. The slice 2a claim holds on the published release.
- **3 hits at site 4 (CA keys), expected on this release:** `~/.local/state/tillandsias/ca/intermediate.key`, `ca/vault.key` and `preview-ca/preview-ca.key`. Slice 2b (#592, 2c9b93d9d) moves these into tmpfs links. It landed after the v56.10.20.1 cut, so the release cannot satisfy site 4 yet. The 2b live arm is due on the next release. The overall verdict line reads `violation:credentials-at-rest:3` because trunk's checker already carries site 4.

## Ledger claims

`NO LEDGER ROW for v56.10.20.1` in README.md at trunk 52e44509a. That is a finding (below). From the coordinator: the release carries 1118 slice 1 and 2a, not 2b.

- EXERCISED: 1118 slice 2a (credentials scan above); clean-room install, init and Vault unseal.
- NOT APPLICABLE: Windows/macOS lanes.
- NOT CHECKED: 1118 slice 1 specifics beyond the scan; artifact signatures (cosign absent).

## Findings

### Work Packet: smoke-finding/v56.10.20.1-no-readme-ledger-row

- id: `smoke-finding/v56.10.20.1-no-readme-ledger-row`
- owner_host: any
- capability_tags: [release, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.20.1`
- evidence:
  - `target/smoke-e2e/00-ledger-row.txt` — `NO LEDGER ROW for v56.10.20.1`
- next_action: >
    Check whether the release skill's README append step ran for v56.10.20.1, then add the row (slice 1 + 2a, not 2b).

### Work Packet: smoke-finding/forge-commits-after-credential-guard-block

- id: `smoke-finding/forge-commits-after-credential-guard-block`
- owner_host: linux
- capability_tags: [forge, methodology, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.20.1`
- evidence:
  - `target/smoke-e2e/04-opencode.log:328` — after `blocked:upstream-no-credential`, the agent appended an event to `plan/issues/blocker-github-upstream-credential-2026-07-18.md` and committed it.
  - `04-opencode.log:399-420` — the push was rejected; the agent salvaged the commit to `refs/heads/salvage/forge-wt-smoke20/20261021-...` (`39b7c0b7`), which could not be pushed and died with the forge.
- repro:
  - a post-reset `tillandsias . --opencode --prompt "Use the /meta-orchestration skill"`
- next_action: >
    The 4a-cold contract says a guard-stopped cycle commits nothing. Either the meta-orchestration runbook tells the agent to report the re-observation without a commit when the guard is blocked, or the contract allows a plan-only note and routes it somewhere that survives teardown. Today the note is written, committed and lost.
- events:
  - type: discovered
    ts: `2026-10-21T00:28:17Z`
    agent_id: `claude-lenovinha`
    host: linux
