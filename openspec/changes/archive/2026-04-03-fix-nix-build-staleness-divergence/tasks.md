## 1. Fix staleness check

- [x] 1.1 Rewrite `_compute_hash()` in `scripts/build-image.sh` to use `git ls-files` instead of `find` for enumerating files in `images/default/` and `images/web/`
- [x] 1.2 Add git-repo detection: if `git rev-parse --is-inside-work-tree` fails, fall back to `find` with a warning
- [x] 1.3 Add untracked file detection: before hashing, check `git ls-files --others --exclude-standard` in image source dirs and fail with clear error if any found

## 2. Verification

- [x] 2.1 Test: create an untracked file in `images/default/`, run `build-image.sh`, confirm it fails with the untracked file error
- [x] 2.2 Test: stage the file with `git add`, run `build-image.sh`, confirm staleness check includes it
- [x] 2.3 Test: confirm normal build (no untracked files) works as before
