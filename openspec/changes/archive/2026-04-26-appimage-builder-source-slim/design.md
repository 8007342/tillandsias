# Design — appimage-builder-source-slim

## Context

`build.sh --install` runs `cargo tauri build --bundles appimage` inside an
Ubuntu 22.04 podman container so the resulting AppImage links against
glibc 2.35 (older than the host's). The container needs:

- The source tree (Cargo workspace + `src-tauri/` + `crates/` + `images/`
  + assets + `tauri.conf.json`)
- A writable filesystem for cargo to write `target/`
- Pre-warmed RW caches for cargo registry, cargo bin, rustup, and apt
  (these are bind-mounts; not copied)

The host repo is bind-mounted at `/src:ro,Z`. cargo refuses to write into
a read-only tree, so the script copies `/src` to a writable `/build`
before invoking cargo. The copy is currently `cp -r /src /build` with no
filter.

## Goals

- Drop the source copy from ~49 GB to <150 MB.
- Keep the change minimal — no new dependencies in the builder image, no
  new files outside `build.sh` and the OpenSpec change.
- Make the exclude list reviewable in one place (single source of truth).
- Fail loudly if the copied tree ever grows past 150 MB (early-warning
  signal that someone has dropped a multi-MB artefact into the workspace
  root or a similarly inappropriate location).

## Non-Goals

- Building from a non-`/src` source (e.g., a separate "src-only" tarball).
  That's a more invasive refactor and would not buy more than this fix.
- Replacing the Ubuntu 22.04 builder. That decision lives elsewhere
  (cross-platform build strategy).
- Changing how the cargo cache is shared (the existing bind-mounts are
  fine).

## Decision

### Replace `cp -r` with `tar … | tar`

```bash
( cd /src && tar \
    --exclude=./target \
    --exclude=./.git \
    --exclude=./.nix-output \
    --exclude=./.claude \
    --exclude=./.opencode \
    --exclude=./node_modules \
    --exclude='./*.AppImage' \
    -cf - . ) \
| ( mkdir -p /build && cd /build && tar -xf - )
```

Why `tar`:

- Default-installed in `ubuntu:22.04` (verified on the upstream image).
  `rsync` is NOT installed and would require an `apt-get install rsync`
  step that costs ~5 s on every cold cache and hits the network.
- Streams source bytes from reader to writer in one pass — no intermediate
  staging, no double disk write.
- Excludes are evaluated by `tar` itself, so excluded dirs are never
  walked. (`cp -r` has no exclude support.)

Rejected alternatives:

- **`rsync -a --exclude=…`**: cleaner syntax, but requires installing
  rsync in the builder. Net negative once you count the install.
- **Pre-build the exclude list with `find`**: works but adds I/O passes
  to enumerate paths the kernel already knows how to skip.
- **Mount `/src` rw**: would let cargo write into the host repo's
  `target/`, defeating the cross-glibc rationale (host's incremental
  artefacts use the host's glibc).
- **Build a separate "src-only" tarball on the host before invoking
  podman**: more moving parts, and the tarball itself becomes a 17 MB
  artefact that needs cleanup. The in-container `tar | tar` pipe avoids
  it.

### Exclude list

| Path                   | Reason omitted                                        |
| ---------------------- | ----------------------------------------------------- |
| `./target`             | Host cargo build output. Builder runs its own cargo.  |
| `./.git`               | VCS metadata. Builder doesn't run git.                |
| `./.nix-output`        | Cached image tarballs from `scripts/build-image.sh`.  |
| `./.claude`            | Sub-agent transcripts (per-developer, no build need). |
| `./.opencode`          | OpenCode session state (per-developer, no build need).|
| `./node_modules`       | If any future JS tooling lands; preventatively excluded. |
| `./*.AppImage`         | Previous build outputs sometimes left at root.        |

The list is encoded ONCE, in a `BUILDER_COPY_EXCLUDES` array near the top
of `build.sh`. The same array is consumed by:

1. The `tar --exclude=…` invocation in the builder.
2. A bash helper `_assert_copy_under_150mb` that runs immediately after
   the tar pipe and `du -sh /build` — fails the build if the copied tree
   exceeds 150 MB.

### Size cap

The cap is **150 MB**, which is roughly 10× the current source footprint
(17 MB). Reasoning:

- Catches drift loudly (e.g., someone commits a binary asset, lockfile
  bloat, or an unexpected sub-tree) before it costs minutes per build.
- Forgiving enough that legitimate source growth (cheatsheets, locales,
  docs, OpenSpec artefacts) doesn't trip the alarm for years.
- 150 MB ≪ the 47 GB problem we're fixing. If a future legitimate
  growth hits the cap, the answer is to revisit the cap deliberately,
  not to silently let the builder bloat back.

The check uses `du -sb /build | cut -f1` (bytes) compared against
`157286400` (150 × 1024 × 1024). On overrun the build aborts with a
specific error citing the offending top-level dir (`du -sh /build/* | sort -hr | head -3`).

## Sources of Truth

- `cheatsheets/utils/tar.md` — currently absent; will be added in tasks
  as part of the closure under the cheatsheet provenance rule.
- `cheatsheets/build/cargo.md` — confirms cargo's read-only-source
  rejection and the cross-glibc rationale.
- `cheatsheets/runtime/runtime-limitations.md` — covers the bind-mount
  RO/RW interaction model the script depends on.
