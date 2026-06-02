<#
.SYNOPSIS
    Windows port of `claude-repeat` (mirrors `origin/linux-next:claude-repeat`).
    Minimalistic — covers the --wait / --skill / positional-prompt shape,
    not the streaming JSON parser or Pacific timestamp helpers.

.DESCRIPTION
    Each iteration is a FRESH context (no --resume / --continue). Permissions
    are bypassed via --dangerously-skip-permissions (matches the unattended-
    loop expectation; don't run in untrusted dirs).

    Accepts both bash-style flags (--wait, --skill) and PowerShell-style
    (-Wait, -Skill) so the .bat wrapper round-trips with no translation.

    Set $env:CLAUDE_BIN to override claude.exe discovery (default: from PATH).

.EXAMPLE
    # One-shot:
    .\claude-repeat.ps1 "review the linux-next queue"

.EXAMPLE
    # 30-minute loop on a skill (either flag style works):
    .\claude-repeat.ps1 --wait 30m --skill advance-work-from-plan
    .\claude-repeat.ps1 -Wait 30m -Skill advance-work-from-plan

.EXAMPLE
    # Hourly skill + positional args (becomes "/loop check the deploy"):
    .\claude-repeat.ps1 --wait 1h --skill loop "check the deploy"
#>

# Manual $args parsing so we accept both --wait (bash) and -Wait (PS) styles.
$WaitArg = ''
$SkillArg = ''
$PromptParts = @()
$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    switch -Regex ($a) {
        '^(--wait|--repeat|-Wait|-Repeat)$' {
            $i++
            if ($i -ge $args.Count) { throw "claude-repeat: $a needs a duration (e.g. 30m, 2h, 45s)" }
            $WaitArg = $args[$i]
        }
        '^(--skill|-Skill)$' {
            $i++
            if ($i -ge $args.Count) { throw "claude-repeat: $a needs a skill name" }
            $SkillArg = $args[$i]
        }
        '^(--help|-h|-Help)$' {
            @"
Usage:
  .\claude-repeat.ps1 [--wait <duration>] [--skill <name>] ["prompt"]
  .\claude-repeat.bat --wait <duration> --skill <name>  (cmd wrapper)

Options:
  --wait <d>    Run claude, sleep d, repeat forever. d = 30m, 2h, 45s, 2h30m, 1d.
  --skill <n>   Invoke a slash command -- the prompt becomes "/<n>".
  --help        Show this help.

Each iteration is a FRESH context (no --resume); --dangerously-skip-permissions
is passed automatically. Set `$env:CLAUDE_BIN to override claude.exe discovery.
"@ | Write-Host
            exit 0
        }
        default {
            $PromptParts += $a
        }
    }
    $i++
}

# --- claude.exe discovery ---------------------------------------------------
$claudeBin = $env:CLAUDE_BIN
if (-not $claudeBin) {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { $claudeBin = $cmd.Source }
}
if (-not $claudeBin -or -not (Test-Path $claudeBin)) {
    Write-Error "claude-repeat: cannot find claude. Set `$env:CLAUDE_BIN=C:\path\to\claude.exe"
    exit 127
}

# --- compose the prompt -----------------------------------------------------
# Skill becomes "/<skill>"; positional prompt args are appended with a space
# (mirrors linux-next behavior: `--skill foo bar baz` -> "/foo bar baz").
$promptText = ''
if ($SkillArg) { $promptText = "/$SkillArg" }
if ($PromptParts.Count -gt 0) {
    $tail = ($PromptParts -join ' ').Trim()
    if ($tail) {
        $promptText = if ($promptText) { "$promptText $tail" } else { $tail }
    }
}
if (-not $promptText) {
    Write-Error "claude-repeat: need --skill <name> and/or a positional prompt"
    exit 2
}

# --- parse a --wait duration like 30m, 2h, 45s, 2h30m, 1d into seconds ------
function ConvertTo-Seconds([string]$d) {
    if (-not $d) { return 0 }
    $total = 0
    $matches = [regex]::Matches($d, '(\d+)([smhd])')
    foreach ($m in $matches) {
        $n = [int]$m.Groups[1].Value
        switch ($m.Groups[2].Value) {
            's' { $total += $n }
            'm' { $total += $n * 60 }
            'h' { $total += $n * 3600 }
            'd' { $total += $n * 86400 }
        }
    }
    if ($total -lt 1) {
        throw "claude-repeat: cannot parse duration '$d' (use 30m, 2h, 45s, 2h30m, 1d)"
    }
    return $total
}
$waitSeconds = ConvertTo-Seconds $WaitArg

# --- main loop --------------------------------------------------------------
# Pipe empty input via cmd's NUL so claude --print doesn't warn about "no stdin
# data received in 3s" when invoked from PowerShell where stdin is a console.
# Inline the cmd.exe /c invocation (no function wrapper) so claude's stdout
# passes through naturally — wrapping in a `function { ...; return $code }`
# would make PowerShell merge stdout AND the return value into a single
# captured array, silently eating the actual output.
$cmdLine = "`"$claudeBin`" --print --dangerously-skip-permissions `"$promptText`" < NUL"

if ($waitSeconds -gt 0) {
    $cycle = 0
    while ($true) {
        $cycle++
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Host "[claude-repeat] $ts cycle $cycle start wait=$WaitArg" -ForegroundColor Cyan
        cmd.exe /c $cmdLine
        $exit = $LASTEXITCODE
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Host "[claude-repeat] $ts cycle $cycle complete exit=$exit" -ForegroundColor DarkGray
        if ($exit -ne 0) { exit $exit }
        Write-Host "[claude-repeat] sleeping ${waitSeconds}s before next cycle" -ForegroundColor DarkGray
        Start-Sleep -Seconds $waitSeconds
    }
} else {
    # One-shot.
    cmd.exe /c $cmdLine
    exit $LASTEXITCODE
}
