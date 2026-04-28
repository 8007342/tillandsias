# scripts/build-sidecar.ps1 — PowerShell-native sidecar builder for Windows.
#
# Cross-compiles tillandsias-router-sidecar to x86_64-unknown-linux-musl using
# Rust's bundled rust-lld linker (no external cc/musl-gcc needed). The staged
# binary is consumed by:
#   - src-tauri/build.rs via include_bytes!()
#   - container builds on Linux/macOS (when those platforms run, they use the
#     bash variant build-sidecar.sh)
#
# This is the Windows-native equivalent of scripts/build-sidecar.sh. It runs
# entirely in the calling PowerShell session — no bash, no popped windows,
# no shell wrapping. All progress goes to the calling terminal.
#
# @trace spec:cross-platform, spec:opencode-web-session-otp
# @cheatsheet runtime/wsl-on-windows.md
# @cheatsheet build/cargo.md

$ErrorActionPreference = 'Continue'  # see cheatsheets/runtime/powershell.md

$scriptDir = $PSScriptRoot
$root = (Resolve-Path "$scriptDir\..").Path
$target = 'x86_64-unknown-linux-musl'
$sidecarDest = Join-Path $root 'images\router\tillandsias-router-sidecar'
# Separate target-dir to avoid deadlock when nested under a parent cargo lock.
$sidecarTargetDir = Join-Path $root 'target-musl'

# Staleness check: skip rebuild if dest exists and is newer than every source.
function Test-IsStale {
    if (-not (Test-Path $sidecarDest)) { return $true }
    $destTime = (Get-Item $sidecarDest).LastWriteTime
    $sourceDirs = @(
        (Join-Path $root 'crates\tillandsias-router-sidecar')
        (Join-Path $root 'crates\tillandsias-otp')
        (Join-Path $root 'crates\tillandsias-control-wire')
    )
    $sourceFiles = @(
        (Join-Path $root 'Cargo.toml')
        (Join-Path $root 'Cargo.lock')
    )
    foreach ($f in $sourceFiles) {
        if ((Test-Path $f) -and (Get-Item $f).LastWriteTime -gt $destTime) {
            return $true
        }
    }
    foreach ($d in $sourceDirs) {
        if (-not (Test-Path $d)) { continue }
        $newest = Get-ChildItem -Path $d -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $destTime } |
            Select-Object -First 1
        if ($null -ne $newest) { return $true }
    }
    return $false
}

if (-not (Test-IsStale)) {
    Write-Host "[build-sidecar] up-to-date: $sidecarDest"
    exit 0
}

# Ensure rustup is on PATH.
$rustup = Get-Command rustup -ErrorAction SilentlyContinue
if (-not $rustup) {
    Write-Host "[build-sidecar] ERROR: rustup not found in PATH." -ForegroundColor Red
    Write-Host "[build-sidecar] Install rustup first: https://rustup.rs/" -ForegroundColor Red
    exit 2
}

# Ensure the musl target is installed.
$installed = & rustup target list --installed
if ($installed -notmatch [regex]::Escape($target)) {
    Write-Host "[build-sidecar] Installing rust target $target..."
    & rustup target add $target
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[build-sidecar] Failed to install target $target" -ForegroundColor Red
        exit 2
    }
}

# Windows host: pin rust-lld + link-self-contained=yes so the cross-link to
# ELF musl works without external cc/musl-gcc.
# @trace spec:cross-platform
$env:CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = 'rust-lld'
$env:CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS = '-C link-self-contained=yes'

Write-Host "[build-sidecar] cargo build --release --target $target --bin tillandsias-router-sidecar --features unix-only"

$env:CARGO_TARGET_DIR = $sidecarTargetDir
Push-Location $root
try {
    & cargo build --release --target $target --bin tillandsias-router-sidecar --features unix-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[build-sidecar] cargo build failed" -ForegroundColor Red
        exit 3
    }
} finally {
    Pop-Location
    Remove-Item env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
}

$src = Join-Path $sidecarTargetDir "$target\release\tillandsias-router-sidecar"
if (-not (Test-Path $src)) {
    Write-Host "[build-sidecar] ERROR: build succeeded but binary not found at $src" -ForegroundColor Red
    exit 3
}

# Stage to images/router/. We don't strip on Windows (no host musl strip
# tool); the binary is ~3.3 MB unstripped which is acceptable.
New-Item -ItemType Directory -Force -Path (Split-Path $sidecarDest) | Out-Null
Copy-Item $src $sidecarDest -Force

$size = (Get-Item $sidecarDest).Length
$sizeMb = [math]::Round($size / 1MB, 1)
Write-Host "[build-sidecar] staged: $sidecarDest (${sizeMb} MB)"
