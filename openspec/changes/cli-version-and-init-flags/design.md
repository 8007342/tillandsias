## Context

The CLI parser in `cli.rs` handles modes: Tray (no args), Init ("init" subcommand), Stats (--stats), Clean (--clean), Update (--update), and Attach (path argument). Init is the odd one out using positional subcommand style. Adding --version follows the same pattern as other flag-based modes.

## Goals / Non-Goals

**Goals:**
- `tillandsias --version` prints version and exits
- `tillandsias --init` replaces `tillandsias init` with consistent flag syntax
- All documentation updated to reflect changes

**Non-Goals:**
- Adding version to tray UI or about dialog
- Changing any other CLI arguments

## Decisions

**--version prints 3-part version**: Use `CARGO_PKG_VERSION` which is the 3-part semver (e.g., "0.1.97"). This matches what --update uses for comparison. Format: "Tillandsias v{version}".

**--init parsed same as --stats/--clean/--update**: Use `args.iter().any()` pattern matching the existing flags. Keep backward compat for bare "init" during transition? No — clean break, no compatibility shims per project conventions.

## Risks / Trade-offs

- [Risk] Users with scripts using `tillandsias init` will break. Mitigation: low user count, documented in CLAUDE.md, clean error for unknown subcommands.
