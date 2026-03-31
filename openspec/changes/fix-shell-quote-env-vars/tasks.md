## 1. Shell quoting

- [ ] 1.1 Add `shell_quote()` function in `handlers.rs` — single-quotes args containing whitespace
- [ ] 1.2 Add `join_shell_args()` function that applies `shell_quote` and joins with spaces
- [ ] 1.3 Replace 3 `podman_parts.join(" ")` calls with `join_shell_args(&podman_parts)` (lines 624, 877, 1005)
- [ ] 1.4 Fix debug display in `runner.rs` to quote args with spaces

## 2. Verify

- [ ] 2.1 `./build-osx.sh --check` compiles clean
- [ ] 2.2 Install and test container launch from tray on macOS 26.4
