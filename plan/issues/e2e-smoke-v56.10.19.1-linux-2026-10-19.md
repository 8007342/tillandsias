# E2E smoke v56.10.19.1 — linux — PASS v56.10.19.1 (2026-10-19)

The linux row of the release smoke for tag v56.10.19.1 (main b2f2f4766; a
prerelease, while the stable channel still resolves to v56.10.17.1). The
evidence is the kind `scripts/promote-stable.sh` reads before a promotion.

## Verdict

| Platform | Verdict | Host | Run |
|---|---|---|---|
| linux | PASS v56.10.19.1 | lenovinha (Fedora Silverblue, rootless podman, Wayland) | 2026-10-19T21:33:56Z onward, project ~/src/rf3c-smoke |

Every step the smoke asks for passed. One known defect is recorded below. It
is not new in this release, and its fix is in flight. It does not block the
smoke steps, but it does affect the desktop CLI path.

## Steps

1. **Install with the keyring UNLOCKED.** Before the install,
   `org.freedesktop.Secret.Collection.Locked` on the default collection read
   `false`. `install.sh` was downloaded from the v56.10.19.1 release and
   checked against its SHA256SUMS (`install.sh: OK`). It ran with
   `TILLANDSIAS_RELEASE_BASE=https://github.com/8007342/tillandsias/releases/download/v56.10.19.1`,
   the installer's documented smoke pin, because the default stable channel
   still serves v56.10.17.1. It exited rc=0 with `PENDING: none`.
   `tillandsias --version` printed `Tillandsias v56.10.19.1`. The installed
   binary's sha256 (2e1c314e…) matches `tillandsias-linux-x86_64` in
   SHA256SUMS.
2. **Vault across the install reset.** The installer's podman reset removed
   every container and podman secret. On the next start the vault logged
   `vault unsealed (sealed=false)` and `vault is unsealed and serving
   (provisioning persisted from a prior boot)`. It unsealed from the keyring
   share and kept its stored data, with no operator step. This is the path
   1796-ukey (#569) fixed, and it shipped in this release.
3. **Cold forge launch.** With no tillandsias process running, `tillandsias
   --bash ~/src/rf3c-smoke --debug` (no display, see the known defect)
   brought up proxy, vault, router, git mirror, inference and
   `tillandsias-rf3c-smoke-forge-maintenance` in 15 s. The images were
   already built by the installer.
4. **publish_local.** `publish_local {category: WEB, runtime: static,
   app_dir: build/web}` was called from inside the forge through the lane
   MCP. It returned `state=running`, `route_ready=true`, `serving=true` and
   `tls.host_trust=verified` ("The localhost-only preview CA is trusted at
   user scope by: chrome, flatpak:com.brave.Browser, firefox:…"), with the
   URL `https://www.rf3c-smoke.localhost:18443`. From the host, `curl
   --cacert ~/.local/state/tillandsias/preview-ca/preview-ca.crt
   …/version.json` returned the published `{"v":"1"}`.
5. **Diagnose.** `tillandsias --status-check --debug` exited rc=0 with
   `status-check:ok`. It started and checked status-proxy, status-git,
   status-inference and status-forge, and it kept the running lane's shared
   stack alive.

## Known defect (not new; fix in flight)

- **1798-nwpg**: on a desktop session with no tray running, `tillandsias
  --bash <project>` spawns a detached tray companion. The companion binds
  the project's lane socket, and the same launch then refuses itself with
  `refused:lane-socket-owned:rf3c-smoke-default`. This reproduced on
  v56.10.19.1 at the start of this smoke. v56.10.18.1 has it too. The
  fix is PR #579. The smoke's cold launch used the headless path (`env -u
  WAYLAND_DISPLAY -u DISPLAY`). Launching from the tray menu is unaffected.

## Not covered

- `browser.open`: it is offered only on a tray-served lane. It was verified
  on v56.10.18.1 earlier the same day (the rf3a/rtfy Linux controls), not
  rerun on this release.
- Antigravity sign-in (1799-a6xi, PR #583) is broken on this release, as
  it is since 2026-10-14. This smoke did not exercise an agent sign-in.

## Provenance

lenovinha's own run, 2026-10-19, at the coordinator's (macuahuitl-fedora)
request. The logs were kept in the session scratchpad: install.log,
smoke-cold-desktop.log, smoke-cold.log, smoke-pub.out, smoke-status.log.
