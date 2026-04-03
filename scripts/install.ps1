# Tillandsias Installer for Windows
# One-line install: irm https://github.com/8007342/tillandsias/releases/latest/download/install.ps1 | iex

# Force TLS 1.2 (PowerShell 5.1 defaults to TLS 1.0, GitHub requires 1.2)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = "8007342/tillandsias"
$setupAsset = "Tillandsias-windows-x86_64-setup.exe"
$setupUrl = "https://github.com/$repo/releases/latest/download/$setupAsset"
$setupPath = "$env:TEMP\$setupAsset"

# --- Download NSIS installer ---
Write-Host ""
Write-Host "  Downloading Tillandsias..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $setupUrl -OutFile $setupPath -UseBasicParsing
} catch {
    Write-Host "  Download failed: $_" -ForegroundColor Red
    Write-Host "  URL: $setupUrl" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $setupPath)) {
    Write-Host "  Download failed — file not found." -ForegroundColor Red
    exit 1
}

# --- Run NSIS installer silently ---
Write-Host "  Installing..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $setupPath -ArgumentList '/S' -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Host "  Installer exited with code $($proc.ExitCode)" -ForegroundColor Red
    Remove-Item $setupPath -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item $setupPath -Force -ErrorAction SilentlyContinue
Write-Host "  Tillandsias installed." -ForegroundColor Green

# --- Create short alias (tillandsias.exe → tillandsias-tray.exe) ---
$installDir = "$env:LOCALAPPDATA\Tillandsias"
$trayExe = "$installDir\tillandsias-tray.exe"
$aliasExe = "$installDir\tillandsias.exe"
if ((Test-Path $trayExe) -and (-not (Test-Path $aliasExe))) {
    Copy-Item $trayExe $aliasExe
}

# --- Ensure WSL2 is available (required by Podman) ---
$wslPath = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $wslPath) {
    Write-Host ""
    Write-Host "  WSL not found. Installing (requires admin + reboot)..." -ForegroundColor Cyan
    wsl --install --no-distribution 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  WSL installed. A reboot may be required before Podman works." -ForegroundColor Yellow
    } else {
        Write-Host "  WSL install failed. Run as admin: wsl --install" -ForegroundColor Yellow
    }
} else {
    # Ensure WSL2 is the default version
    wsl --set-default-version 2 2>$null | Out-Null
}

# --- Ensure Podman CLI is available ---
$podmanPath = Get-Command podman -ErrorAction SilentlyContinue
if (-not $podmanPath) {
    Write-Host ""
    Write-Host "  Podman CLI not found. Installing via winget..." -ForegroundColor Cyan
    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetPath) {
        winget install --id RedHat.Podman --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Podman installed." -ForegroundColor Green
            # Refresh PATH for this session
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        } else {
            Write-Host "  winget install failed. Install Podman manually:" -ForegroundColor Yellow
            Write-Host "    winget install RedHat.Podman" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  winget not available. Install Podman manually from:" -ForegroundColor Yellow
        Write-Host "    https://github.com/containers/podman/releases" -ForegroundColor Yellow
    }
}

# --- Initialize Podman Machine if needed ---
$podmanPath = Get-Command podman -ErrorAction SilentlyContinue
if ($podmanPath) {
    # Check if a machine exists
    $machines = podman machine list --format "{{.Name}}" 2>$null
    if (-not $machines) {
        Write-Host ""
        Write-Host "  Initializing Podman machine (first-time setup)..." -ForegroundColor Cyan
        podman machine init 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Podman machine created." -ForegroundColor Green
        } else {
            Write-Host "  Podman machine init failed — you may need to run it manually." -ForegroundColor Yellow
        }
    }

    # Start machine if not running
    $running = podman machine list --format "{{.Name}} {{.Running}}" 2>$null | Where-Object { $_ -match "true" }
    if (-not $running) {
        Write-Host "  Starting Podman machine..." -ForegroundColor Cyan
        podman machine start 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Podman machine running." -ForegroundColor Green
        } else {
            Write-Host "  Podman machine start failed — you may need to start it manually." -ForegroundColor Yellow
            Write-Host "    podman machine init && podman machine start" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "  Tillandsias is ready! Launch from Start Menu or run: tillandsias" -ForegroundColor Green
Write-Host ""
