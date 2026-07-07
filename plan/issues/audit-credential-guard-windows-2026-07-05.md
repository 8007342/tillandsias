---
date: 2026-07-05
kind: bug-fix
status: completed
owner_host: windows
---

# Audit: Fix `check-credential-channel.sh` invocation context on Windows

## Root Cause
Agents running the meta-orchestration skill on Windows were executing `bash scripts/check-credential-channel.sh` via PowerShell. On many Windows systems without Git Bash explicitly in the path ahead of Windows utilities, `bash` invokes the Windows Subsystem for Linux (WSL), usually running as the `root` user in an isolated context.

This isolated WSL context does not have access to the Windows host's `gh` keyring or `GH_TOKEN` environment variables. As a result, `check-credential-channel.sh` would incorrectly return `missing:no-credential-channel`, causing the meta-orchestration loop to fail loud and halt, mistaking an execution context issue for a missing credential channel.

## Fix
1. **Instruction Clarity (`skills/meta-orchestration/SKILL.md`)**: The skill instructions were updated to explicitly warn agents on Windows about PowerShell's `bash` alias. Agents are now instructed to use `& "C:\Program Files\Git\bin\bash.exe" scripts/check-credential-channel.sh` (Git Bash) which natively shares the host's credentials and `gh` keyring.
2. **Script Fast-Fail (`scripts/check-credential-channel.sh`)**: Added an environment check to the start of the script. If the script detects it is running inside WSL (via `/proc/version`) while the current working directory is on a Windows mount (`/mnt/c/`, etc.), it emits a loud warning to standard error, helping future agents self-correct if they use the wrong bash context.

## Exit Criteria Met
- Credential guard runs successfully on Windows without false negatives.
- Deliverable written with root cause and fix details.
