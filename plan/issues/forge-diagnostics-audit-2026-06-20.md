# Forge Diagnostics & Performance Audit — 2026-06-20

**Origin:** In-forge run via `opencode 1.16.2`, `tillandsias-forge-base` container on `Fedora 44`
**Host hardware:** MacBookAir6,2 — Intel Core i7-4650U @ 1.70GHz (2C/4T, Haswell, 4MiB L3)
**Forge platform:** Linux (Fedora 44 Container Image), kernel 7.0.12-201.fc44.x86_64
**Container:** forge-tillandsias (no cgroup limits, 6 processes, enclave network)
**Agent:** `linux-forge-opencode-20260620T170924Z`
**Trace:** `spec:forge-diagnostics`, `spec:forge-environment-discoverability`

---

## 1. Performance Metrics

| Metric | Value | Notes |
|--------|-------|-------|
| CPU | i7-4650U @ 1.70GHz (burst ~2.9GHz) | 2C/4T, Haswell uarch, 2013 era |
| L1d | 64 KiB | per core |
| L1i | 64 KiB | per core |
| L2 | 512 KiB | per core |
| L3 | 4 MiB | shared |
| RAM total | 7.7 GiB | DDR3 (likely soldered, ~1600 MT/s) |
| RAM available | 4.9 GiB (63%) | after OS + forge |
| Swap | 7.7 GiB zram (349 MiB used) | compressed RAM swap |
| Disk | 111 GB SSD (22G used, 20%) | overlayfs on ext4 |
| DD write | ~1.0 GB/s | tmpfs (memory-backed) |
| Load avg | 0.78 / 0.50 / 0.63 | very light |
| Processes in container | 6 | forge is minimal |
| opencode RSS | ~760 MB | largest process |
| Container cgroup limits | **none** (max) | no memory/cpu caps |

### Analysis

The hardware is a 2013 MacBook Air (Haswell ultrabook). Despite its age, Linux + the bare-minimal forge container runs exceptionally well:
- 63% memory available after OS + forge
- zram swap barely touched (349MiB of 7.7GiB)
- CPU load well below 1.0 even during active agent work
- opencode at 760MB is the dominant memory consumer — all other processes are negligible
- No cgroup limits means the forge could OOM the host under extreme load (e.g., rustc compilation)

### Finding: No cgroup resource limits on forge container

The forge container runs without any CPU or memory limits (`/sys/fs/cgroup/memory.max` = `max`). On a host with only 8GB RAM, a runaway build or inference job inside the forge could exhaust host memory. Consider adding `--memory=6g --cpus=3` to `build_opencode_forge_args` so the forge container has generous but bounded resources.

---

## 2. Tool Availability & Gaps

### Languages — ALL PRESENT
- node v22.22.2, python3 3.14.5, rustc 1.96.0, go 1.26.4, java 25, dart 3.12.1

### Build Tools — ALL PRESENT
- cargo 1.96.0, mvn 3.9.11, npm 10.9.7, yarn 1.22.22, pnpm 10.33.0
- pipx 1.14.0, uv 0.11.19, poetry 2.3.1, make 4.4.1, cmake 4.3.0

### Shells — ALL PRESENT
- bash 5.3.9, fish 4.6.0, zsh 5.9

### Dev Tools — MIXED

| Tool | Status | Notes |
|------|--------|-------|
| git 2.54.0 | ✅ | |
| curl 8.18.0 | ✅ | |
| ripgrep 14.1.1 | ✅ | |
| fd 10.4.2 | ✅ | |
| bat 0.26.1 | ✅ | |
| **fzf** | ❌ **MISSING** | Fuzzy finder — useful for agent/human file search |
| **eza** | ❌ **MISSING** | Modern ls replacement |
| **htop** | ❌ **MISSING** | Process viewer |
| **mc** | ❌ **MISSING** | Midnight Commander file manager |
| **tree** | ❌ **MISSING** | Directory tree |
| **vim** | ❌ **MISSING** | No text editor at all |
| **nano** | ❌ **MISSING** | (confirming no editor) |

### Critical Gap: NO TEXT EDITOR INSTALLED

The forge has **no text editor** (`vim`, `nano`, `emacs`, `micro`, `helix` — none present). If an agent or human attaches interactively and needs to edit a file, there is no way to do so from the terminal. The welcome banner advertises `Edit files with vim or nano` in its rotating tips, but neither is installed.

### LSP & Linters — MOSTLY PRESENT

| Tool | Status | Notes |
|------|--------|-------|
| rust-analyzer | ✅ | |
| pylsp | ✅ | |
| yamllint | ✅ | |
| ruff | ✅ | |
| clippy-driver | ✅ | |
| actionlint | ✅ | |
| **marksman** | ❌ **MISSING at runtime** | Added to Containerfile.base but missing in this running image (image predates the change or rebuild needed) |
| **hadolint** | ❌ **MISSING** | Dockerfile linter for Containerfile maintenance |

### Rust Extras — ALL PRESENT
- cargo-nextest, cargo-watch, cargo-chef, cargo-audit, cargo-expand
- cargo-llvm-cov, cargo-semver-checks, cargo-criterion, cargo-wasi
- wasmtime, wasm-pack

### Misc — MIXED
- vale, typos-cli, watchexec: ✅
- **tellme** ❌ **MISSING at runtime** — see Finding below

---

## 3. Discoverability Gaps

### Finding: tellme command NOT in PATH

The welcome banner advertises `tellme about <topic>` for cheatsheet discovery, but `tellme` is not installed or not in PATH inside this running forge container. The `tellme` implementation was added in `c6600493 feat(forge): implement tellme howto with local inference RAG`, but the running image (forge-base) does not contain the binary.

**Next action:** Verify `tellme` binary is included in the forge base image build. It may need to be added to `images/default/cli/` and `build.rs` embedded assets.

### Finding: /opt/cheatsheets is empty at runtime

The directory `/opt/cheatsheets` exists but is empty. The welcome banner's cheatsheet section activates conditionally on `[ -d "${TILLANDSIAS_CHEATSHEETS:-/opt/cheatsheets}" ]` — if the directory is empty or missing, the cheatsheet advertisement block doesn't appear.

**Next action:** Verify the hot-path tmpfs mount for `/opt/cheatsheets` is being populated during forge image startup. The cheatsheets should be bundled from `images/default/cheatsheets/` at build time or copied during entrypoint init.

### Finding: No /etc/tillandsias-version file

The forge container lacks a version marker file. The forge image version cannot be determined from inside the container without inspecting build labels (which also aren't set per Finding 2 in the 2026-06-16 forge enhancement findings).

**Next action:** Add `ARG TILLANDSIAS_VERSION` + `RUN echo "$TILLANDSIAS_VERSION" > /etc/tillandsias-version` to the Containerfile build so agents can self-report their forge image version.

### Finding: tillandsias-inventory reports "image vunset"

The `tillandsias-inventory` CLI header shows `Tillandsias forge inventory — image vunset`, indicating the `TILLANDSIAS_IMAGE_VERSION` env var (or equivalent) is not set at runtime. This makes inventory output less useful for diagnostics cross-referencing.

**Next action:** Set `TILLANDSIAS_IMAGE_VERSION` (or `TILLANDSIAS_VERSION`) during forge container launch from the headless `build_opencode_forge_args`.

---

## 4. Welcome Banner Discrepancies

### Finding: Rotating tip references missing tools

Several tips in `images/default/forge-welcome.sh` reference tools that are not installed:

| Tip | Claims | Actually installed? |
|-----|--------|-------------------|
| tip 2 | `Try Midnight Commander with mc` | ❌ mc not installed |
| tip 3 | `Browse files with eza --tree` | ❌ eza not installed |
| tip 7 | `Preview files with bat <filename>` | ✅ bat installed |
| tip 10 | `View processes with htop` | ❌ htop not installed |
| tip 11 | `Show directory tree with tree` | ❌ tree not installed |
| tip 12 | `Edit files with vim or nano` | ❌ neither vim nor nano installed |
| tip 16 | `List files in detail with ll` | ⚠️ `ll` may not be aliased |

**Next action:** Either install the missing tools or update the tips to reference only actually-installed tools. For text editing, consider installing `micro` (single binary, minimal) as a lightweight editor.

---

## 5. Agent-Specific Gaps

### Finding: opend encode, claude, codex entrypoints present but untested

The `/usr/local/bin/` directory contains entrypoints for opend encode-web, claude, and codex agents alongside the OpenCode entrypoint. These are untested in the current forge configuration. If they are intended to be usable, they need discoverability and runtime validation.

**Next action:** Either test/validate the alternate agent entrypoints or document them as legacy/unused.

---

## Action Packets

### Packet A: Install missing terminal tools (COMPLETED)

- id: `forge-audit/install-terminal-tools`
- severity: medium
- owner_host: linux
- capability_tags: [containerfiles, dnf, images]
- next_action: ✅ **DONE** — fzf, eza, htop, mc, tree, nano, vim-minimal added to microdnf install line in `images/default/Containerfile.base:12`. Docblock updated. Litmus test `litmus:forge-shell-tools-implementation-shape` updated to check full tool set. Spec `forge-shell-tools/spec.md` divergence block removed (all 10 terminal tools now installed). Welcome banner tips are all accurate.
- evidence_required:
  - ✅ microdnf install succeeds for: fzf, eza, htop, mc, tree, nano, vim-minimal
  - ✅ All welcome banner tips match actually-installed tools
  - ✅ `bash -n images/default/forge-welcome.sh` passes
- completed_in: `9e2be241` (forge audit findings) + `this commit` (implementation)
- completed_by: forge-agent inside forge container

### Packet B: Fix marksman LSP runtime availability

- id: `forge-audit/marksman-runtime-missing`
- severity: medium
- owner_host: linux
- capability_tags: [containerfiles, images, testing]
- next_action: Verify marksman is included in the forge base image build. It was added to Containerfile.base in `48a34dc5` but is not present at runtime — check if image rebuild is needed.
- owned_files:
  - images/default/Containerfile.base
- evidence_required:
  - `command -v marksman` returns a path in the running forge
  - marksman can start and serve a Markdown file

### Packet C: Fix tellme discoverability

- id: `forge-audit/tellme-missing`
- severity: medium
- owner_host: linux
- capability_tags: [rust, forge, cli, images]
- next_action: Ensure the `tellme` binary is installed in the forge image and discoverable via PATH. It may need to be added to `images/default/cli/` and the `build.rs` embedded assets list.
- owned_files:
  - images/default/cli/
  - images/default/Containerfile
  - crates/tillandsias-headless/build.rs
- evidence_required:
  - `tellme about readme-discipline` works in the forge
  - welcome banner's `tellme about <topic>` hint is actionable

### Packet D: Version marker and image metadata

- id: `forge-audit/version-metadata`
- severity: low
- owner_host: linux
- capability_tags: [containerfiles, scripts, images]
- next_action: Add TILLANDSIAS_VERSION build ARG and /etc/tillandsias-version file to the forge image. Set TILLANDSIAS_IMAGE_VERSION env var during forge container launch.
- owned_files:
  - images/default/Containerfile.base
  - images/default/Containerfile
  - crates/tillandsias-headless/src/main.rs (build_opencode_forge_args)
  - scripts/build-image.sh
- evidence_required:
  - `cat /etc/tillandsias-version` returns a version string in the forge
  - `tillandsias-inventory` shows the version instead of "vunset"

### Packet E: Verify /opt/cheatsheets population

- id: `forge-audit/cheatsheets-population`
- severity: medium
- owner_host: linux
- capability_tags: [containerfiles, images, entrypoint]
- next_action: Verify that the hot-path tmpfs mount for /opt/cheatsheets is populated with the bundled cheatsheets from the image. If not, add a startup copy step in the entrypoint.
- owned_files:
  - images/default/entrypoint-forge-opencode.sh
  - images/default/entrypoint-terminal.sh
  - images/default/Containerfile
- evidence_required:
  - `ls /opt/cheatsheets/` shows cheatsheet files in the running forge
  - welcome banner cheatsheet section activates (condition on directory presence)

### Packet F: Set cgroup resource limits

- id: `forge-audit/cgroup-resource-limits`
- severity: low (production) / medium (resource-constrained hosts)
- owner_host: linux
- capability_tags: [rust, podman, containers]
- next_action: Add `--memory=6g --cpus=3` to forge container launch args in `build_opencode_forge_args` so the container doesn't OOM the 8GB host under extreme load.
- owned_files:
  - crates/tillandsias-headless/src/main.rs
- evidence_required:
  - forge container has memory.max < host total
  - forge container CPU quota is set

---

## Diagnostics Summary

- **forge diagnostics probe**: `25/25 checks passed` (from the 2026-06-20 run)
- **tools installed**: 740+ binaries in /usr/bin, 40+ in /usr/local/bin
- **missing tools**: fzf, eza, htop, mc, tree, vim, nano, tellme, marksman
- **discoverability score**: tools present but not discoverable via tellme or cheatsheets
- **performance grade**: B+ — runs well on modest 2013 hardware, no cgroup limits are the main risk
- **welcome banner accuracy**: 4/7 rotati
