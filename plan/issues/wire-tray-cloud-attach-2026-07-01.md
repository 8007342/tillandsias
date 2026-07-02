# Wire-tray cloud attach: transparent clone → forge launch (Windows/macOS parity with Linux tray)

- **Date**: 2026-07-01
- **Host**: windows (windows-next)
- **Status**: implemented on windows-next; macOS adoption pending (same host-shell code, needs the virtio-fs mount half)
- **Trigger**: e2e run after GitHub Login succeeded — clicking `☁️ Cloud > 8007342/visual-chess > OpenCode`
  opened a terminal that died with:
  `Error: no container with name or ID "tillandsias-8007342/visual-chess-forge" found` (exit 125).

## Root cause

The shared host-shell PTY launch path (`tillandsias-host-shell::pty::launch_spec`) assumed every
project click targets an ALREADY-RUNNING forge container:

```
podman exec -it tillandsias-<project>-forge tillandsias --<agent>
```

Two defects for cloud projects:

1. **No orchestration**: nothing clones the repo or brings the enclave up. The Linux native tray
   does this in `tray::handle_launch_cloud_project` (idempotent clone into `~/src/<name>`, then the
   standard `launch_forge_agent` pipeline); the wire trays never got the equivalent.
2. **Invalid container name**: cloud entries are `owner/repo`; podman rejects `/` in container
   names, so the exec target could never exist even post-provisioning.

## Fix (operator-ratified design, 2026-07-01)

Replicate the Linux tray behaviour 1:1, with the checkout living on the HOST:

> When clicking Cloud/<project> it is checked out into the host's `<home>/src/<project-name>`
> transparently and mounted into the forge container at launch: host → VM → container.

Three pieces:

1. **Host→VM mount (Windows half of the cross-host contract)** — `wsl_lifecycle.rs`
   `inject_bootstrap_logic` now writes `home-forge-src.mount`: a TARGETED drvfs mount of
   `%USERPROFILE%\src` at `/home/forge/src` — the pre-existing in-VM project-root convention
   (`TILLANDSIAS_IN_VM_PROJECT_ROOT`, default `/home/forge/src`; macOS mounts ~/src there via
   virtio-fs). Global `[automount]` stays disabled (zero-trust: only the src tree is exposed).
   Bonus: in-VM `EnumerateLocalProjects` now sees the host's local projects (was always `count=0`
   on Windows).

2. **Guest orchestration** — new `tillandsias-headless --cloud <owner/repo>` companion flag for the
   agent modes (`--opencode/--claude/--codex/--bash`): resolves `<projects-root>/<repo>`, clones on
   first use via the existing containerized-gh flow (`remote_projects::clone_project_from_github`,
   token from Vault, never on the VM rootfs), then dispatches to the normal full-enclave agent
   mode (`run_opencode_mode` etc.), whose `build_forge_common_args` volume-mounts the project dir
   into the forge (`-v <path>:/home/forge/src/<name>:rw`, `label=disable` → 9p-safe).

3. **Host launch mapping** — `launch_spec` cloud branch (project name contains `/`, impossible for
   local names): composes the same login-shell preamble GithubLogin uses (SELinux podman shim,
   HOME/XDG_RUNTIME_DIR for `require_desktop_user_session`, vault URL, `&&`-only for the wt.exe
   semicolon bug) + `exec tillandsias-headless --cloud '<owner/repo>' --<agent>`.
   Maintenance shell on a cloud project takes the same path with `--bash`.
   Local (no `/`) projects keep the direct `podman exec` fast path.

## Deployment notes (windows e2e, 2026-07-01)

- In-VM binary built in the tillandsias distro itself (`dnf install rust cargo gcc make`;
  `cargo build --release -p tillandsias-headless --bin tillandsias --features listen-vsock`)
  because the release pipeline only builds headless musl artifacts on tag. VERSION in the VM build
  tree pinned to `0.3.260701.1` so `ensure_versioned_images`/`git_image_tag` reuse the image set
  already present in the VM instead of rebuilding for `.2`. Revert to the released binary at the
  next tag.
- drvfs mount verified: `mount -t drvfs 'C:\Users\bullo\src' /home/forge/src` exposes the host
  tree; git-over-9p is slower than ext4 but correct (`metadata` option enabled for exec bits).

## E2E debugging findings (2026-07-02, windows)

The first live click surfaced four more defects in the clone/launch chain; all fixed on
windows-next:

1. **Clone missed the proxy-exemption pattern** (orders 116/118/119): unlike
   `run_git_image_shell`, `clone_project_from_github_with_debug` passed no proxy env, so the
   VM's global containers.conf proxy env routed vault-cli's `https://vault:8200` through squid →
   TCP reset → vault-cli exited empty → `gh auth login --with-token` blocked on stdin **forever**
   (the user-visible "cloning ... hangs"). Fix: same explicit proxy env block (`no_proxy`
   includes `vault`) as the other containerized-gh calls. This is precisely the audit gap
   order 139(b) predicted.
2. **Clone had no timeout**: bare `.output()` vs the `run_command_with_timeout` every other gh
   call uses. Fix: `CLONE_INVOCATION_TIMEOUT` (600s — moves real data, still bounded).
3. **Nothing guaranteed squid was up when the clone ran** (clone precedes the agent mode's
   enclave bring-up; after a VM restart only Vault gets auto-started by the lease acquire →
   `Could not resolve proxy: proxy`). Fix: `ensure_proxy_running` INSIDE the gh helpers, placed
   AFTER `RemoteVaultLease::acquire` — acquiring the lease can rebuild/recreate Vault (source
   digest moved) which rotates TLS secrets and tears the proxy down. Also added to
   `run_git_image_shell` so probe/list flows self-heal a dead proxy (squid Exited(139) had
   silently degraded the VM for 22h).
4. **In-VM image builds can't egress**: first-run `ensure_versioned_images` builds of
   inference/forge failed — registry pulls go through the containers.conf engine proxy env
   (needs squid up + resolvable from the HOST netns), and RUN steps on the default build
   network stalled at 0 B/s. Workaround for this e2e: manual `env http_proxy= ... podman build
   --network host` builds tagged as ensure_versioned_images expects. PROPER fix is a filed
   follow-up: image builds should either pin `--network host` + explicit no-proxy env, or the
   engine proxy env should carry a host-resolvable proxy address.

Also observed (not fixed here): `podman wait --condition=healthy tillandsias-vault` raced a
vault container restart and returned "container is stopped" as a Permanent failure while vault
came up healthy 30s later — vault bring-up flakiness, linux-owned (relates to order 139
wire-oscillation).

## Follow-ups

- macOS: same `launch_spec` change applies automatically on merge; the virtio-fs mount of ~/src at
  `/home/forge/src` must be verified on osx-next (vz.rs).
- `forge_container_name` still interpolates unsanitized names; with `--cloud` the short repo name
  is used (valid), but a repo named with exotic chars could still break — consider reusing
  `sanitize_hostname`-style cleaning for container names.
- Linux-native `git fetch` freshness step is skipped in-VM (no git on the rootfs) — the forge git
  mirror covers freshness once the container is up.
- E2E gate: `github-login → cloud list → cloud attach → forge TUI` should become a litmus
  (relates to order 139's "github-login->list e2e gate" follow-up).
- In-VM image-build networking (finding 4 above): decide host-network + no-proxy builds vs a
  host-resolvable engine proxy address; today first-run builds only work with the manual
  workaround.
- Local-attach parity: all wire-tray project clicks now go through `--cloud <name>` resolve →
  full launch (podman-exec fast path removed); revisit once a "forge already running → exec"
  optimization is wanted (must probe container existence first).
- Vault health-wait race ("container is stopped" Permanent failure during vault recreate) —
  linux-owned vault_bootstrap hardening.
