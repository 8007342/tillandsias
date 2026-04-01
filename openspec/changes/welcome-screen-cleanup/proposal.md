## Why
Lifecycle log lines bleed into the welcome banner, dark blue text is unreadable on dark terminals, and ramdisk-backed secret mounts are not visually distinguished from disk-backed mounts.

## What Changes
- Redirect lifecycle echo lines to stderr (or suppress them) so they don't interleave with the welcome banner
- Replace dim blue (ANSI 34) with bright blue (ANSI 94) for mount source paths and ro labels
- Add a distinct color (bright magenta, ANSI 95) for ramdisk-backed mount paths
- Add "* ramdisk" legend aligned with ramdisk mounts after the mounts section

## Capabilities
### New Capabilities
_None_
### Modified Capabilities
- `forge-welcome`: Welcome screen colors updated, ramdisk legend added, lifecycle lines no longer bleed into output

## Impact
- images/default/forge-welcome.sh — color changes, ramdisk section
- images/default/entrypoint-forge-claude.sh — lifecycle lines redirected
- images/default/entrypoint-forge-opencode.sh — lifecycle lines redirected
- images/default/entrypoint-terminal.sh — lifecycle lines redirected
- src-tauri/src/embedded.rs — recompile picks up changes (include_str)
