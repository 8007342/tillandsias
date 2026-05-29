---
tags: [linux, installer, runtime-assets, path, podman]
languages: [bash, rust]
since: 2026-05-20
last_verified: 2026-05-20
sources:
  - file://scripts/install.sh
  - file://crates/tillandsias-headless/src/runtime_assets.rs
  - file://openspec/specs/user-runtime-lifecycle/spec.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# User Runtime Install Contract

@trace spec:user-runtime-lifecycle, spec:install-progress, spec:linux-native-portable-executable, spec:init-command
@cheatsheet runtime/linux-user-session-podman.md, runtime/image-lifecycle.md, build/build-strategy.md

**Use when**: changing the curl installer, release binary shape, or any runtime path that would otherwise depend on a Tillandsias checkout.

## Contract

The installed user runtime requires:

- Linux x86_64
- rootless Podman
- a normal user shell/session
- the released `tillandsias-linux-x86_64` binary

It must not require:

- a Tillandsias source checkout
- `TILLANDSIAS_ROOT`
- Rust, Cargo, Nix, toolbox, or host Chromium
- running commands from the repository root

## Installer PATH Rules

The installer should choose the least surprising user-owned bin path:

1. Use `XDG_BIN_HOME` when explicitly set.
2. Prefer `~/.local/bin` or `~/bin` when already on `PATH` and writable.
3. Otherwise accept a safe writable `$HOME/...` directory already on `PATH`.
4. Fall back to `~/.local/bin`.

When the chosen directory is not on `PATH`, persist marked startup snippets for
future POSIX/bash/zsh/fish shells and print the absolute command for immediate
use. Re-running the installer must not duplicate those snippets.

## Runtime Asset Rules

The release binary embeds the runtime image contexts and helper scripts. On
first use it materializes them under:

```text
$XDG_DATA_HOME/tillandsias/runtime/<VERSION>/
```

or the `$HOME/.local/share/tillandsias/runtime/<VERSION>` fallback.

The manifest records the binary version, asset digest, materialization time,
file count, per-file digest, and executable bit. If validation fails, rewrite
only that versioned runtime asset directory. Do not delete projects, Podman
storage, or shared caches while repairing runtime assets.

## Developer Override

`TILLANDSIAS_ROOT` is a developer override for testing local image changes. It
must point at a valid checkout with `VERSION` and `images/`; an invalid value
should fail loudly instead of falling back to embedded assets.

## Validation

```bash
bash scripts/test-install-path.sh
cargo test -p tillandsias-headless --bin tillandsias runtime_assets --features tray
```

For an installed runtime smoke, run from a non-checkout directory:

```bash
env -u TILLANDSIAS_ROOT tillandsias --init --debug
```
