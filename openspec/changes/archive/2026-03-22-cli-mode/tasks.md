## 1. CLI Argument Parser

- [x] 1.1 Create `src-tauri/src/cli.rs` with `CliMode` enum (`Tray`, `Attach { path, image, debug }`)
- [x] 1.2 Implement `parse()` function: no args = Tray, positional path = Attach, `--help` prints usage
- [x] 1.3 Support `--image <name>` flag (default "forge") and `--debug` flag

## 2. CLI Container Runner

- [x] 2.1 Create `src-tauri/src/runner.rs` with `run()` function
- [x] 2.2 Implement image check/build with user-friendly println! output
- [x] 2.3 Build podman run args with all security flags, mounts, port range
- [x] 2.4 Execute podman with inherited stdio (`.status()`) and show exit message

## 3. Main Entry Point

- [x] 3.1 Update `src-tauri/src/main.rs` to parse CLI args at top of main()
- [x] 3.2 Branch: `CliMode::Attach` calls runner::run() and returns, `CliMode::Tray` proceeds with tray setup

## 4. Dev Helper Script

- [x] 4.1 Create `run-tillandsia.sh` at project root

## 5. Build and Verify

- [x] 5.1 Build workspace with `cargo build --workspace`
