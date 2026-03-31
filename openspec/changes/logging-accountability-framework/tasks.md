## Phase 1: Per-Module Log Levels via CLI

This phase adds the `--log` flag and translates it to `tracing::EnvFilter` directives.

- [ ] 1.1 Add `LogConfig` struct to `cli.rs`: `modules: Vec<(String, tracing::Level)>`, `accountability: Vec<AccountabilityWindow>`. Define `AccountabilityWindow` enum with `SecretManagement`, `ImageManagement`, `UpdateCycle` variants.
- [ ] 1.2 Add `--log=MODULES` flag parsing to `cli::parse()`. Parse semicolon-separated `module:level` pairs. Validate module names against the six defined modules (`secrets`, `containers`, `updates`, `scanner`, `menu`, `events`). Warn on unknown modules, error on invalid levels.
- [ ] 1.3 Add `--log-secret-management`, `--log-image-management`, `--log-update-cycle` flag parsing to `cli::parse()`. These set the corresponding `AccountabilityWindow` variant in the `LogConfig`.
- [ ] 1.4 Define the module-to-Rust-target mapping function in `logging.rs`: `fn module_to_targets(module: &str) -> Vec<&str>`. Maps user-facing names to Rust module paths (e.g., `"secrets"` -> `["tillandsias::secrets", "tillandsias::launch"]`).
- [ ] 1.5 Update `logging::init()` to accept `LogConfig` parameter. Build `EnvFilter` from the module map. If `LogConfig` is empty, fall back to current behavior (`TILLANDSIAS_LOG` / `RUST_LOG` / default).
- [ ] 1.6 Thread `LogConfig` from `cli::parse()` through `main.rs` to `logging::init()`. For `CliMode::Attach`, pass log config. For `CliMode::Tray`, pass log config (affects file output).
- [ ] 1.7 Add unit tests for `--log` parsing: valid single module, multiple modules, invalid module name (warning), invalid level (error), empty value, interaction with `TILLANDSIAS_LOG`.
- [ ] 1.8 Add unit tests for `module_to_targets()`: all six modules map correctly, unknown module returns empty.

## Phase 2: Accountability Window Layer

This phase adds the custom `tracing_subscriber::Layer` that formats accountability-tagged spans.

- [ ] 2.1 Create `src-tauri/src/accountability.rs` module. Define `AccountabilityLayer` struct implementing `tracing_subscriber::Layer<S>`. The layer filters on events where the span has `accountability = true` field.
- [ ] 2.2 Implement `AccountabilityFormatter` that renders the `[category] version | message` format with spec name and cheatsheet path. Version is read from `env!("CARGO_PKG_VERSION")` at compile time.
- [ ] 2.3 Define `spec_url(spec_name: &str) -> String` helper that generates `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3A{name}&type=code`. URL-encode the spec name.
- [ ] 2.4 When `--log-secret-management` is active, register the `AccountabilityLayer` with the subscriber in `logging::init()`. The layer uses a per-layer filter (`tracing_subscriber::filter::Targets`) to only process events from the `secrets` module targets.
- [ ] 2.5 Add the `mod accountability;` declaration to `main.rs`.
- [ ] 2.6 Add unit tests for `AccountabilityFormatter`: correct prefix, version present, spec URL generation, cheatsheet path present.
- [ ] 2.7 Add unit test for `spec_url()`: correct URL encoding, correct base URL.

## Phase 3: Instrument Secrets Module

This phase adds accountability-tagged spans to the existing secrets code.

- [ ] 3.1 Add `#[instrument(fields(accountability = true, category = "secrets"))]` to `secrets::store_github_token()`, `secrets::retrieve_github_token()`, `secrets::write_hosts_yml_from_keyring()`, and `secrets::migrate_token_to_keyring()`.
- [ ] 3.2 Add accountability-tagged `info!` events to each secrets function with human-readable summaries: "Token retrieved from native keyring", "Token stored in native keyring", "hosts.yml refreshed from keyring", "Token migrated from hosts.yml to keyring".
- [ ] 3.3 Add `spec` field to `trace!` events in secrets functions: `trace!(spec = "native-secrets-store", "...")`.
- [ ] 3.4 Add accountability-tagged spans to `launch.rs` `ensure_secrets_dirs()` and the secret resolution code in `build_podman_args()`.
- [ ] 3.5 Add accountability-tagged spans to `handlers.rs` at the points where `write_hosts_yml_from_keyring()` is called (three callsites: forge launch, terminal, root terminal).
- [ ] 3.6 Manual test: run `tillandsias --log-secret-management <project>` and verify the accountability output shows each secrets operation with the correct format.

## Phase 4: Instrument Remaining Modules (Future)

These tasks instrument the other five modules. They can be done incrementally.

- [ ] 4.1 Instrument `handlers.rs` container lifecycle functions with `containers` category accountability spans.
- [ ] 4.2 Instrument `updater.rs` and `update_cli.rs` with `updates` category accountability spans.
- [ ] 4.3 Instrument `tillandsias_scanner` with `scanner` category spans (debug-level only, no accountability window yet).
- [ ] 4.4 Instrument `menu.rs` and `event_loop.rs` with `menu`/`events` category spans.
- [ ] 4.5 Add integration test: launch with `--log=secrets:trace;scanner:off`, verify secrets trace output present and scanner output absent in log file.
