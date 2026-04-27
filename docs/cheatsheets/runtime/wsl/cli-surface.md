---
tags: [wsl, wsl2, wsl.exe, cli, control-plane, lifecycle]
languages: [bash, powershell]
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro
authority: high
status: current
---

# wsl.exe — control-plane surface area

@trace spec:cross-platform
@cheatsheet runtime/wsl/architecture-isolation.md, runtime/wsl/wslconfig-tunables.md

## Provenance

- "Basic commands for WSL" — <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — fetched 2026-04-26. `ms.date: 2025-12-01`, `updated_at: 2025-12-09`.

  Selected verbatim entries:

  > "`wsl --install` — Install WSL and the default Ubuntu distribution of Linux. … Options include: `--distribution` … `--no-launch` … `--web-download` … `--location` … `--no-distribution`: Do not install a distribution when installing WSL."

  > "`wsl --list --online` — See a list of the Linux distributions available through the online store."

  > "`wsl --list --verbose` — See a list of the Linux distributions installed on your Windows machine, including the state (whether the distribution is running or stopped) and the version of WSL running the distribution (WSL 1 or WSL 2)."

  > "`wsl --shutdown` — Immediately terminates all running distributions and the WSL 2 lightweight utility virtual machine."

  > "`wsl --terminate <Distribution Name>` — To terminate the specified distribution, or stop it from running, replace `<Distribution Name>` with the name of the targeted distribution."

  > "`wsl --status` — See general information about your WSL configuration, such as default distribution type, default distribution, and kernel version."

  > "`wsl --version` — Check the version information about WSL and its components."

  > "`wsl --update` — Update your WSL version to the latest version. Options include: `--web-download`: Download the latest update from the GitHub rather than the Microsoft Store."

  > "`wsl --user <Username>` — To run WSL as a specified user, replace `<Username>` with the name of a user that exists in the WSL distribution."

  > "`wsl --export <Distribution Name> <FileName>` — Exports a snapshot of the specified distribution as a new distribution file. Defaults to tar format. The filename can be `-` for standard input. Options include: `--vhd`: Specifies the export distribution should be a .vhdx file instead of a tar file (this is only supported using WSL 2)"

  > "`wsl --import <Distribution Name> <InstallLocation> <FileName>` — Imports the specified tar file as a new distribution. The filename can be `-` for standard input. Options include: `--vhd`: Specifies the import distribution should be a .vhdx file instead of a tar file (this is only supported using WSL 2) … `--version <1/2>`: Specifies whether to import the distribution as a WSL 1 or WSL 2 distribution"

  > "`wsl --import-in-place <Distribution Name> <FileName>` — Imports the specified .vhdx file as a new distribution. The virtual hard disk must be formatted in the ext4 filesystem type."

  > "`wsl --unregister <DistributionName>` — Replacing `<DistributionName>` with the name of your targeted Linux distribution will unregister that distribution from WSL so it can be reinstalled or cleaned up. Caution: Once unregistered, all data, settings, and software associated with that distribution will be permanently lost."

  > "`wsl --mount <DiskPath>` — Attach and mount a physical disk in all WSL2 distributions … Options include: `--vhd` … `--name` … `--bare` … `--type <Filesystem>` … `--partition <Partition Number>` … `--options <MountOptions>`."

  > "`wsl --distribution <Distribution Name> --user <User Name>` — To run a specific Linux distribution with a specific user, replace `<Distribution Name>` with the name of your preferred Linux distribution (ie. Debian) and `<User Name>` with the name of an existing user (ie. root)."

- "Import any Linux distribution to use with WSL" — <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro> — fetched 2026-04-26.

  > "Once you have a tar file ready, you can import it using the command:
  >
  > ```powershell
  > wsl.exe --import <Distro> <InstallLocation> <FileName> [Options]
  > Options:
  >     --version <Version>
  >     --vhd
  > ```"

  > "By default when using `--import`, you are always started as the root user."

- **Last updated**: 2026-04-26

**Use when**: planning what subprocess calls Tillandsias would issue if podman.exe were dropped in favour of `wsl.exe` directly. Also useful for debugging the existing `podman machine` (which uses these primitives under the hood).

## Quick reference — verbs Tillandsias would care about

| What we want | `wsl.exe` invocation |
|---|---|
| Check WSL is installed and ≥ a known version | `wsl --status` and `wsl --version` |
| List installed distros + state | `wsl --list --verbose` |
| List only running distros | `wsl --list --running` |
| Install Microsoft Store WSL with no distro | `wsl --install --no-distribution` |
| Import a Tillandsias-shipped distro from a tarball | `wsl --import <Name> <Path> <Tarball>` (defaults to WSL 2) |
| Import a pre-built ext4 VHDX in place | `wsl --import-in-place <Name> <Vhdx>` |
| Boot a one-shot command in a distro | `wsl --distribution <Name> -- <cmd> <args>` (per `basic-commands`, run as default user; add `--user root` to be explicit) |
| Boot a long-running service in a distro | `[boot] command = <cmd>` in that distro's `/etc/wsl.conf` (or `[boot] systemd = true` and a systemd unit) |
| Stop a distro now | `wsl --terminate <Name>` |
| Stop the entire WSL VM | `wsl --shutdown` |
| Snapshot a distro (e.g., golden image build) | `wsl --export <Name> <Tarball>` (or `--vhd` for VHDX) |
| Wipe a distro | `wsl --unregister <Name>` |
| Mount a host VHD into WSL | `wsl --mount <DiskPath> --vhd --name <name>` |

## What this surface gives Tillandsias today (vs. podman)

| podman primitive Tillandsias uses | WSL CLI equivalent | Equivalence |
|---|---|---|
| `podman build -t <tag> -f <Containerfile> <ctx>` | none — must build inside the distro using whatever tool is there (e.g., `wsl --exec buildah`/`docker`/`nix`) or pre-build a VHDX/tarball on the host | partial |
| `podman load -i <tar>` | `wsl --import <name> <path> <tar>` (semantically equivalent: both produce a runnable rootfs) | full |
| `podman pull` | none — pulling is an OCI operation, not WSL's concern | partial |
| `podman run --rm --name X --network=enclave -v ... <image> <cmd>` | `wsl --distribution X -- <cmd>` *after* importing the rootfs and configuring `wsl.conf` | partial — no per-command bind mounts; mounts must be set up in `/etc/fstab` or via Linux mount(8) |
| `podman exec X <cmd>` | `wsl --distribution X --user <u> -- <cmd>` | full |
| `podman stop X` / `podman kill X` | `wsl --terminate X` | partial — only one signal level (immediate); no SIGTERM grace period |
| `podman rm X` | `wsl --unregister X` | full but destructive (also wipes filesystem) |
| `podman ps -a --format json` | `wsl --list --verbose` (text only) or `wsl --list --running --quiet` | partial |
| `podman events --format json` | **none** — no event stream API | gap |
| `podman inspect` | **none** — must read `/etc/os-release` etc. inside the distro via `wsl --exec` | gap |
| `podman network create --internal` | **none** at the WSL layer — must be done inside one distro using `ip netns` + iptables | gap |
| `podman cp` | `\\wsl$\<distro>\path` from Windows side, or `wsl --exec cp` | partial |
| `podman logs X` | none — must `wsl --exec journalctl` (requires systemd) or read log files | partial |

## Common pitfalls

- **`wsl --list` is not stable JSON**. The output is human-readable text in UTF-16 LE on Windows. Tillandsias today parses `podman ps --format json`; switching would require either a JSON parser for `wsl --list --verbose` (no JSON option exists) or shelling out per-distro to a Linux command and parsing that. *No equivalent of `podman events --format json` exists.*

- **`wsl --terminate` is SIGKILL-equivalent**. There is no SIGTERM-with-grace-period, no `--time` flag. To get graceful shutdown of a service distro, you must invoke a shutdown command inside the distro first, then `--terminate` after.

- **Bind mounts are not first-class**. Unlike `podman run -v <host>:<container>`, you cannot pass a bind mount on the `wsl` command line. Host paths show up as DrvFs (`/mnt/c/...`) globally; per-distro bind mounts require `/etc/fstab` or Linux `mount(8)` *inside* the distro.

- **One distro, one rootfs, one identity**. `wsl --import <Name>` consumes the tarball into a private VHDX and treats it as a long-lived "machine". This is the opposite of `--rm` containers — there is no native ephemeral-rootfs concept.

- **No `--cap-drop` / `--security-opt` / `--userns`** at the WSL CLI level. All hardening must happen inside the distro by setting the systemd unit / launching with `unshare --user`, etc.

## Sources of Truth

- <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> (fetched 2026-04-26).
- <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro> (fetched 2026-04-26).
- `cheatsheets/runtime/wsl/architecture-isolation.md` — what wsl.exe lifecycle commands are operating on (the shared utility VM and its private namespaces).
