## Context

The podman events listener is the primary mechanism for tracking container state changes. On Linux with native podman, it works reliably. On macOS/Windows where podman runs via a VM (`podman machine`), or when podman isn't installed at all, the events stream fails immediately and the retry logic creates a tight loop.

## Goals / Non-Goals

**Goals:**
- Zero CPU waste when podman is unavailable — don't even start the events listener
- When podman becomes unavailable mid-session, back off exponentially to 5 minutes max
- Correct reconnect detection that actually verifies podman can serve events
- Find podman on macOS regardless of install method (Homebrew, MacPorts, pkg installer)

**Non-Goals:**
- Auto-starting podman machine (user responsibility)
- Switching to Docker as fallback
- Watching for podman installation (restart app after installing)

## Decisions

### D1: Don't start events stream without podman

The `has_podman` check already exists at startup. Simply gate the podman events task spawn on this flag. If podman is installed but machine isn't running (`has_podman = true` but `has_machine = false` on macOS), also skip — events won't work without a running machine.

### D2: Exponential backoff in the outer loop

The outer `stream()` loop currently has no delay between retries. Add exponential backoff starting at 2s, doubling to 5 minutes max. This catches the case where podman becomes unavailable after the app starts.

### D3: Fix reconnect check

Replace `podman events --help` with `podman info --format json` which actually connects to the podman service. On macOS, this fails when the machine isn't running, making it an accurate readiness check.

### D4: macOS podman paths

Add to `find_podman_path()`:
- `/opt/homebrew/bin/podman` (Homebrew on Apple Silicon)
- `/opt/local/bin/podman` (MacPorts)

These go after the standard Linux paths but before the bare `podman` fallback.
