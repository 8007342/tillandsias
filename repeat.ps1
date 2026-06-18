<#
.SYNOPSIS
    Windows-friendly wrapper for the Tillandsias /meta-orchestration repeat loop.

.DESCRIPTION
    Finds an available `bash` (Git Bash, MSYS2, WSL, or PATH) on this Windows
    host and delegates to the canonical `./repeat` script with all arguments
    passed through verbatim.

    Uses a bash wrapper that overrides `pwd` to return Windows-format paths
    so native git.exe can resolve the worktree root via `-C`.

    Supports the same interface as the bash `./repeat`:
        .\repeat.ps1 --prompt "Use the /meta-orchestration skill" [--times <n>] [--wait <duration>] [--timeout <duration>] [--agent <agents>]

    Set REPEAT_BASH to a specific bash.exe path to bypass auto-detection.

.EXAMPLE
    .\repeat.ps1 --prompt "Use the /meta-orchestration skill"
    .\repeat.ps1 --prompt "Use the /meta-orchestration skill" --times 3 --agent claude
#>

# NO named parameters — $script:rawArgs captures all script arguments.
# PowerShell parses unquoted commas as array constructors; we flatten
# nested arrays back to comma-separated strings for bash's repeat script.
$ErrorActionPreference = 'Stop'
$script:rawArgs = $args

function Find-Bash {
    $override = [Environment]::GetEnvironmentVariable('REPEAT_BASH')
    if ($override -and (Test-Path $override)) {
        return (Get-Item $override).FullName
    }

    $pathBash = Get-Command bash -ErrorAction SilentlyContinue
    if ($pathBash) {
        $source = $pathBash.Source
        $isWindowsApp = ($source -match 'WindowsApps\\bash\.exe')
        if (-not $isWindowsApp) {
            return (Get-Item $source).FullName
        }
    }

    $pf = $env:ProgramFiles
    $la = $env:LOCALAPPDATA
    $gitBashPaths = @(
        "$pf\Git\bin\bash.exe"
        "$pf\Git\usr\bin\bash.exe"
        "$la\Programs\Git\bin\bash.exe"
        "$la\Programs\Git\usr\bin\bash.exe"
    )
    foreach ($p in $gitBashPaths) {
        if (Test-Path $p) {
            return (Get-Item $p).FullName
        }
    }

    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wsl) { return 'wsl' }

    return $null
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $absPath = (Resolve-Path $WindowsPath).Path
    $drive = $absPath.Substring(0, 1).ToLower()
    $rest = $absPath.Substring(3) -replace '\\', '/'
    return "/mnt/$drive/$rest"
}

function Invoke-Repeat {
    $bashPath = Find-Bash
    if (-not $bashPath) {
        Write-Error "No bash found. Install Git for Windows (https://git-scm.com) or WSL (wsl --install)."
        exit 2
    }

    $repoRoot = $PSScriptRoot
    $repeatScript = Join-Path $repoRoot 'repeat'

    if ($bashPath -eq 'wsl') {
        $wslScript = ConvertTo-WslPath $repeatScript
        $wslCwd = ConvertTo-WslPath $repoRoot

        $wslArgs = @('bash', $wslScript)
        if ($script:rawArgs) { $wslArgs += $script:rawArgs }

        Write-Host "[repeat.ps1] delegating via wsl (cwd: $wslCwd)" -ForegroundColor Cyan
        & wsl --cd "$wslCwd" $wslArgs
        exit $LASTEXITCODE
    }

    # Native Windows bash (Git Bash, MSYS2, Cygwin) — runs repeat directly.
    # Git Bash's native git.exe cannot resolve MSYS2 paths (/c/Users/...) 
    # passed via `-C`. Override `pwd` to return Windows-format paths so the
    # repeat script's `git -C "$(pwd -P)"` works correctly.
    Write-Host "[repeat.ps1] delegating to $bashPath" -ForegroundColor Cyan

    $guid = [guid]::NewGuid().ToString('N')
    $wrapperPath = Join-Path $env:TEMP "repeat_pwd_wrapper_$guid.sh"

    $wrapperContent = "pwd() { builtin pwd -W; }`nexport -f pwd`n. '$repeatScript' `"`$@`""

    try {
        Set-Content -Path $wrapperPath -Value $wrapperContent -Encoding ASCII

        # Flatten $script:rawArgs: PowerShell parses unquoted commas as array
        # constructors (e.g. `--agent claude,codex` produces args like
        # @('--agent', @('claude', 'codex'), ...)). Rejoin nested arrays
        # back to comma-separated strings for the bash repeat script.
        $processedArgs = @()
        $i = 0
        $a = @()
        foreach ($elem in $script:rawArgs) {
            if ($elem -is [array]) {
                $a += ($elem -join ',')
            } else {
                $a += "$elem"
            }
        }

        while ($i -lt $a.Length) {
            $curr = $a[$i]
            if ($curr -eq '--agent' -and $i + 1 -lt $a.Length) {
                $processedArgs += $curr
                $i++
                $processedArgs += $a[$i]
            } else {
                $processedArgs += $curr
            }
            $i++
        }

        $argLine = ''
        if ($processedArgs) {
            $quoted = $processedArgs | ForEach-Object {
                if ($_ -match '[\s"]') { "`"$($_-replace '"', '""')`"" } else { $_ }
            }
            $argLine = ' ' + ($quoted -join ' ')
        }

        $env:MSYS2_ARG_CONV_EXCL = '*'
        $cmdLine = "cd /d `"$repoRoot`" && `"$bashPath`" --noprofile --norc `"$wrapperPath`"$argLine"
        & cmd.exe /c $cmdLine
        $ec = $LASTEXITCODE
    } finally {
        if (Test-Path $wrapperPath) { Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue }
    }

    exit $ec
}

Invoke-Repeat
