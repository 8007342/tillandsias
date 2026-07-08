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
