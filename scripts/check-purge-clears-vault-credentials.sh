#!/usr/bin/env bash
# ORDER 803-49re. A script that DESTROYS THE GUEST must also clear the host's
# copy of that guest's Vault identity.
#
# WHY THIS GUARD EXISTS RATHER THAN A THIRD CAREFUL EDIT. Part A landed the
# clearing in scripts/install-windows.ps1 in a8cd8cc32 and the packet read as
# fixed. Measured 2026-09-02 on yolanda, six days later:
# scripts/build-and-install-windows-local.ps1 -Purge unregistered the
# `tillandsias` distro and cleared nothing — so the DEVELOPER-facing installer,
# the one an agent or the operator actually runs on a dev host, still produced
# the 2026-08-17 incident end to end. The tray delivers the dead vault's share
# into the next guest unconditionally, it fails to authenticate, and GitHub
# login is broken until someone runs cmdkey by hand.
#
# One copy fixed and one copy missed is this project's most-repeated defect —
# four independent plan-binary probes (704-zcgi), two hardware-fingerprint
# implementations (805-r98w), the accel probe's own transports (793-zumy). The
# remedy that works is not "be careful with the second copy"; it is to make the
# second copy impossible to add silently. So the clearing is ONE function in
# scripts/clear-vault-host-credentials.ps1 and this refuses any purge path that
# unregisters the distro without calling it.
#
# WHAT IT CHECKS, deliberately narrow: any tracked .ps1 that unregisters the
# `tillandsias` distro must also name Clear-TillandsiasVaultHostCredentials. It
# does NOT check that the call is reachable or correctly placed — a shell
# grep cannot know that, and a guard that pretends to would be the
# pinned-but-wrong shape 803-49re's own sibling packet was filed about.
#
# Prints exactly one line matching
#   ^(ok:purge-clears-vault-credentials:[0-9]+ scanned|violation:purge-without-credential-clear:.+)$
# and exits 0 when every such script calls the shared clearer, 1 otherwise.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "violation:purge-without-credential-clear:not-a-git-repo"
    exit 1
}
cd "$ROOT" || exit 1

CLEARER='Clear-TillandsiasVaultHostCredentials'
# The destroying act, by the command that performs it. Matching on `-Purge`
# instead would miss a future path that wipes the guest under another name, and
# the guest's destruction is what makes the host's copy dangerous.
DESTROYS='wsl --unregister tillandsias'

scanned=0
violations=()
while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -qF -- "$DESTROYS" "$f" || continue
    scanned=$((scanned + 1))
    # The definition site names the function too; it is the clearer, not a
    # caller, and requiring it to call itself would be nonsense.
    case "$f" in scripts/clear-vault-host-credentials.ps1) continue ;; esac
    grep -qF -- "$CLEARER" "$f" || violations+=("$f")
done < <(git ls-files '*.ps1')

if [ ${#violations[@]} -gt 0 ]; then
    echo "violation:purge-without-credential-clear:$(
        IFS=,
        echo "${violations[*]}"
    )"
    exit 1
fi

echo "ok:purge-clears-vault-credentials:${scanned} scanned"
exit 0
