# Research: split forge image into CREATION_TIME (dnf-only) vs FIRST_RUN (persistent cache) vs EVERY_LAUNCH — 2026-07-04

- class: research (forge image architecture)
- filed: 2026-07-04
- owner: linux
- status: ready
- trace: spec:default-image, spec:forge-cache-dual, spec:forge-hot-cold-split, cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md
- goal: operator directive — remove finicky curl/tar installers from container CREATION and move them to idempotent FIRST_RUN flows on the persistent cache; harnesses reinstalled EVERY_LAUNCH for latest.

## Why

`images/default/Containerfile.base` bakes a large block of "exploded" curl/tar
installers (`curl -o x.tar && sha256 && tar -x && ...`) at image build time.
Problems the operator called out:

1. Fragile + hard to maintain (each is a pinned URL + SHA that rots).
2. Everything is frozen at build time — a fresh forge shows "newer version
   available" for Codex/Claude/etc. because they were npm-pinned at build.
3. The correct home for these tools is a **user-space install on FIRST_RUN** into
   a persistent cache (so they persist but can be refreshed dynamically), and for
   the harnesses themselves an **EVERY_LAUNCH** reinstall (always latest).

## Audit — current install methods in the forge base image

Source: `images/default/Containerfile.base` (+ `images/inference/Containerfile`).

### KEEP at CREATION_TIME (already correct — microdnf, no change)
Single `microdnf install` layer covers the system + language BASE toolchains:
`bash coreutils git gh curl wget jq ripgrep fd-find bat fzf eza htop tree nano
vim-minimal zoxide git-delta git-lfs httpie yq`, **`nodejs npm`**, `java maven`,
`golang gopls`, **`rust cargo clippy rustfmt rust-analyzer cargo-deny`**,
`python3-pip … ruff poetry pipx uv black pylint yamllint`, `pnpm yarnpkg just
gdb lldb strace valgrind shellcheck shfmt gcc gcc-c++ make cmake pkgconfig unzip
iproute iputils socat nmap-ncat sqlite`. The language runtimes (Rust/Node/Go/
Java/Python) are ALREADY dnf-installed — no curl there. Good.

### MOVE to FIRST_RUN (persistent cache, idempotent install-if-missing)
The curl/tar "install_archive" block (`Containerfile.base` ~L90-128) — user-space
tools that should install once into the persistent cache and be refreshable:

| Tool | Current method | First-run install target |
|---|---|---|
| cargo-nextest, cargo-chef, cargo-watch, cargo-audit, cargo-edit, cargo-llvm-cov, cargo-semver-checks, cargo-expand, cargo-criterion, cargo-wasi, cargo-outdated | curl+tar prebuilt (cargo-quickinstall assets) | `cargo install <tool>` or cargo-binstall into `$CARGO_HOME` |
| wasm-pack, trunk, typos-cli, watchexec-cli | curl+tar | `cargo install` / official installer into `$CARGO_HOME/bin` |
| actionlint, vale | curl+tar (GitHub release) | official installer / go install into cache bin |
| wasmtime | curl+tar.xz | official `wasmtime` installer into `$HOME/.wasmtime` (cache-backed) |
| dart | curl+zip → /opt/dart-sdk | first-run SDK fetch into cache (or keep if truly needed at build) |
| marksman | curl GitHub binary | first-run fetch into cache bin |
| ollama (inference img) | curl+zstd+tar (`images/inference/Containerfile` L35-41) | first-run official `ollama` install into inference cache |

### MOVE to EVERY_LAUNCH (npm, always latest)
`Containerfile.base` L29-33 npm-pins the harnesses at BUILD (the "newer version
available" bug). These should be `npm install -g` (or `npx`) on EVERY launch into
the persistent `$NPM_CONFIG_PREFIX`, so a fresh forge always runs latest:
`@openai/codex`, `@anthropic-ai/claude-code`, `opencode-ai`, and the Antigravity
CLI (`agy`). (openspec/typescript/eslint/prettier/markdownlint could stay pinned
first-run or every-launch — decide per tool.)

### Cleanup finding (from the current dirty worktree — user WIP)
`Containerfile.base` currently has the Antigravity `curl … install.sh | bash`
block **DUPLICATED** (two identical RUN blocks, ~L36 and ~L46). Whichever
migration lands should collapse this to a single EVERY_LAUNCH npm/installer step.

## THE #1 open question (blocks all impl) — does the persistent cache actually mount?

The whole "first-run installs persist" premise depends on a persistent, writable
cache surviving the forge's `--rm`. Evidence is contradictory:

- `images/default/lib-common.sh` exports `CARGO_HOME=$PROJECT_CACHE/cargo` and
  `NPM_CONFIG_PREFIX=$PROJECT_CACHE/npm/global` where
  `PROJECT_CACHE=/home/forge/.cache/tillandsias-project`, and the cheatsheet
  `runtime/forge-paths-ephemeral-vs-persistent.md` documents PROJECT_CACHE as a
  **host bind-mount** from `~/.cache/tillandsias/<project>/` (persistent).
- BUT the LIVE launch path `build_forge_agent_run_args`
  (`crates/tillandsias-headless/src/main.rs`, called by `run_forge_agent_cli_mode`
  / `launch_forge_agent`) mounts only: the project (`/home/forge/src/<project>`),
  the CA cert, and tmpfs (`/tmp`, `/run/user/1000`, `/opt/cheatsheets`). It does
  **NOT** bind-mount `/home/forge/.cache/tillandsias-project`. Combined with `--rm`
  (a container hardening default, `container_spec.rs`), that means CARGO_HOME /
  NPM_CONFIG_PREFIX live in the container's ephemeral overlay upper-dir and are
  **LOST on exit** — first-run installs would re-run every launch (slow, defeats
  the point).
- Meanwhile `crates/tillandsias-core/src/container_profile.rs` DOES describe a
  rich cache/overlay architecture (`tools-overlay/current`, a models cache at
  `~/.cache/tillandsias/models/` mounted dynamically) and specs
  `layered-tools-overlay` / `overlay-mount-cache` / `forge-cache-dual`. It is
  unclear whether `ContainerProfile` is on the live forge-launch path or is
  aspirational/parallel to `build_forge_agent_run_args`.

**Research must resolve, with ground-truth evidence (`podman inspect <forge>`):**
1. Which code path builds the live forge `podman run` args — `build_forge_agent_run_args`
   or `ContainerProfile`? (Grep says the CLI/tray both call `build_forge_agent_run_args`.)
2. Does ANY persistent, writable mount back `$PROJECT_CACHE` (or `$CARGO_HOME` /
   `$NPM_CONFIG_PREFIX`) across `--rm`? Inspect a live forge's `.Mounts`.
3. If NOT, the FIRST prerequisite impl is **add the persistent cache mount**
   (host bind-mount `~/.cache/tillandsias/<project>/` or a named volume) — without
   it, first-run migration makes the forge SLOWER, not faster.

## Verifiable closure (research done-when)
- Audit table above confirmed against the current Containerfiles (done).
- The persistence question answered with `podman inspect` evidence: exactly which
  paths persist across a forge relaunch.
- A decision recorded per tool: CREATION_TIME / FIRST_RUN / EVERY_LAUNCH.
- Impl packets shaped: (a) persistent cache mount [prereq if missing], (b) first-run
  tool migration, (c) every-launch harness reinstall, (d) ollama first-run. Each
  with an idempotency litmus (install-if-missing; second run is a no-op).

## Handoff
Impl packets (orders 179-182 + inference 183-184) reference this research; do not
start the tool migration before the persistence question is answered — a
first-run install that doesn't persist is a regression.
