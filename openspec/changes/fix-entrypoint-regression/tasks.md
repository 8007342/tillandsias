## 1. Fix find_project_dir() return code

- [x] 1.1 Add `return 0` at end of `find_project_dir()` in `images/default/lib-common.sh`
- [x] 1.2 Add comment explaining why the explicit return is needed

## 2. Fix install_opencode() error handling

- [x] 2.1 Change `return 1` to `return 0` on curl failure in `install_opencode()`
- [x] 2.2 Wrap `tar xzf` in `if !` guard with error message and `return 0`
- [x] 2.3 Add `|| true` to `chmod +x` and `2>/dev/null` redirect
- [x] 2.4 Clean up temp tarball on extraction failure

## 3. Fix update_opencode() error handling

- [x] 3.1 Move `tar xzf` into the `if curl` compound condition (curl && tar)
- [x] 3.2 Add `|| true` to `chmod +x` in the update path
- [x] 3.3 Clean up temp tarball on failure path

## 4. Verify

- [x] 4.1 `./build.sh --check` passes (embedded.rs recompiles with changed scripts)
- [x] 4.2 `./build.sh --test` passes (all 142 tests)
- [x] 4.3 `./scripts/build-image.sh forge --force` succeeds
- [x] 4.4 Container entrypoint survives with empty `$HOME/src/` (no project mounted)
- [x] 4.5 Container entrypoint works with project mounted (normal launch path)
