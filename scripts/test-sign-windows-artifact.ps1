<#
.SYNOPSIS
    Fixture for the Windows Authenticode signing seam (orders 722-qvqb,
    722-f86z, 724-rpna).

.DESCRIPTION
    What this CAN prove without an Azure identity, and what it deliberately
    does not claim.

    PROVEN HERE: every refusal path. An unsigned file must be REJECTED by the
    verifier, and a signing request with no configured identity must fail
    loudly rather than skip. Those are the two ways this seam could silently
    ship unsigned binaries under a green release, which is the failure 722-f86z
    exists to prevent.

    NOT PROVEN HERE: that a real signature and a real timestamp are produced.
    That needs the Artifact Signing account from 722-w7a2 and cannot be faked
    without lying. It is asserted at release time by the same
    Assert-SignedAndTimestamped code path these scenarios exercise, which is
    why the verifier is one function called by both modes rather than two.

    The most valuable case here is scenario 1: it proves the verifier CAN fail.
    A check that has never been observed failing is indistinguishable from a
    check that always passes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$signer = Join-Path $PSScriptRoot 'sign-windows-artifact.ps1'
$failures = @()

$work = Join-Path ([System.IO.Path]::GetTempPath()) "sign-fixture-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force $work | Out-Null

try {
    # An unsigned but otherwise real PE. Copying a system binary keeps this
    # honest: a text file with an .exe name is not a PE and could pass or fail
    # for reasons that have nothing to do with signatures.
    $unsigned = Join-Path $work 'unsigned.exe'
    Copy-Item "$env:SystemRoot\System32\where.exe" $unsigned
    # Append raw bytes so the PE cannot validate. Use a FileStream, NOT
    # `Add-Content -Encoding Byte` — PowerShell 7 removed that encoding and the
    # cmdlet throws, which under this fixture's ErrorActionPreference is a
    # WARNING, not a stop. The first run of this fixture did exactly that: the
    # tamper silently did nothing, scenario 1 still passed (a copied
    # catalog-signed system binary does not carry its signature to a new path),
    # and the fixture reported green for a reason it had not tested.
    $fs = [System.IO.File]::Open($unsigned, 'Append')
    try { $fs.Write([byte[]](0x74, 0x61, 0x6D, 0x70, 0x65, 0x72), 0, 6) } finally { $fs.Dispose() }
    # Assert the PRECONDITION rather than assume it: this file must genuinely
    # not be validly signed, or scenario 1 proves nothing about the verifier.
    if ((Get-AuthenticodeSignature -LiteralPath $unsigned).Status -eq 'Valid') {
        $failures += "fixture-precondition: the tampered PE still validates; scenario 1 would be vacuous"
    }

    # 1. THE LOAD-BEARING NEGATIVE CONTROL: the verifier must reject a file
    #    that is not validly signed. If this ever passes, every other green
    #    verdict in this seam is meaningless.
    & $signer -Path $unsigned -VerifyOnly *> "$work/out1.txt"
    if ($LASTEXITCODE -eq 0) {
        $failures += "unsigned-rejected: verifier ACCEPTED an unsigned/tampered PE"
    } elseif (-not (Select-String -Path "$work/out1.txt" -Pattern 'blocked:signing:signature-not-valid' -Quiet)) {
        $failures += "unsigned-rejected: wrong verdict: $(Get-Content "$work/out1.txt" -Raw)"
    }

    # 2. A signing request with NO identity configured must refuse, naming the
    #    missing variables. The dangerous alternative is a no-op that returns
    #    zero and lets the build package an unsigned artifact.
    $env:TILLANDSIAS_SIGNING_ENDPOINT = ''
    $env:TILLANDSIAS_SIGNING_ACCOUNT = ''
    $env:TILLANDSIAS_SIGNING_PROFILE = ''
    & $signer -Path $unsigned *> "$work/out2.txt"
    if ($LASTEXITCODE -eq 0) {
        $failures += "unconfigured-refused: signing returned 0 with no identity configured"
    } elseif (-not (Select-String -Path "$work/out2.txt" -Pattern 'blocked:signing:identity-unconfigured' -Quiet)) {
        $failures += "unconfigured-refused: wrong verdict: $(Get-Content "$work/out2.txt" -Raw)"
    }

    # 2b. POSITIVE CONTROL, and the reason the other scenarios mean anything: a
    #     REAL signed-and-timestamped binary must be ACCEPTED. Every other case
    #     here asserts a refusal, and a verifier that refuses unconditionally
    #     would satisfy all of them while being useless. A Windows system
    #     binary in place (not copied — catalog signatures do not travel) is a
    #     genuine signed+timestamped PE, which is exactly the shape the release
    #     artifact will have.
    $systemSigned = "$env:SystemRoot\System32\where.exe"
    & $signer -Path $systemSigned -VerifyOnly *> "$work/out2b.txt"
    if ($LASTEXITCODE -ne 0) {
        $failures += "signed-accepted: verifier REJECTED a genuinely signed+timestamped binary: $(Get-Content "$work/out2b.txt" -Raw)"
    } elseif (-not (Select-String -Path "$work/out2b.txt" -Pattern 'ok:signed-and-timestamped' -Quiet)) {
        $failures += "signed-accepted: wrong verdict: $(Get-Content "$work/out2b.txt" -Raw)"
    }

    # 3. A missing file is named as such, not reported as a signing failure.
    & $signer -Path (Join-Path $work 'no-such-file.exe') -VerifyOnly *> "$work/out3.txt"
    if ($LASTEXITCODE -eq 0 -or -not (Select-String -Path "$work/out3.txt" -Pattern 'blocked:signing:no-such-file' -Quiet)) {
        $failures += "missing-file-named: wrong verdict: $(Get-Content "$work/out3.txt" -Raw)"
    }

    # 4. STRUCTURAL: the build script signs BEFORE it zips and hashes. This is
    #    a source-order assertion rather than a behavioural one because the
    #    behavioural version needs a real identity — but the ordering is the
    #    invariant that silently breaks checksums if a later edit moves it, and
    #    an out-of-order signing step would not fail any other test.
    #     STRIP COMMENTS FIRST. The first version of this scenario matched
    #     against the raw file and found "Compress-Archive" inside the very
    #     comment explaining why signing must precede it — so it compared a
    #     code position against a prose position and reported the ordering
    #     backwards. A source-order test that reads documentation as code is
    #     worse than no test; it fails on correct code and would pass on
    #     incorrect code that happened to describe itself accurately.
    $code = (Get-Content (Join-Path $PSScriptRoot 'build-windows-tray.ps1') |
        Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $signAt = $code.IndexOf('sign-windows-artifact.ps1')
    $zipAt = $code.IndexOf('Compress-Archive')
    $hashAt = $code.IndexOf('Get-FileHash $zip')
    if ($signAt -lt 0) {
        $failures += "sign-before-package: build script no longer calls the signing seam"
    } elseif (-not ($signAt -lt $zipAt -and $signAt -lt $hashAt)) {
        $failures += "sign-before-package: signing at $signAt must precede Compress-Archive ($zipAt) and the checksum ($hashAt)"
    }
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    Write-Host "sign-windows-artifact: FAIL $($failures.Count) scenario(s)" -ForegroundColor Red
    exit 1
}
Write-Host "PASS: sign-windows-artifact fixture 5/5 scenarios green (unsigned-rejected, unconfigured-refused, signed-accepted, missing-file-named, sign-before-package)" -ForegroundColor Green
# EXIT EXPLICITLY. Without this the script falls off the end carrying
# $LASTEXITCODE from the last scenario — which is a DELIBERATE non-zero, since
# most scenarios assert a refusal. The fixture then prints PASS and exits 1,
# and every caller that branches on the exit code reads green as red. Found by
# running it, not by reading it.
exit 0
