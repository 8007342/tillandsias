# Change: fix-windows-extended-path

## Why

User-reported failure on Windows when attaching to a project from a relative path:

```
> tillandsias.exe .\tillandsias\ --debug
...
Cloning mirror {project=tillandsias, source=\\?\C:\Users\bullo\src\tillandsias, ...}
[debug] Enclave setup failed: Mirror setup failed: git clone --mirror failed:
fatal: Could not read from remote repository.

Cloning into bare repository ...
hostname contains invalid characters
```

Root cause: `Path::canonicalize()` on Windows returns paths in the extended form `\\?\C:\Users\bullo\src\tillandsias` to bypass the legacy `MAX_PATH=260` limit. When that path is passed to `git clone <source>`, git's URL parser interprets the leading `\\` as a UNC URL scheme and then chokes on the `?` character in `\\?\` with "hostname contains invalid characters".

The user's request to support local-only projects (no GitHub remote) is **already satisfied architecturally** — `ensure_mirror` clones from the local path regardless of remote presence, the post-receive hook is a no-op when there's no remote, and the forge clones from the mirror via `git://git-service:9418/<project>`. Verification (this session): the user's `tillandsias` project (which DOES have a GitHub remote) produces `Mirror origin set to project's remote URL {remote_url=https://github.com/8007342/tillandsias.git}`. The same code path with `remote_url` empty would simply skip that step and proceed.

The blocker for both local-only and remote-backed projects on Windows was the path-prefix bug. Fixing it unblocks both flows.

## What Changes

- Add `crate::embedded::simplify_path(&Path) -> PathBuf` helper that strips the `\\?\` prefix when the remainder is a normal drive-letter path. UNC paths (`\\?\UNC\server\share`) are deliberately left alone — there is no shorter form. On non-Windows the function is identity.
- Apply at `runner.rs::run_attach_command` immediately after `canonicalize()` so the rest of the runner sees a normal path.
- Apply defensively at `handlers.rs::ensure_mirror` so any future tray-mode caller that didn't strip is also safe.
- Unit-test the four cases: drive-letter strip, UNC preservation, no-prefix passthrough, Unix-paths passthrough.

## Capabilities

### Modified Capabilities
- `cli-mode`: `tillandsias <relative_or_absolute_windows_path>` now works without `git clone` choking on the `\\?\` prefix that `canonicalize()` emits.
- `git-mirror-service`: the host-path passed to `git clone --mirror` is the simplified form. Unblocks both remote-backed and local-only projects on Windows.

### New Capabilities
None — defect fix.
