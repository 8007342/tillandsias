## Context

The codebase has accumulated `#[allow(dead_code)]` annotations that fall into three categories:

1. **Genuinely dead** — code that was once used but no longer is, or was added speculatively and never wired up
2. **Incorrectly suppressed** — code that IS used but was marked `#[allow(dead_code)]` unnecessarily (possibly due to a previous compiler state)
3. **Planned feature code** — functions that are part of an active OpenSpec change and will be wired up soon

This change addresses categories 1 and 2 only. Category 3 is intentionally left for the owning OpenSpec changes.

## Decisions

### D1: Remove `GhRepoEntry.url` field

The `url` field is fetched via `gh repo list --json name,nameWithOwner,url` but only `name` and `name_with_owner` are used. Serde's default behavior is to ignore unknown JSON fields, so removing the Rust field does not break deserialization. The `url` field is also removed from the `--json` query parameter to avoid fetching data we discard.

### D2: Remove `cli::version_full()` function

The function wraps `VERSION_FULL.trim()` but is never called. All call sites use `VERSION_FULL.trim()` directly or the `TILLANDSIAS_FULL_VERSION` env var. The function adds no value.

### D3: Remove `#[allow(dead_code)]` from `UpdateState`

`UpdateState` is imported in `main.rs`, constructed via `Default::default()`, passed to `app.manage()`, and used in `spawn_update_tasks()`. The `#[allow(dead_code)]` is incorrect.

### D4: Fix placeholder trace in `log_format.rs`

Line 259 contains `@trace spec:name https://...` as a format example in a code comment. This is not a real trace and could confuse trace audits. Replace with the actual spec reference: `@trace spec:logging-accountability`.

### D5: Keep `install_update`, token file functions, `PlatformEntry.signature`, `write_temp_script`

These are either part of active features or active OpenSpec changes. Removing them would conflict with planned work.
