<!-- @trace spec:fix-windows-extended-path -->
# fix-windows-extended-path Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-16-fix-windows-extended-path/
annotation-count: 4
implementation-complete: true

## Purpose

Fix git mirror cloning on Windows when the project path is in extended form `\\?\C:\...` (returned by `Path::canonicalize()` to bypass the legacy `MAX_PATH=260` limit). Git's URL parser rejects the `\\?\` prefix, causing clone failures with "hostname contains invalid characters".

## Requirements

### Requirement: Path Simplification Helper

A `simplify_path(path: &Path) -> PathBuf` helper MUST be added to strip the Windows extended-form prefix.

#### Behavior on Windows

- **Drive-letter paths** (`\\?\C:\...`): Strip the prefix, return `C:\...`
- **UNC paths** (`\\?\UNC\server\share`): Preserve as-is (no shorter form exists)
- **Paths without prefix**: Pass through unchanged
- **Unix paths** (on non-Windows systems): Function is identity; return input unchanged

#### Scenario: Windows extended path with drive letter
- **WHEN** `simplify_path` receives `\\?\C:\Users\bullo\src\tillandsias`
- **THEN** it returns `C:\Users\bullo\src\tillandsias`

#### Scenario: Windows UNC path
- **WHEN** `simplify_path` receives `\\?\UNC\server\share`
- **THEN** it returns `\\?\UNC\server\share` (unchanged)

#### Scenario: Non-Windows system
- **WHEN** `simplify_path` is called on Linux or macOS
- **THEN** it returns the input path unchanged (identity function)

### Requirement: Apply at CLI Entry Point

The `simplify_path` helper MUST be applied immediately after `Path::canonicalize()` in `runner.rs::run_attach_command`.

#### Scenario: CLI attach to relative path
- **WHEN** user runs `tillandsias.exe .\tillandsias\ --debug` on Windows
- **WHEN** the path is canonicalized to `\\?\C:\Users\bullo\src\tillandsias`
- **THEN** `simplify_path` is applied
- **THEN** the rest of the runner code sees the simplified path `C:\Users\bullo\src\tillandsias`

### Requirement: Defensive Application in Handlers

The `simplify_path` helper MUST also be applied defensively in `handlers.rs::ensure_mirror` before the path is passed to `git clone --mirror`.

#### Scenario: Tray mode with extended path
- **WHEN** a tray-mode caller passes an extended-form path to `ensure_mirror`
- **THEN** the path is simplified before `git clone --mirror` is invoked
- **THEN** git receives a valid path it can parse

### Requirement: Unit Tests

Tests MUST cover all four path forms:
- Drive-letter paths with prefix: stripped
- UNC paths: preserved
- Paths without prefix: passed through
- Unix paths: passed through unchanged

#### Test Scenario: Strip drive-letter extended form
- **GIVEN** input `\\?\C:\Users\bullo\src\tillandsias`
- **THEN** output is `C:\Users\bullo\src\tillandsias`

#### Test Scenario: Preserve UNC paths
- **GIVEN** input `\\?\UNC\server\share`
- **THEN** output is `\\?\UNC\server\share` (unchanged)

#### Test Scenario: Unix path passthrough
- **GIVEN** input `/home/user/src/tillandsias`
- **THEN** output is `/home/user/src/tillandsias` (unchanged)

## Impact on Architecture

### Local-Only Projects (No Remote)

The architectural support for local-only projects already exists:
- `ensure_mirror` clones from the local path regardless of remote presence
- The post-receive hook is a no-op when there is no GitHub remote
- The forge clones from the mirror via `git://git-service:9418/<project>`

This spec fix unblocks the local-only flow on Windows by allowing `git clone --mirror` to succeed with the simplified path.

### Remote-Backed Projects

Projects with a GitHub remote (like the user's `tillandsias` repository) automatically set the mirror origin:
```
Mirror origin set to project's remote URL {remote_url=https://github.com/8007342/tillandsias.git}
```

This spec fix unblocks this flow on Windows as well.

## Rationale

`Path::canonicalize()` on Windows returns paths with the extended-form prefix `\\?\` to support paths longer than the legacy MAX_PATH=260 limit. However, git's URL parser interprets `\\` as a UNC scheme and rejects the `?` character, causing clone failures. Stripping the prefix where possible (drive-letter paths are shorter anyway) allows git to parse the path as a normal filesystem reference. UNC paths are left intact because their extended form is necessary for Windows semantics.

## Sources of Truth

- `docs/cheatsheets/runtime/windows-paths.md` — Windows path forms and canonicalization
- `docs/cheatsheets/build/git-operations.md` — git clone semantics and path handling

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Windows path handling is temporary; no registry changes persist
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable
