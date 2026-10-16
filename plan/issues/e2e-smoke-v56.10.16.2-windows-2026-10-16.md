# E2E smoke — v56.10.16.2 — Windows (yolanda) — 2026-10-16

**Verdict: PASS.** These qualifications come first:
- `cosign:could-not-run:cosign-absent`. The installer checks SHA256 only, so authenticity was NOT verified.
- **Not a credential clean room:** the operator's Credential Manager entries were kept (operator rule).
- **1751-ipuw: the window could not be reached on Windows.** In 3 of 3 boots Vault was unsealed before phase=Ready. This is not a reproduction and not proof of a fix (see the arm below).
- **Memory sampling is incomplete:** Claude Code reaped the sampler for low host memory at 15:43:19Z, 2 minutes in.

Channel prerelease, tag `v56.10.16.2` (pinned via `TILLANDSIAS_VERSION`), tray `56.10.16.2 (c6641b45c)`.
Run start 2026-10-16T15:37:12Z. Sibling heads: main c6641b45c, linux-next 75850c8a0, windows-next b38f71052, osx-next 49731c152.
Evidence: `target/smoke-e2e/` on yolanda.

The README row for v56.10.16.2 was missing at my fetch. It landed after it (ba303c632, per the coordinator), so it is not a finding.

## Steps

| Step | Result |
|---|---|
| §1 install | PASS. install_exit=0, `--version` = 56.10.16.2 (c6641b45c). |
| §1s signature | could-not-run: cosign absent. |
| §2 reset | Tray stopped. `wsl --terminate`/`--unregister tillandsias` exit 0. Runtime caches purged by name. Builder vhdx snapshotted. Credentials kept. |
| §3 cold provision | PASS. `--provision-once` exit 0, 111 s total for the §3 script. Fresh distro newer than the marker. Builder disk survived. `--status-once` Ready, podman_ready=true. `--diagnose` exit 0. |
| §4 lane | Tray running. Lane run as a `systemd-run` unit. |

## Arm 1 — 1713-1dnx live (#470): the forge uid reaches host-browser and the msg lane — PASS

Lane: `tillandsias-headless --cloud 8007342/tillandsias.org --opencode --prompt …`, run from 15:41:01Z to 15:50:33Z (cold image builds included), lane_exit=0. Output from inside the forge, verbatim:
- `id`: `uid=1000(forge) gid=1000(forge) groups=1000(forge),0(root)`.
- `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias-mcp/mcp.sock`.
- `/run/host/tillandsias-mcp/`: `drwx------ forge forge`, holding `srw------- 1 forge forge 0 … mcp.sock`. On v56.10.16.1 the same dir and socket were root-owned and gave EACCES.
- `/run/host/tillandsias-msg/`: `drwxr-xr-x forge forge`, with `dead inbox outbox receipts` all `drwx------ forge forge`.
- An MCP `initialize` + `tools/list` through `/home/forge/.config-overlay/mcp/host-browser.sh` exited rc=0. serverInfo was `tillandsias-host-services 56.10.16`, and the tool list includes `publish_local`, `browser.open`, `browser.cdp` and `browser.list_windows`, among others.

The agent's last line, `HOST_BROWSER_TOOLS=no`, is an artifact of my prompt. The prompt asked for the literal `browser_open`, but the tool is named `browser.open`, and the agent said so. The verbatim tool list above is the evidence.

Side observation (not 1dnx): `tillandsias-plan` was not on PATH in this `--prompt` lane (rc=127 for `msg whoami`). That matches the experts-build timing in 1746-4q34. The msg lane tree itself is present and forge-owned.

## Arm 2 — 1751-ipuw: quit during "Securing Vault" after Ready — NOT REACHABLE on Windows; the unseal key survived every stop

Mechanism note: this shell cannot see the tray window (`FindWindowW('TillandsiasTrayClass')` returned 0 from the agent's session), so the menu Quit could not be posted. The substitute was the Quit's own backstop, `wsl --terminate tillandsias` (notify_icon.rs Quit, step 2), issued at Ready. That is harsher than Quit, because it skips the graceful wire drain of step 1.

- **Attempt 1, unclean stop and relaunch** (Stop-Process -Force on the tray, then `wsl --terminate`, then a relaunch at 16:15:44Z). Ready came at 16:16:22Z with `last_event=tillandsias-in-vm`. The guest journal shows `vault unsealed (sealed=false)` at 16:15:50Z, 32 s BEFORE Ready.
- **Attempt 2, soft reset (`--reset-state`, the nearest analog of the macOS REBUILD) with terminate at Ready.** reset-state exit 0 at 16:18:46Z, then `wsl --terminate` at once. Vault had unsealed at 16:18:41Z, 5 s before Ready.
- **Next boot after attempt 2:** the tray relaunch reached Ready (`last_event=Setting up Git`). The journal shows `subsequent boot: using unseal key from secret` and `vault unsealed (sealed=false)` at 16:19:01Z, with no `wrong key`, `REJECTED` or `OPERATOR ACTION` lines anywhere since 16:17Z.
- `tillandsias-headless --list-cloud-projects` exited rc=1 with `vault-cli: HTTP error reading secret/data/github/token: … 404`. The store has no GitHub sign-in: the operator reported on 2026-10-16 that this tray is not logged into GitHub. This is a missing secret in an unsealed store, not the 1751 failure, which is `HTTP 400: wrong key` on unseal.

**Reading:** on Windows, Vault unseals before Ready on every boot measured (3 of 3, including the first-provision boot at 15:40:47Z). The macOS ordering (Ready while the event still says Securing Vault) did not occur. A plain stop never replaces the WSL distro's rootfs, so the unseal secret is not rewritten after an unclean stop. 1751-ipuw stays a macOS bug on this evidence. Its live exit criterion needs the macOS REBUILD path.

## Memory

- Start: 6624 MB free of 15526 MB, at 15:41:07Z.
- Lowest sampled: 3704 MB at 15:43:19Z. **The sampler was then reaped** by Claude Code for low host memory, so the true low point during the cold image builds is unknown.
- At the end of the 1dnx lane (15:50Z) there was 6521 MB free.
- Nothing in the guest was reaped: the lane ran as a systemd unit.

## Clean-up

No smoke units remain. The tray is running on v56.10.16.2 and the VM is Ready.
