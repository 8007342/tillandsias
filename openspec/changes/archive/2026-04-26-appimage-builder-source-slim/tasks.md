# Tasks — appimage-builder-source-slim

## 1. Implementation

- [ ] 1.1 Declare `BUILDER_COPY_EXCLUDES=(./target ./.git ./.nix-output ./.claude ./.opencode ./node_modules './*.AppImage')` near the top of `build.sh` so callers can grep for it.
- [ ] 1.2 Replace `cp -r /src /build` with the streaming `tar … | tar` pipe documented in design.md, building the `--exclude=…` flags from `${BUILDER_COPY_EXCLUDES[@]}`.
- [ ] 1.3 Add `_assert_copy_under_150mb` helper: runs `du -sb /build`, compares against 157286400 (150 × 1024 × 1024), aborts the build with `du -sh /build/* | sort -hr | head -3` on overrun.
- [ ] 1.4 Verify `tar` is the only tool used inside the container — no new `apt-get install` lines added.

## 2. Smoke test

- [ ] 2.1 With a warm cargo cache and the existing 47 GB `target/`, run `./build.sh --install` and confirm the source-copy step takes <30 seconds (vs ~5 minutes before).
- [ ] 2.2 Confirm the produced AppImage launches the tray (smoke test: `--version` returns the new version).
- [ ] 2.3 Confirm `/build/target` is built fresh inside the container — not the host's 47 GB tree.

## 3. Cheatsheet closure

- [ ] 3.1 Add `cheatsheets/utils/tar.md` with provenance citing
  `https://www.gnu.org/software/tar/manual/` and `man tar`. Cover:
  `--exclude` patterns, streaming pipe (`-cf - … | tar -xf -`),
  `--exclude` interaction with leading `./`, exit-code conventions,
  the difference between `tar` and `bsdtar` on Alpine.
- [ ] 3.2 Update `cheatsheets/INDEX.md` (run
  `scripts/regenerate-cheatsheet-index.sh`).

## 4. Spec convergence

- [ ] 4.1 `openspec validate appimage-builder-source-slim --strict` is green.
- [ ] 4.2 `/opsx:archive` after the implementation is verified.
- [ ] 4.3 Bump `--bump-changes`.
