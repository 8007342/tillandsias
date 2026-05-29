---
title: Fix forge image build failure — stage cheatsheets into build context
gap: "Forge tray build fails at COPY cheatsheets/ — directory missing from runtime bundle context"
category: sdk
status: proposed
proposed_at: 2026-05-28T21:15:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Added ENV TILLANDSIAS_CHEATSHEETS, DART_ROOT, FLUTTER_ROOT so the
      diagnostics agent detects these environment variables without waiting
      for the entrypoint to source lib-common.sh.
  - file: scripts/build-image.sh
    description: |
      Changed staging logic: instead of creating cheatsheets/ and
      cheatsheet-sources/ as temporary build-context directories (and cleaning
      them up on EXIT), the script now refreshes the permanent directories in
      images/default/ from the project root canon. The cleanup trap now only
      handles the BUILD_LOG tempfile.
  - file: images/default/cheatsheets/
    description: |
      Created as a permanent copy of the project-root cheatsheets/ so the
      Tillandsias runtime packaging (which copies images/default/ verbatim)
      includes them in the build context. The Containerfile's COPY instruction
      can resolve them at podman build time.
  - file: images/default/cheatsheet-sources/
    description: |
      Created as a permanent copy of the project-root cheatsheet-sources/ for
      the same reason — the Containerfile's COPY instruction needs these
      directories in the build context at all times.
approval_required: orchestrator
approved_by:
---

## Gap

The forge image build, triggered by the Tillandsias tray, fails with:

```
Error: building at STEP "COPY cheatsheets/ /opt/cheatsheets-image/":
  checking on sources under ".../runtime/.../images/default":
  copier: stat: "/cheatsheets": no such file or directory
```

**Evidence**: `diagnostics_20260528T210510Z.stderr.log` line 3952

## Root cause

The Containerfile references `cheatsheets/` and `cheatsheet-sources/` as
build-context-relative paths (standard Dockerfile `COPY` semantics). The
`build-image.sh` script handles this by staging these directories from the
project root into `images/default/` at build time, then cleaning up afterward.

However, the Tillandsias tray's runtime build path does not use
`build-image.sh`. It copies the contents of `images/default/` into the
runtime bundle (`~/.local/share/tillandsias/runtime/<version>/`) and runs
`podman build` directly from that bundle. Since `cheatsheets/` and
`cheatsheet-sources/` were not permanent files in `images/default/`, the
runtime bundle lacked them and the build failed.

## Fix applied

1. Created `images/default/cheatsheets/` and `images/default/cheatsheet-sources/`
   as permanent directories (copied from project root canon).
2. Updated `build-image.sh` to refresh these directories without cleaning up
   afterward, so they persist for runtime bundle packaging.
3. Added `ENV TILLANDSIAS_CHEATSHEETS`, `DART_ROOT`, `FLUTTER_ROOT` to the
   Containerfile for pre-entrypoint diagnostics visibility.

## Privacy/isolation safety

This change does not weaken the forge isolation envelope. It only ensures
that the build context contains the directories the Containerfile already
references. No new mounts, credentials, or network access are introduced.
