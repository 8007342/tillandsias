# v56.10.17.1 stable-channel e2e smoke — macos: install PASS; first cold forge launch FAIL (router), retry PASS (2026-10-18)

- run_start: 2026-10-18T07:04:33Z
- evidence_dir: target/smoke-e2e on tlatoanis-macbook-air (previous run archived under _archived-20261018t070433z/)
- forge_lane_outcome: try 1 FAILED at the router start (`podman run tillandsias-router` hit its 300 s budget, rc=1). Try 2, an immediate relaunch with warm images, completed with rc=0 (an agent session ran; the sign-in survived the SOFT reset, so this is not a cold-host guard stop).
- signature_verification: cosign:verified:1/1

Release: v56.10.17.1 = `bf21de967`, promoted to stable (`/releases/latest` resolves to it; `stable^{}` = bf21de967), publishedAt 2026-10-17T20:02:41Z, 34 assets. Smoke run on the coordinator's GO, under the operator's standing instruction (2026-10-12) to smoke every release. The user was warned in-session before the install's reset.

| | |
|---|---|
| host | tlatoanis-macbook-air, macOS 27.0 arm64, 10 cores / 16 GiB; guest 8 vCPU / 8 GiB |
| install | `curl -fsSL …/v56.10.17.1/install-macos.sh \| TILLANDSIAS_RELEASE_BASE=… TILLANDSIAS_VERSION=v56.10.17.1 bash`, exit 0 (07:05:07Z → 07:05:30Z); sha256 ok 5d39390aba92…; installed pin 55c60a3b80d3; /Applications, no fallback |
| version | `tillandsias-tray 56.10.17.1 (git bf21de967, built 2026-10-17T20:26:23Z)`; `--diagnose --json` .version = 56.10.17.1, provisioned and rootfs_present true |
| reset | the installer now runs a **SOFT** reset on macOS: guest podman reset at next boot, store and sign-ins kept. It reported `disposition=Absent:REINIT-AT-INIT` ("no share is in the Keychain") |

    §1 install     PASS  exit 0, exact version, signature verified (verify.sh, tar.gz bundle)
    §2 ready       PASS  phase=Ready 07:06:09Z, 39 s after the install ended, event=Routing Proxy
    §3 quit        PASS  Apple-event quit 07:06:27Z → "Quit: VM drained cleanly" 07:06:33Z (6 s)
    §3 cloud       PASS  --list-cloud-projects rc=0, 19 repos (GitHub sign-in survived the SOFT reset)
    §3 rebuilt     PASS  localhost/ images all created 07:05:51Z → 07:06:18Z, after run_start; root 1.8G of 20G
    §4 forge try1  FAIL  --opencode ~/src/tillandsias, 07:07:35Z → 07:20:39Z, rc=1:
                           "Failed to start router … podman container operation exceeded its 300s budget"; router left state=created.
                           Guest: forge image tagged 07:10:29Z, then no podman activity until 07:13:55Z
                           fail:managed-service-death:service=tillandsias-vault:state=unknown, while vault[1391] kept logging;
                           router container create + conmon 07:15:29Z, no crun start after it.  → filed 1784-skfj
    §4 forge try2  PASS  07:21 → 07:24:24Z rc=0; the agent ran its commands; skills: project-discipline, start-a-new-project
    1750-a4re      PASS  the forge image ships /usr/local/lib/tillandsias/bash-policy-hook and a static aarch64
                           policy-bin/tillandsias-plan; the hook allows `ls` (rc 0). ~/.claude/settings.json is absent in an
                           OpenCode forge BY DESIGN (seed_claude_pretooluse_hook runs from entrypoint-forge-claude.sh only)
    end state      tray relaunched, phase=Ready 07:26:00Z

## Ledger claims

**NO LEDGER ROW for v56.10.17.1** in README.md at bf21de967 or on linux-next 50c44138d (the newest row is v56.10.16.2). That is a finding for the release skill's append step. The claims below come from the GitHub release notes instead.

- EXERCISED: 1750-a4re (above), 1743/1705 skills linked in OpenCode (above), the install/sha/signature path.
- NOT CHECKED: 1719-83po slice 3, "the macOS tray shows Cloudflare Login while none is stored" (#482). Checking it needs a menu open, and this lane does no GUI scripting. 1772-irs3, the read-only Cloudflare MCP tools, waits on the operator's Cloudflare sign-in (the live arm). 1771-4iw3, the --init bar naming the image and step, is Linux-only CLI.
- NOT APPLICABLE: Linux/Windows tray Cloudflare Login (#483, #484), 1725-wkfl WebKit (Linux tray).

## Findings

- **1784-skfj** (filed): the first forge launch after the reset wedged guest podman. The router run hung at conmon for the full 300 s and Vault was declared dead while running. A relaunch passed. Cause unknown; the packet asks for an automatic capture at budget-exceeded.
- **No README ledger row for the promoted stable** (reported to the coordinator; not a product packet).
