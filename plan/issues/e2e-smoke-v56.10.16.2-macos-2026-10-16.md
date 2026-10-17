# v56.10.16.2 e2e smoke — macos PASS (2026-10-16)

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.16.2, a prerelease published 2026-10-16T15:16:11Z with 32 assets. macOS curl-install smoke on tlatoanis-macbook-air, on the coordinator's GO, with the arms 1751-ipuw (live), 1752-nd3t (live), 1744-xjfw (5th fresh-disk build), and rechecks of 1743-h9rz and 1724-kcj4's guidance.

**PASS.** Install, Ready, crash rebuild and quit pass. 1751-ipuw's live arm passes 3 of 3: after a rebuild, the first Ready already carries event=Routing Proxy, and a quit at that first Ready leaves a disk whose next boot unseals (16 repos). 1744-xjfw's fifth fresh-disk build passes. 1743 and 1724's guidance pass again.

**Not exercised: 1752-nd3t's live arm.** Its precondition, a guest Vault at OPERATOR ACTION REQUIRED, did not arise in this run, and the product's own path no longer reaches it (1751 above). Producing it deliberately takes more than corrupting the `tillandsias-vault-unseal` podman secret, because `recover_rejected_unseal_secret_once` re-derives a rejected secret from the Shamir share, which the macOS host delivers. It would need a corrupted share too, and the share guards the operator's real sign-ins, so the smoke did not take that step. 1752's fixture coverage stands; the live check stays open.

| | |
|---|---|
| host | Tlatoanis-MacBook-Air (tlatoanis-macbook-air), macOS 27.0, arm64, 10 cores / 16 GiB; guest 8 vCPU / 8 GiB |
| tag | v56.10.16.2 = `c6641b45c`; tray reports git `c6641b45c`, built 2026-10-16T15:33:51Z (17 min after publishedAt, the same pattern as 15.1 and 16.1) |
| install | `curl -fsSL …/releases/download/v56.10.16.2/install-macos.sh \| TILLANDSIAS_VERSION=v56.10.16.2 bash`, exit 0 (15:36:47Z → 15:36:57Z), sha256 ok (fda85c383b3f…), installed pin 55c60a3b80d3 |
| consent | the operator's standing instruction (2026-10-12) to smoke-test every release; warned in-session before the wipe |
| tag contents | 1751-ipuw (land ca9eaf4b5), 1752-nd3t (land 683f64c53), 1744-xjfw part 1 (5eeab661c), 1724-kcj4 (72e729513): all ancestors of the tag |
| evidence | `target/smoke-e2e/` on the smoke host |

    §1 install     PASS  exit 0, --version "tillandsias-tray 56.10.16.2 (git c6641b45c …)", /Applications, no fallback;
                            the old 16.1 tray's quit drained cleanly in 7 s
    §2 ready       PASS  phase=Ready 15:37:37Z (50 s after the install began), event=Routing Proxy; 16 repos at 15:37:54Z
    §3 crash       PASS  kill -9 15:37:55Z → REBUILD 15:37:58Z → Ready 15:39:57Z (event=Routing Proxy) → 16 repos 15:40:21Z
    §4 quit        PASS  Apple-event quit 15:40:22Z → "Quit: VM drained cleanly" 15:40:28Z (6 s); relaunch Ready + 16 repos 15:40:51Z
    1751-ipuw      PASS 3/3  each try: kill -9 → REBUILD → Apple-event quit at the FIRST phase=Ready → normal relaunch
                            try 1: REBUILD 15:41:11Z, first Ready 15:42:03Z event=Routing Proxy, drained clean, relaunch 16 repos 15:42:38Z
                            try 2: REBUILD 15:42:45Z, first Ready 15:43:34Z event=Routing Proxy, drained clean, relaunch 16 repos 15:44:19Z
                            try 3: REBUILD 15:44:26Z, first Ready 15:45:15Z event=Routing Proxy, drained clean, relaunch 16 repos 15:45:52Z
                            (16.1: the first Ready after a REBUILD carried event=Securing Vault, and a quit there broke the next unseal, 2 of 2)
                            guest journal, all 9 surviving boots: wait:ready-gate:vault=0, blocked:ready-gate=0, "was REJECTED"=0,
                            "wrong key"=0, OPERATOR ACTION=0: the gate passed on its first call every time, so the 5→30 s retry
                            and "vault said: …" paths were not exercised (headless stderr does reach the journal: checked on boot 0)
    1752-nd3t      NOT EXERCISED  no boot reached a locked Vault (see above); the tray log since the install has 12 Ready
                            lines and no "Vault locked" or "Vault starting" event; the Starting lines before each relaunch carry
                            event=tillandsias-in-vm
    1744-xjfw      PASS  5th fresh-disk build: REBUILD 15:49:36Z, then --opencode rc=0 in 253 s, image built; peak build
                            step 4.3G; 0 soft-lockup/RCU-stall lines; root 5.5G of 20G (the 16.1 builds: 4.2G, 0, 5.5G)
    1743-h9rz      PASS  in a real OpenCode forge: ~/.config/opencode/skills and ~/.claude/skills each link project-discipline
                            and start-a-new-project to /opt/skills/…; the agent's own list has 29 skills, both among them
    1724-kcj4      PASS (guidance)  ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.gemini/GEMINI.md and
                            ~/.config/opencode/AGENTS.md each resolve to ~/.config-overlay/mcp/forge-agent-guidance.md and each
                            holds the "pkill -f … killall -r" sentence; the hook arm waits on 1750-a4re (#479, next release)

## Findings

- **1751-ipuw**: the live exit criterion is met on 3 of 3 targeted tries plus §3 and the xjfw rebuild (5 rebuilds in all, every first Ready carried Routing Proxy). The root cause of the 16.1 rejection is still not named: no unseal failed, so the new "vault said: …" detail never printed.
- **1752-nd3t**: the live arm needs a decision. Either it waits for a natural occurrence (the instrumentation above will catch one), or a supervised induction corrupts the share with a backup taken first. The second risks the operator's stored sign-ins, so it isn't done without an explicit go.
- **Smoke-harness note, not a product defect**: my first guidance probe grepped the agent files' contents for the file name and got 0, because the files ARE symlinks to the guidance. The probe was rerun as readlink plus a grep for the sentence (above).
- **Release asset timing**: the build is 17 minutes after publishedAt, as in 15.1 and 16.1.

## State left behind

Tray v56.10.16.2 running, phase=Ready at 16:00:41Z, 16 cloud projects. The guest rootfs was last rebuilt at 15:49:36Z (the xjfw build). The Vault store on the identity disk was never re-initialized.
