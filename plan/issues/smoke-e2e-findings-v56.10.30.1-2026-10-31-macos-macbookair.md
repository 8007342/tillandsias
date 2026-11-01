# v56.10.30.1 e2e smoke — macos FAIL: forge lane unlaunchable from the tray CLI (2026-10-31)

- run_start: 2026-10-31T02:16:04Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous runs archived under _archived-<ts>/; forge attempts 1-2 under _attempt1/, _attempt2/)
- forge_lane_outcome: NOT LAUNCHED — the tray's `--opencode` accepts only a `~/src` path, and the guest refuses every local-checkout launch (776-jcf3); there is no CLI cloud form on the macOS tray
- signature_verification: cosign:verified:1/1

Release under test: v56.10.30.1 (prerelease, daily), target cec5797c35d4fd1fa77c7cec1329b4ef9e0a05bd, published 2026-10-30T23:27:04Z. Pinned through `TILLANDSIAS_RELEASE_BASE=https://github.com/8007342/tillandsias/releases/download/v56.10.30.1`; `latest` still points at v56.10.16.2.

**Verdict: FAIL for promotion.** The core install path passes. But the forge launch, which the coordinator listed as a required step, cannot run on macOS in this release, so `image.generate` was never reached.

```
§0 ledger row      present (README.md:84, "local image generation")
§1 install         PASS  install_exit=0; /Applications, no ~/Applications fallback;
                         --version "tillandsias-tray 56.10.30.1 (git cec5797c3, built 2026-10-30T23:50:34Z)"
§1s signature      PASS  cosign:verified:1/1 (tillandsias-tray-56.10.30.1-macos-arm64.tar.gz)
§2 reset           PASS  ok:e2e-step2-macos:destroyed; App Support and Caches removed; residue empty
§3 provision       PASS  provision_exit=0 in 44 s; rootfs.img newer than the destruction marker;
                         --diagnose --json exit 0: provisioned=true, rootfs_present=true, version=56.10.30.1
§3b shutdown       NOT ASSERTED (stated macOS gap: guest-container shutdown is not checked on this lane)
§4 forge lane      FAIL  see finding 1; three attempts, the first two harness-side
§4 image.generate  NOT RUN (forge never started); see finding 2 for the imagegen build on this VM
```

The three §4 attempts:
1. `_attempt1/`: harness error, not product. My CPU sampler's `--exec-guest` booted the VM at the same moment as the forge's `--opencode`, and the forge lost the race. The tray diagnosed it correctly ("pid … still has nvram.bin open … DO NOT --reset-guest").
2. `_attempt2/`: `--opencode /home/forge/src` → exit 2, "launching from a local checkout ('/home/forge/src') is no longer supported … launch it from the cloud instead: tillandsias --cloud <owner>/<repo> --opencode".
3. `04-opencode.log`: `--opencode 8007342/tillandsias` → exit 2, "--opencode project path must be under /Users/tlatoani/src (host form) or /home/forge/src (guest form)".

## Ledger claims

- EXERCISED: the tray reports the release version (`--version`, and `--diagnose --json .version`).
- NOT CHECKED: `image.generate` on the lane MCP socket, the I0-I3 tier ladder and its consent token, and the imagegen image built on first use. None was reachable, because the forge did not start (finding 1).
- NOT APPLICABLE: the Linux- and Windows-specific rows.

### Work Packet: smoke-finding/macos-tray-opencode-cannot-launch-after-776-jcf3

- id: `smoke-finding/macos-tray-opencode-cannot-launch-after-776-jcf3`
- owner_host: macos
- capability_tags: [macos, tray, forge, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.30.1`
- evidence:
  - `_attempt2/04-opencode.log`: `Error: launching from a local checkout ('/home/forge/src') is no longer supported` (`main.rs` `resolve_launch_project_identity`, from 5f63f81df 776-jcf3, landed 2026-10-23)
  - `04-opencode.log:1`: `--opencode project path must be under /Users/tlatoani/src (host form) or /home/forge/src (guest form); got: 8007342/tillandsias` (`diagnose.rs` `translate_project_path_for_guest`)
  - On v56.10.16.2 (before 776-jcf3), the same lane passed: `--opencode rc=0 in 253 s` (plan/issues/e2e-smoke-v56.10.16.2-macos-2026-10-16.md:34).
- repro:
  - `/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --opencode 8007342/tillandsias --prompt hi` (exit 2), then the same with `/home/forge/src` (exit 2).
- next_action: >
    Give the tray's --opencode (or a new --cloud flag) the owner/repo form that 776-jcf3 made the
    only launch, so the guest runs a cloud launch, and add a test that the tray accepts owner/repo.
    The menu's cloud launch may still work; it was not checked, because this lane does no GUI scripting.
- events:
  - type: discovered
    ts: `2026-10-31T02:40:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos

### Work Packet: smoke-finding/macos-imagegen-image-build-silent-21h-on-vz

- id: `smoke-finding/macos-imagegen-image-build-silent-21h-on-vz`
- owner_host: macos
- capability_tags: [macos, imagegen, podman, measurement]
- status: ready
- discovered_by: 1921-sdv9 CPU baseline (not this smoke's own step; the smoke never reached image.generate)
- evidence:
  - The guest built `images/imagegen/Containerfile` (sd.cpp `master-1015-e41fbcf`) on the v56.10.16.2 VZ guest (8 vCPU, 8 GiB, kernel 6.19.10-300.fc44.aarch64). Its log stopped after cmake configure (`pnpm not found; frontend build disabled.`) and showed no further output for about 21 h, 2026-10-30T04:32Z → 2026-10-31T02:15Z, until it was stopped.
  - Not determined: hang or silent compile. The build ran under `podman build -q`, and the host sampler used `top -l 1`, whose first-sample CPU is always 0, so it cannot tell idle from busy. Logs: target/timing-probe/run.log and host-top.log on tlatoanis-macbook-air.
- repro:
  - `podman build -t sdbench-imagegen -f images/imagegen/Containerfile images/imagegen` inside the macOS guest, without -q, with `top -b -d 30` beside it.
- next_action: >
    Rerun the build without -q and with an in-guest CPU sampler. If ninja is CPU-busy, it is slow and needs a
    pre-built image or a smaller -j; if it is idle, capture the process tree for the hang. The macOS imagegen
    lane was scoped to slip from R1, so this does not block promotion.
- events:
  - type: discovered
    ts: `2026-10-31T02:40:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20261012t100000z`
    host: macos
