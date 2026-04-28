# Windows Event Viewer for Tillandsias

**Use when**: Diagnosing errors and warnings on Windows systems, or accessing Tillandsias application logs visible to all system users.

## Provenance

- https://learn.microsoft.com/en-us/windows/win32/eventlog/event-logging — Official Microsoft Event Logging documentation
- https://learn.microsoft.com/en-us/windows/win32/wes/windows-event-service — Windows Event Service reference
- **Last updated:** 2026-04-27

## Overview

Tillandsias writes errors, warnings, and accountability events to the Windows Event Log via the "Tillandsias" event source. Events appear in **Event Viewer > Windows Logs > Application** under the source name **Tillandsias**.

Unlike file-based logs, Event Log entries are:
- Visible to all users (not stored in user-only directories)
- Persistent across reboots
- Queryable and filterable by severity and timestamp
- Accessible via Event Viewer UI or PowerShell (`Get-EventLog`)

## Viewing Events in Event Viewer

### GUI Method

1. **Open Event Viewer**:
   - Press `Win+R`, type `eventvwr.msc`, press Enter
   - Or: Control Panel → Administrative Tools → Event Viewer

2. **Navigate to Application Log**:
   - Left sidebar: **Windows Logs** > **Application**

3. **Filter by Tillandsias source**:
   - Right sidebar: Click **Filter Current Log**
   - Event sources: Type `Tillandsias`
   - Click **OK**

4. **Inspect events**:
   - Events are listed by timestamp (newest first)
   - Double-click an event to view full details
   - Accountability events include Category, Safety, and Spec information in the description

### PowerShell Method

View all Tillandsias events in the current session:

```powershell
Get-EventLog -LogName Application -Source Tillandsias | Select-Object TimeGenerated,EntryType,Message
```

View errors only:

```powershell
Get-EventLog -LogName Application -Source Tillandsias -EntryType Error
```

View the last 10 events:

```powershell
Get-EventLog -LogName Application -Source Tillandsias -Newest 10
```

Export to CSV:

```powershell
Get-EventLog -LogName Application -Source Tillandsias | Export-Csv -Path "C:\tillandsias-events.csv"
```

## Event Levels

| Level | Icon | Meaning | When to Investigate |
|-------|------|---------|---------------------|
| **Error** | Red X | A serious problem — operation failed or security violation | Always; check logs for root cause |
| **Warning** | Yellow ! | Potential issue — may impact functionality | Yes; understand the condition |
| **Information** | Blue i | Accountability event — high-signal operational event | Rarely; used for compliance audits |

## Event Message Format

### Regular Events

```
Container stopped
{container=tillandsias-myapp-aeranthos, reason=user-requested}
```

### Accountability Events

```
GitHub token retrieved from OS keyring
Category: secrets
Safety: Never written to disk, injected via bind mount
@trace spec:native-secrets-store
```

## Manual Event Source Registration

The Tillandsias installer automatically registers the event source. If using a portable build or development installation:

```powershell
New-EventLog -LogName Application -Source Tillandsias
```

**Note**: Requires administrator privileges. Run PowerShell as Admin.

To verify registration:

```powershell
Get-EventLog -List | Select-Object Log
```

Should include an "Application" entry.

## Troubleshooting

### Events not appearing

1. **Event source not registered**: Run `New-EventLog -LogName Application -Source Tillandsias` in PowerShell admin
2. **Tillandsias running as SYSTEM**: Events may appear under a different source name; check all sources in Application log
3. **Older event log retention**: Old events are removed after 30 days by default; check Event Viewer > Application Properties

### "Access Denied" when filtering

- Event Viewer must run with admin privileges to access some event properties
- Right-click Event Viewer → "Run as Administrator"

### PowerShell commands fail with "No matches found"

- The event source "Tillandsias" may not be registered
- Run `New-EventLog -LogName Application -Source Tillandsias`
- Restart Tillandsias for new events to appear

## Clearing Old Events

To delete events older than a date (e.g., clear events before 2026-01-01):

```powershell
Get-EventLog -LogName Application -Source Tillandsias | Where-Object { $_.TimeGenerated -lt "2026-01-01" } | Remove-EventLog
```

**Caution**: Event clearing is permanent and cannot be undone.

## Related Cheatsheets

- `runtime/logging-levels.md` — Log level reference and environment variables
- `build/windows-cross-compilation.md` — Windows build and deploy process

@trace spec:windows-event-logging
