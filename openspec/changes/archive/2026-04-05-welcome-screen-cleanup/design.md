## Context
forge-welcome.sh uses ANSI color codes for the mount table. D_BLUE (34) is too dark. Lifecycle lines from entrypoints are plain echo to stdout that mix with the welcome banner.

## Goals / Non-Goals
**Goals:** Clean welcome screen, readable colors, ramdisk transparency
**Non-Goals:** Changing mount logic, adding new mounts, changing entrypoint behavior

## Decisions
- Lifecycle echo lines get `>&2` redirect — they're diagnostic, not user-facing
- D_BLUE replaced with B_BLUE (bright blue, 94) for mount sources
- New B_MAGENTA (95) color for any mount path containing "tmpfs" or "tokens" or "/run/secrets"
- "* ramdisk" legend line uses same B_MAGENTA color
- @trace spec:forge-welcome on all changed sections
