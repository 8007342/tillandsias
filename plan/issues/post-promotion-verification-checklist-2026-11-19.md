# Post-promotion verification checklist

Generated 2026-11-19 by calmecacpilli from the rows tagged
"Verify on next stable (live checks run on stable releases)" in the
tech-debt triage (PRs #1165 and #1167; order 2112-ebtv). Run it after the next
promotion to stable, against that stable release. Close each row with
`tillandsias-plan set-field <id> status verified --evidence "<release> <host> <date> <result>"`.

Who: **operator** means you, the human: these are plain asks, a minute each. **smoke** means a smoke
host (yoga, lenovinha, macbookair, yolanda, as the platform says) runs the named check.

Counts: Linux 55, macOS 21, Every platform (Linux, Windows, macOS) 3, Windows 4; operator 9, smoke 74; total 83.

## For the operator (plain asks)

- [ ] **1247-amcu** (Linux): Read the nine error messages listed on this row and say whether each one tells you what went wrong and what to do next.
- [ ] **1725-5uue** (Linux): Approve (or reject) the browser-window design on this row.
- [ ] **1779-sq9g** (Linux): Read the forge-diagnostics-scope spec and say yes or no.
- [ ] **1835-v7vx** (Linux): Glance at the benchmark results on the GPU machine and say whether they look right.
- [ ] **2018-cabd** (Linux): After the next stable install on macuahuitl, tell us if you still get any unexpected login prompts.
- [ ] **1718-adra** (macOS): On your Mac, run the Cloudflare sign-in once and tell us whether the permission screen lists the expected permissions.
- [ ] **1719-83po** (macOS): On your Mac, using the released app, use the Cloudflare tray item once and tell us whether it finishes.
- [ ] **1758-wdvf** (macOS): On your Mac, sign in to Cloudflare with the device code once and tell us whether it works.
- [ ] **1886-hf9j** (macOS): On a Mac with Touch ID, approve two actions and tell us whether Touch ID asked twice.

## Linux — smoke host (50)

- [ ] **1254-47xd**: AMD GPU host: the container lane gets its render node; the matrix line says schedulable
- [ ] **1255-rvr7**: skills-canonical litmus on Linux across tiers (absolute-path and dir-symlink arm)
- [ ] **1264-s4id**: live forge launch shows the push-capability report
- [ ] **1437-8c6p**: all 11 children verified, plus a Linux smoke: sign in, --reset-state, --init, Claude forge with no prompts
- [ ] **1696-gz2y**: live forge lane: browser_open window_id used by screenshot; lane isolation
- [ ] **1722-2haw**: a browser-window test tone is recorded on the host default sink
- [ ] **1723-2fiq**: live preview removal does not hang on busybox SIGTERM
- [ ] **1750-a4re**: released forge on a non-Tillandsias project: pkill -f x exits 2
- [ ] **1754-bu07**: opencode run opens a window and exits; the window is still visible 60s later
- [ ] **1761-bvyn**: fresh host browser profile opens the localhost preview with no certificate warning
- [ ] **1762-bano**: running tray renews the year-long enclave CA at launch inside the 60-day margin
- [ ] **1767-5q4b**: after the monitor-source decision, re-run browser capture denial live on Linux
- [ ] **1772-irs3**: forge read-only Cloudflare MCP tools answer against a real account
- [ ] **1774-ibyx**: live forge entrypoint sources lib-common.sh cleanly
- [ ] **1776-74hj**: a gh call rotates a due GitHub token before reading it
- [ ] **1776-d5k2**: live podman: on-demand build refuses a store too small for the image
- [ ] **1776-pr0g**: tray shows the on-demand build step while it runs
- [ ] **1776-v1t4**: live podman: the Vault image and toolchain prepare go through on-demand ensure
- [ ] **1777-yhwr**: once the chromium-framework image is built, the window lists only Speakers
- [ ] **1780-jxc3**: full ./build.sh gate run inside a forge
- [ ] **1782-bek5**: recorded host-browser interaction with the observatorium site
- [ ] **1783-k5hm**: live tray: a CLI lane it serves is refused by name
- [ ] **1787-i2ir**: OpenCode auth fixture on a host that has the forge image
- [ ] **1796-ukey**: launch under a locked keyring keeps the existing vault unseal secret
- [ ] **1804-sccl**: ./build.sh --preflight shows sccache on, then a warm build (sccache --show-stats)
- [ ] **1859-v5iv**: litmus-dead-tray-run-is-reaped (tray kill -9 then restart, no leftovers) on Linux
- [ ] **1861-nmpp**: scripts/test-studio-grapesjs.sh on a podman host (its old litmus is gone)
- [ ] **1862-wrx5**: scripts/test-studio-decap.sh on a podman host
- [ ] **1863-dmke**: scripts/test-studio-tina.sh plus a zero-egress check (its old litmus is gone)
- [ ] **1864-ay3x**: scripts/test-studio-puck.sh on a podman host
- [ ] **1919-keyc**: enclave start: healthcheck rc=0 with interval >= 30s
- [ ] **1935-svxq**: cargo test preview_probe_uses_client_sni_for_underscore_project, then a live a_b project preview via browser.open and curl
- [ ] **1978-n8c6**: podman host: test-git-mirror-vault-sink-wait-is-an-event.lua
- [ ] **1998-mvrs**: with a mirror running, restart Vault and push within 60s, plus a --github-login push
- [ ] **2005-ccli**: test-tillandsias-cache-in-image.lua on a built forge image
- [ ] **2006-rotw**: force a GitHub token-rotation failure and see the operator warned
- [ ] **2006-srcr**: fill a real forge past the old limit and commit (test-tillandsias-room.lua ok 5 arms)
- [ ] **2007-acst**: GPU studio run producing audio with a provenance record
- [ ] **2007-hear**: play audio from a forge in a host browser (test-tillandsias-listen.lua ok 7 arms)
- [ ] **2007-uvtl**: rotate the CA under a running forge (test-tillandsias-trust.lua ok 7 arms)
- [ ] **2017-flwt**: run flutter in a real forge from the cache worktree
- [ ] **2041-i3nk**: live proxy: the assets port reaches fonts.googleapis.com and is refused pypi.org
- [ ] **2053-bg68**: ETXTBSY repro loop N times under load, with a red negative control
- [ ] **2054-kiwm**: GraphRoot-under-load repro with podman
- [ ] **2067-faum**: check-forge-languages.lua inside a built forge (all four languages resolve)
- [ ] **2068-cqis**: test-audio-studio-separate.lua (CPU Demucs) on a podman host
- [ ] **2069-f58n**: flutter-lane against a silent host (no fake-host fixture landed)
- [ ] **2070-mtf9**: tray upgrade on a host with a launcher-served lane
- [ ] **2073-i4jr**: test-json-query-jq-parity.sh x20 under load (one run: ok 79/79)
- [ ] **965-hz3f**: live warm-tier model selection remains per the 2026-10-27 note

## macOS — smoke host (17)

- [ ] **1642-cc54**: macOS install smoke; recurrence seen 2026-11-07 v56.11.7.1
- [ ] **1712-3fsw**: macOS tray VM: headless browser.open 'iphone 12 pro max' returns headless:true
- [ ] **1713-1dnx**: macOS-tray forge: claude mcp list shows host-browser connected; record WSL2 too
- [ ] **1724-kcj4**: hook refuses pkill in a non-Tillandsias forge (macOS live arm PASS recorded on v56.10.16.1)
- [ ] **1744-xjfw**: five consecutive forge builds on a fresh macOS guest; record memory and swap peaks
- [ ] **1751-ipuw**: macOS: kill -9, relaunch, quit at Securing Vault; the next boot unseals
- [ ] **1752-nd3t**: macOS broken-unseal disk: the tray shows the Vault state, not Ready
- [ ] **1756-z3kz**: aarch64 macOS headless smoke: the embedded router sidecar is aarch64
- [ ] **1784-skfj**: macOS cold forge launch smoke (its named fixture is missing; e4b0cb74a shim fixture landed)
- [ ] **1785-655p**: macOS rootless first run: keep-id copy lands outside the start budget (its named fixture is missing on trunk)
- [ ] **1788-qlwq**: live arms in a new-project --opencode forge (macOS run recorded; needs acceptance)
- [ ] **1792-48yg**: macOS e2e smoke (e2e-step2-macos.sh), first podman boot in the guest
- [ ] **1794-rf3a**: macOS smoke: rootful guest preview publish reaches the router
- [ ] **1795-rtfy**: macOS smoke: browser open; the CDP socket appears
- [ ] **2004-qzem**: warm launch from a published release on the macOS M5 tier, per-step lines
- [ ] **2063-nfag**: one live Linux --copilot turn after --copilot-login (part 3 #1044 waits on darwin attestation)
- [ ] **2066-395p**: macOS VZ guest: in-forge df with a forge up, plus the discard hole-punch check

## Windows — smoke host (4)

- [ ] **1560-uam3**: Windows: the installer powershell arm; no prompt; Hyper-V and WSL swap set (check-installer-prompts.sh is not on disk)
- [ ] **1656-yhjt**: yolanda: browser.open shows a WSLg window on the Windows desktop
- [ ] **1713-3v3f**: yolanda: no Windows host browser process started (process list before and after)
- [ ] **858-3v74**: Windows host: install the Task Scheduler cycle task; check-cycle-scheduler.lua reports ok

## Every platform (Linux, Windows, macOS) — smoke host (3)

- [ ] **1249-xngp**: readiness verdict names the serving lane on bare-metal, container, WSL2 and macOS
- [ ] **1430-rnpd**: a tray quit on fresh macOS and Windows VMs logs a clean guest shutdown with no drain_timeout force-stop
- [ ] **776-jcf3**: a forge on a host with no ~/src/<project> clones from the mirror, commits, pushes and verifies upstream, on Linux, Windows and macOS
