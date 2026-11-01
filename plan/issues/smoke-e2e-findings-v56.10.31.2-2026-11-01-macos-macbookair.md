# v56.10.31.2 e2e smoke — macos FAIL: the forge comes up cold, but a warm CLI boot never unseals, and image.generate times out (2026-11-01)

- run_start: 2026-11-01T01:09:48Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (cold attempt under _attempt-cold/)
- forge_lane_outcome: cold boot STARTED. The agent ran (OpenCode, big-pickle) and exited 0 after 585 s. The warm boot did NOT reach Ready.
- signature_verification: cosign:verified:1/1

Release under test: v56.10.31.2 (prerelease), target 5c81b924711fda4bf93bbf837c7c76288e80a245, ledger row 1a03d4ca1. Installed with `TILLANDSIAS_VERSION=v56.10.31.2` on bash.

**Verdict: FAIL for promotion.** It is the first macOS release since v56.10.16.2 whose forge comes up. But a second CLI launch strands the Vault, and `image.generate` does not complete.

```
§0 ledger row      present (README.md:84)
§1 install         PASS  install_exit=0; "tillandsias-tray 56.10.31.2 (git 5c81b9247, built 2026-11-01T00:05:25Z)"; CFBundleVersion 56.10.31.2
§1s signature      PASS  cosign:verified:1/1
§2 reset           PASS  ok:e2e-step2-macos:destroyed; residue empty
§3 provision       PASS  provision_exit=0 in 50 s; fresh rootfs; diagnose version=56.10.31.2
§3b shutdown       NOT ASSERTED (stated macOS gap)
§4 forge, cold     PASS  --cloud 8007342/tillandsias --opencode: proxy `status=ready-earlier` (1922-lrdy), mirror seeded, forge started, agent ran, exit 0
§4 forge, warm     FAIL  wait_phase_ready timeout after 300 s: the boot credential exchange failed to connect (finding 1)
§4 image.generate  FAIL  MCP error -32001: Request timed out; no file, no engine process (finding 2)
```

What each targeted fix did, measured:
- #751, the CLI `--cloud` form: PASS.
- 1922-lrdy, the proxy readiness gate: PASS (`event:service_ready service=proxy … status=ready-earlier`).
- #769, the CLI credential exchange:
  - The before-stop half is PASS. After the cold lane, the host Keychain holds `vault-shamir-share-v1` and `vault-root-token-v1` (checked by metadata only, `04-keychain-after-cold.txt`); after the same lane on v56.10.31.1 there were none.
  - The boot half is FAIL (finding 1).

## Ledger claims

- EXERCISED: the CLI cloud launch, the readiness gate, and the CLI credential exchange (both halves, as above). `image.generate` was called once at the smallest tier (finding 2).
- NOT CHECKED: the menu launch (no GUI scripting on this host), and the tier ladder above I0.

### Work Packet: smoke-finding/macos-cli-boot-exchange-connects-before-the-guest-listens

- id: `smoke-finding/macos-cli-boot-exchange-connects-before-the-guest-listens`
- owner_host: macos
- capability_tags: [macos, tray, vault, credentials]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.31.2`
- evidence:
  - Both attempts (`_attempt-cold/04-opencode.log`, `04-opencode.log`) print `[tillandsias-tray] credential exchange (boot): connect: VzRuntime GuestTransport: VZ connect error: … Connection reset by peer`, right after `starting VM`.
  - The warm attempt: `wait_phase_ready: … timeout after 300s (phase never reached Ready)`. On v56.10.31.1 the guest journal showed this hold as Vault waiting for the host's share.
- cause: 1925-cxch (#769) makes ONE exchange attempt immediately after `vz.start()`, before the guest's control-wire listener is up. The VZ connect is reset at once, so the share is never delivered.
- next_action: >
    Retry the boot exchange's connect until it succeeds, bounded by the Ready deadline, and test that
    a guest that refuses the first connects still gets the delivery.
- events:
  - type: discovered
    ts: `2026-11-01T01:40:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos

### Work Packet: smoke-finding/macos-image-generate-mcp-request-timed-out

- id: `smoke-finding/macos-image-generate-mcp-request-timed-out`
- owner_host: macos
- capability_tags: [imagegen, mcp, macos]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.31.2`
- evidence:
  - `_attempt-cold/04-opencode.log`: `host-browser_image_generate {"prompt":"a red fox in a snowy forest"} failed — MCP error -32001: Request timed out`. Afterwards `/work/tmp/imagegen/` was empty, and `pgrep -af 'stable-diffusion|sd\.|imagegen'` found nothing.
  - Related: on the VZ guest, building the imagegen image (sd.cpp) went silent for about 21 h after cmake configure (smoke-finding/macos-imagegen-image-build-silent-21h-on-vz, filed with v56.10.30.1). A first-use build that outlives the MCP request timeout would read exactly like this.
- next_action: >
    Read the guest's imagegen build log and the lane MCP server's log for this request. If the
    first-use image build is the cause, image.generate needs to return a progress or pending result
    instead of holding the request past the client's timeout. The macOS imagegen lane was scoped to
    slip from R1, so this does not block promotion on its own.
- events:
  - type: discovered
    ts: `2026-11-01T01:40:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos
