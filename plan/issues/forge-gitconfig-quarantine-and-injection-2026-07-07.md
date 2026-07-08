# Forge Gitconfig Quarantine and Injection (Order 224)

**Date:** 2026-07-07
**Agent:** linux-macuahuitl-bigpickle

## Summary

Prevent host `.gitconfig` from leaking into forge containers by quarantining
credential-surface paths in the OpenCode forge path (which had no quarantine)
and replacing the forge-agent path's empty tmpfs for `.config/git` with a
read-only bind-mount of a pre-populated Tillandsias-owned `.gitconfig` that
includes the mirror redirect, safe.directory, and CA bundle path.

## Deliverables

### main.rs changes

1. **`write_forge_gitconfig()`** (`main.rs:5207`): New function that writes a
   pre-populated `.gitconfig` to `~/.cache/tillandsias/forge-gitconfig/<project>.config`.
   The config includes:
   - `[safe] directory = /home/forge/src/*`
   - `[http] sslCAInfo = /etc/tillandsias/ca.crt`
   - `[credential] helper =` (disables credential helper)
   - `[core] hooksPath = /home/forge/.cache/tillandsias/git-hooks`
   - `[url "git://tillandsias-git/"] insteadOf = <host_origin_url>` (only when
     the host project has an origin URL; also adds HTTPS equivalent for SSH origins)

2. **`build_forge_agent_run_args()`** (`main.rs:7391`): Replaced
   `.tmpfs("/home/forge/.config/git:size=1m,mode=0700")` with a read-only
   bind-mount of the forge-owned gitconfig at
   `/home/forge/.config/git/config`. Keeps `.tmpfs` for `.ssh` and
   `.config/gh` (unchanged). `GIT_CONFIG_GLOBAL` remains pointing to
   `/home/forge/.config/git/config`.

3. **`build_opencode_forge_args()`** (`main.rs:3089`): Added credential
   quarantine that did not previously exist:
   - `--tmpfs /home/forge/.ssh:size=1m,mode=0700`
   - `--tmpfs /home/forge/.config/gh:size=1m,mode=0700`
   - Bind-mount forge gitconfig at `/home/forge/.config/git/config`
   - `GIT_CONFIG_GLOBAL=/home/forge/.config/git/config`

### lib-common.sh changes

4. **`lib-common.sh:114`** (`safe.directory`): Added check to skip
   `git config --global --add safe.directory` if the pattern is already
   present (avoids failure on read-only `$GIT_CONFIG_GLOBAL`).

5. **`lib-common.sh:328-337`** (`rewrite_origin_for_enclave_push`): Added
   early-return that checks whether the `url.<mirror>.insteadOf` redirect
   is already installed for the host's origin URL before attempting to
   write it. Prevents spurious `|| true` errors on the read-only mount.

### Tests

6. **`write_forge_gitconfig_produces_valid_config_with_origin_redirect`**:
   Creates a temp git repo with an HTTPS origin, calls
   `write_forge_gitconfig()`, verifies the output contains safe.directory,
   CA cert, credential helper, and mirror redirect.

7. **`write_forge_gitconfig_handles_ssh_origin_with_https_redirect`**:
   Creates a temp git repo with an SSH origin, verifies both the SSH
   redirect and the HTTPS equivalent redirect are present.

8. **`extract_gitconfig_section_finds_user_block`** / **`..._returns_none...`**:
   Unit tests for the helper function.

9. **`opencode_args_mount_workspace_and_prompt`**: Updated to assert
   credential quarantine tmpfs for `.ssh` and `.config/gh`.

10. **`forge_credential_quarantine_mounts_present`**: Updated to check for
    forge-owned gitconfig bind mount instead of `.config/git` tmpfs.

11. **`launch_forge_agent_does_not_mount_user_home`**: Updated to allow
    the forge gitconfig cache path as an exception to host-$HOME guard.

## Verification

- `cargo check --package tillandsias-headless` passes
- `cargo test --package tillandsias-headless` — 124/124 unit tests pass,
  all integration tests pass
