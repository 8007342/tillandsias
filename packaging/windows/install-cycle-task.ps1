# @trace order:858-3v74, order:856-s56y
#
# install-cycle-task.ps1 — arm the durable Windows scheduler for unattended
# Tillandsias cycles: one Task Scheduler task that runs
# scripts/tillandsias-cycle-driver.sh through Git Bash, at logon (or boot) and
# then every -Interval. The Windows half of 856-s56y; the Linux half is
# scripts/install-cycle-timer.sh (systemd user timer) and is the reference.
#
# Git Bash, not PowerShell's `bash`: PowerShell's bash alias is an isolated WSL
# session without the host's git credentials (meta-orchestration skill,
# Windows note). The driver is the same script every platform runs.
#
# NO STACKING, two layers, each sufficient alone: MultipleInstances=IgnoreNew
# (Task Scheduler drops a fire while the previous one runs) and the driver's own
# lock (which also excludes an operator's manual ./repeat).
# A FAILING CYCLE DOES NOT STOP THE SCHEDULE: the repetition trigger fires on
# its own clock whatever the last exit code was; the driver's JSONL records it.
#
# -LogonType decides when the task can run:
#   Interactive (default)  only while this user is logged on; no stored secret.
#   S4U                    whether logged on or not, no password stored, but
#                          the session has NO network credentials, so git push
#                          over HTTPS may fail. Measure before relying on it.
#   Password               whether logged on or not, with the user's network
#                          credentials; prompts once for the password.
# The boot trigger follows: AtLogOn for Interactive, AtStartup otherwise.
#
# Usage:
#   powershell -File packaging/windows/install-cycle-task.ps1 -Interval 2h [-LogonType S4U] [-BootDelay 10m]
#   powershell -File packaging/windows/install-cycle-task.ps1 -Uninstall
# Fixture/demo seams: -TaskName (default TillandsiasCycle), -CycleCmd and
# -StateDir (passed to the driver as TILLANDSIAS_CYCLE_CMD and
# TILLANDSIAS_CYCLE_STATE_DIR, so a demo fires a stub instead of an agent),
# -BashPath (default: Git for Windows' bin\bash.exe), -StartIn (first fire
# delay, default 1m).
#
# Verdict grammar (exactly one line on stdout, last):
#   ^(ok:cycle-task-installed:interval=[^:]+:logon=(Interactive|S4U|Password)|ok:cycle-task-uninstalled|fail:install:[a-z-]+)$
param(
    [string]$Interval = '1h',
    [string]$BootDelay = '10m',
    [ValidateSet('Interactive', 'S4U', 'Password')][string]$LogonType = 'Interactive',
    [string]$TaskName = 'TillandsiasCycle',
    [string]$CycleCmd = '',
    [string]$StateDir = '',
    [string]$BashPath = '',
    [string]$StartIn = '1m',
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

function Fail([string]$reason, [string]$why) {
    if ($why) { [Console]::Error.WriteLine("install-cycle-task: $why") }
    Write-Output "fail:install:$reason"
    exit 1
}

# 90s, 15m, 2h, 1d -> TimeSpan; anything else is refused, not guessed.
function Parse-Span([string]$s, [string]$what) {
    if ($s -notmatch '^(\d+)(s|m|min|h|d)$') { Fail 'bad-interval' "$what '$s' is not <n>s, <n>m, <n>h or <n>d" }
    $n = [int]$Matches[1]
    switch ($Matches[2]) {
        's' { return New-TimeSpan -Seconds $n }
        { $_ -in 'm', 'min' } { return New-TimeSpan -Minutes $n }
        'h' { return New-TimeSpan -Hours $n }
        'd' { return New-TimeSpan -Days $n }
    }
}

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
        catch { Fail 'unregister' $_.Exception.Message }
    }
    Write-Output 'ok:cycle-task-uninstalled'
    exit 0
}

$every = Parse-Span $Interval '-Interval'
$delay = Parse-Span $BootDelay '-BootDelay'
$first = Parse-Span $StartIn '-StartIn'
if ($every.TotalMinutes -lt 1) { Fail 'bad-interval' 'Task Scheduler repeats no more often than once a minute' }

$checkout = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$driver = Join-Path $checkout 'scripts\tillandsias-cycle-driver.sh'
if (-not (Test-Path -LiteralPath $driver)) { Fail 'driver-missing' "no $driver" }

if (-not $BashPath) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    $candidates = @()
    if ($git) { $candidates += Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe' }
    $candidates += Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    $BashPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $BashPath -or -not (Test-Path -LiteralPath $BashPath)) { Fail 'no-git-bash' 'Git for Windows bash.exe not found; pass -BashPath' }

# The driver reads its seams from the environment, and a task action has no
# environment of its own, so the seams ride as `export` lines in the -c script.
# Single quotes inside a value are closed and reopened, the shell way.
function Sh-Quote([string]$v) { "'" + ($v -replace "'", "'\''") + "'" }
$exports = ''
if ($CycleCmd) { $exports += 'export TILLANDSIAS_CYCLE_CMD=' + (Sh-Quote $CycleCmd) + '; ' }
if ($StateDir) { $exports += 'export TILLANDSIAS_CYCLE_STATE_DIR=' + (Sh-Quote ($StateDir -replace '\\', '/')) + '; ' }
$script = $exports + 'exec bash ' + (Sh-Quote ($driver -replace '\\', '/'))
# Windows argv quoting for bash.exe: the -c script is one argument; embedded
# double quotes are backslash-escaped.
$arguments = '-c "' + ($script -replace '"', '\"') + '"'
$action = New-ScheduledTaskAction -Execute $BashPath -Argument $arguments -WorkingDirectory $checkout

$user = "$env:USERDOMAIN\$env:USERNAME"
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Add($first) -RepetitionInterval $every
if ($LogonType -eq 'Interactive') {
    $boot = New-ScheduledTaskTrigger -AtLogOn -User $user
} else {
    $boot = New-ScheduledTaskTrigger -AtStartup
}
$boot.Delay = [System.Xml.XmlConvert]::ToString($delay)

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$common = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = @($repeat, $boot)
    Settings    = $settings
    Description = "Tillandsias unattended cycle every $Interval (order 858-3v74). Remove: install-cycle-task.ps1 -Uninstall"
    Force       = $true
}
try {
    if ($LogonType -eq 'Password') {
        $cred = Get-Credential -UserName $user -Message 'Password for the Tillandsias cycle task (stored by Task Scheduler)'
        Register-ScheduledTask @common -User $user -Password $cred.GetNetworkCredential().Password -RunLevel Limited | Out-Null
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType $LogonType -RunLevel Limited
        Register-ScheduledTask @common -Principal $principal | Out-Null
    }
} catch {
    Fail 'register' $_.Exception.Message
}

Write-Output "ok:cycle-task-installed:interval=${Interval}:logon=$LogonType"
exit 0
