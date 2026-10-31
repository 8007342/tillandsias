# v56.10.31.1 e2e smoke — macos FAIL: CLI forge launch reaches the guest, then the proxy readiness gate and a never-delivered Vault share stop it (2026-10-31)

- run_start: 2026-10-31T17:16:52Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (cold attempt under _attempt-cold/; previous runs archived under _archived-<ts>/)
- forge_lane_outcome: NOT STARTED, at two different gates. Cold boot: `readiness gate: ... tillandsias-proxy: no ready event within 125s`. Warm boot: the VM never reached Ready, because Vault stayed sealed with no share delivered from the host.
- signature_verification: cosign:verified:1/1

Release under test: v56.10.31.1 (prerelease), target 25dd6362fde2fb9d9ad002b760d16f10be7d7382, ledger row d47783fc5. Pinned through `TILLANDSIAS_RELEASE_BASE=…/releases/download/v56.10.31.1` and `TILLANDSIAS_VERSION=v56.10.31.1`.

**Verdict: FAIL for promotion.** The two v56.10.30.1 fixes both did what they were for. #751: the CLI cloud launch reaches the guest. #750: no "keyring locked" anywhere. But the forge lane still does not start on macOS.

```
§0 ledger row      present (README.md:84, "fix forward of v56.10.30.1")
§1 install         PASS  install_exit=0; --version "tillandsias-tray 56.10.31.1 (git 25dd6362f, built 2026-10-31T16:20:00Z)"
§1s signature      PASS  cosign:verified:1/1 (tillandsias-tray-56.10.31.1-macos-arm64.tar.gz)
§2 reset           PASS  ok:e2e-step2-macos:destroyed; residue empty
§3 provision       PASS  provision_exit=0 in 52 s; fresh rootfs; diagnose provisioned=true, rootfs_present=true, version=56.10.31.1
§3b shutdown       NOT ASSERTED (stated macOS gap)
§4 forge lane      FAIL  cold: proxy readiness gate (finding 1); warm: Vault sealed, share never reached the host (finding 2)
§4 image.generate  NOT RUN (the forge never started)
```

What each fix did, measured:
- #751, the CLI cloud form: PASS. `--cloud 8007342/tillandsias --opencode` was accepted. The guest built router, git, inference and forge, brought the enclave up, and seeded the mirror (`event:service_ready service=git-tillandsias status=mirror_seeded_(1)`).
- #750, the guest-credentials socket: no `keyring locked` in either attempt, and on the cold boot the lane got past the Vault prerequisite. That is the v56.10.30.1 failure gone, on this host. It does not prove the socket path end to end: the cold boot initialised a fresh Vault rather than reading a delivered share.

## Ledger claims

- EXERCISED: the CLI cloud launch (#751): the guest is reached. The Vault delivery to lanes (#750): no keyring-locked failure. Readiness events (1922-rann): `mirror_seeded` was observed; `proxy_listening` was not (finding 1).
- NOT CHECKED: `image.generate` and the tier ladder, because the forge never started. The menu launch, because this host does no GUI scripting.

### Work Packet: smoke-finding/macos-proxy-ready-event-not-seen-by-gate

- id: `smoke-finding/macos-proxy-ready-event-not-seen-by-gate`
- owner_host: any
- capability_tags: [proxy, readiness, podman, macos]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.31.1`
- evidence:
  - `_attempt-cold/04-opencode.log`: `event:service_ready_failed service=proxy container=tillandsias-proxy reason=no_ready_event_within_125s`, then `Error: readiness gate: a hard requirement is not ready (tillandsias-proxy: no ready event within 125s)`. The git mirror's `mirror_seeded` arrived in the same launch.
  - `04-proxy-notify-evidence.txt`: the proxy container runs with `sdnotify=container` and `NOTIFY_SOCKET=/run/notify/notify.sock`; socat is present in the image; squid logs `listening port: 3128`. No `READY=1 not delivered` line is in its log, so the entrypoint's `notify_ready` either delivered or never ran.
  - `04-guest-evidence.txt`: squid served 30 requests before shutdown, so the proxy was up and working.
- hypothesis (unverified): the proxy is application-lifetime and was already running. Its one-shot READY datagram fired at its own start, before this launch's gate subscribed, so a gate that waits for a fresh event misses it.
- repro:
  - On a freshly provisioned macOS VM: `tillandsias-tray --cloud 8007342/tillandsias --opencode --prompt hi`.
- next_action: >
    Have the gate accept an already-running proxy (podman inspect a recorded ready state, or replay the
    last ready event per container), then add a fixture where the proxy starts before the gate listens.
- events:
  - type: discovered
    ts: `2026-10-31T17:45:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos

### Work Packet: smoke-finding/macos-cli-launch-never-collects-or-delivers-vault-share

- id: `smoke-finding/macos-cli-launch-never-collects-or-delivers-vault-share`
- owner_host: macos
- capability_tags: [macos, tray, vault, credentials]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.31.1`
- evidence:
  - `04-opencode.log` (warm attempt): `wait_phase_ready: timeout after 300s (phase never reached Ready)`.
  - `04-guest-evidence.txt` (journal of that boot): `wait:ready-gate:vault: Ready held until Vault is unsealed … waiting for the host to unlock the vault … remedy: start the Tillandsias tray on the host`, repeating every 30 s, plus `blocked:github-token-rotation-failed:read:vault-unavailable`.
  - Host keychain, checked by metadata only (`security find-generic-password` with no `-w`): no `vault-shamir-share-v1` item after the cold boot that initialised Vault.
- reading: the CLI modes (`--opencode`, `--exec-guest`) boot the VM without the tray's credential exchange. A Vault they initialise never hands its share back to the host keychain (GetVaultHandover), and a later boot gets no delivery, so Vault stays sealed and the share is lost when the VM stops. The tray app does this exchange; the CLI path does not. Code read, not traced.
- repro:
  - After §2 and §3: `--cloud <o>/<r> --opencode` once (Vault is initialised), then the same command again (it never reaches Ready).
- next_action: >
    Make the CLI boot path run the same delivery and handover as the tray (installation_uuid
    deliver_and_handover_with), then add a test that a CLI-initialised Vault's share reaches the keychain
    and is delivered on the next CLI boot. Until then a CLI-only first launch strands the Vault; the
    recovery is a reset, which loses the sign-ins.
- events:
  - type: discovered
    ts: `2026-10-31T17:45:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos
