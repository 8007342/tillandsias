## Context

Tillandsias orchestrates containers via podman and authenticates with GitHub via the `gh` CLI. Currently, both operations are wrapped in bash scripts (`build-image.sh`, `gh-auth-login.sh`) that the Rust binary extracts to temp and executes. On Windows, Git Bash (MSYS2) does not initialize properly when launched from a native process, causing these scripts to fail.

The Windows image build path already bypasses bash with a direct `podman build` call in `handlers.rs`. This change extends that approach to all host-side script invocations, on all platforms.

Container entrypoints (`entrypoint.sh`, etc.) are unaffected -- they run inside Linux containers where bash works correctly.

## Goals / Non-Goals

**Goals:**
- Eliminate bash as a runtime dependency for host-side operations on all platforms
- Make GitHub Login work on Windows without Git Bash
- Unify the build-image codepath across platforms (remove `#[cfg(target_os = "windows")]` branching in `run_build_image_script`)
- Keep bash scripts in the repo for manual developer use and documentation

**Non-Goals:**
- Modifying container entrypoints (they run inside containers, bash is fine there)
- Changing the nix build backend (Phase 2 only migrates the fedora/podman-build backend)
- Rewriting the interactive terminal UI for GitHub auth (Phase 1 uses `gh` CLI's own TUI)
- Removing bash scripts from the repository

## Decisions

### D1: Phase 1 targets gh-auth-login.sh, Phase 2 targets build-image.sh

**Rationale:** gh-auth-login is the immediate pain point on Windows (it's the only remaining script that goes through bash at runtime and has user-facing impact). build-image.sh already works on Windows via the direct podman bypass, so it's lower priority.

Phase 1 delivers immediate Windows value. Phase 2 unifies the codebase.

### D2: GitHub Login uses host `gh` first, falls back to `podman run ... gh auth login`

The existing `gh-auth-login.sh` script already implements this priority:
1. If `gh` is installed on the host, use it directly (token goes to OS keyring)
2. If not, run `gh` inside a forge container with D-Bus forwarding (Linux) or hosts.yml fallback

The Rust implementation replicates this logic:
- Use `which::which("gh")` or platform-specific known paths to find host `gh`
- If found: spawn `gh auth login --git-protocol https` in a terminal
- If not found: spawn `podman run -it ... <forge-image> gh auth login --git-protocol https` in a terminal

On Windows, host `gh` is almost always available (installed via `winget` or GitHub Desktop). The container fallback is primarily for Linux headless environments.

### D3: Git identity prompting moves to Rust

The bash script prompts for git name and email before running `gh auth login`. In the Rust implementation, this is handled by:
- Reading existing values from `~/.cache/tillandsias/secrets/git/.gitconfig` (or platform equivalent)
- Using a simple terminal prompt (print question, read stdin line) before spawning the gh process
- Writing the result via `git config --file <path>`

This keeps the interactive flow identical to the bash version but without bash.

### D4: Terminal spawning uses `open_terminal` with a command, not a script path

Currently `handle_github_login` calls `open_terminal(&bash_path(&script_path), "GitHub Login")`. After migration:
- Build the full command string (either `gh auth login ...` or `podman run -it ... gh auth login ...`)
- Pass it to `open_terminal` as a command to execute
- No temp script extraction needed

The `open_terminal` function already supports running arbitrary commands on all platforms.

### D5: build-image.sh migration (Phase 2) removes cfg(windows) branching

Currently `run_build_image_script` has:
```rust
#[cfg(target_os = "windows")]
{ /* direct podman build */ }

#[cfg(not(target_os = "windows"))]
{ /* shell out to build-image.sh */ }
```

Phase 2 removes this branching. All platforms use the direct podman path. The Rust code handles:
- Staleness detection (hash computation, same logic as the bash script)
- `podman build --tag <tag> -f <Containerfile> <context>`
- Image tagging and verification

The nix backend is deferred -- it requires running nix inside a container, which is more complex. For now the fedora backend (which is the default) is the target.

### D6: Bash scripts stay in the repo as documentation

`gh-auth-login.sh` and `scripts/build-image.sh` remain in the repository:
- Developers can run them manually for debugging
- They document the intended behavior and security flags
- They serve as reference for the Rust implementation
- They are no longer `include_str!`'d or extracted at runtime

### D7: Embedded script constants are removed incrementally

- Phase 1: Remove `embedded::GH_AUTH_LOGIN` constant and `gh-auth-login.sh` from `include_str!`
- Phase 2: Remove `embedded::BUILD_IMAGE` constant and `build-image.sh` from `include_str!`
- `embedded::bash_path` can be removed after Phase 2 (no more bash invocations from the binary)

## Alternatives Considered

### A1: Fix MSYS2 initialization in bash_path

Could try harder to make Git Bash work (set `MSYSTEM`, `MSYS2_PATH_TYPE`, etc.). Rejected: this is fighting the platform instead of working with it. Direct CLI calls are simpler and more reliable.

### A2: Bundle a minimal POSIX shell (busybox-w64)

Ship a Windows busybox binary for script execution. Rejected: adds binary size, maintenance burden, and another dependency. Direct Rust calls are zero-dependency.

### A3: Use PowerShell on Windows instead of bash

Replace bash scripts with PowerShell equivalents on Windows. Rejected: still requires shelling out to a script interpreter. Direct Rust calls avoid the indirection entirely. Also creates a third codepath to maintain.
