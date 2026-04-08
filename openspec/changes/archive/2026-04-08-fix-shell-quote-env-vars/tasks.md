## 1. Shell quoting

- [x] 1.1 Add `shell_quote()` function — `shell_quote_join()` exists in `launch.rs:272` (added in v0.1.105)
- [x] 1.2 Add `join_shell_args()` function — same as above, `shell_quote_join()` handles quoting
- [x] 1.3 Replace `podman_parts.join(" ")` calls — podman args are now passed as array (not joined string), shell quoting is only needed for terminal command display
- [x] 1.4 Fix debug display in `runner.rs:503` — already quotes args with spaces via `format!("'{a}'")`

## 2. Verify

- [ ] 2.1 `./build-osx.sh --check` compiles clean
- [ ] 2.2 Install and test container launch from tray on macOS 26.4
