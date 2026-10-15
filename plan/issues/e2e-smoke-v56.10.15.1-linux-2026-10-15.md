# v56.10.15.1 e2e smoke — linux FAIL (2026-10-15)

**FAIL on onboarding (1743-h9rz).** The installer, the sign-in survival (1738-wqmt), the browser window (1725-cgh2) and the nested cold-start run all pass. But an OpenCode forge launched through the CLI lane does not see `start-a-new-project`, so this release's headline feature is missing on Linux too, not only on Windows. The fix is PR #461.

**Signature: `cosign:could-not-run:cosign-absent`.** cosign is not installed on lenovinha, so the artifact's AUTHENTICITY was not verified. Its integrity was: the installed binary's sha256 `6dc72c73…8f0427` equals the release asset's, and install.sh checked SHA256SUMS.

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.15.1, ledger row on trunk at 9a0673502. The coordinator (macuahuitl-fedora) gave the go once the assets were up. Install base pinned with `TILLANDSIAS_RELEASE_BASE=…/releases/download/v56.10.15.1`. The installer banner said "Channel: stable" because the override replaces the channel URL.

| Platform | Host | Result | Evidence |
|---|---|---|---|
| linux | lenovinha-silverblue (Fedora Silverblue) | FAIL v56.10.15.1 (onboarding) | curl install on the host, then the installed tray, then a live OpenCode forge; plus nested cold-start run v56.10.15.1-20261015212804: `ok:cold-start-acceptance:v56.10.15.1:served:https://www.macron.dev.localhost:18443:http=200:lakanoa-shape=built-nested-served:router-failure=step-qualified:recovered:app-dir=served:project=bc47e63a459f27a7bf44189eb079cf7b3423588f:flutter=hot-reload-seen:regime=release` |

## Deviation from the runbook, by operator ruling

§2 was **not run**: no `podman system reset --force` and no `clear-vault-host-credentials.sh`. The operator ruled on 2026-10-15 that the dev runtime is ephemeral, but that the Vault contents and the keyring unlock share must survive a reinstall, and this run's purpose (a) was to prove exactly that. Running the clearer would have destroyed the evidence under test. The clean-room property was covered instead by the nested cold-start run, which starts from an empty substrate with no keyring and a fresh Vault.

The §4 opencode meta-orchestration run was replaced by the coordinator's three directed checks (a), (b) and (c).

## Sections

| Section | Result | What was observed |
|---|---|---|
| Pre-flight | PASS | The ledger row for v56.10.15.1 is present. Sibling heads: main 35ca3353f, linux-next 9a0673502, windows-next b38f71052, osx-next 49731c152. The keyring was unlocked (`Locked=false`) before the install and before every tray start. The credential probe read `credential-warm`; `vault-shamir-share-v1` was created 2026-09-26T02:26:06Z (metadata only). |
| §1 curl install | PASS | install rc=0 in about 7 minutes. `tillandsias --version` reads `Tillandsias v56.10.15.1`. 33 localhost/tillandsias image tags were present after reprovision. |
| §1s signature | COULD-NOT-RUN | `cosign:could-not-run:cosign-absent`. The asset sha256 matches the installed binary (see above). |
| (a) 1738-wqmt: install output | PASS | The terminal got 26 lines: banner, download, checksum, "Getting Tillandsias ready…", the setup-log path, and "Tillandsias is ready". No debug or `[tillandsias]` lines. The SOFT reset ran into `~/.local/state/tillandsias/setup.log` (120 lines, 0 error/panic/fail). |
| (a) 1738-wqmt: Vault store kept | PASS | setup.log says `reset: SOFT` and `Vault store kept (Verified:KEEP) — share vault-shamir-share-v1 present`. `vault-data`'s core and barrier files (`_seal-config`, `_shamir-kek`, `_mounts`) still date from 2026-09-25, so Vault UNSEALED the existing store rather than creating a new one. The keychain share's created/modified stamps are unchanged. |
| (a) 1738-wqmt: sign-ins survive | PASS | Evidence is the Vault audit log, paths and times only, never values. The GitHub token and refresh token the operator wrote from the old v56.9.27.2 tray at 04:14Z were read successfully by the new tray at 21:18:12Z. The rotation used the surviving refresh token at 21:41:48Z (`ok:github-token-rotation:rotated`). The next tray start ran `cloud refresh: loaded 16 repos from gh` and refreshed `github-app-user.tsv`. Claude (`claude/oauth`) and Codex (`codex/oauth`) records are in the same unchanged store; they were not read after the upgrade. |
| (a) finding: rotation reads Vault-not-up as no-token | FINDING → 1742-zg7r | At each tray start the GitHub rotation runs before Vault is up and reports `ok:github-token-rotation:no-token`, then waits 15 minutes. Cloudflare's says `vault-unavailable` in the same second. The access token had expired by the upgrade, so the cloud project list failed for about 23 minutes with an EMPTY reason, because the gh script's `gh auth login … >/dev/null 2>&1` under `set -eu` swallows it. The credential survived; this was a delay plus an unexplained error. |
| (b) 1725-cgh2: window first navigation | PASS | Nested cold-start arm 7d: `browser.open https://flutter.macron.dev.localhost:18443/` returned a window, and its FIRST navigation booted the app (title `HOT-RELOAD-BEFORE`). An edit plus `r` reloaded in 230 ms (title `HOT-RELOAD-AFTER`), a screenshot was kept, and `q` left 0 Flutter siblings and route 404. The run's evidence contains no `ERR_NETWORK_CHANGED`. |
| Nested cold-start acceptance | PASS | Install rc=0 (sha256 matches SHA256SUMS). The macron.dev forge was up on attempt 1 after 65 s. publish_local auto returned 200. Lakanoa-shape was refused before its build, naming the build command, and served after it. App-dir confinement refused `../escape` and served `site-app`. The forced router failure was step-qualified, then recovered. Host keychain metadata was identical before and after. |
| (c) onboarding skill in an OpenCode forge | **FAIL → 1743-h9rz** | `tillandsias --opencode ~/src/hello-world --prompt …` on the installed v56.10.15.1, which is the CLI lane the tray opens. Its forge had NO `~/.config/opencode/skill`, `~/.config/opencode/skills`, `~/.claude/skills` or `~/.agents/skills` (agent's `ls` and a host-side `podman exec` agree). The agent's skill tool listed `customize-opencode` and six `openspec-*` project skills, and it said "`start-a-new-project` is not among them". The image does ship `/opt/skills/start-a-new-project/SKILL.md`, and the profile links it when sourced. Cause (a): `entrypoint-forge-opencode.sh` sources the profile from `/opt/config-overlay`, which doesn't exist; 1517-p83m missed this lane. Cause (b): the OpenCode link targets `skill/`, while OpenCode searches `skills/`. Cause (c), frontmatter, is ruled out. Same result as the Windows lane, so it is a product bug. Fix and discovery fixture: PR #461. |

An earlier (c) check in this run passed by sourcing the profile by hand in a throwaway container. That only proved the profile works when something sources it. The forge launch above is the check that counts, and it supersedes the earlier one.

## Rows

- 1738-wqmt: reinstall proof recorded above (PASS). It can close on this report.
- 1725-cgh2: verified on the release (already completed on land evidence).
- 1742-zg7r: filed from this run (p2).
- 1743-h9rz: reproduced on Linux; fix in PR #461.

## Provenance

Run by lenovinha (Claude, session fa3e1fe9), 2026-10-15T21:10:44Z to 22:31Z, at the coordinator's direction. Evidence lives in lenovinha's `target/smoke-e2e/` (install, setup and tray logs, credential probes, the OpenCode probe transcript, the forge home listing) and in `target/work/cold-start-acceptance/v56.10.15.1-20261015212804/evidence`. No secret value was read. Vault evidence is audit-log request paths, operations, error fields and times only.
