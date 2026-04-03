## Why

Tillandsias on Windows runs as a system tray application with no visible console window. When something goes wrong — a podman machine fails to start, a container launch errors out, or a forge image build fails — the user has no way to discover the problem through the standard Windows diagnostic tool: Event Viewer. All log output goes to a file in `%LOCALAPPDATA%\Tillandsias\tillandsias.log`, which most users will never think to check.

Windows sysadmins and power users expect well-behaved applications to write errors and important operational events to the Windows Event Log. This is the standard diagnostic surface on Windows — it's where users look when an application misbehaves silently. Adding an ETW/Event Log layer to the existing tracing subscriber stack would make Tillandsias a good citizen on Windows without affecting Linux or macOS builds.

The existing logging architecture (tracing + tracing-subscriber with layered subscribers) is designed exactly for this kind of extension. Adding a Windows-specific layer is a minimal, low-risk change.

## What Changes

- Add a Windows-only tracing subscriber layer that writes events to the Windows Application Event Log
- Errors and warnings are logged as Event Log entries visible in Event Viewer
- Accountability events (secret management, container lifecycle, image builds) are logged with structured metadata
- `@trace spec:<name>` fields are preserved in Event Log event data
- All changes are gated behind `#[cfg(target_os = "windows")]` — zero impact on Linux/macOS
- Existing file and stderr logging continues unchanged

## Capabilities

### New Capabilities
- `windows-event-logging`: Windows-specific tracing layer that emits errors, warnings, and accountability events to the Windows Application Event Log via ETW or the Event Log API

### Modified Capabilities
- `runtime-logging`: Extended to compose the Windows Event Log layer into the subscriber stack on Windows builds

## Impact

- **Windows builds**: New dependency (`tracing-etw` or `tracing-layer-win-eventlog`) added under `[target.'cfg(windows)'.dependencies]`
- **Linux/macOS builds**: No changes — all new code is `#[cfg(target_os = "windows")]`
- **Runtime**: Errors and warnings appear in Event Viewer > Windows Logs > Application under source "Tillandsias"
- **Performance**: ETW is designed for near-zero overhead when no consumer is listening; the `tracing-etw` crate targets no heap allocations in the hot path
- **Install/uninstall**: Event source registration may need to happen at install time (NSIS script) or first-run
