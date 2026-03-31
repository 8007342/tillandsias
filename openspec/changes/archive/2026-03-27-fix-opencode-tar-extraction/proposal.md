## Why

The opencode tarball from GitHub releases contains a single bare file `opencode` (no directory wrapper). The entrypoint used `tar xzf ... --strip-components=1` which stripped the filename itself, extracting nothing. Result: `chmod` fails on the missing binary and the container exits.

## What Changes

- Remove `--strip-components=1` from the tar extraction in `images/default/entrypoint.sh`
- The binary extracts directly to `$OC_DIR/bin/opencode` as intended

## Impact

- Modified: `images/default/entrypoint.sh` (1 line)
- Only affects opencode agent path — claude path is unaffected
