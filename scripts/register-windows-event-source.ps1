# @trace spec:windows-event-logging
# PowerShell script to register the Windows Event Log source for Tillandsias.
# Run with administrator privileges to register the event source in the
# Application event log. This is called by the NSIS installer during
# installation and can be run manually for development.
#
# Usage (admin PowerShell):
#   .\register-windows-event-source.ps1
#
# Or as a one-liner:
#   New-EventLog -LogName Application -Source Tillandsias -ErrorAction SilentlyContinue

param(
    [string]$EventSource = "Tillandsias",
    [string]$LogName = "Application"
)

# Check if running as administrator
$isAdmin = [bool]([System.Security.Principal.WindowsIdentity]::GetCurrent().groups -match "S-1-5-32-544")
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator to register the event source."
    exit 1
}

# Check if the source is already registered
try {
    $existingSource = Get-EventLog -LogName $LogName -Source $EventSource -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingSource) {
        Write-Host "Event source '$EventSource' is already registered in the '$LogName' log."
        exit 0
    }
} catch {
    # Source doesn't exist, proceed with registration
}

# Attempt to register the event source
try {
    New-EventLog -LogName $LogName -Source $EventSource -ErrorAction Stop
    Write-Host "Successfully registered event source '$EventSource' in the '$LogName' event log."
    Write-Host "You can now view Tillandsias events in Event Viewer > Application log."
    exit 0
} catch {
    Write-Error "Failed to register event source: $_"
    exit 1
}
