## 1. Add --version flag

- [x] 1.1 Add `Version` variant to `CliMode` enum in `cli.rs`
- [x] 1.2 Add --version parsing before other flags in `parse()`
- [x] 1.3 Add --version to USAGE string
- [x] 1.4 Handle `CliMode::Version` in `main.rs` — print version and exit

## 2. Change init to --init

- [x] 2.1 Change `init` parsing from positional subcommand to `--init` flag in `cli.rs`
- [x] 2.2 Update USAGE string to show `--init` instead of `init`
- [x] 2.3 Update CLAUDE.md CLI reference (already used `--init` syntax)

## 3. Update references

- [x] 3.1 Update `scripts/install.sh` — changed `tillandsias init` to `tillandsias --init`
- [x] 3.2 Update other references: `init.rs` doc comment, `runner.rs` comment, `locales/en.toml` comment, `openspec/specs/init-command/spec.md`, `openspec/specs/dev-build/spec.md`

## 4. Verify

- [x] 4.1 Run `./build-osx.sh --check` — compilation passes
- [x] 4.2 `tillandsias --version` prints `Tillandsias v0.1.97`
- [x] 4.3 `tillandsias -V` also works
- [x] 4.4 `tillandsias --update` reports "Already up to date."
- [x] 4.5 `tillandsias --help` shows updated usage with `--init` and `--version`
