# Bug: `_toolbox_exists()` in `scripts/with-tillandsias-builder.sh` uses `grep -qxF` which never matches toolbox column output

**Filed**: 2026-07-08
**Classification**: bug/optimization
**Severity**: medium (blocks toolbox auto-re-exec on second+ invocation)

## Summary

`scripts/with-tillandsias-builder.sh:71` uses:
```bash
toolbox list --containers 2>/dev/null | grep -qxF "$TOOLBOX_NAME"
```

`toolbox list --containers` outputs space-aligned columns:
```
CONTAINER ID  CONTAINER NAME       CREATED        STATUS   IMAGE NAME
aa89e74cf8bf  tillandsias-builder  7 minutes ago  running  registry.fedoraproject.org/fedora-toolbox:44
```

`grep -x` requires the ENTIRE line to match, but the line has columns, so `-x` prevents any match. The function always returns false (container "doesn't exist"), causing the script to try (and fail) to recreate an already-existing container on every subsequent invocation.

## Fix

Change line 71 from:
```bash
toolbox list --containers 2>/dev/null | grep -qxF "$TOOLBOX_NAME"
```
to:
```bash
toolbox list --containers 2>/dev/null | grep -qF "$TOOLBOX_NAME"
```

Remove the `-x` (whole-line) flag so the substring match works across the columnar output.

## Resolution — 2026-07-13

Fixed on linux-next by the fresh-Silverblue provisioning drain
(linux-yolanda-fable5-20260713T1058Z). `_toolbox_exists()` now extracts the
CONTAINER NAME column and exact-matches it (safer than the proposed plain
`grep -qF`, which would also match substrings and the IMAGE NAME column):

```bash
toolbox list --containers 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$TOOLBOX_NAME"
```

Verified live on host yolanda: first `./build.sh --check` created the toolbox,
second invocation reused it (no recreate attempt). Same commit also fixes three
sibling wrapper defects found the same morning — see the commit message on
scripts/with-tillandsias-builder.sh (linux-next, 2026-07-13).

Status: resolved.
