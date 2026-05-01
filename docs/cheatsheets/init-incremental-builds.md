# Init Incremental Builds

**Provenance**: `@trace spec:init-incremental-builds`  
**Spec**: `openspec/specs/init-incremental-builds/spec.md`  
**Change**: `openspec/changes/init-incremental-builds/`

## Overview

`tillandsias --init` now supports incremental builds — if an image build fails, re-running `--init` will skip already-successful images and only rebuild failed/pending ones.

## State File

**Location**: `$HOME/.cache/tillandsias/init-build-state.json`

**Format**:
```json
{
  "version": "0.1.160.15",
  "last_run": "1715000000",
  "images": {
    "proxy": {"status": "success", "tag": "tillandsias-proxy:v0.1.160.15"},
    "forge": {"status": "failed", "tag": "tillandsias-forge:v0.1.160.15", "log_path": "/tmp/tillandsias-init-forge.log"}
  }
}
```

**Fields**:
- `version`: Tillandsias version when state was saved
- `last_run`: Unix timestamp of last init run
- `images`: Per-image status (`success`, `failed`, `pending`)

## Usage

### Basic init (incremental)
```bash
tillandsias --init
```
- Skips images that succeeded in a previous run (verifies with `podman image exists`)
- Rebuilds images that failed or are missing

### Force rebuild all
```bash
tillandsias --init --force
```
- Ignores state file, rebuilds all images from scratch
- State file is updated as each image completes

### Debug mode with failed log display
```bash
tillandsias --init --debug
```
- Shows verbose build output AND captures to `/tmp/tillandsias-init-<image>.log`
- At end of run, displays `tail -10` of each failed build's log
- Log files are created only for images that are actually built (not skipped)

## Implementation Details

| Component | File | Trace |
|------------|------|-------|
| CLI parsing | `src-tauri/src/cli.rs:147` | `spec:init-incremental-builds` |
| State structs | `src-tauri/src/init.rs:20-45` | `spec:init-incremental-builds` |
| Load/Save state | `src-tauri/src/init.rs:48-85` | `spec:init-incremental-builds` |
| Incremental logic | `src-tauri/src/init.rs:175-200` | `spec:init-incremental-builds` |
| Debug log capture | `src-tauri/src/init.rs:230-250` | `spec:init-incremental-builds` |
| Failed log display | `src-tauri/src/init.rs:380-395` | `spec:init-incremental-builds` |

## Troubleshooting

### Reset state (rebuild all)
```bash
rm ~/.cache/tillandsias/init-build-state.json
tillandsias --init
```

### Check state file
```bash
cat ~/.cache/tillandsias/init-build-state.json | jq
```

### Debug a failed build
```bash
# Run with debug to capture logs
tillandsias --init --debug

# Check the log for a specific image
tail -50 /tmp/tillandsias-init-forge.log
```

### State file says "success" but image is missing
The init command verifies with `podman image exists` before skipping. If the image was manually deleted, it will be rebuilt despite state saying "success".

## Log File Cleanup

Debug logs in `/tmp/` are NOT automatically cleaned up. They persist until:
- Manual deletion: `rm /tmp/tillandsias-init-*.log`
- System reboot (tmpfs/tmp cleanup)
- Next `--init --debug` run (overwritten per image)

## Cross-Platform Notes

- **Linux**: Uses `/home/user/.cache/tillandsias/`
- **macOS**: Uses `~/Library/Caches/tillandsias/`
- **Windows**: Uses `%LOCALAPPDATA%/tillandsias/` (via `dirs` crate)

Debug logs always use `/tmp/` regardless of platform (familiar to users, writable).
