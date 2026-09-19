#!/usr/bin/env bash
# @trace order:900-z3kv, spec:tillandsias-vault
#
# clear-vault-host-credentials.sh — THE host-side clearing of the guest Vault's
# identity on Linux, in ONE place. The sibling of
# scripts/clear-vault-host-credentials.ps1 (order 803-49re/804-ckst), which has
# had no Linux counterpart.
#
# WHY IT EXISTS. `podman system reset --force` empties the podman store —
# containers, volumes AND images, asserted on three hosts — and reaches NONE of
# the host-side state below. Vault then recovers the pre-existing share and logs
# "preserving existing data volume", so the keychain-volume resync path a clean
# room claims to exercise has not been exercised on Linux since at least
# 2026-06. Measured on four hosts with differently-aged shares, which makes it a
# property of the Linux lane rather than one host's dirty state.
#
# THREE LOCATIONS, because clearing any two leaves the room warm:
#   1. the host KEYCHAIN item        vault-shamir-share-v1
#   2. host FALLBACK FILES           fallback_vault-shamir-share-v1
#                                    fallback_vault-root-token-v1
#      (vault reads the keychain OR these; pirria's 1149-vgn2 measured a
#       fallback file keeping every reset warm since 2026-09-01 while a
#       keychain-only probe certified the host cold)
#   3. the host DATA DIRECTORY       <init-cache>/vault-data
#      `vault_data_volume_exists()` tests a host path, NOT a podman volume,
#      which is why a smoke can assert 0 volumes and `--init` still report
#      "preserving existing data volume" — both true, about different things.
#
# WHAT IS DELIBERATELY NOT CLEARED, and this is the safety-critical half:
#
#   * `installation-uuid-v1` in the keychain (INSTALL_ANCHOR_V1). It anchors the
#     INSTALLATION, not the guest. This is the Linux counterpart of the Windows
#     script's `tillandsias-vm-uuid`, and the same reasoning applies: clearing
#     it would make the next vault UNDERIVABLE rather than merely
#     re-initialised.
#   * `/etc/machine-id`. The unseal key is derived from it by HKDF. Nothing here
#     touches it and nothing here should; a clean room re-initialises a vault,
#     it does not re-identify the machine.
#
# NEVER MATERIALISES A SECRET (900-z3kv criterion 4). `secret-tool clear`
# deletes by attribute and prints nothing; `secret-tool search --all` prints the
# secret inline and put live tokens into two transcripts on 2026-08-25. Presence
# and deletion are the whole of what this needs.
#
# BEST-EFFORT BY DESIGN, the .ps1's reasoning unchanged: a credential that is
# absent is the desired end state, and a failure is REPORTED rather than fatal,
# because a purge that aborts halfway leaves more stale state than one that
# finishes noisily.
#
# Exit: 0 cleared or already absent | 2 refused (no destructive consent)
#       3 could-not-run (no secret-tool, so the keychain cannot be reached)
set -uo pipefail

DRY_RUN=0
for _a in "$@"; do
    case "$_a" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h) sed -n '3,50p' "$0"; exit 0 ;;
    esac
done

KEYCHAIN_SERVICE="tillandsias"
SHARE_ATTR="vault-shamir-share-v1"
ROOT_TOKEN_ATTR="vault-root-token-v1"
ANCHOR_ATTR="installation-uuid-v1"   # PRESERVED — never cleared here
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias"

# The destructive-consent gate the runbook already uses (1004-vsh2). An
# operator's workstation holds work this cannot consent on behalf of.
if [ "${TILLANDSIAS_DESTRUCTIVE_RESET_OK:-1}" = "0" ]; then
    echo "refused:clear-vault-credentials:no-destructive-consent (TILLANDSIAS_DESTRUCTIVE_RESET_OK=0)"
    exit 2
fi

if [ "$DRY_RUN" = "0" ] && ! command -v secret-tool >/dev/null 2>&1; then
    echo "could-not-run:clear-vault-credentials:no-secret-tool (the host keychain cannot be reached; the fallback files and data dir are NOT cleared either, because a partial clear leaves a room that looks cold and is not)"
    exit 3
fi

_did=""; _kept=""; _failed=""
_say() { printf '  %s\n' "$1"; }

# 1. keychain items
for _attr in "$SHARE_ATTR" "$ROOT_TOKEN_ATTR"; do
    if [ "$DRY_RUN" = "1" ]; then
        _did="$_did keychain:$_attr"; _say "would clear keychain item $_attr"; continue
    fi
    if secret-tool clear service "$KEYCHAIN_SERVICE" username "$_attr" 2>/dev/null; then
        _did="$_did keychain:$_attr"; _say "cleared keychain item $_attr"
    else
        # Absent is the desired end state, not a failure.
        _say "keychain item $_attr already absent (or not clearable)"
    fi
done
_kept="$_kept keychain:$ANCHOR_ATTR"
_say "PRESERVED keychain item $ANCHOR_ATTR (installation anchor — clearing it makes the next vault underivable)"

# 2. fallback files
for _f in "$CACHE_DIR/fallback_$SHARE_ATTR" "$CACHE_DIR/fallback_$ROOT_TOKEN_ATTR"; do
    [ -e "$_f" ] || { _say "fallback ${_f##*/} already absent"; continue; }
    if [ "$DRY_RUN" = "1" ]; then _did="$_did file:${_f##*/}"; _say "would remove ${_f##*/}"; continue; fi
    if rm -f "$_f" 2>/dev/null; then _did="$_did file:${_f##*/}"; _say "removed ${_f##*/}"
    else _failed="$_failed file:${_f##*/}"; _say "WARNING: could not remove ${_f##*/}"; fi
done

# 3. host data directory
_vd="$CACHE_DIR/vault-data"
if [ -e "$_vd" ]; then
    if [ "$DRY_RUN" = "1" ]; then _did="$_did dir:vault-data"; _say "would remove vault-data/"
    elif rm -rf "$_vd" 2>/dev/null && [ ! -e "$_vd" ]; then _did="$_did dir:vault-data"; _say "removed vault-data/"
    # ORDER 1284-jf86. The directory is written from INSIDE A CONTAINER UNDER A
    # SUBUID (measured on pirria: 524388:lapto, subdirectories mode 700), so a
    # rootless `rm` as the invoking uid is refused on every subdirectory. This
    # script anticipated that and warned; warning is not clearing, and §2 of the
    # curl-install smoke is the only thing that ever noticed, via its own
    # `test ! -e`. Measured twice on 2026-09-19, byte-identical, on a directory
    # the SAME RUN's install had created minutes earlier — so it is the product
    # writing under a subuid, not inherited state with odd ownership.
    #
    # `podman unshare` runs in the user namespace where that subuid maps to
    # root, which is the one context able to remove what the product wrote.
    # Tried only AFTER the plain rm, so a host whose directory is owned by the
    # invoking user never needs a container runtime for this.
    elif command -v podman >/dev/null 2>&1 && podman unshare rm -rf "$_vd" 2>/dev/null && [ ! -e "$_vd" ]; then
        _did="$_did dir:vault-data"; _say "removed vault-data/ (via podman unshare — subuid-owned)"
    else _failed="$_failed dir:vault-data"; _say "WARNING: could not remove vault-data/ (it is written from inside a container under a subuid; a rootless rm may be refused, and podman unshare did not resolve it)"; fi
else
    _say "vault-data/ already absent"
fi

if [ -n "$_failed" ]; then
    echo "warn:clear-vault-credentials:partial (cleared:${_did:-none} failed:$_failed) — the room is NOT cold; a partial clear is the state that looks clean and is not"
    # ORDER 1284-jf86, the exit-code half. This printed the sentence "the room
    # is NOT cold" and then exited 0, so a caller branching on the status was
    # told the opposite of what the text said — a verdict channel contradicting
    # its own prose. Every caller that trusted `clear_exit=0` certified a room
    # it had not cleared. DRY_RUN keeps exit 0: a dry run that "fails" to remove
    # anything has not failed at anything.
    [ "$DRY_RUN" = "1" ] && exit 0
    exit 1
fi
echo "ok:clear-vault-credentials:${_did:-nothing-to-clear} (preserved:$_kept)"
exit 0
