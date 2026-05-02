## 1. CLI Infrastructure for --diagnostics

- [ ] 1.1 Add `--diagnostics` flag to `src-tauri/src/cli.rs` CLI struct (takes optional project path argument)
- [ ] 1.2 Add `--diagnostics` variant to CLI match statement in `main.rs` (entry point routing)
- [ ] 1.3 Update `--help` text to describe `--diagnostics <project-path>` for container log streaming
- [ ] 1.4 Add `@trace spec:cli-diagnostics` annotation near CLI flag definition

## 2. Diagnostics Handler Implementation

- [ ] 2.1 Create `handle_diagnostics()` function in `src-tauri/src/handlers.rs` that accepts project path
- [ ] 2.2 Implement container discovery logic: identify all running Tillandsias containers (shared + project-specific)
  - Shared: proxy, git-mirror, inference
  - Project-specific: forge, browser-core, browser-framework for the given project
- [ ] 2.3 Spawn `podman logs -f` subprocess for each running container
- [ ] 2.4 Implement line-by-line prefix labeling: prepend `[<container-type>:<owner>]` to each log line
  - Example: `[forge:visual-chess]`, `[proxy:shared]`
- [ ] 2.5 Aggregate all subprocess output to stderr (unbuffered, real-time)
- [ ] 2.6 Implement graceful shutdown: Ctrl+C kills all podman subprocesses cleanly, exits with code 0
- [ ] 2.7 Handle edge case: no running containers → print clear error message and exit 0
- [ ] 2.8 Emit observability events at start/end:
  - Start: `event="diagnostics_start" spec="cli-diagnostics" project="<path>" containers=<count>`
  - End: `event="diagnostics_end" spec="cli-diagnostics" stopped_by="<sigterm|error>"`
- [ ] 2.9 Add `@trace spec:cli-diagnostics, spec:observability-convergence` annotations throughout handler

## 3. Init Command Enhancements for Browser Containers

- [ ] 3.1 Update `src-tauri/src/init.rs::run()` to include browser-core and browser-framework in image build list
- [ ] 3.2 Verify browser image Containerfiles exist at `images/chromium/Containerfile.core` and `.framework`
  - (If missing, create placeholder files referencing browser isolation spec)
- [ ] 3.3 Extend staleness detection in `init.rs` to check browser image sources alongside other images
- [ ] 3.4 Add `--debug` flag handling: disable timeout limits, stream build logs to stderr in real-time
- [ ] 3.5 Modify build progress output to show all 6 images: "Building images (1/6) proxy, (2/6) forge, ..., (6/6) browser-framework"
- [ ] 3.6 Update failure reporting: after build completes, print last 20 lines of failed image logs (if any)
- [ ] 3.7 Add `@trace spec:init-command, spec:observability-convergence` near image build loop
- [ ] 3.8 Emit events:
  - Per-image: `event="image_build_start" spec="init-command" image="<name>"`
  - Per-image: `event="image_build_end" spec="init-command" image="<name>" status="success|failed" duration_secs=<N>`

## 4. Cheatsheet Creation with Provenance

- [ ] 4.1 Create `docs/cheatsheets/podman-logging.md` with sections:
  - `## Provenance`: https://docs.podman.io/en/latest/markdown/podman-logs.1.html, Last updated: 2026-05-01
  - `## Use when`: Inspecting container logs, debugging build failures, monitoring live output
  - `## Quick Reference`: `podman logs <container>`, `podman logs -f <container>`, filtering patterns
  - `## Timestamp Handling`: How Tillandsias prefixes lines with container source
  - `@trace spec:cli-diagnostics, spec:observability-convergence`
- [ ] 4.2 Create `docs/cheatsheets/container-lifecycle.md` with sections:
  - `## Provenance`: https://github.com/opencontainers/image-spec, https://github.com/opencontainers/runtime-spec, Last updated: 2026-05-01
  - `## Use when`: Understanding container states, debugging lifecycle issues, checking container health
  - `## State Machine`: created → running → stopped → removed (with transitions)
  - `## Status Checks`: `podman ps`, `podman inspect`, `podman stats`
  - `## Cleanup`: `podman rm`, staleness detection, orphaned container removal
  - `@trace spec:init-command, spec:observability-convergence`
- [ ] 4.3 Add "Sources of Truth" sections to all three specs referencing new cheatsheets:
  - `cli-diagnostics/spec.md`: reference podman-logging.md and container-lifecycle.md
  - `init-command/spec.md`: reference container-lifecycle.md and podman-logging.md
  - `observability-convergence/spec.md`: reference both

## 5. Trace Annotations Throughout Implementation

- [ ] 5.1 Add `// @trace spec:cli-diagnostics` annotation in `handle_diagnostics()` function header
- [ ] 5.2 Add `// @trace spec:observability-convergence` near event emission code (logging module)
- [ ] 5.3 Add `// @trace spec:init-command` near browser image build loop in `init.rs`
- [ ] 5.4 Add `// @trace spec:init-command, spec:observability-convergence` in init event emitters
- [ ] 5.5 Verify no implementation code lacks @trace annotations (grep for function definitions implementing specs)

## 6. Observability Event Structure

- [ ] 6.1 Ensure all events emitted by diagnostics and init include:
  - `spec = "cli-diagnostics"` or `spec = "init-command"` (whichever applies)
  - `cheatsheet = "docs/cheatsheets/podman-logging.md"` or `cheatsheet = "docs/cheatsheets/container-lifecycle.md"` (whichever applies)
  - Timestamp (structured logging already provides this)
- [ ] 6.2 Verify events are queryable: `grep 'spec="cli-diagnostics"' logs.txt` returns all diagnostics events
- [ ] 6.3 Test that missing containers is logged as an event (not silent) with `spec=` attribute

## 7. Integration: End-to-End Test Flow

- [ ] 7.1 Ensure `./build.sh --install` succeeds (builds tray AppImage, copies to ~/Applications/)
- [ ] 7.2 Ensure `tillandsias --init --debug` builds all 6 images (proxy, forge, git, inference, browser-core, browser-framework)
- [ ] 7.3 Verify browser images are properly tagged and inspectable: `podman images | grep browser`
- [ ] 7.4 Test `tillandsias /var/home/machiyotl/src/visual-chess --diagnostics`:
  - Should list running containers for that project
  - Should stream logs in real-time
  - Should show source labels on each line
  - Ctrl+C should exit cleanly
- [ ] 7.5 Test full end-to-end: `./build.sh --install && tillandsias --init --debug && tillandsias /var/home/machiyotl/src/visual-chess --diagnostics`
  - App installs successfully
  - All 6 images build
  - Diagnostics streams live output from launched containers

## 8. Documentation and Spec Sync

- [ ] 8.1 Verify all three specs are complete and syntactically valid (openspec validate)
- [ ] 8.2 Add commit message with GitHub search URL:
  ```
  feat: add --diagnostics CLI and browser container init
  
  @trace spec:cli-diagnostics, spec:init-command, spec:observability-convergence
  https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Acli-diagnostics&type=code
  https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Ainit-command&type=code
  https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aobservability-convergence&type=code
  ```
- [ ] 8.3 Prepare delta specs for archival (no changes to main specs needed; new capability specs created, init-command modified)
- [ ] 8.4 After implementation complete, run `/opsx:verify` to confirm code matches specs
- [ ] 8.5 After verification, run `/opsx:archive` to finalize change and sync delta specs to main

## 9. Testing & Verification

- [ ] 9.1 Unit test: `test_diagnostics_container_labeling()` — verify log prefix format
- [ ] 9.2 Unit test: `test_diagnostics_no_containers()` — verify graceful error when no containers exist
- [ ] 9.3 Integration test: `test_init_builds_all_six_images()` — verify init completes all images
- [ ] 9.4 Integration test: `test_init_debug_mode_skips_timeouts()` — verify extended timeout in --debug
- [ ] 9.5 Manual test: Run full end-to-end flow and capture logs showing observable convergence
  - Logs should have `spec=` attributes
  - Code should have `@trace` annotations
  - Cheatsheets should have provenance sections
- [ ] 9.6 Verify build passes: `./build.sh --test` (no regressions)
- [ ] 9.7 Verify cross-platform (Linux): `cargo clippy --workspace` (no warnings)
