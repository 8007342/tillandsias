---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://www.gnu.org/software/tar/manual/tar.html
  - https://man7.org/linux/man-pages/man1/tar.1.html
  - https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html
  - https://www.busybox.net/downloads/BusyBox.html#tar
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# tar

@trace spec:agent-cheatsheets, spec:appimage-builder-source-slim

**Version baseline**: GNU tar 1.35 (Fedora 43, Ubuntu 22.04). On Alpine the
`tar` binary is BusyBox tar, which is missing several flags below — the
forge image installs GNU tar so this cheatsheet applies as written.
**Use when**: archiving / extracting / streaming files; in particular,
copying directory trees with exclusion filters (the use case `cp -r`
cannot serve).

## Provenance

- GNU tar manual (official): <https://www.gnu.org/software/tar/manual/tar.html> — full flag reference and exit-status conventions.
- `man tar` (GNU): <https://man7.org/linux/man-pages/man1/tar.1.html> — terse synopsis + per-flag semantics.
- POSIX `pax` (the standard tar inherits from): <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html> — portable archive format definition.
- BusyBox tar limitations: <https://www.busybox.net/downloads/BusyBox.html#tar> — note the missing `--exclude`, `--exclude-from`, `--anchored` on Alpine.
- **Last updated:** 2026-04-26

## Quick reference

| Command / Pattern | Effect |
|---|---|
| `tar -cf out.tar .` | Create archive `out.tar` from current dir (no compression) |
| `tar -xf in.tar -C dest` | Extract `in.tar` into `dest/` |
| `tar -tf in.tar` | List contents (do not extract) |
| `tar -czf out.tgz .` | Create gzip-compressed archive |
| `tar -xzf in.tgz` | Extract gzip-compressed archive |
| `tar -cJf out.txz .` | Create xz-compressed archive (smaller, slower) |
| `tar --exclude=./target -cf - . \| tar -xf - -C dest/` | Stream-copy with exclusion (no intermediate file) |
| `tar -cf - src \| ssh host tar -xf - -C dest` | Stream-copy across SSH |
| `tar -tvf in.tar` | Verbose list (perms, owner, size, mtime, name) |

## Common patterns

### Pattern 1 — Stream copy with exclusions (the `cp -r` substitute)

```bash
( cd /src && tar \
    --exclude=./target \
    --exclude=./.git \
    --exclude='./*.AppImage' \
    -cf - . ) | ( cd /dest && tar -xf - )
```

`cp -r` has no `--exclude`. tar does. The pipe streams in one pass — no
temp file, no double disk write. Used by `build.sh` to drop the
appimage-builder source copy from 47 GB to 17 MB
(`@trace spec:appimage-builder-source-slim`).

### Pattern 2 — Extract a single file from a big archive

```bash
tar -xzf release.tgz path/inside/archive/file.txt -O > /tmp/file.txt
```

`-O` writes to stdout instead of disk, so you can pipe it. Useful when
the archive is gigabytes and you only need one config file.

### Pattern 3 — Reproducible archive (same bytes from same input)

```bash
tar --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime='2024-01-01 00:00:00 UTC' \
    -cf reproducible.tar src/
```

Strips owner/timestamp variance so `sha256sum` is stable across machines
and times. Required when the archive feeds a hash-pinned download (Nix,
content-addressable storage).

### Pattern 4 — Convert tarball compression in place

```bash
zstd -dc in.tar.zst | tar -xf -
```

tar accepts uncompressed input on stdin. Pair with any decompressor
(`gzip -dc`, `xz -dc`, `zstd -dc`, `lz4 -dc`) instead of relying on tar's
auto-detection — BusyBox tar lacks the `-z`/`-J`/`--zstd` flags.

### Pattern 5 — List archive contents without extracting

```bash
tar -tvf in.tar | head -20      # human-readable
tar -tf  in.tar | wc -l         # count entries
```

`-t` is read-only; safe to run on archives from untrusted sources before
extracting.

## Common pitfalls

- **`--exclude` patterns are anchored at the working directory inside
  the archive, NOT the host.** Write `--exclude=./target` (with the
  leading `./`) when streaming `tar -cf - .` — `--exclude=target`
  matches differently and may skip more or less than intended. The
  GNU manual section "Wildcard patterns and matching" is the source of
  truth.
- **Shell expansion of glob `*`.** `--exclude=*.tmp` lets the shell
  expand the glob against the current directory FIRST, replacing it
  with whatever `*.tmp` files are local. Quote it: `--exclude='*.tmp'`
  or escape: `--exclude=\*.tmp`. The script
  `build.sh::appimage-builder-source-slim` uses `--exclude=./\*.AppImage`
  because it lives inside a single-quoted bash -c argument where
  embedded single quotes would close the outer string.
- **BusyBox tar (Alpine) lacks `--exclude`, `--anchored`,
  `--transform`, and `--sort`.** Containers based on `alpine:*` need
  `apk add tar` to install GNU tar. The forge uses Fedora minimal so
  this is not an issue, but builder/image scripts that target Alpine
  must check.
- **`tar -czf` vs `tar -xzf` argument order.** GNU tar accepts both
  `-czf out.tgz dir` and `-cf out.tgz -z dir`, but BSD tar (macOS) is
  pickier about flag clustering. Stick to long-form (`--create
  --gzip --file=out.tgz dir`) when writing scripts intended to run on
  both.
- **Trailing slash on the source path.** `tar -cf x.tar src/` and
  `tar -cf x.tar src` produce slightly different tarball internals
  (the path within the archive starts with `src/` either way, but
  rsync-style trailing-slash semantics do NOT apply — tar always
  archives the named directory itself).
- **Symlinks.** Default behaviour archives the symlink, NOT the target.
  Use `--dereference` (`-h`) to follow links and archive the targets.
  Reverse: `--keep-old-files` on extract to refuse to overwrite.
- **Sparse files.** Cargo's `target/` and many database files have
  large sparse regions. `tar` without `--sparse` (`-S`) writes them
  fully expanded — a 1 MiB sparse file becomes 1 MiB in the archive
  even if the on-disk size was 10 KiB. Enable sparse handling for any
  archive that may contain VM images, database files, or build
  artefacts.
- **Exit code 1 vs 2.** `tar` exits 1 on "some files differ" (during
  `--diff`) and exits 2 on "fatal error". A script that checks
  `if ! tar …; then` treats 1 the same as 2. Test `$?` explicitly when
  you need to distinguish.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://www.gnu.org/software/tar/manual/tar.html`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.gnu.org/software/tar/manual/tar.html`
- **License:** see-license-allowlist
- **License URL:** https://www.gnu.org/software/tar/manual/tar.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.gnu.org/software/tar/manual/tar.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://www.gnu.org/software/tar/manual/tar.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/tar.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/rsync.md` — when you need delta sync (only changed files
  cross the wire), not stream-copy.
- `utils/curl.md` — pair with curl for tarball pipelines:
  `curl -fsSL <url> | tar -xzf -`.
- `build/cargo.md` — explains why cargo's `target/` is the recurring
  exclusion target in tar pipes.
