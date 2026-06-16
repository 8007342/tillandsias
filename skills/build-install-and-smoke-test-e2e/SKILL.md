---
name: build-install-and-smoke-test-e2e
description: Build, install, and DESTRUCTIVELY smoke-test the current Tillandsias checkout on the host you are running on — Linux (Podman), macOS (Virtualization.framework VM), or Windows (WSL2). Detects the OS, builds + installs the locally built tray, irreversibly destroys the host's runtime substrate (Podman store / macOS VM dir / WSL2 distro), re-provisions from a pristine state, and — on Linux only — launches the forge with `/forge-continuous-enhancement`. Every issue observed is filed as a `plan/issues/` work packet.
---

# Build, Install, and Smoke Test End-to-End (OS-aware)

Validate the current checkout as a locally built operator workflow on **this
host's native runtime**. The flow is the same shape on every OS — build +
install the local tray, destroy the runtime substrate, re-provision from
nothing, observe — but the concrete commands differ per platform. Run every
gate in order and **stop at the first failure**.

| Host    | Branch         | Build               | Runtime substrate destroyed (DESTRUCTIVE)                                  | Cold re-provision        | Forge lane |
| ------- | -------------- | ------------------- | -------------------------------------------------------------------------- | ------------------------ | ---------- |
| Linux   | `linux-next`   | `./build.sh --ci-full --install` | `podman system reset --force`                                 | `tillandsias --init`     | yes        |
| macOS   | `osx-next`     | `scripts/build-macos-tray.sh`    | `rm -rf ~/Library/Application Support/tillandsias` + `~/Library/Caches/tillandsias` | `…tillandsias-tray --provision` | no (N/A)   |
| Windows | `windows-next` | `scripts/build-windows-tray.ps1` | `wsl --unregister tillandsias` (+ cached rootfs)              | tray cold launch / `--provision` | no (N/A)   |

This skill is for local-build install testing. On immutable Linux
(`/run/ostree-booted` or `rpm-ostree` present), do not run this skill; use
`/smoke-curl-install-and-test-e2e` instead. Mutable Linux, macOS, and Windows
hosts run this skill for their native local build/install path.

> Architecture note: on macOS the runtime substrate is **not** a Podman/Docker
> store and **not** Apple's `apple/container` per-container product — it is a
> single long-lived Linux VM that the tray drives directly through
> `Virtualization.framework` (`VZVirtualMachine` + virtio-vsock control wire),
> mirroring the single-VM model WSL2 gives Windows. See
> `plan/issues/apple-containerization-evaluation-2026-06-14.md` for why we use
> Virtualization.framework directly rather than `apple/container`.

## Destructive operation

This skill intentionally and irreversibly destroys the host's container/VM
runtime state. The operator selected this skill with that behavior understood.
**Do not ask for confirmation before the destruction step.**

On Tillandsias smoke hosts, destructive runtime reset is not merely allowed; it
is a required precondition for the idempotence test. If
`TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`, run the reset. Do not stop,
skip, or file a blocker because Podman will be wiped. Only refuse the reset when
the environment explicitly sets `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`.

- **Linux** — `podman system reset --force` deletes ALL Podman containers,
  images, volumes, networks, and secrets for the current user (including the
  Vault sealed store and every project mirror volume).
- **macOS** — deleting `~/Library/Application Support/tillandsias/` removes the
  VM disk (`rootfs.img`, `rootfs.qcow2`), `nvram.bin`, and `cidata.iso`; the
  next `--provision` re-downloads the Fedora cloud rootfs (multi-GB) and
  re-materializes the ext4 disk from scratch — this can take many minutes.
- **Windows** — `wsl --unregister tillandsias` deletes the WSL2 distro and its
  backing VHDX irreversibly.

These wipes are acceptable on Tillandsias smoke hosts. For a non-smoke host,
set `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` before invoking this skill; the skill
must then file a blocker instead of resetting the substrate.

## 0. Preflight

Run from the Tillandsias repository root. **Detect the OS first**, then enforce
only that OS's guards.

```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="target/build-install-smoke-e2e/$RUN_ID"
mkdir -p "$LOG_DIR"

OS="$(uname -s)"                      # Linux | Darwin | (MINGW*/MSYS* => treat as Windows)
case "$OS" in
  Linux)  HOST_BRANCH=linux-next  ; HOST_KIND=linux   ;;
  Darwin) HOST_BRANCH=osx-next    ; HOST_KIND=macos   ;;
  *)      HOST_BRANCH=windows-next; HOST_KIND=windows ;;   # PowerShell lanes below
esac
echo "host_kind=$HOST_KIND host_branch=$HOST_BRANCH" | tee "$LOG_DIR/00-host.txt"

# Common guards (all OSes):
test "$(pwd -P)" = "$(git rev-parse --show-toplevel)"
test "$(git branch --show-current)" = "$HOST_BRANCH"

git rev-parse HEAD       | tee "$LOG_DIR/00-commit.txt"
git status --short       | tee "$LOG_DIR/00-status.txt"
cat VERSION 2>/dev/null  | tee "$LOG_DIR/00-version.txt"
```

Do not switch branches automatically. A dirty checkout is a valid local build
target; record it and never modify, discard, or hide existing changes.

Per-OS build-script guard:

- **Linux**: `test -x ./build.sh`
- **macOS**: `test "$(uname -m)" = arm64 && test -x scripts/build-macos-tray.sh`
- **Windows** (PowerShell): `Test-Path scripts/build-windows-tray.ps1`

---

## 1. Build and install

### 1·Linux

```bash
./build.sh --ci-full --install 2>&1 | tee "$LOG_DIR/01-build-install.log"
BUILD_RC=${PIPESTATUS[0]}
printf 'build_install_exit=%s\n' "$BUILD_RC" | tee "$LOG_DIR/01-build-install-exit.txt"
test "$BUILD_RC" -eq 0
hash -r
command -v tillandsias        | tee "$LOG_DIR/01-installed-path.txt"
tillandsias --version         | tee "$LOG_DIR/01-installed-version.txt"
```

### 1·macOS

```bash
scripts/build-macos-tray.sh 2>&1 | tee "$LOG_DIR/01-build-macos.log"
BUILD_RC=${PIPESTATUS[0]}
printf 'build_exit=%s\n' "$BUILD_RC" | tee "$LOG_DIR/01-build-exit.txt"
test "$BUILD_RC" -eq 0

# Success criteria (per /build-macos-tray §1):
TRAY_BIN=dist/Tillandsias.app/Contents/MacOS/tillandsias-tray
test -x "$TRAY_BIN"
test -f dist/SHA256SUMS
codesign --verify --deep --strict dist/Tillandsias.app 2>&1 | tee "$LOG_DIR/01-codesign.txt"

# Install locally to ~/Applications (NEVER sudo /Applications in an unattended
# skill). Stop any running tray first, then atomic .new + mv replace.
INSTALL_DIR="$HOME/Applications"; mkdir -p "$INSTALL_DIR"
pkill -TERM -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true
sleep 2
pkill -KILL -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true
rm -rf "$INSTALL_DIR/Tillandsias.app.new"
cp -R dist/Tillandsias.app "$INSTALL_DIR/Tillandsias.app.new"
rm -rf "$INSTALL_DIR/Tillandsias.app.bak"
[[ -d "$INSTALL_DIR/Tillandsias.app" ]] && mv "$INSTALL_DIR/Tillandsias.app" "$INSTALL_DIR/Tillandsias.app.bak"
mv "$INSTALL_DIR/Tillandsias.app.new" "$INSTALL_DIR/Tillandsias.app"
INSTALLED_BIN="$INSTALL_DIR/Tillandsias.app/Contents/MacOS/tillandsias-tray"
"$INSTALLED_BIN" --version 2>&1 | tee "$LOG_DIR/01-installed-version.txt" || true
```

### 1·Windows (PowerShell)

```powershell
scripts/build-windows-tray.ps1 *>&1 | Tee-Object "$LOG_DIR/01-build-windows.log"
if ($LASTEXITCODE -ne 0) { throw "build-windows-tray.ps1 exited $LASTEXITCODE" }
# Install the freshly built tray per the repo's Windows install convention
# (scripts/install-windows.ps1 against the local dist artifact).
```

If the build, CI, install, path lookup, or version probe fails, **stop**. Do
not destroy the runtime substrate, because no valid local build was installed.

---

## 2. Destroy the runtime substrate (DESTRUCTIVE — see warning above)

Run the destructive step immediately without another confirmation.

If `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, stop here, write a plan blocker, and
push it. Otherwise continue; on Linux the Podman reset is mandatory.

### 2·Linux — Podman reset

```bash
podman system reset --force 2>&1 | tee "$LOG_DIR/02-reset.log"
RESET_RC=${PIPESTATUS[0]}; printf 'reset_exit=%s\n' "$RESET_RC" | tee "$LOG_DIR/02-reset-exit.txt"
test "$RESET_RC" -eq 0
CONTAINERS="$(podman ps -aq)"; VOLUMES="$(podman volume ls -q)"; IMAGES="$(podman images -q)"
printf '[containers]\n%s\n[volumes]\n%s\n[images]\n%s\n' "$CONTAINERS" "$VOLUMES" "$IMAGES" \
  | tee "$LOG_DIR/02-empty-store.txt"
test -z "$CONTAINERS"; test -z "$VOLUMES"; test -z "$IMAGES"
```

### 2·macOS — destroy the Virtualization.framework VM

```bash
# Stop any running tray that holds the VM handle first.
pkill -TERM -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true
sleep 2
pkill -KILL -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true

VM_DIR="$HOME/Library/Application Support/tillandsias"
CACHE_DIR="$HOME/Library/Caches/tillandsias"
{ echo "[before]"; du -sh "$VM_DIR" "$CACHE_DIR" 2>/dev/null; } | tee "$LOG_DIR/02-destroy-before.txt"
rm -rf "$VM_DIR" "$CACHE_DIR"
{ echo "[after]"; ls -la "$VM_DIR" 2>&1; ls -la "$CACHE_DIR" 2>&1; } | tee "$LOG_DIR/02-destroy-after.txt"
test ! -e "$VM_DIR"   # the whole VM state dir (rootfs.img lives at its top level) must be gone
```

> The macOS substrate is a single VFR-hosted VM, not a container store. There
> is no `podman`/`apple container` daemon to reset — the entire VM lives in
> `~/Library/Application Support/tillandsias/` (`rootfs.img`, `rootfs.qcow2`,
> `nvram.bin`, `cidata.iso` at the top level) plus any downloaded rootfs in
> `~/Library/Caches/tillandsias/`. Removing both directories is the full,
> irreversible destruction of the "MacosContainer".

### 2·Windows (PowerShell) — unregister the WSL2 distro

```powershell
# Mirrors scripts/install-windows.ps1 -Purge (the canonical destructive path).
& wsl --shutdown 2>$null
& wsl --unregister tillandsias *>&1 | Tee-Object "$LOG_DIR/02-wsl-unregister.log"
# Tolerate "no distro" — that just means it was already clean.
$registered = (& wsl --list --quiet 2>$null) -contains 'tillandsias'
if ($registered) { throw "WSL distro 'tillandsias' still registered after --unregister" }
# Also clear the cached downloaded rootfs so re-provision is truly cold.
```

Any residue (a listed container/volume/image on Linux, a surviving `rootfs.img`
on macOS, or a still-registered distro on Windows) **fails the destruction
gate**.

---

## 3. Re-provision from a pristine substrate

### 3·Linux

```bash
tillandsias --init --debug 2>&1 | tee "$LOG_DIR/03-init.log"
INIT_RC=${PIPESTATUS[0]}; printf 'init_exit=%s\n' "$INIT_RC" | tee "$LOG_DIR/03-init-exit.txt"
test "$INIT_RC" -eq 0
```

Inspect for panics, build failures, exited containers, Vault init/unseal
errors, unexpected registry pulls, and enclave-health failures.

### 3·macOS

```bash
# Cold provision: re-downloads the Fedora cloud rootfs and re-materializes the
# ext4 VM disk from nothing (this is the highest-signal step — it exercises the
# whole materialize → boot → vsock-handshake cold path). Streams JSON phases.
INSTALLED_BIN="$HOME/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray"
"$INSTALLED_BIN" --provision 2>&1 | tee "$LOG_DIR/03-provision.log"
PROV_RC=${PIPESTATUS[0]}; printf 'provision_exit=%s\n' "$PROV_RC" | tee "$LOG_DIR/03-provision-exit.txt"
test "$PROV_RC" -eq 0

# Post-provision health: the VM disk must exist again, and --diagnose --json
# must report a stable schema (per litmus:macos-tray-diagnose-cli-surface).
# NOTE: the disk is written at the top level of the state dir, not a vm/ subdir
# (provision_main writes ~/Library/Application Support/tillandsias/rootfs.img).
test -f "$HOME/Library/Application Support/tillandsias/rootfs.img"
"$INSTALLED_BIN" --diagnose --json 2>&1 | tee "$LOG_DIR/03-diagnose.json"
DIAG_RC=${PIPESTATUS[0]}; printf 'diagnose_exit=%s\n' "$DIAG_RC" | tee "$LOG_DIR/03-diagnose-exit.txt"
# exit 0=provisioned, 2=degraded are acceptable here; exit 1=hard failure is a finding.
test "$DIAG_RC" -ne 1
```

Inspect `03-provision.log` for: download/SHA-verify failures against the
manifest, ext4 materialization errors, `VZVirtualMachineConfiguration.validate`
failures (missing `com.apple.security.virtualization` entitlement), boot
hangs, or vsock control-wire handshake errors / `wire_version mismatch`.

### 3·Windows (PowerShell)

```powershell
# Cold launch re-imports the WSL2 distro from the bundled rootfs. Use the
# tray's provision/diagnose surface to confirm the distro boots and the vsock
# control wire comes up.
```

If re-provision is not healthy on any OS, **stop** — do not launch the forge;
record where and why it halted.

---

## 4. Run continuous enhancement in the build forge — **Linux only**

The `--opencode` forge lane is Linux/Podman today. **On macOS and Windows this
step is N/A** — record it as `forge: n/a (linux-only lane)` and skip to
findings.

### 4·Linux

```bash
tillandsias . --opencode \
  --prompt "Use the /forge-continuous-enhancement skill" 2>&1 \
  | tee "$LOG_DIR/04-forge-continuous-enhancement.log"
FORGE_RC=${PIPESTATUS[0]}; printf 'forge_exit=%s\n' "$FORGE_RC" | tee "$LOG_DIR/04-forge-exit.txt"
test "$FORGE_RC" -eq 0
```

Allow the in-forge agent to complete its skill, including filing and pushing
its plan work packets. Do not terminate it merely because it runs long.

---

## Findings and report

Report the commit tested, installed version, evidence directory (`$LOG_DIR`),
host kind, and the result of every reached gate. On failure, include the
failing command, exit code, and the smallest useful log excerpt.

For each distinct product issue, **de-duplicate** against `plan/issues/` and
file a ready work packet using the repository's smoke-report conventions:

- `discovered_by: /build-install-and-smoke-test-e2e (<host_kind>)`
- cite evidence from `$LOG_DIR/*` with line numbers,
- redact secrets (never paste tokens or unredacted push URLs),
- one issue per packet, always include a repro.

A clean run still gets a one-line PASS entry recording the tested commit, so
the convergence record shows the build was exercised on this host.

**Branch routing** (per CLAUDE.md canon §2 — findings live under `plan/`):

- Commit findings/ledger files to the **host branch**: `linux-next` on Linux,
  `osx-next` on macOS, `windows-next` on Windows.
- **Never** push directly to `main`, open a release PR, or `--force`.
- Do **not** implement product fixes during this skill — fixes are the job of
  `/advance-work-from-plan` workers claiming the packets you file.
- Before a successful exit, commit and push the PASS/finding report. Do not
  leave a local-only smoke result.

## Guardrails

- **Never** skip the destruction step (§2) on a Tillandsias smoke host because
  it wipes Podman/WSL/VM state. The wipe is the test precondition. The only
  supported opt-out is `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, which must produce
  a pushed plan blocker instead of a partial smoke.
- **Never** substitute a published-release binary for the local build — this
  skill tests the *locally built* tray (use `/smoke-curl-install-and-test-e2e`
  to test a published release instead).
- **macOS**: never `sudo` the install (use `~/Applications`, not
  `/Applications`); never kill a tray PID you did not spawn except in the §1/§2
  best-effort `pkill` that the install/destroy replace genuinely requires.
- Findings are intake, not authority — durable conclusions still land in
  `openspec/specs/`, `methodology/`, or cheatsheets via the normal flow.
</content>
</invoke>
