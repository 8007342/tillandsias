<#
.SYNOPSIS
    Build (and optionally package) the Tillandsias Windows tray
    (tillandsias-tray.exe).

.DESCRIPTION
    The windows-owned parallel to scripts/build-macos-tray.sh. Compiles the
    `tillandsias-windows-tray` crate for the host MSVC target and reports the
    resulting executable path. Release by default (GUI subsystem, no console
    window); pass -DebugBuild for a console-attached build that surfaces tracing
    output for interactive debugging.

    With -Release it ALSO packages the publishable release artifacts (mirroring
    build-macos-tray.sh): a `tillandsias-tray-<version>-windows-x64.zip` (the exe
    + install-windows.ps1) plus a distinct `SHA256SUMS-windows` (so it does not
    collide with the Linux/macOS sums in the shared release), written under
    `release-artifacts/`. This absorbs the inline packaging stopgap previously in
    the release.yml `windows-release` job (tray-convergence-coordination.md ask).

    Guest-binary embed (order 190 windows half / order 282): before compiling,
    any non-empty staged guest headless under `target-guest/` (the
    scripts/build-guest-binaries.sh staging contract) is copied per-arch into
    `crates/tillandsias-windows-tray/assets/` so `include_bytes!` embeds it and
    fresh WSL guests skip the release-download fetch (no version skew). When a
    staged binary is absent the build.rs zero-byte placeholder stays, keeping
    the in-VM fetch-headless network fallback for that arch. Artifact transport
    onto a Windows host, any of: (a) build inside the local WSL distro with a
    rustup musl toolchain and `install` the binary into `target-guest/`;
    (b) copy `target-guest/` from a Linux checkout (CI nightly or sibling
    host); (c) let the guest fetch the published release (the fallback this
    embed demotes).

    @trace spec:windows-native-tray, spec:linux-native-portable-executable

.PARAMETER DebugBuild
    Build the debug profile (keeps a console window + assertions) instead of
    release. Mutually exclusive with -Release.

.PARAMETER Release
    After a release build, stage + zip the publishable artifacts + emit
    SHA256SUMS-windows under release-artifacts/. Implies a release profile.

.PARAMETER Version
    Release version string (no leading 'v') used in the artifact name. Defaults
    to the contents of the repo-root VERSION file. Only used with -Release.

.PARAMETER Sign
    Authenticode-sign the staged tray exe through Azure Artifact Signing before
    it is zipped and hashed (orders 722-qvqb / 724-rpna). Opt-in: the signing
    plan is 5,000 signatures/month, so a developer build loop must not spend it
    on artifacts nobody ships. A build without -Sign says plainly that it is
    unsigned; a build WITH -Sign that cannot sign fails rather than degrading.

    Locally: `az login` first -- DefaultAzureCredential resolves
    AzureCliCredential. In CI: federated OIDC, same code path.

.EXAMPLE
    scripts\build-windows-tray.ps1
    scripts\build-windows-tray.ps1 -DebugBuild
    scripts\build-windows-tray.ps1 -Release
    scripts\build-windows-tray.ps1 -Release -Version 0.2.260527.1
    scripts\build-windows-tray.ps1 -Release -Sign
#>
[CmdletBinding()]
param(
    [switch]$DebugBuild,
    [switch]$Release,
    [string]$Version,
    [switch]$Sign,
    # Order 776-g6r3. Emit the MSIX with Revision=0. The Store may reserve the
    # fourth version field; this host cannot reach Partner Center validation to
    # settle it, so the constraint is a FLAG rather than a guess in either
    # direction. See the version block in the MSIX section for what it costs.
    [switch]$MsixStoreRevisionZero
)

$ErrorActionPreference = 'Stop'

if ($DebugBuild -and $Release) {
    throw "-DebugBuild and -Release are mutually exclusive (packaging needs a release build)."
}

# Repo root = parent of this script's directory.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# Ensure cargo is on PATH (matches the project's session convention).
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo not found on PATH. Install Rust (https://rustup.rs) or add %USERPROFILE%\.cargo\bin."
}

# --- Stage guest headless binaries into assets/ (order 190 windows half) ------
# Embed per HOST arch (order 282): a WSL2 guest always matches the Windows
# host architecture, so only that one staged binary from target-guest/ (the
# scripts/build-guest-binaries.sh staging contract) is copied into the
# crate's assets/ for include_bytes! embedding. The other arch's asset is
# reset to the zero-byte placeholder (absent-asset = in-VM fetch-headless
# fallback) so a stale copy can't bloat the exe by ~40MB. Copy only when
# content differs so incremental cargo builds don't recompile for an
# unchanged asset.
$assetsDir = Join-Path $RepoRoot 'crates\tillandsias-windows-tray\assets'
New-Item -ItemType Directory -Force $assetsDir | Out-Null
# The version every staged guest must carry to be embeddable (order 689-gipe).
# Read from the repo-root VERSION, the same source build.rs stamps into
# WORKSPACE_VERSION, so the build-time refusal and the test-time assertion
# cannot disagree about what "current" means.
$workspaceVersion = (Get-Content (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
$hostGuestArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$guestArches = @('x86_64', 'aarch64')
foreach ($guestArch in $guestArches) {
    $guestBin = "tillandsias-headless-$guestArch-unknown-linux-musl"
    $stagedGuest = Join-Path $RepoRoot "target-guest\$guestBin"
    $assetGuest = Join-Path $assetsDir $guestBin
    if ($guestArch -ne $hostGuestArch) {
        if ((Test-Path $assetGuest) -and ((Get-Item $assetGuest).Length -gt 0)) {
            [System.IO.File]::WriteAllBytes($assetGuest, @())
            Write-Host "Reset non-host-arch guest asset to placeholder: $guestBin" -ForegroundColor DarkGray
        }
        continue
    }
    if ((Test-Path $stagedGuest) -and ((Get-Item $stagedGuest).Length -gt 0)) {
        # Order 689-gipe: a staged binary that predates the checkout is the
        # dangerous case, and it used to be copied silently -- the hash compare
        # below only asks "did the asset change", never "is it CURRENT". A
        # tray built that way embeds a guest older than its own source and
        # injects it into fresh provisions, which is the registered-distro
        # version skew order 350's identity criterion exists to catch. Nothing
        # caught it at build time; the only guard was
        # `embedded_guest_headless_matches_workspace_version` in a test run
        # that a build does not perform.
        #
        # Stale staging is HOST STATE, not a code defect (order 447: any
        # --install VERSION bump leaves target-guest/ behind), so the response
        # matches that script's posture -- refuse the STALE COPY, not the
        # build. The asset falls back to the zero-byte placeholder, which is
        # the sanctioned absent-asset path: a fresh guest fetches the
        # published release instead of being handed a skewed binary.
        $stagedVersionOk = $false
        try {
            $needle = [System.Text.Encoding]::ASCII.GetBytes($workspaceVersion)
            $hay = [System.IO.File]::ReadAllBytes($stagedGuest)
            for ($i = 0; $i -le ($hay.Length - $needle.Length); $i++) {
                $hit = $true
                for ($j = 0; $j -lt $needle.Length; $j++) {
                    if ($hay[$i + $j] -ne $needle[$j]) { $hit = $false; break }
                }
                if ($hit) { $stagedVersionOk = $true; break }
            }
        } catch {
            $stagedVersionOk = $false
        }
        if (-not $stagedVersionOk) {
            Write-Host "  WARN: staged guest binary target-guest\$guestBin does not carry workspace VERSION $workspaceVersion - it predates this checkout. NOT embedding it (a stale embed injects a version-skewed guest into fresh provisions); the asset falls back to the zero-byte placeholder and fresh guests fetch the published release. Restage with scripts/build-guest-binaries.sh." -ForegroundColor Yellow
            if ((Test-Path $assetGuest) -and ((Get-Item $assetGuest).Length -gt 0)) {
                [System.IO.File]::WriteAllBytes($assetGuest, @())
            }
            continue
        }
        $srcHash = (Get-FileHash $stagedGuest -Algorithm SHA256).Hash
        $dstHash = ''
        if ((Test-Path $assetGuest) -and ((Get-Item $assetGuest).Length -gt 0)) {
            $dstHash = (Get-FileHash $assetGuest -Algorithm SHA256).Hash
        }
        if ($srcHash -eq $dstHash) {
            Write-Host "Guest binary already staged (unchanged): $guestBin" -ForegroundColor DarkGray
        } else {
            Copy-Item $stagedGuest $assetGuest -Force
            Write-Host "Staged guest binary into assets ($hostGuestArch host): $guestBin" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  WARN: no staged guest binary at target-guest\$guestBin for this host arch - embedded asset stays empty; fresh guests fall back to fetching the latest release (version skew possible). Stage with scripts/build-guest-binaries.sh (see .DESCRIPTION for Windows transport options)." -ForegroundColor Yellow
    }
}

$profileName = if ($DebugBuild) { 'debug' } else { 'release' }
$buildArgs = @('build', '-p', 'tillandsias-windows-tray')
if (-not $DebugBuild) { $buildArgs += '--release' }

Write-Host "Building tillandsias-tray ($profileName)..." -ForegroundColor Cyan
# Cargo writes its progress messages ("Compiling...", "Finished...") to stderr.
# Under `$ErrorActionPreference = 'Stop'` PowerShell wraps each stderr write
# from a native exe as a NativeCommandError RemoteException, which the Stop
# trap treats as a terminating error -- aborting the build mid-stream the
# moment cargo first writes "Compiling X". This is the well-known stderr-wrap
# quirk documented in skills/build-windows-tray + cheatsheets/runtime/
# windows-tray-diagnostics.md. Locally relax the preference around the cargo
# invocation, capture $LASTEXITCODE explicitly, then restore -- a real cargo
# compile failure still surfaces via the exit code check below.
$prevErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & cargo @buildArgs
    $cargoExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevErrorActionPreference
}
if ($cargoExit -ne 0) { throw "cargo build failed (exit $cargoExit)" }

$exe = Join-Path $RepoRoot "target\$profileName\tillandsias-tray.exe"
if (-not (Test-Path $exe)) { throw "expected binary not found: $exe" }

Write-Host "Built: $exe" -ForegroundColor Green

if (-not $Release) {
    # Emit the path as the script's object output so callers can capture it.
    Write-Output $exe
    return
}

# --- Release packaging (mirrors build-macos-tray.sh) ---------------------------
if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionFile = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path $versionFile)) {
        throw "-Release needs a version: pass -Version or provide a repo-root VERSION file."
    }
    $Version = (Get-Content $versionFile -Raw).Trim()
}
# Tolerate a leading 'v' if a caller passes a tag.
$Version = $Version.TrimStart('v')

$artifactsDir = Join-Path $RepoRoot 'release-artifacts'
New-Item -ItemType Directory -Force $artifactsDir | Out-Null

$base = "tillandsias-tray-$Version-windows-x64"
$stage = Join-Path $artifactsDir $base
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $exe (Join-Path $stage 'tillandsias-tray.exe')
# Ship the canonical operator scripts inside the release zip so users get
# the full diagnostic toolchain on extract -- no need to clone the repo
# separately for tray-diagnose.ps1 / diagnose-windows.ps1. Each script
# is best-effort: a missing source path is non-fatal so the build still
# packages the core binary + installer.
$bundledScripts = @(
    'install-windows.ps1', # curl installer (parity with install.sh / install-macos.sh)
    'tray-diagnose.ps1',   # live-runtime health check (consumes --diagnose --json)
    'diagnose-windows.ps1' # pre-tray host-facts diagnostic
)
foreach ($scriptName in $bundledScripts) {
    $src = Join-Path $RepoRoot "scripts\$scriptName"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $stage $scriptName)
    } else {
        Write-Host "  WARN: bundled script $scriptName not found at $src" -ForegroundColor Yellow
    }
}

# -- Authenticode (orders 722-qvqb / 724-rpna) -------------------------------
# POSITION IS LOAD-BEARING. Signing mutates the exe, so it must happen on the
# STAGED file -- before Compress-Archive below and before the Get-FileHash that
# writes SHA256SUMS-windows. Sign after either and every published checksum
# describes a file nobody can download, which reaches users as a checksum
# mismatch on a correctly signed binary: indistinguishable, from the outside,
# from a supply-chain attack.
#
# The bare tillandsias-tray.exe the release workflow extracts from the zip
# inherits this signature, which is why one signing call here covers every
# published Windows artifact.
$stagedExe = Join-Path $stage 'tillandsias-tray.exe'
if ($Sign) {
    Write-Host "Signing $stagedExe ..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'sign-windows-artifact.ps1') -Path $stagedExe
    if ($LASTEXITCODE -ne 0) {
        # A signing failure must never degrade into an unsigned release. The
        # whole point of 722-f86z is that a step which quietly no-ops when a
        # credential is absent ships unsigned binaries under a green run.
        throw "signing refused (see the blocked:signing: verdict above); refusing to package an unsigned artifact"
    }
} else {
    # SAY IT. An unsigned build that looks exactly like a signed one is the
    # defect this milestone exists to prevent. Opt-in locally because the plan
    # is 5,000 signatures/month and a build loop would burn it on artifacts
    # nobody ships.
    Write-Host "  NOTE: UNSIGNED build (pass -Sign to Authenticode-sign; requires az login or CI federated credentials)" -ForegroundColor Yellow
}

# -- MSIX (order 776-g6r3) ---------------------------------------------------
# POSITION IS LOAD-BEARING, for the same reason the zip's is: this packages the
# STAGED exe, so it must run AFTER the -Sign block above. Signing mutates the
# file; packaging first would seal an unsigned binary inside a package whose
# checksum we then publish (722-qvqb).
#
# It must also run BEFORE the Remove-Item of $stage further down. The MSIX and
# the zip are two packagings of one staged payload, not two builds.
#
# The MSIX supersedes install-windows.ps1's job rather than shipping it: the
# startupTask replaces the Startup-folder shortcut, the package root replaces
# %LOCALAPPDATA%\Programs, and Store uninstall replaces the HKCU uninstall key.
# So the MSIX payload is the exe and its assets only -- the bundled operator
# scripts stay in the zip, which is the channel that still needs them.
$msix = Join-Path $artifactsDir "$base.msix"
$msixTemplate = Join-Path $RepoRoot 'packaging\msix\AppxManifest.xml.template'
if (Test-Path -LiteralPath $msixTemplate) {
    Write-Host "Packaging MSIX ..." -ForegroundColor Cyan

    # -- resolve makeappx ----------------------------------------------------
    # Same glob + env-override shape as sign-windows-artifact.ps1's signtool
    # resolution, deliberately: two tools from the same SDK discovered two
    # different ways is how one of them silently stops being found.
    $makeappx = $env:TILLANDSIAS_MAKEAPPX
    if (-not $makeappx) {
        $candidates = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe",
            "${env:ProgramFiles}\Windows Kits\10\bin\*\x64\makeappx.exe"
        ) | ForEach-Object { Get-ChildItem -Path $_ -ErrorAction SilentlyContinue } |
            Sort-Object { try { [version]$_.VersionInfo.ProductVersion } catch { [version]'0.0' } } -Descending
        if ($candidates) { $makeappx = $candidates[0].FullName }
    }
    if (-not $makeappx -or -not (Test-Path -LiteralPath $makeappx)) {
        throw "makeappx-absent (need the Windows SDK; set TILLANDSIAS_MAKEAPPX to override)"
    }

    # -- version: ONE encoding, two consumers --------------------------------
    # Reuses crates/tillandsias-windows-tray/build.rs's u16 re-encoding rather
    # than inventing a second one. 0.4.260826.1 -> 0.4.2608.2601: YYMMDD does
    # not fit a u16 field, so it splits as YYMM and DD*100+N, monotonic within
    # each field.
    #
    # OPEN CONSTRAINT, deliberately not guessed: Store submissions may require
    # Revision=0 (Microsoft reserves the fourth field). This host cannot reach
    # Partner Center validation to settle it, so the default keeps the full
    # encoding and -MsixStoreRevisionZero produces the Store variant. If the
    # Store does require it, same-day builds collide at 0.4.2608.0 and the N
    # component needs somewhere else to live -- that is a decision for the
    # submission slice, not a default to assume here.
    # SUPERSEDED 2026-08-31 by the epoch-anchored encoding below. The old
    # YYMM/DD*100+N split kept the workspace major in field one, and the
    # workspace major is 0 -- which the Store forbids outright ("the first
    # section cannot be 0"). Every MSIX this repo produced was rejected before
    # certification ever looked at it, and -MsixStoreRevisionZero alone did not
    # help: it fixed field four while field one stayed 0.
    #
    # OPERATOR-DIRECTED ENCODING, 2026-08-31:
    #
    #     <minor> . <years_since_epoch><day_of_year:3> . <daily_N> . 0
    #     0.4.260831.5  ->  4.56243.5.0
    #
    # Field 1 is the workspace MINOR, promoted so field one is non-zero.
    # Field 2 concatenates years since the Unix epoch with the zero-padded day
    # of year. Field 3 is the daily build number. Field 4 is 0, which the Store
    # reserves.
    #
    # THE ZERO-PADDING IS LOAD-BEARING, not cosmetic. Unpadded, 2026 day 366
    # encodes as 56366 and 2027 day 001 as 571 -- the version would go BACKWARDS
    # at the year boundary, and the Store permanently refuses a version lower
    # than one already shipped. Padded, 56366 -> 57001 and it climbs.
    #
    # TWO KNOWN LIMITS, recorded rather than discovered later:
    #   * FIELD 2 OVERFLOWS IN 2036. Store fields cap at 65535; year 65 (2035)
    #     yields at most 65366 and fits, year 66 (2036) yields 66001 and does
    #     not. That is ~9 years of runway and a hard wall, not a degradation.
    #   * MINOR MUST NEVER BE 0. Field one is the minor, so a future 1.0 release
    #     would put 0 back in field one and the package would be rejected again
    #     for the exact reason this encoding exists to fix.
    # Both are asserted below rather than trusted.
    $vParts = $Version.Split('.')
    if ($vParts.Count -ne 4) {
        throw "msix-version-unmappable: expected major.minor.YYMMDD.N, got '$Version'"
    }
    $minor = [int]$vParts[1]
    if ($minor -lt 1) {
        throw "msix-version-first-field-zero: the MSIX first field is the workspace MINOR and it is '$minor'. The Store forbids a leading 0, so this package would be rejected. Pick a non-zero minor or re-map the encoding."
    }
    # Day-of-year from the workspace version's own YYMMDD, NOT from the wall
    # clock: rebuilding an old tag must reproduce its version, and `date` would
    # silently stamp today onto a rebuild of last week's release.
    $yymmdd = $vParts[2]
    if ($yymmdd -notmatch '^\d{6}$') {
        throw "msix-version-unmappable: expected a 6-digit YYMMDD in field 3, got '$yymmdd'"
    }
    $stampYear  = 2000 + [int]$yymmdd.Substring(0, 2)
    $stampMonth = [int]$yymmdd.Substring(2, 2)
    $stampDay   = [int]$yymmdd.Substring(4, 2)
    $stamp = Get-Date -Year $stampYear -Month $stampMonth -Day $stampDay -Hour 0 -Minute 0 -Second 0
    $yearsSinceEpoch = $stampYear - 1970
    $dayOfYear = $stamp.DayOfYear
    $fineGrained = [int]("{0}{1:D3}" -f $yearsSinceEpoch, $dayOfYear)
    if ($fineGrained -gt 65535) {
        throw "msix-version-field-overflow: fine-grained field is $fineGrained and the Store caps fields at 65535. This encoding runs out in 2036; it is now that year or later, so the scheme needs re-mapping (see the comment above)."
    }
    $daily = [int]$vParts[3]
    if ($daily -gt 65535) {
        throw "msix-version-field-overflow: daily build number $daily exceeds 65535"
    }
    $msixVersion = "{0}.{1}.{2}.0" -f $minor, $fineGrained, $daily

    # -- stage the package layout -------------------------------------------
    $msixStage = Join-Path $artifactsDir "$base-msix"
    if (Test-Path $msixStage) { Remove-Item -Recurse -Force $msixStage }
    New-Item -ItemType Directory -Force $msixStage | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $msixStage 'Assets') | Out-Null
    Copy-Item $stagedExe (Join-Path $msixStage 'tillandsias-tray.exe')

    # Logos are RENDERED by the windows-tray build script from the bloom SVG
    # (no ImageMagick). Absence is fatal HERE and best-effort there, on purpose:
    # a Linux host cross-checking the crate must not need the art, but a release
    # package without its Store logos is not a release package.
    $logoSrc = Join-Path $RepoRoot 'target\msix-logos'
    $logos = @('Square44x44Logo.png', 'Square150x150Logo.png', 'StoreLogo.png')
    foreach ($logo in $logos) {
        $src = Join-Path $logoSrc $logo
        if (-not (Test-Path -LiteralPath $src)) {
            throw "msix-logo-missing: $src (build crates/tillandsias-windows-tray once to render it)"
        }
        Copy-Item $src (Join-Path $msixStage "Assets\$logo")
    }

    # -- manifest ------------------------------------------------------------
    # Placeholders, not defaults with real-looking values: a publisher CN that
    # LOOKS plausible is one somebody ships under by accident. These are
    # overridable per-invocation and the Store values come from Partner Center.
    # IDENTITY RESOLUTION: env var, then an UNTRACKED user-space file, then the
    # placeholder. The middle rung exists because the operator declines to
    # commit the Partner Center Publisher CN to a public repo (2026-08-31), and
    # retyping an env var every session is how a value ends up wrong once and
    # silently thereafter.
    #
    # The file is KEY=VALUE, one per line, read as UTF-8 EXPLICITLY. That is
    # load-bearing rather than tidy: PublisherDisplayName must match Partner
    # Center byte-for-byte and this operator's is "Tlatoa" + U+0304 + "ni". Read
    # with the ANSI default it becomes mojibake, the manifest is written
    # correctly from a wrong string, and certification fails for a reason that
    # looks nothing like encoding. Get-Content without -Encoding is exactly that
    # bug, which is why this uses ReadAllText with an explicit UTF8Encoding.
    #
    # This function contains no non-ASCII literals: 722-qvqb pins this script to
    # ASCII for the 5.1 parser, so the macron only ever travels as DATA.
    $identityFile = Join-Path $HOME '.config/tillandsias/msix-identity.env'
    $identityFromFile = @{}
    if (Test-Path -LiteralPath $identityFile) {
        $lines = [System.IO.File]::ReadAllText(
            $identityFile, (New-Object System.Text.UTF8Encoding($false))) -split "`r?`n"
        foreach ($line in $lines) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') {
                $identityFromFile[$Matches[1]] = $Matches[2]
            }
        }
    }
    function Resolve-MsixIdentityValue([string]$Key, [string]$Fallback) {
        $fromEnv = [Environment]::GetEnvironmentVariable($Key)
        if ($fromEnv) { return $fromEnv }
        if ($identityFromFile.ContainsKey($Key) -and $identityFromFile[$Key]) {
            return $identityFromFile[$Key]
        }
        return $Fallback
    }

    $identityName = Resolve-MsixIdentityValue 'TILLANDSIAS_MSIX_IDENTITY_NAME' 'Tlatoani.Tillandsias'
    # The default publisher sits in Microsoft's UNSIGNED NAMESPACE -- the
    # OID.2.25.3117... suffix. Two reasons, and the second is the important one:
    #   1. It makes `Add-AppxPackage -AllowUnsigned` work, so the acceptance test
    #      for this packaging needs no certificate and no change to the machine's
    #      trust store. Sideload-testing a package should not require installing
    #      a root you then have to remember to remove.
    #   2. It CANNOT be shipped by accident. A package in the unsigned namespace
    #      is refused by the Store and by any normal install path, so a build
    #      that forgot to set TILLANDSIAS_MSIX_PUBLISHER fails loudly at the
    #      point of distribution rather than quietly publishing under a
    #      plausible-looking fake identity.
    $placeholderPublisher = 'CN=TillandsiasTestPublisher, OID.2.25.311729368913984317654407730594956997722=1'
    $publisher = Resolve-MsixIdentityValue 'TILLANDSIAS_MSIX_PUBLISHER' $placeholderPublisher
    $publisherDisplay = Resolve-MsixIdentityValue 'TILLANDSIAS_MSIX_PUBLISHER_DISPLAY' 'Tlatoani'
    $displayName = Resolve-MsixIdentityValue 'TILLANDSIAS_MSIX_DISPLAY_NAME' 'Tillandsias'

    # STORE-BOUND BUILDS REFUSE THE PLACEHOLDER. -MsixStoreRevisionZero is only
    # ever passed when the package is meant for Partner Center, and a Store
    # submission carrying the unsigned-namespace CN is rejected after upload,
    # certification queue and wait -- feedback measured in hours for a fault
    # knowable in milliseconds. Worse, the package LOOKS submittable: it builds,
    # it sideloads, its manifest reads plausibly.
    #
    # This refuses instead, and never prints the resolved CN. The operator
    # treats it as sensitive; a build log is the last place it should surface,
    # and "did the build see it" is answerable without echoing it.
    if ($MsixStoreRevisionZero -and $publisher -eq $placeholderPublisher) {
        throw @"
msix-store-identity-missing: refusing to build a Store-bound package under the
placeholder publisher.

  -MsixStoreRevisionZero says this package is for Partner Center, but
  TILLANDSIAS_MSIX_PUBLISHER resolved to the unsigned-namespace placeholder, so
  the Store would reject it after upload and certification.

  Set it in the environment, or in an untracked file:
    $identityFile
  as KEY=VALUE lines (UTF-8), using the values from Partner Center ->
  Product management -> View app identity details:
    TILLANDSIAS_MSIX_IDENTITY_NAME=<Package/Identity/Name, verbatim>
    TILLANDSIAS_MSIX_PUBLISHER=<Package/Identity/Publisher, the CN=... string>
    TILLANDSIAS_MSIX_PUBLISHER_DISPLAY=<Package/Identity/PublisherDisplayName>

  Omit -MsixStoreRevisionZero to build a sideload package instead.
"@
    }

    $manifestText = Get-Content -LiteralPath $msixTemplate -Raw
    $manifestText = $manifestText.Replace('@MSIX_IDENTITY_NAME@', $identityName)
    $manifestText = $manifestText.Replace('@MSIX_PUBLISHER@', $publisher)
    $manifestText = $manifestText.Replace('@MSIX_PUBLISHER_DISPLAY_NAME@', $publisherDisplay)
    $manifestText = $manifestText.Replace('@MSIX_DISPLAY_NAME@', $displayName)
    $manifestText = $manifestText.Replace('@MSIX_VERSION@', $msixVersion)
    if ($manifestText -match '@MSIX_[A-Z_]+@') {
        # A leftover placeholder produces a manifest makeappx may still accept,
        # yielding a package identified as literally "@MSIX_PUBLISHER@". Fail
        # here, where the cause is one line away.
        throw "msix-manifest-unsubstituted: $($Matches[0]) still present"
    }
    # UTF-8 without BOM: makeappx rejects a BOM'd manifest.
    [System.IO.File]::WriteAllText(
        (Join-Path $msixStage 'AppxManifest.xml'),
        $manifestText,
        (New-Object System.Text.UTF8Encoding($false)))

    if (Test-Path $msix) { Remove-Item -Force $msix }
    & $makeappx pack /d $msixStage /p $msix /o
    if ($LASTEXITCODE -ne 0) {
        throw "makeappx-failed (exit $LASTEXITCODE); refusing to publish a package that did not build"
    }
    Remove-Item -Recurse -Force $msixStage

    if ($Sign) {
        # An MSIX carries its own signature; signing the payload exe does not
        # sign the package. Skipped for Store submission (Microsoft re-signs),
        # required for sideloading.
        Write-Host "Signing $msix ..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot 'sign-windows-artifact.ps1') -Path $msix
        if ($LASTEXITCODE -ne 0) {
            throw "signing refused for the MSIX; refusing to publish an unsigned package"
        }
    }
    Write-Host "Packaged: $msix (version $msixVersion)" -ForegroundColor Green
} else {
    Write-Host "  WARN: $msixTemplate not found; skipping MSIX" -ForegroundColor Yellow
    $msix = $null
}

$zip = Join-Path $artifactsDir "$base.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item -Recurse -Force $stage

# Distinct sums file so it does not collide with the Linux/macOS SHA256SUMS in
# the shared release. sha256sum format: "<hash>  <filename>".
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$sums = Join-Path $artifactsDir 'SHA256SUMS-windows'
# One sums file covering every Windows artifact. The MSIX gets its own line
# rather than its own file: a verifier that has to know which sums file to fetch
# for which artifact is a verifier people skip. Order matters only for humans;
# sha256sum -c does not care.
#
# The PUBLISHED file carries two separator conventions and that is expected,
# not a defect. These lines use sha256sum TEXT mode ("<hash>  <name>"); the
# release workflow later appends the alias, exe and installer lines with
# coreutils sha256sum, which writes BINARY mode ("<hash> *<name>"). Both parse,
# and release.yml runs `sha256sum -c` on the merged file right after appending.
# Do not "normalize" one producer without the other -- a uniform-looking file
# produced by changing only this end would still be produced by two writers.
$sumLines = @("$hash  $(Split-Path $zip -Leaf)")
if ($msix -and (Test-Path -LiteralPath $msix)) {
    $msixHash = (Get-FileHash $msix -Algorithm SHA256).Hash.ToLower()
    $sumLines += "$msixHash  $(Split-Path $msix -Leaf)"
}
($sumLines -join "`n") | Out-File -Encoding ascii -NoNewline $sums

Write-Host "Packaged: $zip" -ForegroundColor Green
Write-Host "Checksums: $sums" -ForegroundColor Green
Get-ChildItem $artifactsDir | Select-Object Name, Length | Format-Table -AutoSize | Out-Host
# Emit the zip path as the script's object output.
Write-Output $zip
