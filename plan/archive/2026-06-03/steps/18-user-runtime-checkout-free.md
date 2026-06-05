# User Runtime Without Checkout - Assetized Install, PATH-Safe Installer

## Status

completed

## Completion Evidence

Completed locally 2026-05-20 for publication from `main`.

- `scripts/install.sh` now chooses a safe user-owned bin directory, persists
  marked PATH snippets for POSIX/bash/zsh/fish shells when needed, and prints
  an absolute immediate command.
- The headless binary embeds `images/**`, `scripts/manage-cache.sh`, and
  `scripts/run-observatorium.sh` at compile time and materializes them under
  `$XDG_DATA_HOME/tillandsias/runtime/<VERSION>` or
  `~/.local/share/tillandsias/runtime/<VERSION>`.
- User runtime paths now resolve through `resolve_runtime_asset_root()` by
  default. `TILLANDSIAS_ROOT` remains a loud developer override only.
- Init rebuild decisions now track per-image runtime source digests in
  `~/.cache/tillandsias/init-build-state.json` instead of checkout
  Containerfile mtimes.
- Specs, litmus metadata, cheatsheets, trace indexes, and README were updated
  to state the checkout-free user runtime contract.

Validation run:

```bash
bash scripts/test-install-path.sh
cargo fmt --check --all
cargo clippy --workspace --features tray -- -D warnings
cargo test --workspace --lib
cargo test -p tillandsias-headless --bin tillandsias --features tray
cargo test -p tillandsias-headless --test signal_handling --features tray
bash scripts/validate-spec-cheatsheet-binding-fast.sh
scripts/check-cheatsheet-tiers.sh --strict
scripts/validate-traces.sh
scripts/run-litmus-test.sh user-runtime-lifecycle --phase pre-build --timeout 240
./build.sh --ci-full --install
(cd /tmp && tillandsias --init --debug)
```

Observed notes:

- `scripts/validate-traces.sh` returned 0 errors and the existing 5 in-flight
  localization/WSL warnings.
- `./build.sh --ci-full --install` passed pre-build and post-build gates,
  built and installed the musl binary, generated an evidence bundle, and
  skipped only runtime residual litmus because the host Podman health probe was
  unhealthy.
- `(cd /tmp && tillandsias --init --debug)` used
  `~/.local/share/tillandsias/runtime/0.2.260520.1` and successfully built all
  eight runtime images.
- Commit `6540eb4e1edf423a428c227134f0d347139d27c7` was pushed to
  `origin/main`.
- GitHub Actions Convergence run `26186617492` passed on `main`.
- Release workflow run `26190392894` passed on `main` and published
  `v0.2.260520.1`.
- Release readback confirmed `v0.2.260520.1` is latest and includes
  `install.sh`, `SHA256SUMS`, `tillandsias-linux-x86_64`, `uninstall.sh`,
  `verify.sh`, and the expected Cosign bundle assets.

## Trigger

2026-05-20 Fedora Silverblue install report:

- The curl installer completed, but `~/.local/bin` was not on the user's
  shell `PATH`, so `tillandsias` was not invocable by command name.
- The released binary still required a Tillandsias source checkout for
  `--init`, `--tray`, and `--headless`-adjacent runtime paths because runtime
  image builds resolve `images/*` from `find_checkout_root()`.

This violates the release promise: after the curl installer, user runtime must
require only Podman and normal host shell facilities. A Tillandsias checkout is
a developer/runtime-build input, not a user runtime dependency.

## Audit Findings

### Installer PATH Gap

`scripts/install.sh` installs to `${XDG_BIN_HOME:-$HOME/.local/bin}` and only
prints:

```bash
export PATH="$INSTALL_DIR:$PATH"
```

That is insufficient for Fedora Silverblue users whose shell startup files do
not already add `~/.local/bin`. The desktop launcher uses an absolute `Exec=`,
but terminal commands do not work until the user manually exports PATH.

### Checkout Dependency Hotspots

The runtime has a hard checkout lookup:

- `crates/tillandsias-headless/src/main.rs::find_checkout_root()`
  requires `VERSION` plus `images/` in either `TILLANDSIAS_ROOT` or an ancestor
  of the current directory.
- `run_init()` calls `find_checkout_root()?`, then builds all images from that
  root.
- `image_specs()` maps image names to repository-relative `images/*`
  Containerfiles and build contexts.
- `build_image_with_logging()` passes those paths directly to `podman build`.
- `containerfile_is_stale()` and `capture_containerfile_mtime()` use repository
  Containerfile mtimes as the staleness signal.
- `run_status_check()`, `run_github_login()`, `run_observatorium_mode()`, tray
  startup, forge agent launch, OpenCode, and OpenCode Web all either require
  or fall back to checkout-derived roots before ensuring images.
- `run_disk_usage_check()` still shells out to `scripts/manage-cache.sh` from a
  checkout root.

### Asset Shape

The `images/` tree is about 29 MiB and has no symlinks. It contains regular
files with mode bits that matter for shell scripts and helper binaries. That
makes either an embedded asset table or a release asset tarball feasible. For
the zero-runtime-dependency contract, the preferred path is embedding the
runtime image contexts into the binary and materializing them to user data on
demand.

## Target Contract

After the curl installer:

```bash
tillandsias --init --debug
tillandsias --debug --tray
tillandsias --headless /path/to/project
tillandsias --opencode-web /path/to/project --debug --tray
```

must not require:

- a Tillandsias source checkout,
- `TILLANDSIAS_ROOT`,
- running from the repo root,
- `git clone` of Tillandsias,
- toolbox/nix/cargo/rustup,
- host package installation beyond Podman itself.

Developer checkouts remain supported as an override for local development, but
the installed binary must use its embedded runtime assets by default.

## Design Decision

Use a versioned materialized runtime asset tree:

```text
$XDG_DATA_HOME/tillandsias/runtime/<VERSION>/
  manifest.json
  images/
    proxy/
    git/
    inference/
    router/
    chromium/
    default/
    web/
  scripts/
    manage-cache.sh
    run-observatorium.sh
```

The binary embeds the source asset bytes at compile time, writes them into that
tree on first use, validates a manifest digest on later uses, and rebuilds the
tree if the version or digest changes.

Resolution order:

1. If `TILLANDSIAS_ROOT` is set and valid, use it as a developer override.
2. Otherwise use the materialized runtime asset root.
3. Never silently use `current_dir()` as a fake Tillandsias root for user
   runtime image builds.

This keeps the release as a single binary plus installer scripts, preserves the
only-Podman runtime dependency, and avoids adding tar/zstd extraction
requirements to user runtime.

## Implementation Plan

### Phase 1 - Installer PATH Repair

Goal: after curl install, the next normal shell can run `tillandsias` by name,
and the current installer output gives an absolute fallback.

Tasks:

1. Add installer PATH detection for `~/.local/bin`, `$HOME/bin`, and any
   writable user-owned directory already present in `PATH`.
2. Prefer an install directory already on `PATH` when safe. If none exists,
   continue installing to `~/.local/bin`.
3. Create `~/.local/bin` before PATH checks so shell startup logic that only
   adds existing directories can work after re-login.
4. Add idempotent shell startup snippets:
   - POSIX login shell: `~/.profile`
   - Bash interactive shell: `~/.bashrc`
   - Zsh: `~/.zprofile` or `~/.zshrc`
   - Fish: `~/.config/fish/conf.d/tillandsias.fish`
5. Use marker comments so repeated installer runs do not duplicate PATH lines.
6. Print both:
   - immediate absolute command: `$INSTALL_PATH --init --debug`
   - next-shell command: `tillandsias --init --debug`
7. Update desktop file generation to continue using absolute `Exec=` so the
   tray launcher works even before a shell reload.
8. Add installer tests with synthetic `HOME`, empty `PATH`, bash/zsh/fish
   profile fixtures, and rerun idempotence checks.

Acceptance:

- `scripts/install.sh` does not merely print a PATH export when the install dir
  is missing from PATH; it persists the PATH setup when a known shell profile
  exists or can be safely created.
- A rerun does not duplicate profile snippets.
- README states the immediate absolute command and shell reload behavior.

### Phase 2 - Runtime Asset Contract

Goal: make checkout-free user runtime a first-class spec, not an accidental
implementation detail.

Tasks:

1. Update `openspec/specs/user-runtime-lifecycle/spec.md`:
   - user runtime image sources are shipped with the release,
   - installed runtime must not require a source checkout,
   - `TILLANDSIAS_ROOT` is a developer override only,
   - Podman remains the only runtime dependency.
2. Update `openspec/specs/install-progress/spec.md`:
   - installer sets up command discoverability,
   - installer does not run `--init`,
   - installed runtime can initialize without checkout.
3. Update `openspec/specs/init-command/spec.md`:
   - `--init` resolves runtime assets from the embedded/materialized tree,
   - image staleness is content/version based, not repo mtime based.
4. Update `openspec/specs/linux-native-portable-executable/spec.md`:
   - released binary carries everything needed to materialize runtime image
     contexts.
5. Add or update a litmus binding named
   `litmus:user-runtime-checkout-free-install`.
6. Add cheatsheet citations for:
   - `cheatsheets/runtime/linux-user-session-podman.md`
   - `cheatsheets/runtime/image-lifecycle.md`
   - `cheatsheets/build/build-strategy.md`
   - new or updated installer/PATH discipline cheatsheet.

Acceptance:

- The spec suite explicitly forbids requiring a Tillandsias checkout in user
  runtime.
- Traceability points at concrete runtime resolver and installer code.

### Phase 3 - Embedded Runtime Asset Generator

Goal: compile release image contexts into the binary with file modes and hashes.

Tasks:

1. Add a build-time generator under `crates/tillandsias-headless/build.rs` or a
   shared helper crate that walks:
   - `images/**`
   - `scripts/manage-cache.sh`
   - `scripts/run-observatorium.sh`
2. Generate a Rust module with:
   - relative path,
   - byte slice,
   - executable bit,
   - SHA256 digest,
   - total manifest digest.
3. Preserve current `scripts/build-sidecar.sh` ordering so
   `images/router/tillandsias-router-sidecar` is already staged before release
   compilation.
4. Fail the release build if any required runtime asset is missing:
   - all image Containerfiles,
   - router sidecar,
   - router base Caddyfile and entrypoints,
   - proxy allowlist and squid config,
   - forge entrypoint and config overlay scripts.
5. Keep generated code deterministic by sorting paths and using stable mode
   metadata.
6. Ensure generated source is included in `cargo fmt` and compile checks.

Acceptance:

- `cargo build --release --target x86_64-unknown-linux-musl --features tray`
  embeds every runtime image context required by user commands.
- A missing or unstaged router sidecar fails the build before release upload.

### Phase 4 - Materialized Runtime Asset Root

Goal: replace checkout lookup as the default runtime source.

Tasks:

1. Introduce a `runtime_assets` module with:
   - `runtime_data_dir() -> PathBuf`
   - `runtime_asset_root(version) -> PathBuf`
   - `ensure_runtime_assets(version, debug) -> Result<PathBuf, String>`
   - `validate_runtime_assets(version) -> Result<bool, String>`
2. Write assets to a temporary sibling directory first, then atomically rename
   into `$XDG_DATA_HOME/tillandsias/runtime/<VERSION>`.
3. Persist a `manifest.json` containing:
   - binary version,
   - manifest digest,
   - file count,
   - per-file mode/digest,
   - materialized timestamp.
4. If validation fails, delete and rewrite only the versioned runtime asset
   directory, never user project data or shared caches.
5. Set executable permissions for scripts and staged helper binaries based on
   embedded metadata.
6. Add debug output:
   - materialized path,
   - whether assets were reused or rewritten,
   - manifest digest.
7. Add a non-mutating command or internal test hook to validate the asset tree
   without building images.

Acceptance:

- A fresh user with no checkout can run `tillandsias --init --debug` and see
  the materialized runtime asset path before image builds start.
- Corrupt asset files are repaired on next run.

### Phase 5 - Runtime Root Refactor

Goal: every user runtime image build uses the resolved runtime asset root.

Tasks:

1. Replace `find_checkout_root()` with two explicit concepts:
   - `find_developer_checkout_root()` for dev override/tests,
   - `resolve_runtime_asset_root(version, debug)` for user runtime.
2. Change `run_init()` to call `resolve_runtime_asset_root()` instead of
   requiring a checkout.
3. Change `run_status_check()` to stop deriving the project name from the
   Tillandsias root; use a stable synthetic project name for status smoke.
4. Change `run_github_login()` to build/ensure the git image from runtime
   assets.
5. Change `run_observatorium_mode()` to use the materialized
   `scripts/run-observatorium.sh` path or remove the host script dependency if
   observatorium can launch directly.
6. Change `run_disk_usage_check()` to use the materialized
   `scripts/manage-cache.sh`, or port that script logic into Rust and drop the
   shell dependency.
7. Change OpenCode, OpenCode Web, forge agent, tray startup, and
   `ensure_enclave_for_project()` to call the runtime resolver instead of
   `find_checkout_root().unwrap_or_else(current_dir)`.
8. Remove current-dir fallback for image builds. The current directory may be a
   user project, not Tillandsias.
9. Keep `TILLANDSIAS_ROOT` as a documented developer override that bypasses
   embedded assets only when it points at a valid checkout.

Acceptance:

- `rg 'find_checkout_root\\(\\)' crates/tillandsias-headless/src` shows only
  developer/test helper usage, not user runtime paths.
- No image build path uses `std::env::current_dir()` as a Tillandsias root.

### Phase 6 - Staleness and Cache Semantics

Goal: image rebuild decisions remain correct without repo mtimes.

Tasks:

1. Replace Containerfile mtime staleness with embedded asset manifest digest
   staleness.
2. Extend `InitBuildState` with:
   - `runtime_asset_manifest_digest`,
   - per-image source digest,
   - binary version,
   - build timestamp.
3. Compute each image's source digest from the embedded asset subset for its
   build context.
4. Rebuild an image when:
   - image tag is absent,
   - previous image status was failed,
   - `--force` is set,
   - binary version changed,
   - image source digest changed.
5. Keep cache corruption recovery scoped to
   `~/.cache/tillandsias/init-build-state.json`.
6. Update status and debug output to say "runtime assets changed" instead of
   "Containerfile modified" when appropriate.

Acceptance:

- Releasing a new binary with changed embedded image contexts triggers rebuilds
  without relying on checkout file mtimes.
- User project directories are never treated as image source state.

### Phase 7 - Checkout-Free Tests

Goal: catch this failure mode before release.

Tasks:

1. Add a unit test that runs runtime root resolution with:
   - temp `HOME`,
   - temp `XDG_DATA_HOME`,
   - cwd in an unrelated project directory,
   - `TILLANDSIAS_ROOT` unset.
2. Add a unit test that materializes assets and verifies:
   - `images/default/Containerfile`,
   - `images/proxy/allowlist.txt`,
   - `images/router/tillandsias-router-sidecar`,
   - `scripts/manage-cache.sh`.
3. Add a unit test that corrupts one materialized asset and verifies repair.
4. Add a source test that fails if user runtime code calls
   `find_developer_checkout_root()` in:
   - `run_init`,
   - `run_status_check`,
   - `run_github_login`,
   - OpenCode/OpenCode Web launch,
   - tray startup.
5. Add a fake-Podman integration smoke:
   - no checkout cwd,
   - fake `podman` captures `build` invocations,
   - `tillandsias --init --debug` reaches build calls with materialized
     Containerfile paths.
6. Add installer PATH tests with synthetic homes and shell profiles.
7. Add a release-workflow smoke that runs binary checks from a temp cwd outside
   the checkout. Hosted cloud should remain static/fake-only; real Podman image
   builds stay local.

Acceptance:

- The failure reproducer is automated:
  `cd "$(mktemp -d)" && env -u TILLANDSIAS_ROOT tillandsias --init --debug`
  must not fail with "Could not find Tillandsias checkout".
- GitHub-hosted tests do not run real Podman builds.

### Phase 8 - Documentation and User Messaging

Goal: docs match the new user runtime contract.

Tasks:

1. Update README install section:
   - PATH behavior,
   - immediate absolute fallback,
   - no checkout required,
   - Podman only runtime dependency.
2. Update README run section to say first run materializes bundled runtime
   assets under user data and builds Podman images.
3. Update installer output:
   - "Run now: `$INSTALL_PATH --init --debug`"
   - "After opening a new shell: `tillandsias --init --debug`"
4. Update release notes and verification docs.
5. Update cheatsheets:
   - build strategy,
   - Linux user session Podman,
   - image lifecycle,
   - install/PATH discipline.
6. Add a troubleshooting entry:
   - command not found after install,
   - no checkout required,
   - where runtime assets live,
   - how to reset runtime assets safely.

Acceptance:

- No user-facing doc implies cloning Tillandsias before `--init` or `--tray`.
- Troubleshooting tells users how to reload PATH and how to run the absolute
  installed binary immediately.

### Phase 9 - Local Silverblue Reproducer

Goal: verify on the original runtime model, not only in the checkout.

Tasks:

1. From a clean temp user-like environment, install the release candidate via
   the curl installer.
2. Confirm `~/.local/bin` is made discoverable for a new shell.
3. From a directory that is not a Tillandsias checkout:
   ```bash
   env -u TILLANDSIAS_ROOT tillandsias --version
   env -u TILLANDSIAS_ROOT tillandsias --init --debug
   env -u TILLANDSIAS_ROOT tillandsias --debug --tray
   ```
4. Confirm no command errors with "Could not find Tillandsias checkout".
5. Confirm materialized runtime assets are versioned under user data.
6. Confirm `--cache-clear` and image eviction do not delete runtime assets
   unless explicitly scoped to runtime asset reset.
7. Confirm re-running installer is idempotent.

Acceptance:

- The Fedora Silverblue host flow works from a normal terminal after install.
- Runtime remains Podman-only from the user's perspective.

### Phase 10 - Patch Release

Goal: ship the fix quickly and verify the released artifact.

Tasks:

1. Bump patch/build version.
2. Run local checks:
   ```bash
   cargo fmt --check --all
   cargo clippy --workspace --features tray -- -D warnings
   cargo test --workspace --lib
   cargo test -p tillandsias-headless --bin tillandsias
   cargo test -p tillandsias-headless --features tray --bin tillandsias
   scripts/check-cheatsheet-tiers.sh --strict
   scripts/validate-spec-cheatsheet-binding-fast.sh
   scripts/validate-traces.sh
   ./build.sh --ci-full --install
   env -u TILLANDSIAS_ROOT tillandsias --init --debug
   env -u TILLANDSIAS_ROOT tillandsias --debug --tray
   ```
3. Push `linux-next`, fast-forward `main`, monitor static convergence.
4. Dispatch release workflow.
5. Read back release assets and confirm the new release includes the fixed
   binary and installer.
6. Run the curl installer from the new release on a clean Silverblue runtime.

Acceptance:

- New release passes.
- README references the new behavior.
- `main` and `linux-next` are aligned.

## File Scope

Expected implementation files:

- `scripts/install.sh`
- `README.md`
- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `crates/tillandsias-headless/build.rs`
- `crates/tillandsias-headless/src/main.rs`
- `crates/tillandsias-headless/src/runtime_assets.rs`
- `crates/tillandsias-headless/src/tray/mod.rs`
- `crates/tillandsias-core/src/image_builder.rs`
- `openspec/specs/user-runtime-lifecycle/spec.md`
- `openspec/specs/install-progress/spec.md`
- `openspec/specs/init-command/spec.md`
- `openspec/specs/linux-native-portable-executable/spec.md`
- `openspec/litmus-bindings.yaml`
- `openspec/litmus-tests/*checkout-free*.yaml`
- `cheatsheets/build/build-strategy.md`
- `cheatsheets/runtime/image-lifecycle.md`
- `cheatsheets/runtime/linux-user-session-podman.md`
- release verification docs.

## Non-Goals

- Do not make GitHub-hosted CI run real Podman image builds.
- Do not install Podman automatically.
- Do not require Rust, Cargo, Nix, toolbox, or a Tillandsias checkout on user
  machines.
- Do not delete user projects, cloned repositories, GitHub credentials, or
  container volumes while repairing runtime assets.
- Do not hide the developer checkout override; keep it explicit and documented.

## Exit Criteria

- Installer makes `tillandsias` discoverable in subsequent shells and prints an
  immediate absolute fallback.
- `--init`, `--tray`, `--headless`, GitHub login, OpenCode, OpenCode Web, and
  tray project attach do not require a Tillandsias checkout.
- Runtime image builds use embedded/materialized assets by default.
- Staleness is based on version/content digest, not checkout mtimes.
- Specs, cheatsheets, README, release docs, and litmus metadata all describe
  checkout-free user runtime.
- Local Silverblue smoke passes from a non-checkout directory.
- A patch release is published and verified.
