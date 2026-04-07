## Context

`build-image.sh` line 146-170 uses `find "$dir" -type f -print0` to enumerate files for hashing. Nix flake builds only see git-tracked files. The staleness check and the build see different file sets.

The embedded source path (`src-tauri/src/embedded.rs`) is unaffected — it uses `include_str!()` constants compiled into the binary, so there's no working-tree vs git-index divergence at runtime.

## Goals / Non-Goals

**Goals:**
- Make `_compute_hash()` use `git ls-files` so it sees the same files Nix sees
- Warn and fail early if untracked files exist in `images/` directories
- Maintain the existing hash format and cache file behavior

**Non-Goals:**
- Not changing how Nix builds reference files (that's correct as-is)
- Not auto-staging files — that's surprising and dangerous
- Not changing the embedded source extraction path

## Decisions

**Decision: Use `git ls-files` for hashing, fail on untracked files in image sources.**
Rationale: `git ls-files` is the ground truth for what Nix sees. Failing on untracked files prevents the silent wrong-image scenario. This is a development-time check (build-image.sh is a dev tool), so the stricter behavior is appropriate.

**Decision: Fall back to `find` if not in a git repo.**
Rationale: Edge case — someone running build-image.sh from a tarball or non-git context. The fallback preserves the existing behavior without breaking non-standard setups.

## Risks / Trade-offs

- [Risk] Developer creates a file and forgets `git add` → build fails with clear error message explaining exactly what to do. This is the intended behavior — better than silently building the wrong image.
- [Risk] Not in a git repo → Falls back to `find` with a warning. Acceptable for non-standard setups.
