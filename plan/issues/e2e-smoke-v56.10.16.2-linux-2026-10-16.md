# v56.10.16.2 e2e smoke — linux PASS, with one known open issue (2026-10-16, WebKit arm 2026-10-17)

**PASS.** Every directed arm passes on the installed release:

| Arm | Row | Result |
|---|---|---|
| The reinstall keeps Vault and the sign-ins | 1738-wqmt | PASS |
| The first rotation check doesn't read "Vault not up" as no-token | 1742-zg7r | PASS |
| A quit during the Vault bootstrap leaves a disk that unseals | 1751-ipuw | PASS, Linux analog |
| `start-a-new-project` appears in a tray-launched OpenCode forge | 1743-h9rz | PASS |
| A container Chromium window plays sound | 1722-2haw | PASS |
| No `[tillandsias]` lines in an attached TUI | 1741-xq7d | PASS so far |

**Known open issue, not a regression: 1630-pz77, raised to p1.** While the tray runs, a project with a local `~/src` clone cannot be opened, from the tray menu or from the CLI. The row measured it on v56.10.9.1, and the refusal it hits has been in stable v56.10.13.1 since d74d07f4b. By the coordinator's ruling, 16.2 is no worse than stable here, so this does not block promotion.

**1725-wkfl criterion 2 (WebKit window): PASS for reach.** It ran after the operator's session, on 2026-10-17. A WebKit window on the routed Flutter dev URL loads it with status 200, and the app connects to the dev server. The app then renders a blank page, which is filed as **1760-54sr** (p2). Chromium renders the same app, and WebKit windows are newer than stable, so this is not a regression and does not gate the verdict.

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.16.2. It is a prerelease, published 2026-10-16T15:16:11Z with 32 assets, from target c6641b45c. The coordinator (macuahuitl-fedora) gave the go once it was published. The install base was pinned with `TILLANDSIAS_RELEASE_BASE=…/releases/download/v56.10.16.2`.

| Platform | Host | Result | Evidence |
|---|---|---|---|
| linux | lenovinha-silverblue (Fedora Silverblue) | PASS v56.10.16.2, with 1630-pz77 open (pre-existing) | Curl install on the host, then the installed tray, then tray-launched OpenCode forges (visual-chess, lakanoa) and a container Chromium window |

## Deviations from the runbook

- **§2 not run, by operator ruling (2026-10-15).** There was no `podman system reset --force` by hand and no `clear-vault-host-credentials.sh`. The dev runtime is ephemeral, but the Vault contents and the keyring share must survive. The installer's own SOFT reset ran.
- **Vault store backed up first.** Before arm 1751, the store was copied with `podman unshare cp -a` to `~/.cache/tillandsias/vault-data.smoke-backup-20261016` (688 KB, same size as the original). Nothing was read. The backup was not needed.
- **§4 replaced.** The opencode meta-orchestration run was replaced by the coordinator's directed arms.

## Sections

### Pre-flight — PASS
- Sibling heads at start: main c6641b45c, linux-next 75850c8a0, windows-next b38f71052, osx-next 49731c152.
- The keyring was unlocked (`Locked=false`).
- The credential probe read `credential-warm` both before and after the run. `vault-shamir-share-v1` was created 2026-09-26T02:26:06Z, and that stamp is unchanged. Metadata only.

### §1 curl install — PASS
- install rc=0.
- `tillandsias --version` reads `Tillandsias v56.10.16.2`.
- The installed binary's sha256 prefix `8c6894f961e0eda6` equals the `tillandsias-linux-x86_64` line in SHA256SUMS.
- The terminal got 36 lines with 0 `[tillandsias]` or debug lines. The setup detail went to `setup.log`: 120 lines, 0 error, panic or fail.

### 1738-wqmt: Vault kept — PASS
- `setup.log` says `reset: SOFT`, and then `reset: Vault store kept (Verified:KEEP) — share vault-shamir-share-v1 present`.
- The tray's Vault bootstrap logged `preserving existing data volume`, then `vault healthy (initialized=true sealed=false)`.
- `cloud refresh: loaded 16 repos from gh` followed within seconds of the tray start.

### 1742-zg7r: first rotation check — PASS
- The tray started at 15:43:52.771Z. Its first checks ran before Vault was up:
  - `blocked:github-token-rotation-failed:read:vault-unavailable`
  - `blocked:cloudflare-token-rotation-failed:read:vault-unavailable … retried automatically`
- Neither check read the down Vault as `no-token` and parked for 15 minutes, which was the bug.
- The Vault container started at 15:43:53.88Z and wrote its policies at 15:43:57Z.
- At 15:44:53.086Z, about 60 s later on the error backoff, the Vault audit shows `read secret/data/github/token` and `read secret/data/github/refresh`. Paths and times only.
- The tray then logged `ok:github-token-rotation:not-due:expires_at=1792184002`.

### 1751-ipuw: quit during the Vault bootstrap — PASS, Linux analog, 3 of 3
The macOS "phase=Ready while Securing Vault" window is a guest phase that the Linux tray does not have. The Linux equivalent was run instead:
1. Stop the tray and remove the Vault container, so the bootstrap runs again.
2. Start the tray and stop it at a chosen point in its Vault bootstrap.
3. Relaunch and read the outcome.

| Arm | Quit point | Relaunch |
|---|---|---|
| a | no trigger fired (the unseal secret already existed and was reused), so the quit came 2 min in, after a full start | `vault healthy … sealed=false`, `loaded 16 repos` |
| b | the unseal podman secret was removed first, and the quit came **78 ms** after `creating podman secret tillandsias-vault-unseal (32 bytes from HKDF)` | `secret … already exists; reusing it unchanged (verify-before-persist)`, `vault healthy … sealed=false`, `loaded 16 repos` |
| c | secret removed again, quit at `waiting for podman health status=healthy` | the same: unsealed, 16 repos |

- No relaunch printed `wrong key` or `OPERATOR ACTION REQUIRED`.
- The macOS live arm stays the Mac's.

### 1743-h9rz: onboarding skill — PASS
- The forge was launched from the tray menu: dbusmenu `Event clicked` on Cloud → OpenCode → 8007342/visual-chess, the same item a click sends.
- Its forge `tillandsias-visual-chess-forge` has `~/.config/opencode/skills/` (plural) with `start-a-new-project -> /opt/skills/start-a-new-project` and `project-discipline -> /opt/skills/project-discipline`.
- OpenCode in that forge listed 14 skills, `start-a-new-project` and `project-discipline` among them. It answered "Yes, start-a-new-project is among them."
- The v56.10.15.1 FAIL is fixed on Linux.

### 1722-2haw: sound from a container Chromium window — PASS
- **The window.** In the tray-launched lakanoa forge, the agent called `publish_local {"category":"WEB","runtime":"auto"}`. It served `https://www.lakanoa.localhost:18443` with runtime wrangler and `route_ready:true`. The agent then called `browser.open` with that URL.
- **The operator heard it.** The operator played the arkanoid game in that window and heard its sound from the speakers.
- **The stream came from the container.** Throughout the 120 s capture, PipeWire held exactly one playback stream: sink input #476, `application.process.binary="chromium-browser"`, `application.process.host="f14b99462a61"`. That host is the hostname of the `tillandsias-browser-lakanoa-817caba02357` container.
- **The speakers carried it.** The default sink's monitor recorded signal in 111 of 118 s, with peaks of 1,300 to 4,000 out of 32,767.
- **Output only.** The browser container had 0 source-outputs, so it never recorded; the only capture stream was the host's own `pacat`.

### 1741-xq7d: clean attached TUI — PASS so far
- The operator saw no `[tillandsias]` lines over the tray-launched OpenCode TUIs, through a long development session afterwards. They will report it if one shows up later.
- The forge's `attached-sessions/<container>.log` holds the lifecycle events instead (container_start and the rest).

### 1725-wkfl criterion 2: WebKit window — PASS for reach; the app renders blank (1760-54sr)
- **First attempt, 2026-10-16.** It was in progress in the lakanoa forge when the operator started their own development session there. I stopped it.
- **Rerun, 2026-10-17.**
  1. Clicked the tray menu at 02:25Z, which started a fresh lakanoa forge.
  2. The forge agent ran `flutter run -d web-server` in `arkanoid_game/`. Its log: "Dev server routed: open https://flutter.lakanoa.localhost:18443/".
  3. One `browser.open` with the "iPhone 15" preset started `tillandsias-browser-lakanoa-24a741964d96`, image `tillandsias-webkit:v56.10.16.2`, at 03:21:22Z.
- **What the window logged:** `webkit-window: loopback relay 127.0.0.1:18443 -> 10.89.1.2`, then `webkit-window: loaded https://flutter.lakanoa.localhost:18443/ status=200`. The flutter run log then printed `Debug service listening on ws://…`, so the app's JavaScript ran and reached the dev server.
- **What the operator saw** while it was alive: "a playwright window open in portrait aspect ratio at https://flutter.lakanoa.localhost:18443/ but no app shows up, blank screen".
- **Verdict:** criterion 2 ("loads it") holds. That is the routing reach 1725-wkfl was about. The blank render is filed as 1760-54sr; Chromium windows on the same server read `document.title = "Lakanoa"`.
- **An earlier attempt the same night** had its windows SIGKILLed at 02:33:34Z, when its agent run ended. That is 1754-bu07 again: the operator never saw them.

## Findings

- **1630-pz77, raised to p1. Pre-existing, not a regression.** The tray binds `<project>-default/mcp.sock` for every project under `~/src`. The lane it launches calls `start_mcp_socket_server_for_lane`, which refuses that socket as `mcp socket already has a live owner`. Measured:
  - `tillandsias --opencode ~/src/hello-world` → exit 1.
  - The tray menu's OpenCode → lakanoa with `~/src/lakanoa` cloned → the lane died, leaving its `--hold-window` terminal open.
  - visual-chess (no clone), and lakanoa once the clone was removed and the tray restarted, both opened.
  - The row first measured this on v56.10.9.1 (yoga). The refusal (d74d07f4b) is in stable v56.10.13.1. This run measured the row's UNMEASURED case, a launch with the tray already running.
- **1754-bu07, filed (p2).** A `browser.open` window opened by a one-shot `opencode run` was SIGKILLed about 20 s after that run exited. The window and its forwarder were both killed (`exit_code=137`, 16:09:22 → 16:09:42Z). The agent had already reported the window open (`headless:false`, a window_id). The same call from a session that stayed alive kept the window up. The hypothesis is a session-scoped lifetime.
- **1760-54sr, filed (p2).** A Flutter app renders blank in a WebKit window, although the page loads and the app connects (above).
- **Host-browser certificate warning, to be filed** (the operator, via the coordinator). The operator opened `https://www.lakanoa.localhost:18443/` in their own host browser and had to accept a certificate warning, a step that prompt-to-app onboarding should not have.

## Provenance

Run by lenovinha (Claude, session fa3e1fe9), 2026-10-16T15:36:48Z to about 20:05Z (the sound arm ran at 19:55Z, after the operator returned), at the coordinator's direction. Evidence is in lenovinha's `target/work/wt-smoke16/target/smoke-e2e/`:
- install and setup logs;
- tray stdio logs;
- the per-arm 1751 quit and relaunch logs;
- the Vault audit extract (`03-vault-audit-github.tsv`, paths and times only);
- forge skill links and the OpenCode skill listing;
- the 1630 reproduction logs;
- browser.open transcripts;
- the PipeWire stream log and the per-second monitor levels (the raw capture was deleted).

No secret value was read.
