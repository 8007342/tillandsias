---
tags: [windows, wsl, wsl2, runtime, enclave, no-podman, troubleshooting]
languages: [bash, powershell]
since: 2026-04-27
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://www.msys2.org/docs/filesystem-paths/
  - https://github.com/containers/skopeo
  - https://alpinelinux.org/downloads/
  - https://registry.fedoraproject.org/
authority: vendor
status: active
---

# WSL on Windows — runtime model

@trace spec:cross-platform, spec:enclave-network, spec:forge-offline, spec:windows-wsl-runtime
@cheatsheet runtime/forge-container.md, runtime/windows-native-dev-build.md, languages/bash.md

## Provenance

- "Import any Linux distribution to use with WSL" — <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro> — fetched 2026-04-26.

  > "First you'll need to obtain a tar file that contains all the Linux binaries for the distribution. You can obtain a tar file in a variety of ways, two of which include: Download a provided tar file. ... Find a Linux distribution container and export an instance as a tar file."

  > "Once you have a tar file ready, you can import it using the command: `wsl.exe --import <Distro> <InstallLocation> <FileName> [Options]`"

- "Basic commands for WSL" — <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — fetched 2026-04-26 (re-verified 2026-04-28).

  > "`wsl --user <Username>` — To run WSL as a specified user, replace `<Username>` with the name of a user that exists in the WSL distribution."

  > "`wsl --terminate <Distribution Name>` — To terminate the specified distribution, or stop it from running."

  > "`wsl --list --running` — Lists only distributions that are currently running."

- "Advanced settings configuration in WSL (`.wslconfig` and `wsl.conf`)" — <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — fetched 2026-04-28. Authoritative reference for `WSL_UTF8`, `localhostForwarding`, `firewall`, and per-distro auto-mount behaviour.

- MSYS2 — Filesystem Paths reference — <https://www.msys2.org/docs/filesystem-paths/> — fetched 2026-04-28. Confirms the `MSYS_NO_PATHCONV=1` and `//flag` escape semantics used in the Troubleshooting section.

- skopeo (daemonless OCI registry client) — <https://github.com/containers/skopeo> — confirmed Windows binary release ~25 MB, supports `skopeo copy docker://... oci:<dir>` for non-daemon image extraction.

- Alpine minirootfs — <https://alpinelinux.org/downloads/> — confirmed signed `alpine-minirootfs-<x.y.z>-x86_64.tar.gz` published per release with SHA-256 sidecars.

- **Last updated**: 2026-04-28

**Use when**: working on Tillandsias for Windows. The Windows path uses WSL2 distros directly, with no podman/docker. A "podman image" on Linux corresponds 1:1 to a "WSL distro" on Windows.

## The mapping

| Linux/macOS (podman)              | Windows (WSL)                                                  |
|-----------------------------------|----------------------------------------------------------------|
| podman image (`tillandsias-forge`) | WSL distro (`tillandsias-forge`)                              |
| `podman create + export`          | `wsl --import <name> <install-dir> <tarball> --version 2`      |
| `podman run --rm`                 | clone distro on attach, `wsl --unregister` on detach           |
| `podman exec -u 1000 -w /x cmd`   | `wsl -d <name> --user 1000 --cd /x --exec cmd`                 |
| `podman stop`                     | `wsl --terminate <name>`                                       |
| `podman rm`                       | `wsl --unregister <name>`                                      |
| `podman ps -a`                    | `wsl --list --verbose`                                         |
| `podman events`                   | (none — poll `wsl --list --running` every 500 ms)              |
| `--network=enclave-internal`      | shared netns + uid-based iptables drop in enclave-init distro  |
| `--cap-drop=ALL`                  | `unshare --net --setuid` in entrypoint                         |
| `-v /host:/dest`                  | `/mnt/c/...` (DrvFs, automatic, no per-launch flag)            |
| `--memory=8g`                     | cgroup-v2 `memory.max` written by entrypoint inside the distro |

## Build pipeline (Windows-only, no podman)

Each enclave service is built natively in WSL, never via podman:

| Service       | Base                    | Built by                                      |
|---------------|-------------------------|-----------------------------------------------|
| forge         | Fedora 43 (container)   | `scripts/wsl-build/build-forge.sh`            |
| proxy         | Alpine minirootfs       | `scripts/wsl-build/build-proxy.sh`            |
| git           | Alpine minirootfs       | `scripts/wsl-build/build-git.sh`              |
| inference     | Alpine minirootfs       | `scripts/wsl-build/build-inference.sh`        |
| router        | Alpine minirootfs       | `scripts/wsl-build/build-router.sh`           |
| enclave-init  | Alpine minirootfs       | `scripts/wsl-build/build-enclave-init.sh`     |

```bash
# Acquire base, ONCE per host (cached under ~/.cache/tillandsias/wsl-bases/):
scripts/wsl-build/bases.sh alpine-3.20      # direct download from dl-cdn.alpinelinux.org
scripts/wsl-build/bases.sh fedora-43        # skopeo copy docker://registry.fedoraproject.org/fedora:43

# Build a service:
scripts/wsl-build/build-proxy.sh            # produces target/wsl/tillandsias-proxy.tar
```

The Containerfile under `images/<service>/` remains the source of truth: each `RUN`/`COPY` in it has a 1:1 line in the build script.

## Quick reference — verbs Tillandsias issues

```powershell
# Import a service distro (--init time):
wsl.exe --import tillandsias-proxy `
  $env:LOCALAPPDATA\Tillandsias\WSL\proxy `
  target\wsl\tillandsias-proxy.tar --version 2

# Run an agent inside a forge clone (--rm-equivalent):
wsl.exe --export tillandsias-forge "$env:TEMP\forge-$session.tar"
wsl.exe --import "tillandsias-forge-$session" `
  "$env:LOCALAPPDATA\Tillandsias\Sessions\$session" `
  "$env:TEMP\forge-$session.tar" --version 2
wsl.exe -d "tillandsias-forge-$session" --user 2003 `
  --cd /mnt/c/Users/bullo/src/myproject --exec /opt/agents/entrypoint.sh

# Detach:
wsl.exe --terminate "tillandsias-forge-$session"
wsl.exe --unregister "tillandsias-forge-$session"
```

## forge-offline on Windows

All distros share **one Linux network namespace** (Microsoft Learn confirms). forge-offline-ness is enforced two ways simultaneously:

1. **Layer 1 — uid-based iptables egress drop**, applied once at WSL VM cold-boot by the `enclave-init` distro:
   ```
   iptables -A OUTPUT -m owner --uid-owner 2000-2999 -d 127.0.0.0/8 -j ACCEPT
   iptables -A OUTPUT -m owner --uid-owner 2000-2999 -j DROP
   ```
   forge agents always run as a uid in `[2000, 2999]`. proxy/git/inference run as uids outside that range.

2. **Layer 2 — `unshare --net`** when the entrypoint exec's the agent: the agent process gets a fresh net namespace whose only interface is `lo`. A `socat` relay plumbs the agent's loopback to the proxy in the parent namespace.

The tray runs a smoke probe before every attach — if `curl https://example.com` succeeds OR `curl http://127.0.0.1:3128/health` fails, the tray refuses to attach.

## Common pitfalls

- **Don't expect per-distro network isolation**. They share netns. Every distro's `eth0` has the same IP and MAC. Use uid scoping instead.
- **`wsl --terminate` is SIGKILL**. No grace period. Run a shutdown command inside the distro first.
- **`wsl --import` of a 6 GB tarball takes ~30-60 s.** For ephemeral session distros, prefer the future copy-on-write VHDX path; the slow path is the Phase 1 fallback.
- **Bind mounts are not first-class.** Windows paths come through `/mnt/c/...` automatically; per-launch `-v` does not exist.
- **`localhost:8080` from Windows browser reaches the WSL service** because of `localhostForwarding=true` (default). LAN access requires `firewall=false` in `.wslconfig`.
- **There is NO event stream.** Tray polls `wsl --list --running` at 500 ms cadence to synthesize `start`/`stop` events.
- **A "WSL distro" is not a "container".** No `--cap-drop`, no `--security-opt`, no `--userns`. All hardening is done inside the distro by the entrypoint via `unshare`, `setpriv`, `capsh`, etc.

## Troubleshooting build steps

@trace spec:windows-wsl-runtime, spec:cross-platform
@cheatsheet languages/bash.md

Failures during `build-local.sh`, `--init`, and the WSL session-clone path are dominated by the same handful of issues. This is the triage list in priority order.

### `wsl.exe --list` parsing (UTF-16 LE BOM)

`wsl.exe` emits **UTF-16 LE with a BOM** to its console handle. Piping it into bash text tools without normalising will silently produce empty matches:

```bash
# WRONG — appears empty, or shows mojibake bytes:
wsl.exe --list --quiet | grep '^tillandsias-'

# RIGHT (per-call) — strip NULs and trailing CRs:
wsl.exe --list --quiet | tr -d '\0\r' | grep '^tillandsias-'

# RIGHT (process-wide) — set WSL_UTF8 once at script top:
export WSL_UTF8=1
wsl.exe --list --quiet | grep '^tillandsias-'      # plain UTF-8

# PowerShell equivalent — force UTF-8 on the input pipeline:
$env:WSL_UTF8 = '1'
wsl.exe --list --quiet | Where-Object { $_ -like 'tillandsias-*' }
```

`WSL_UTF8=1` is documented at <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>. Set it at the top of every script that parses `wsl.exe` output. As a defensive measure, keep `tr -d '\0\r'` on the parse pipeline anyway — older WSL builds and some PowerShell hosts ignore the env var.

### `wsl.exe --import` requires the install dir to NOT exist

The first argument to `--import` after the distro name is the **install directory** for the resulting `ext4.vhdx`. If the directory already exists (even empty), `--import` aborts with `The directory name is invalid`:

```powershell
# Idempotent import — clean slate every time:
$installDir = "$env:LOCALAPPDATA\Tillandsias\WSL\proxy"
if (Test-Path $installDir) {
    wsl.exe --terminate tillandsias-proxy 2>$null
    wsl.exe --unregister tillandsias-proxy 2>$null
    Remove-Item -Recurse -Force $installDir
}
wsl.exe --import tillandsias-proxy $installDir target\wsl\tillandsias-proxy.tar --version 2
```

```bash
# Same logic in bash (Git Bash):
INSTALL_DIR="$LOCALAPPDATA/Tillandsias/WSL/proxy"
if [[ -d "$INSTALL_DIR" ]]; then
    wsl.exe --terminate tillandsias-proxy 2>/dev/null || true
    wsl.exe --unregister tillandsias-proxy 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
fi
INSTALL_DIR_WIN="$(cygpath -w "$INSTALL_DIR")"
TARBALL_WIN="$(cygpath -w target/wsl/tillandsias-proxy.tar)"
MSYS_NO_PATHCONV=1 wsl.exe --import tillandsias-proxy "$INSTALL_DIR_WIN" "$TARBALL_WIN" --version 2
```

The `--terminate` before `--unregister` is mandatory — `--unregister` of a running distro fails with a non-obvious "Element not found" error.

### `ERROR_FILE_EXISTS` on `wsl --import` — orphaned `ext4.vhdx`

A second failure mode is `Wsl/Service/RegisterDistro/ERROR_FILE_EXISTS`. It looks like:

```
The supplied install location is already in use.
Error code: Wsl/Service/RegisterDistro/ERROR_FILE_EXISTS
```

Trigger: the install directory still contains an `ext4.vhdx` from a prior import even though `wsl --unregister <distro>` was called. `--unregister` is supposed to delete the vhdx atomically, but it can leave the file behind when:

- the distro was still mounted by another `wsl.exe` process at unregister time (the file lock survives the unregister, the vhdx is orphaned),
- the user terminated `wsl.exe` mid-shutdown (kill -9, taskkill /F),
- antivirus held the file briefly while scanning (real-time AV is the most common cause on consumer Windows installs),
- a previous import was interrupted before the vhdx was registered to a distro name.

**Fix**: `Remove-Item -Force "$installDir\ext4.vhdx"` (or `rm -f` in bash) **before** retrying `--import`. This is what Tillandsias' `init.rs` does as a defensive pre-step on every import. If the file is still locked, the remove will fail and you have a runaway WSL process — `wsl --shutdown` is the hammer.

References:
- <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro> — `wsl --import` semantics, install-location requirements
- <https://learn.microsoft.com/en-us/windows/wsl/basic-commands#unregister-or-uninstall-a-linux-distribution> — what `--unregister` is supposed to do (and the implicit caveat that it can fail silently)

### Clean-up sequence — terminate, then unregister

```bash
# Single distro:
wsl.exe --terminate "$DISTRO" 2>/dev/null || true     # SIGKILL all procs in the distro
wsl.exe --unregister "$DISTRO" 2>/dev/null || true    # delete the .vhdx

# Wipe every Tillandsias session distro:
wsl.exe --list --quiet | tr -d '\0\r' \
    | grep '^tillandsias-forge-' \
    | while IFS= read -r d; do
        wsl.exe --terminate "$d" 2>/dev/null || true
        wsl.exe --unregister "$d" 2>/dev/null || true
    done

# Nuclear — terminates the whole WSL VM (all distros across all users on this host):
wsl.exe --shutdown
```

`--terminate` is **SIGKILL with no grace period** — if you need clean shutdown, run a stop command inside the distro first (`wsl.exe -d $DISTRO -- /bin/sh -c 'kill -TERM 1; sleep 2'`).

### Detect "running" without polling — per-distro check

The tray's monitor loop intentionally does not stream events (none exist). The cheap check that synthesises a state transition is:

```bash
# Returns 0 if the distro is currently running, non-zero otherwise:
is_running() {
    wsl.exe --list --running --quiet \
        | tr -d '\0\r' \
        | grep -Fxq "$1"
}

if is_running tillandsias-forge-abc123; then
    echo "running"
fi
```

For the **PID** of a distro's `init` process (rare — usually the tray only cares about up/down), spawn a no-op exec and read `/proc/1/status` from inside:

```bash
WSL_UTF8=1 wsl.exe -d "$DISTRO" -- /bin/sh -c 'cat /proc/1/status | grep ^Pid:' \
    | tr -d '\0\r' | awk '{print $2}'
```

Polling cadence is documented in `wsl-on-windows.md` § Common pitfalls — 500 ms.

### Silent failures — `wsl.exe --export` and antivirus

`--export` writes a tarball of a live or stopped distro:

- **An open file inside the distro can wedge the export silently.** A process holding `/var/log/journal/foo.journal` open during `--export` produces a tarball that's missing entries (no error). Always `--terminate` before exporting:
  ```bash
  wsl.exe --terminate "$DISTRO"
  wsl.exe --export "$DISTRO" "$(cygpath -w target/wsl/$DISTRO.tar)"
  ```

- **Defender / corporate AV scans the tarball mid-write.** A 4 GB forge tarball can stall `--import` for tens of seconds while AV reads it cover-to-cover. Symptoms: `--import` appears to hang, no progress output, but CPU usage on `MsMpEng.exe` is pegged. Workarounds:
  - Add `target\wsl\` to Defender exclusions for the duration of the build (administrator only — ask the user, don't auto-elevate).
  - Use `--vhd <path-to-vhdx>` form when both ends of the trip are on the same host — it skips the tarball entirely.
  - Build smaller distros (Alpine minirootfs is ~5 MB, Fedora is ~80 MB; the bulk comes from `dnf install`).

- **`--export` of a recently-imported distro can fail with "device or resource busy".** Symptom: import succeeds but immediate re-export fails. Cause: the WSL VM hasn't fully released the `ext4.vhdx`. Mitigation: `wsl.exe --terminate "$DISTRO"; sleep 1; wsl.exe --export ...`.

### Path translation — `cygpath -m` (host) vs `wslpath -a -u` (inside WSL)

These are **not interchangeable**. They run in different environments and produce different forms.

| Tool        | Where it runs        | Input          | Output           | Use when                                         |
|-------------|----------------------|----------------|------------------|--------------------------------------------------|
| `cygpath -m`| Git Bash / MSYS2     | `/c/Users/x`   | `C:/Users/x`     | host-side script needs Win32 form (forward-slash, Cargo-friendly) |
| `cygpath -w`| Git Bash / MSYS2     | `/c/Users/x`   | `C:\Users\x`     | host-side script feeding cmd.exe / PowerShell    |
| `cygpath -u`| Git Bash / MSYS2     | `C:\Users\x`   | `/c/Users/x`     | host-side script normalising user input          |
| `wslpath -a -u` | inside WSL distro| `C:\Users\x`   | `/mnt/c/Users/x` | inside WSL needs Linux mount form                |
| `wslpath -a -w` | inside WSL distro| `/mnt/c/Users/x`| `C:\Users\x`    | inside WSL emitting paths back to host           |

**Preferred form on the host: `cygpath -m`** — forward-slash Windows paths are accepted by every Windows tool plus by Rust/Cargo without escape hassles. **Inside WSL: `wslpath`** — `cygpath` doesn't exist there, and the `/c/...` form is meaningless to a real Linux filesystem.

```bash
# Host-side script, calling a Windows-native exe with a Windows path:
TARBALL_WIN=$(cygpath -m "$PWD/target/wsl/forge.tar")
some-tool.exe --input "$TARBALL_WIN"

# Host-side script, calling INTO WSL with a path that WSL must resolve:
WIN=$(cygpath -w "$PWD")
WSL_VIEW=$(MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias-forge wslpath -a -u "$WIN" \
           | tr -d '\0\r')
MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias-forge --cd "$WSL_VIEW" -- /bin/bash -c 'pwd'
```

`MSYS_NO_PATHCONV=1` is required on the second call — without it, Git Bash mangles `/mnt/c/...` into `C:\msys64\mnt\c\...` before `wsl.exe` even runs. See `cheatsheets/languages/bash.md` § Bash on Windows for the full translator behaviour.

### Quick triage flowchart

```
Symptom                                       First check
-------------------------------------------- -----------------------------
"empty list" / "no match" parsing wsl.exe   set WSL_UTF8=1, pipe through tr -d '\0\r'
"directory name is invalid" on --import     install dir already exists; remove it first
"Element not found" on --unregister         distro is running; --terminate first
--import hangs for >60 s on small tarball   antivirus scan; check Defender exclusions
exported tarball is empty / corrupt         --terminate before --export
"command not found: cygpath" inside WSL     wrong tool — use wslpath -a -u
backslashes in Cargo.toml or env var        used cygpath -w; switch to cygpath -m
/bin/sh rewritten to C:\msys64\usr\bin\sh   wrap call with MSYS_NO_PATHCONV=1
```

## See also

- `cheatsheets/languages/bash.md` § Bash on Windows — companion reference for the host-side shell environment.
- `cheatsheets/runtime/windows-native-dev-build.md` — host-side build of the tray binary itself (rustup + sidecar staging).
- `cheatsheets/runtime/forge-container.md` — what the forge environment provides agents (same on Linux and Windows).
- `docs/cheatsheets/runtime/wsl/architecture-isolation.md` — Microsoft Learn deep-dive on the shared-namespace constraint.
- `docs/cheatsheets/runtime/wsl/cli-surface.md` — full `wsl.exe` verb inventory.
