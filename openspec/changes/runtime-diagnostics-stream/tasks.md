# Tasks — runtime-diagnostics-stream

- [x] CLI: parse `--diagnostics`; thread through `CliMode::Attach` and `runner::run`
- [x] `src-tauri/src/diagnostics.rs`: Windows implementation (wsl.exe tail -F per source)
- [x] Forge `lib-common.sh::trace_lifecycle` mirrors to `/tmp/forge-lifecycle.log`
- [x] `runner.rs` Windows path passes `TILLANDSIAS_DEBUG=1` when diagnostics is set
- [ ] Linux: `podman logs -f` per enclave container, prefixed
- [ ] macOS: same as Linux (works through podman-machine)
- [ ] Curate the SOURCES list as Phase 2 services come up (proxy/router/inference on WSL)
- [ ] Cheatsheet: `cheatsheets/runtime/observability.md` cross-link
