# v56.10.15.1 e2e smoke — macos FAIL (2026-10-15)

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.15.1. macOS curl-install smoke on tlatoanis-macbook-air, requested by the coordinator (macuahuitl-fedora) after the release's ledger row landed (9a0673502). This is the onboarding release, so the coordinator added three checks: the start-a-new-project skill in a forge, the 702-6jza stderr bleed, and the 1743-h9rz OpenCode checks.

**FAIL.** Two failures:
1. **Onboarding (1743-h9rz): an OpenCode forge never sees start-a-new-project.** The cause is one line, and it's on every platform, not Windows only.
2. **Forge image builds (1744-xjfw): 2 of 4 attempts on a clean disk failed.**

Install, Ready, crash rebuild, a clean quit, and sign-in survival all passed.

| | |
|---|---|
| host | Tlatoanis-MacBook-Air (tlatoanis-macbook-air), macOS 27.0, arm64, 10 cores / 16 GiB; guest 8 vCPU / 8 GiB, swap /dev/vdb 24 GiB + zram 2 GiB |
| tag | v56.10.15.1, tray git `35ca3353f`, built 2026-10-15T20:12:01Z |
| install | `curl -fsSL …/releases/download/v56.10.15.1/install-macos.sh \| TILLANDSIAS_VERSION=v56.10.15.1 bash`, exit 0 (21:10:47Z → 21:10:50Z) |
| consent | the operator's standing instruction (2026-10-12) to smoke-test every release with the default install, destructive by design; the operator was warned in-session before the run (they are away) |
| go | coordinator macuahuitl, ledger row at 9a0673502 |
| evidence | `target/smoke-e2e/` on the smoke host (install log, diagnose JSON, forge transcripts, saved guest console) |

    §1 install     PASS  exit 0  sha256: ok (fea3efb5442a…)  installed: version=56.10.15.1 pin=55c60a3b80d3
                            --version = "tillandsias-tray 56.10.15.1 (git 35ca3353f …)"; /Applications, no fallback
                            reset: SOFT ("derived state cleared — store and sign-ins kept")
    §2 ready       PASS  launch 21:10:50Z → phase=Ready 21:11:29Z (39 s)
                            --diagnose --json: version 56.10.15.1, provisioned, rootfs_present
    §3 crash       PASS  kill -9 at 21:12:05Z, relaunched: "reset: REBUILD (unclean previous stop; … sign-ins are kept)",
                            fresh Fedora Cloud image at 21:12:58Z, phase=Ready 21:13:38Z
    §4 quit        PASS  Apple-event quit 21:22:50Z → "Quit: VM drained cleanly" 21:22:57Z (7 s); again 22:00:18Z → 22:00:25Z
    sign-in        PASS, with a p1 delay: never lost (the identity disk's vault-data dates from Oct 13), but the cloud list
                            stayed at 0 entries for ~15 min after each boot (1744-jp5x below)
    onboarding     FAIL  /opt/skills/start-a-new-project ships; no forge-level link exists, and the OpenCode agent
                            does not list it (1743-h9rz below)
    forge build    FAIL  2 of 4 clean-disk builds failed (1744-xjfw below)
    702-6jza       NOT OBSERVED in an attached TUI (see below)

## The onboarding check (coordinator's 1743-h9rz request)

In a real OpenCode forge started by the release binary (`tillandsias-tray --opencode ~/src/tillandsias --prompt …`; run of 22:33:10Z → 22:38:47Z, exit 0), the agent ran the coordinator's command. It added a trailing period to the last path; the other three paths are what matter:

```
ls: cannot access '/home/forge/.config/opencode/skill': No such file or directory
ls: cannot access '/home/forge/.config/opencode/skills': No such file or directory
ls: cannot access '/home/forge/.claude/skills': No such file or directory
```

An earlier run (21:26Z) showed `/opt/skills/start-a-new-project/SKILL.md` present, with its frontmatter `name: start-a-new-project`, and also `~/.codex/skills` and `~/.gemini/skills` absent.

Asked to list its skills from its own tool listing, the agent answered:

```
SKILLS-I-CAN-LOAD
advance-work-from-plan, build-install-and-smoke-test-e2e, build-macos-tray, build-windows-tray,
coordinate-multihost-work, customize-opencode, diagnose-forge, forge-continuous-enhancement,
forge-quick-intro, haiku-delegate, hello-world, merge-to-main-and-release, meta-orchestration,
multihost-orchestration, openspec-apply-change, openspec-archive-change, openspec-bulk-archive-change,
openspec-continue-change, openspec-explore, openspec-ff-change, openspec-new-change, openspec-onboard,
openspec-propose, openspec-sync-specs, openspec-verify-change, probe-macos-tray-on-windows,
smoke-curl-install-and-test-e2e
```

That list is exactly the `.opencode/skills/` of the checkout the forge was seeded from (host `~/src/tillandsias` main at 341ab0010, 2026-08-25, which predates start-a-new-project), plus `customize-opencode`, which isn't in this repository and so is presumably one of OpenCode's built-ins. So OpenCode does read project-level `.opencode/skills/`. It gets nothing from the forge-level generic skills, because no forge-level link exists.

**Cause (a), with its line.** `images/default/entrypoint-forge-opencode.sh` still loads the profile like this:

```bash
if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then
    source /opt/config-overlay/mcp/agent-profile.sh
fi
```

The image never installs that path; the Containerfile copies `config-overlay/mcp/` to `/home/forge/.config-overlay/mcp/`. So `agent-profile.sh` never runs, and neither does its `link_forge_generic_skills`. 1517-p83m (completed) moved the Claude, Codex, Antigravity and opencode-web entrypoints to lib-common's `load_agent_profile` and missed this one. The line is the same at the tag and on linux-next. The fix is one line plus a fixture asserting every `entrypoint-forge-*.sh` calls `load_agent_profile` and none names `/opt/config-overlay`. Recorded as an event on 1743-h9rz.

Still open after that fix, as cause (b): whether the shipped OpenCode reads `~/.config/opencode/skill` or `skills`. No link was ever made, so this run can't tell. A Claude-path measurement (the default agent) was attempted and lost to the 1744-xjfw lockup; by source, the Claude entrypoint calls `load_agent_profile` and so links `~/.claude/skills/start-a-new-project`. That's a source read, not a measurement.

## 702-6jza / 1741-xq7d stderr bleed

**Not observed in an attached TUI.** An attached agent TUI is opened from the tray menu, which needs the operator, who is away. As a proxy, the `--opencode` one-shot stream had 16 `[tillandsias]` lines, all before the agent's first output (workspace progress, image-ensure notices, the seed, swap and chown warnings) or after it exited (lane cleanup). There were none between the agent's start and its exit. That isn't evidence about the attached-PTY path 1741-xq7d fixes.

## Findings

- **1743-h9rz (p1, existing; root cause added)**: see above. It's not Windows-specific; every platform's OpenCode forge is affected.
- **1744-jp5x (p1, new)**: the guest's GitHub token rotation runs its first due-check before Vault is up. `VaultGitHubTokenStore::read_bundle` answers `Ok(None)` when the Vault container isn't running, so the check reads `NoToken`, prints nothing, and sleeps the full 15 minutes. Measured: relaunch 21:39:45Z, Ready 21:41:17Z, the list at "(0 entries)" from 21:41:33Z, and `--list-cloud-projects` failing ("containerized gh exited with status 1") after a 4.3 KB api.github.com exchange. Then at 21:56:51Z github-login updated and 16 entries loaded. The sign-in was intact the whole time. Probably also explains the 13.1 "fetch unconfirmed … 0 entries" seen in the 14.1 report.
- **1744-xjfw (p1, new)**: forge image builds on the macOS guest. Clean-disk attempts: 21:26Z OK (10.5 min); ~22:03Z in-guest `tillandsias-headless --init` wedged the guest in a `kswapd0` soft lockup on CPU 3 (up to 943 s, with RCU stalls; both swaps active; console saved as `target/smoke-e2e/11-console-kswapd-lockup.log`); 22:27Z on a freshly rebuilt disk, the forge ensure helper exited 101 with nothing in its log beyond the forge-base pull (a fail-loud gap); 22:33Z OK on the same disk (5.6 min). One buildah step peaked at 4.2 GiB in an 8 GiB guest. That memory pressure caused either failure is not established.
- **1744-jrjw (p2, new)**: the 21:26Z `--opencode` run exited 0 without a clean power-off line, and the next tray launch REBUILT the guest, losing the forge image it had built. The 22:33Z run stopped cleanly, so it's intermittent (1 of 2). Also, the CLI boot modes boot a disk the tray would rebuild, and a clean CLI stop then removes `vm-running.marker`, so an unclean disk ends up accepted as clean. Measured here: after a forced stop, an `--opencode` build on that disk died with a Go register dump. That failure is discounted in 1744-xjfw's count.
- **Noise, not filed**: `blocked:cloudflare-token-rotation-failed:read:vault-unavailable` appears on every guest boot, because the Cloudflare scheduler (1505-iysn) fails closed before Vault is up and then retries. That's correct behaviour, but it's a "blocked" line on every boot; 1744-jp5x's fix (start rotation after the Vault bootstrap) would remove it too.
- **Checked, not a finding**: the tray logs "recorded in …/unclean-rebuilds.log", and the file is absent after the quit. That's by design: `mark_vm_stopped_cleanly` removes it on a clean stop.
- **Checked, not a finding**: after the install, the macOS keychain holds only the `tillandsias-vm-uuid` anchor (service `tillandsias`). On macOS the Vault shares live on the identity disk (`fallback_vault-*` dated Oct 13), so this keychain doesn't say whether the sign-in survived.

## State left behind

Tray v56.10.15.1 relaunched at 22:39Z, phase=Ready, with no rebuild. Forge images were built in the guest at 22:33Z.
