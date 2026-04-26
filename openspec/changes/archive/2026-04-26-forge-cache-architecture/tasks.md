## 1. Mount infrastructure

- [ ] 1.1 In `crates/tillandsias-core/src/container_profile.rs`, add two `MountSource` variants: `SharedCache` and `ProjectCache`. Resolution: `SharedCache` resolves to `~/.cache/tillandsias/forge-shared/nix-store/` (host) → `/nix/store/` (forge) `:ro`. `ProjectCache` resolves to `~/.cache/tillandsias/forge-projects/<project>/` (host) → `/home/forge/.cache/tillandsias-project/` (forge) `:rw`. Project name passed via launch context.
- [ ] 1.2 Extend `common_forge_mounts()` to add both mounts to every forge profile (opencode-web, terminal, claude, opencode-non-web).
- [ ] 1.3 In `src-tauri/src/handlers.rs::handle_attach_*`, ensure `~/.cache/tillandsias/forge-projects/<project>/` exists with mode 0700 owned by host UID before container start. Same for `~/.cache/tillandsias/forge-shared/nix-store/` (no project name).
- [ ] 1.4 Add `--security-opt=label=disable` or appropriate SELinux relabel flag for the two new mounts so SELinux doesn't deny access on Fedora hosts. Pattern matches existing mounts.

## 2. Env vars

- [ ] 2.1 In `images/default/lib-common.sh`, add a new export block setting all 12 per-language env vars listed in spec §Per-language env vars table to `/home/forge/.cache/tillandsias-project/<lang>/`.
- [ ] 2.2 Tombstone the prior exports (`@tombstone superseded:forge-cache-architecture` — kept three releases until 0.1.169.232).
- [ ] 2.3 Ensure each subdirectory exists at first use — entrypoint `mkdir -p` for each before launching the agent. (The mount creates the parent; subdirs are tools' responsibility but a defensive mkdir in the entrypoint avoids tool-specific bugs.)

## 3. Download telemetry

- [ ] 3.1 New module `crates/tillandsias-core/src/download_telemetry.rs` exporting `pub fn log_download(...)` matching the spec field set. Wraps `tracing::info!` with the canonical fields.
- [ ] 3.2 Audit existing download callsites in `src-tauri/src/handlers.rs`, `src-tauri/src/updater.rs`, `crates/tillandsias-podman/src/launch.rs`, image-build subprocess invocations. Replace ad-hoc logging with the canonical helper.
- [ ] 3.3 In `images/inference/entrypoint.sh`, wrap `ollama pull` invocations to emit a parseable log line. (Bash, not Rust — use `printf '{"category":"download",...}\n'` to stdout, host parses.)
- [ ] 3.4 Forge-side downloads (cargo, npm, etc.) are tool-managed — we don't intercept. But the `--download-stats` parser SHALL use a heuristic: any file written to a `forge-projects/<project>/` subdir whose mtime is between container start and the next stop counts as a download with `source="forge:<project>"`. Implement that heuristic in §4.

## 4. CLI subcommand

- [ ] 4.1 In `src-tauri/src/main.rs`, add `--download-stats [--since=<duration>]` argument parsing. Out-of-band of the tray (so `tillandsias --download-stats` runs as a one-shot, no tray spawning).
- [ ] 4.2 Implement the report: parse the accountability log file (already-existing path under `~/.cache/tillandsias/`), filter `category="download"`, aggregate by source / reason / day. Plain text output to stdout.
- [ ] 4.3 If zero downloads in window, output `"no downloads in last <duration> ✓"` and exit 0.

## 5. Cheatsheets (with provenance)

- [ ] 5.1 Write `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — definitive path-category table, when each survives, anti-patterns flagged. Provenance: this OpenSpec change ID + project Containerfile + lib-common.sh.
- [ ] 5.2 Write `cheatsheets/runtime/forge-shared-cache-via-nix.md` — why nix is the right shared-cache entry, content-addressed conflict-freedom, what the forge sees vs what it doesn't. Provenance: nix.dev + nixos.org manual + this spec.

## 6. Methodology

- [ ] 6.1 Write `images/default/config-overlay/opencode/instructions/cache-discipline.md` — opencode first-turn instruction. Tells the agent: shared cache is RO; per-project cache is RW; project workspace is for source only; build artifacts NEVER go in the workspace; use the env vars.
- [ ] 6.2 Update `images/default/config-overlay/opencode/config.json` (or wherever instruction list lives) to include the new file in opencode's auto-loaded instruction set.
- [ ] 6.3 Add a new section to `~/src/tillandsias/CLAUDE.md` codifying the dual-cache + ephemeral path model so host Claude (me) and project contributors share the same mental model.

## 7. Build + verify

- [ ] 7.1 `cargo check --workspace` clean.
- [ ] 7.2 `cargo test --workspace --lib` plus `cargo test -p tillandsias --bin tillandsias` — all green. New tests for the mount path resolution + the env var generation in `lib-common.sh` (smoke-tested via expect).
- [ ] 7.3 `scripts/build-image.sh forge --force` — re-bake the forge image with the new `lib-common.sh`.
- [ ] 7.4 Manual: launch tray, attach to a project, run `cargo new foo && cd foo && cargo build` — confirm `target/` lives under `~/.cache/tillandsias/forge-projects/<project>/cargo/target/` (host) and NOT under the project workspace.
- [ ] 7.5 Manual: stop the forge container, attach again, run `cargo build` (no source changes) — confirm zero crate downloads (cache hit).
- [ ] 7.6 Manual: launch a SECOND project's forge concurrently, confirm via `ls /home/forge/.cache/tillandsias-project/` that ONLY this project's cache is visible.
- [ ] 7.7 Run `tillandsias --download-stats --since=1h` after the manual flow — confirm the log was parsed and the report is non-empty.
