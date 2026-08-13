<#
.SYNOPSIS
    Authenticode-sign a Windows artifact through Azure Artifact Signing
    (formerly Trusted Signing), then VERIFY that the signature and its
    timestamp actually landed.

.DESCRIPTION
    Order 722-qvqb / 724-rpna. One signing seam for two lanes:

        dev lane   `az login`, then -Sign on the build script.
                   DefaultAzureCredential finds AzureCliCredential.
        CI lane    federated OIDC on the runner. Same code path; only the
                   credential the chain resolves differs.

    That is the whole reason this is a script and not two inline blocks: if the
    lanes diverge, what CI signs stops being what a developer can reproduce.

    THE THREE-DAY FACT, and why -Verify is not optional. Artifact Signing mints
    a FRESH certificate per request, valid ~3 days, and lets it die. Nobody
    holds or renews one, which is the security property: a stolen certificate is
    worthless by the weekend. The timestamp countersignature is what decouples
    the SIGNATURE's lifetime from the CERTIFICATE's — validation asks "was the
    cert valid at time T", not "is it valid now" — so a timestamped binary stays
    trusted for years and an untimestamped one dies in 72 hours.

    It dies RETROACTIVELY, for copies already on users' disks, because
    validation runs at launch against the current clock. A release that omits
    the timestamp passes every check on the build machine and breaks in the
    field the same week, with no signal on our side. So this script refuses to
    report success on a signature it has not confirmed is timestamped.

.PARAMETER Path
    The file to sign. Must exist.

.PARAMETER MetadataPath
    An existing Artifact Signing metadata.json. When omitted, one is generated
    in a temp file from the TILLANDSIAS_SIGNING_* environment variables.

.PARAMETER VerifyOnly
    Skip signing; only assert the file is signed AND timestamped. This is the
    check 722-f86z wires into the release path, and the mode the negative
    controls exercise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$MetadataPath,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Fail($message) {
    Write-Host "blocked:signing:$message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Path)) { Fail "no-such-file:$Path" }
$Path = (Resolve-Path -LiteralPath $Path).Path

# ── verification ────────────────────────────────────────────────────────────
# Deliberately a separate function called by BOTH modes. Signing that does not
# verify its own result is the failure shape this repo keeps repairing: a step
# that exits zero having done nothing. `signtool sign` can succeed against a
# misconfigured profile in ways that leave the file worse than untouched.
function Assert-SignedAndTimestamped($file) {
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    if ($sig.Status -ne 'Valid') {
        Fail "signature-not-valid:$($sig.Status):$file"
    }
    # The load-bearing assertion. TimeStamperCertificate is $null on a
    # signed-but-untimestamped file, which is the 72-hour time bomb.
    if ($null -eq $sig.TimeStamperCertificate) {
        Fail "signature-not-timestamped:$file (valid now, untrusted in ~3 days when the signing certificate expires — re-sign with /tr)"
    }
    $subject = $sig.SignerCertificate.Subject
    $expires = $sig.TimeStamperCertificate.NotAfter.ToString('yyyy-MM-dd')
    Write-Host "ok:signed-and-timestamped:$([System.IO.Path]::GetFileName($file)) signer=$subject timestamp-valid-until=$expires" -ForegroundColor Green
}

if ($VerifyOnly) {
    Assert-SignedAndTimestamped $Path
    exit 0
}

# ── resolve the signing identity ────────────────────────────────────────────
# These are NOT secrets — an account name, a profile name and a regional URI —
# so they live in plain environment variables and repo variables rather than
# the secret store. The credential is what must never be long-lived, and that
# comes from DefaultAzureCredential, not from here.
$generatedMetadata = $null
if (-not $MetadataPath) {
    $endpoint = $env:TILLANDSIAS_SIGNING_ENDPOINT
    $account = $env:TILLANDSIAS_SIGNING_ACCOUNT
    $profile = $env:TILLANDSIAS_SIGNING_PROFILE
    $missing = @()
    if (-not $endpoint) { $missing += 'TILLANDSIAS_SIGNING_ENDPOINT' }
    if (-not $account) { $missing += 'TILLANDSIAS_SIGNING_ACCOUNT' }
    if (-not $profile) { $missing += 'TILLANDSIAS_SIGNING_PROFILE' }
    if ($missing.Count -gt 0) {
        Fail "identity-unconfigured:$($missing -join ',') (see plan packet 722-w7a2; the endpoint is REGION-SPECIFIC and a mismatch surfaces as 403 + an internal SignerSign failure)"
    }
    $generatedMetadata = [System.IO.Path]::GetTempFileName()
    @{
        Endpoint               = $endpoint
        CodeSigningAccountName = $account
        CertificateProfileName = $profile
        CorrelationId          = "tillandsias-$(git -C (Split-Path $PSScriptRoot -Parent) rev-parse --short HEAD 2>$null)"
    } | ConvertTo-Json | Set-Content -Encoding ascii $generatedMetadata
    $MetadataPath = $generatedMetadata
}

# ── resolve signtool ────────────────────────────────────────────────────────
# The doc pins a FLOOR (Windows SDK >= 10.0.2261.755) and explicitly excludes
# the 20348 SDK, so "whatever signtool is on PATH" is not good enough — an
# older one fails in a way that reads as a signing problem rather than a
# toolchain problem. Prefer the newest x64 signtool the SDK ships.
$signtool = $env:TILLANDSIAS_SIGNTOOL
if (-not $signtool) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe",
        "${env:ProgramFiles}\Windows Kits\10\bin\*\x64\signtool.exe"
    ) | ForEach-Object { Get-ChildItem -Path $_ -ErrorAction SilentlyContinue } |
        Sort-Object { $_.VersionInfo.FileVersion } -Descending
    if ($candidates) { $signtool = $candidates[0].FullName }
}
if (-not $signtool -or -not (Test-Path -LiteralPath $signtool)) {
    Fail "signtool-absent (need Windows SDK >= 10.0.2261.755; set TILLANDSIAS_SIGNTOOL to override)"
}

$dlib = $env:TILLANDSIAS_SIGNING_DLIB
if (-not $dlib) {
    $dlibCandidates = @(
        "${env:ProgramFiles}\Microsoft\Azure Artifact Signing Client Tools\bin\x64\Azure.CodeSigning.Dlib.dll",
        "${env:ProgramFiles(x86)}\Microsoft\Azure Artifact Signing Client Tools\bin\x64\Azure.CodeSigning.Dlib.dll"
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($dlibCandidates) { $dlib = $dlibCandidates[0] }
}
if (-not $dlib -or -not (Test-Path -LiteralPath $dlib)) {
    Fail "dlib-absent (winget install -e --id Microsoft.Azure.ArtifactSigningClientTools; set TILLANDSIAS_SIGNING_DLIB to override)"
}

# ── sign ────────────────────────────────────────────────────────────────────
# /tr is not optional here; see the three-day note above.
try {
    & $signtool sign /v /debug /fd SHA256 `
        /tr 'http://timestamp.acs.microsoft.com' /td SHA256 `
        /dlib $dlib /dmdf $MetadataPath `
        $Path
    if ($LASTEXITCODE -ne 0) { Fail "signtool-exit-${LASTEXITCODE}:$Path" }
} finally {
    if ($generatedMetadata) { Remove-Item -Force -ErrorAction SilentlyContinue $generatedMetadata }
}

# Never trust the exit code alone — confirm the artifact.
Assert-SignedAndTimestamped $Path
