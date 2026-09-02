# ORDER 803-49re. THE host-side clearing of the guest Vault's identity, in ONE
# place, dot-sourced by every installer that can destroy the guest.
#
# WHY THIS FILE EXISTS. Part A landed in a8cd8cc32 on scripts/install-windows.ps1
# and nowhere else, and there are TWO purge paths. Measured 2026-09-02 on
# yolanda: scripts/build-and-install-windows-local.ps1 -Purge unregisters the
# `tillandsias` distro — destroying the guest Vault — and left
# vault-shamir-share-v1 and vault-root-token-v1 sitting in Credential Manager.
# So the developer-facing installer, the one an agent or the operator actually
# runs on a dev host, still produced the exact 2026-08-17 incident: the tray
# delivers the dead vault's share into the next guest unconditionally, it fails
# to authenticate, and GitHub login is broken until someone runs cmdkey by hand.
#
# The fix that was applied to one copy is the whole class of bug this project
# keeps paying for — four scripts independently writing the same plan-binary
# probe (704-zcgi), two hardware-fingerprint implementations (805-r98w). A
# second copy is where the fix does not go. So the clearing is a function, and
# scripts/check-purge-clears-vault-credentials.sh refuses a third copy that
# unregisters the distro without calling it.
#
# WHAT IS DELIBERATELY NOT CLEARED: `tillandsias-vm-uuid`. It anchors the
# INSTALLATION, not the guest, and the in-VM Vault derives its master key from
# it — clearing it would make the next guest's vault underivable rather than
# merely re-initialised.

# Clear the host-held copies of the guest Vault's identity.
#
# Call this from any path that destroys the guest (`wsl --unregister
# tillandsias`). `-Say` takes a scriptblock so each installer keeps its own
# output style; omit it and the function is silent.
#
# Best-effort by design: a credential that is absent is the desired end state,
# and a cmdkey that fails is reported rather than thrown, because a purge that
# aborts halfway leaves MORE stale state than one that finishes noisily.
function Clear-TillandsiasVaultHostCredentials {
    param(
        [scriptblock]$Say = { param($m) }
    )
    foreach ($cred in @('vault-shamir-share-v1', 'vault-root-token-v1')) {
        $listed = & cmdkey.exe /list:$cred 2>$null
        if ($listed -match [regex]::Escape($cred)) {
            & cmdkey.exe /delete:$cred > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                & $Say "  cleared Credential Manager entry '$cred'"
            } else {
                & $Say "  WARNING: could not clear Credential Manager entry '$cred'"
            }
        }
    }
}
