# v56.10.16.1 e2e smoke — macos FAIL (2026-10-16)

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.16.1, a prerelease published 2026-10-16T02:50:41Z. macOS curl-install smoke on tlatoanis-macbook-air, on the coordinator's GO, with four extra arms: 1743-h9rz, 1742-zg7r, 1724-kcj4 and 1744-xjfw part 2.

**FAIL**, on one new p1 that ordinary use reaches:

- **1751-ipuw (new, reproduced 2 of 2).** After a rebuild, the tray reports Ready while Vault is still being secured. Quitting in that window leaves an unseal secret Vault rejects, so the next launch has no sign-ins: the tray shows Ready, the repo list is empty, and there's no error. The store itself is intact; a rebuild recovers it.

Install, Ready, crash rebuild and a clean quit pass. Three of the four arms pass. The fourth, 1724's hook, is blocked by a second new p1, **1750-a4re**: the forge's Claude command-check hook names a binary that forge images don't ship.

| | |
|---|---|
| host | Tlatoanis-MacBook-Air (tlatoanis-macbook-air), macOS 27.0, arm64, 10 cores / 16 GiB; guest 8 vCPU / 8 GiB |
| tag | v56.10.16.1, tray git `def043785`, built 2026-10-16T03:05:53Z (after the release's publishedAt; the same pattern as 15.1) |
| install | `curl -fsSL …/releases/download/v56.10.16.1/install-macos.sh \| TILLANDSIAS_VERSION=v56.10.16.1 bash`, exit 0 (03:19:55Z → 03:20:05Z), sha256 ok (077792837177…) |
| consent | the operator's standing instruction (2026-10-12) to smoke-test every release; warned in-session before the wipe; the operator had just finished with a forge and released it |
| tag contents | 1743-h9rz (b2b2133f2), 1742-zg7r (57280bd9d via land 462), 1724-kcj4 (land 72e729513), 1744-xjfw part 1 (land 5eeab661c): all ancestors of the tag |
| evidence | `target/smoke-e2e/` on the smoke host |

    §1 install     PASS  exit 0, --version "tillandsias-tray 56.10.16.1 (git def043785 …)", /Applications, no fallback
                            the old 15.1 tray's quit: drained cleanly in 7 s; reset: SOFT (store and sign-ins kept)
    §2 ready       PASS  phase=Ready 03:20:45Z (40 s after launch); cloud list 16 entries at 03:21:01Z
    §3 crash       PASS  kill -9 03:21:23Z → REBUILD 03:21:26Z → Ready 03:22:38Z → 16 entries 03:22:55Z
    §4 quit        PASS  Apple-event quit 03:23:18Z → "Quit: VM drained cleanly" 03:23:25Z (7 s)
    1743-h9rz      PASS  in a real OpenCode forge: ~/.config/opencode/skills and ~/.claude/skills each link
                            project-discipline and start-a-new-project; the agent's own list has 29 skills,
                            start-a-new-project and project-discipline among them (15.1: 27, neither)
    1742-zg7r      PASS (code path)  first rotation check at 03:22:15Z logged
                            "blocked:github-token-rotation-failed:read:vault-unavailable" (15.1: a silent NoToken
                            and a 15-min sleep), Vault unsealed 03:22:31Z; this run's token was valid (the operator
                            had just used a forge), so "an expired token recovers fast" is not exercised
    1724-kcj4      PARTIAL  guidance PASS: ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.gemini/GEMINI.md and
                            ~/.config/opencode/AGENTS.md all link forge-agent-guidance.md, each holding the sentence;
                            hook BLOCKED: `tillandsias-plan: command not found` (rc 127) in the forge → 1750-a4re
    1744-xjfw p2   PASS  4 fresh-disk forge image builds via --opencode, each after a forced REBUILD: images built
                            every time; 0 soft-lockup/RCU-stall lines; peak build step 4.2G each; root 5.5G of 20G;
                            build 3's rc=1 was 1751-ipuw (Vault), not the image build; the runner was stopped
                            after build 4 to keep the identity disk's state intact for diagnosis

## Findings

- **1751-ipuw (p1, new)**: quitting while Ready still says "Securing Vault" breaks the next boot's unseal. First hit in xjfw build 3: REBUILD at 03:41:14Z, then Ready at 03:42:45.231Z with event=Securing Vault, and the quit 0.3 s later drained "cleanly". The next boot of that disk failed with `[vault-entrypoint] FATAL: unseal request returned HTTP 400: wrong key` → "existing unseal secret was REJECTED" → "OPERATOR ACTION REQUIRED … self-recovery is not possible". The deliberate repro gave the same result: Ready with Securing Vault at 03:55:35Z, quit 0.5 s later, then `--list-cloud-projects` rc=1 with the same text. A normal tray launch then showed Ready, cloud list "(0 entries)", and no Vault error in the tray log. A kill -9 forced a REBUILD, and 16 entries were back at 03:58:36Z. Every boot's journal says "subsequent boot … provisioning persisted from a prior boot": the store was never re-initialized. Hypothesis, not established: the quit interrupts the write of the `tillandsias-vault-unseal` podman secret on the rootfs.
- **1750-a4re (p1, new)**: `seed_claude_pretooluse_hook` puts `tillandsias-plan policy classify-bash --hook` into every forge's `~/.claude/settings.json`. The forge image never ships `tillandsias-plan`; a forge builds it only from a Tillandsias checkout's own crate, and asynchronously. In the forge: `tillandsias-plan: command not found`, rc 127, for both `pkill -f vite` and `pgrep -f vite`. Claude Code treats a hook's 127 as a non-blocking error, so outside Tillandsias forges the whole command policy (credential mutation, unquoted heredocs, 1724's rule) is silently off. Not measured: the PATH Claude's Bash tool sees; the probe ran in OpenCode's shell. The non-Tillandsias case doesn't depend on PATH.
- **1744-xjfw**: neither failure from 15.1 reproduced on the product's path, and the new fail-loud message was not exercised because no build failed. The kswapd lockup came under an in-guest `tillandsias-headless --init`, which builds every image at once; that is not a path a user takes.
- **1744-jrjw data point**: 4 of 5 `--opencode` runs logged a clean power-off. The one that didn't was xjfw build 3, the run that failed on 1751-ipuw's Vault error.
- **Release asset timing**: the tray reports `built 2026-10-16T03:05:53Z`, 15 minutes after the release's publishedAt (02:50:41Z), as in 15.1. Not a defect by itself, but "published" doesn't mean "the assets are final".

## State left behind

Tray v56.10.16.1 running, phase=Ready, 16 cloud projects after the recovery REBUILD at 03:57:29Z. The guest is on a fresh rootfs. The Vault store on the identity disk was never re-initialized (every boot's journal reports "provisioning persisted from a prior boot").
