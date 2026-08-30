# measure-sc11-idle-cpu.ps1 -- take one SC-11 reading, or refuse and say why.
#
# @trace order:154, spec:windows-native-tray
#
# SC-11 (plan/issues/observable-streams-contract-2026-06-30.md): "CPU usage of a
# tray with a healthy idle VM is <0.1% OF ONE CORE over a 5-minute window."
#
# WHY THIS EXISTS RATHER THAN A GET-PROCESS ONE-LINER
#
# The criterion has two preconditions that a naive sample silently ignores, and
# both have already produced numbers that looked like results:
#
#   1. THE UNIT. The threshold shipped without one. The first live measurement
#      read ~0.11% of one core and ~0.007% of a 16-core machine -- a marginal
#      fail and a 14x pass from the SAME samples. Pinned 2026-08-30 to share of
#      ONE CORE, because share-of-machine divides by core count and would let a
#      tray "improve" by moving to a bigger host. This script reports the pinned
#      unit and prints the other only as context, never as the verdict.
#
#   2. "HEALTHY IDLE VM". On 2026-08-30 a clean 300s window gave 0.1615% of one
#      core -- a 1.61x fail -- from a tray whose control wire flapped FIVE times
#      inside the sample. That is a tray reconnecting, not an idle tray, and
#      reconnection work is exactly what an idle-CPU criterion must exclude. The
#      number was real and the precondition was not met, so it was discarded.
#
# So this refuses rather than reports when the precondition fails. A refusal is
# an ABSENCE OF DATA, not a failing measurement: "the tray was not idle" and
# "the idle tray used too much CPU" are different claims and only one of them is
# about the code.
#
# ASCII-only (722-qvqb: PowerShell 5.1 parses this file as CP1252).

[CmdletBinding()]
param(
    [int]$WindowSeconds = 300,
    [int]$SettleSeconds = 45,
    [string]$LogPath = "$env:LOCALAPPDATA\tillandsias\logs\tray.log"
)

$ErrorActionPreference = 'Stop'

function Emit-Refusal([string]$reason) {
    # No cpu_percent field at all. A zero here would be a measurement claim and
    # there is no measurement.
    [pscustomobject]@{
        verdict = 'refused'
        reason  = $reason
        unit    = 'share-of-one-core'
    } | ConvertTo-Json -Compress
    exit 0
}

$proc = Get-Process tillandsias-tray -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Emit-Refusal 'no tillandsias-tray process is running' }

# Settle first: a tray that just started is provisioning, not idle.
if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }

# Mark the log position BEFORE sampling. Counting flaps over the whole file
# would fail a tray for a disconnect that happened yesterday.
$logStart = 0
if (Test-Path -LiteralPath $LogPath) {
    $logStart = (Get-Item -LiteralPath $LogPath).Length
} else {
    Emit-Refusal "tray log not found at $LogPath -- cannot verify the healthy-VM precondition, and an unverified precondition is not a passed one"
}

$proc.Refresh()
$cpu0  = $proc.TotalProcessorTime.TotalSeconds
$wall0 = Get-Date

Start-Sleep -Seconds $WindowSeconds

$proc.Refresh()
$cpu1  = $proc.TotalProcessorTime.TotalSeconds
$wall1 = Get-Date

if ($proc.HasExited) { Emit-Refusal 'the tray exited during the sampling window' }

# PRECONDITION: no control-wire disconnects inside the window. Read only the
# bytes appended since logStart, so this is scoped to the sample.
$appended = ''
if (Test-Path -LiteralPath $LogPath) {
    $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -gt $logStart) {
            $null = $fs.Seek($logStart, 'Begin')
            $buf = New-Object byte[] ($fs.Length - $logStart)
            $null = $fs.Read($buf, 0, $buf.Length)
            $appended = [System.Text.Encoding]::UTF8.GetString($buf)
        }
    } finally { $fs.Close() }
}

$flaps = ([regex]::Matches($appended, 'control wire unreachable')).Count
if ($flaps -gt 0) {
    Emit-Refusal "control wire flapped $flaps time(s) inside the window -- the tray was reconnecting, not idle, so SC-11's healthy-VM precondition did not hold"
}

$cpuSeconds = $cpu1 - $cpu0
$wallSeconds = ($wall1 - $wall0).TotalSeconds
if ($wallSeconds -le 0) { Emit-Refusal 'non-positive wall time' }

$oneCore = 100.0 * $cpuSeconds / $wallSeconds
$machine = $oneCore / [Environment]::ProcessorCount

[pscustomobject]@{
    verdict           = $(if ($oneCore -lt 0.1) { 'pass' } else { 'fail' })
    unit              = 'share-of-one-core'
    cpu_percent       = [math]::Round($oneCore, 4)
    threshold_percent = 0.1
    cpu_seconds       = [math]::Round($cpuSeconds, 3)
    wall_seconds      = [math]::Round($wallSeconds, 1)
    logical_cores     = [Environment]::ProcessorCount
    # Context only. SC-11 does not use this reading -- see the header.
    share_of_machine_percent_context_only = [math]::Round($machine, 4)
    flaps_in_window   = $flaps
} | ConvertTo-Json -Compress
