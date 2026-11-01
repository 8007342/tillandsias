# v56.11.1.1 e2e smoke — macos PASS (core and warm unseal; OpenCode lane not run, per the operator pause) (2026-11-01)

- run_start: 2026-11-01T08:53:07Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air
- forge_lane_outcome: NOT RUN by design. The operator paused OpenCode and opencode.ai traffic until 2026-11-02 ~03:00Z, so the lane was replaced by a cold `--exec-guest` boot, a warm `--exec-guest` boot and `--list-cloud-projects` (approved by macuahuitl).
- signature_verification: cosign:verified:1/1

Release under test: v56.11.1.1 (prerelease), target 05341632f4d94aaf2a0f5bb2c89a7f4ffa4f9a5b, ledger 991183d89. It contains #783 (1925-fans): its head 918677bd1 is an ancestor of the tag.

**Verdict: PASS for the steps run (signatures verified).** The OpenCode forge lane and `image.generate` were NOT exercised, because of the operator pause. A promotion decision should weigh that.

```
§1 install          PASS  install_exit=0; "tillandsias-tray 56.11.1.1 (git 05341632f, built 2026-11-01T08:28:56Z)"; CFBundleVersion 56.11.1.1
§1s signature       PASS  cosign:verified:1/1
§2 reset            PASS  ok:e2e-step2-macos:destroyed; residue empty
§3 provision        PASS  provision_exit=0 in 39 s; fresh rootfs; diagnose version=56.11.1.1
§4a cold boot       PASS  --exec-guest: rc=0, guest answered, vault container healthy, proxy healthy
§4b warm boot       PASS  the Vault UNSEALED on the warm CLI boot (#783 proven)
§4c list projects   PASS (cold-expected)  Ready reached, vault-health and proxy-ready passed; the listing fails only because there is no GitHub token
§4  forge/imagegen  NOT RUN (operator pause on OpenCode)
```

The warm-boot evidence, `04b-warm-exec-guest.log`, from the guest journal:
- 09:06:41 `bootstrap starting`
- 09:06:48 `subsequent boot: using unseal key from secret` → `vault is unsealed` → `event:service_ready service=vault container=tillandsias-vault status=vault_unsealed`

The guest logged `Ready held until Vault is unsealed` exactly ONCE before the delivery arrived. That is the first-answer delivery (#783) working. On v56.10.31.1 and v56.10.31.2 the same warm boot held for 300 s and never unsealed.

The listing, `04c-list-cloud-projects.log`: `bringup: step=vault-health ms=254`, `bringup: step=proxy-ready ms=1839`, then `vault-cli: HTTP error reading secret/data/github/token: curl: (22) … 404`. On a host whose reset left no GitHub sign-in, that is the correct stop. Proving a real listing needs a GitHub device-flow sign-in, which the operator must approve.

1922-rann capture (macOS, this release, on the warm boot): `vault_unsealed` observed. On v56.10.31.2: `proxy` `status=ready-earlier` and `mirror_seeded_(1)`. This is a capture on a published release, as asked.

## Ledger claims

- EXERCISED: #783, the CLI boot delivery on the guest's first answer (the warm unseal above); the CLI credential exchange; and the readiness events.
- NOT CHECKED: the OpenCode forge lane and `image.generate` (operator pause), a real projects listing (no GitHub token after the reset), and the menu launch (no GUI scripting).

### Work Packet: smoke-finding/macos-reset-keeps-keychain-vault-credentials

- id: `smoke-finding/macos-reset-keeps-keychain-vault-credentials`
- owner_host: macos
- capability_tags: [macos, smoke, vault, credentials]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.11.1.1`
- evidence:
  - `02-keychain-after-reset.txt`: after `scripts/e2e-step2-macos.sh` destroyed the VM, `vault-shamir-share-v1` and `vault-root-token-v1` were still present in the Keychain (metadata only; their mdat, 08:06Z, predates run_start). So the macOS lane is not credential-cold, and the cold boot delivered a share from a destroyed Vault.
  - Linux clears the host-held credentials in the same step (900-z3kv, `scripts/clear-vault-host-credentials.sh`). The macOS step does not.
- next_action: >
    Decide whether the macOS reset should clear the two Keychain items, as 900-z3kv decided for Linux, keeping
    tillandsias-vm-uuid. Then make e2e-step2-macos.sh do it, with a metadata-only assertion in the residue file.
- events:
  - type: discovered
    ts: `2026-11-01T09:20:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos
