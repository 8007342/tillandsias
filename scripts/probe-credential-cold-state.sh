#!/usr/bin/env bash
# ORDER 900-z3kv. Report whether this host's clean room is CREDENTIAL-COLD or
# CREDENTIAL-WARM, so an e2e can demonstrate which state it ran in instead of
# four separate agents volunteering the gap in prose.
#
# THE DEFECT THIS SERVES. `podman system reset --force` empties the podman store
# — containers, volumes AND images — but it does not reach the HOST KEYCHAIN.
# Vault then recovers the pre-existing Shamir share and logs "preserving existing
# data volume (Shamir share present in keychain)". Measured independently on two
# Linux hosts with differently-aged shares (yoga: created 2026-06-15; lenovinha:
# created 2026-07-08), which is what makes it a PLATFORM property of the Linux
# lane rather than one host's dirty state.
#
# So every Linux "clean room" e2e since at least 2026-06 reused a months-old
# share while the runbook asserted the reset re-initializes Vault. A test that
# RAN and reported a property it was not measuring — the shape that survives by
# looking like data.
#
# METADATA ONLY, NEVER THE SECRET. This reads Label/Created/Modified/Locked over
# the Secret Service D-Bus API. It does NOT call `secret-tool search --all`,
# which prints the secret inline and put live tokens into two transcripts on
# 2026-08-25. Metadata answers the question completely: presence and age are the
# whole question, and the value is nobody's business here.
#
# ADVISORY, NOT A GATE. Exit 0 for both cold and warm — reporting which state a
# run was in is the point; refusing a warm host would block every developer
# machine. Exit 2 only when the question could not be ASKED (no busctl, no
# Secret Service), which is a could-not-run and must never be reported as cold.
#
# Usage: scripts/probe-credential-cold-state.sh [--format=line|md]
set -uo pipefail

FORMAT="line"
for arg in "$@"; do
    case "$arg" in
        --format=line|--format=md) FORMAT="${arg#--format=}" ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "probe-credential-cold-state: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

KEYCHAIN_SERVICE="tillandsias"
SHARE_ATTR="vault-shamir-share-v1"

# ── COULD THE QUESTION BE ASKED AT ALL? ─────────────────────────────────────
# A host with no busctl or no org.freedesktop.secrets has no Secret Service BY
# DESIGN (a headless container, a minimal image). That is could-not-run, exit 2,
# and it is deliberately NOT "cold": reporting an unaskable question as a clean
# room is the exact substitution this order exists to stop.
if ! command -v busctl >/dev/null 2>&1; then
    echo "credential-state:could-not-run:no-busctl (the host keychain could not be queried; this is NOT a cold verdict)"
    exit 2
fi
# CAPTURE BEFORE MATCHING (792-ksr8), and this was MEASURED here, not copied
# from the rule. The first cut of this check was
# `busctl --user list | grep -q 'org.freedesktop.secrets'`, and two consecutive
# runs of this script disagreed: the first reported `warm`, the second
# `could-not-run:no-secret-service` on the same host, seconds apart. `grep -q`
# exits on the FIRST match and SIGPIPEs busctl, so the pipeline's status depends
# on which side won the race. A verdict decided by a signal is precisely what
# this probe must never emit — and a spurious could-not-run here would read as
# "we could not check", which is the honest-looking half of the failure.
_bus_list="$(busctl --user list 2>/dev/null || true)"
case $'\n'"$_bus_list" in
    *$'\n'*org.freedesktop.secrets*) ;;
    *)
        echo "credential-state:could-not-run:no-secret-service (org.freedesktop.secrets is not on the user bus; this is NOT a cold verdict)"
        exit 2
        ;;
esac

# ── THE ATTRIBUTE SCHEMA IS THE keyring CRATE'S, NOT A GUESS ────────────────
# vault_bootstrap.rs builds the entry as Entry::new(KEYCHAIN_SERVICE,
# VAULT_SHAMIR_SHARE_V1), and the keyring crate stores those as the `service`
# and `username` attributes.
#
# THIS MATTERED: the first probe written for this order searched on
# `service=vault-shamir-share-v1` and returned zero items on a host that DOES
# hold the share. Trusting it would have reported CREDENTIAL-COLD for a
# credential-WARM host — the same false-clean-room verdict this order is about,
# reproduced inside its own instrument. A wrong query and an absent secret are
# indistinguishable from the outside, so the schema is pinned here with its
# source named.
_search="$(busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
           org.freedesktop.Secret.Service SearchItems 'a{ss}' 2 \
           'service' "$KEYCHAIN_SERVICE" 'username' "$SHARE_ATTR" 2>/dev/null)" || _search=""

if [ -z "$_search" ]; then
    echo "credential-state:could-not-run:search-failed (SearchItems returned nothing at all; this is NOT a cold verdict)"
    exit 2
fi

# Reply shape: `aoao <n-unlocked> [paths...] <n-locked> [paths...]`. Take the
# first object path if any appears; a locked item still PROVES PRESENCE, which
# is the whole question, so both lists count.
_item="$(printf '%s\n' "$_search" | grep -oE '"/org/freedesktop/secrets/[^"]+"' | head -1 | tr -d '"')"

if [ -z "$_item" ]; then
    if [ "$FORMAT" = "md" ]; then
        printf '## Credential state\n\n- **verdict**: `credential-cold`\n- no `%s` entry for service `%s` in the host keychain\n- the clean room genuinely starts without an unseal share; `--init` will re-initialize Vault and the keychain-volume resync path IS exercised\n' \
            "$SHARE_ATTR" "$KEYCHAIN_SERVICE"
    else
        echo "credential-state:cold (no $SHARE_ATTR in the host keychain; --init will re-initialize and the resync path IS exercised)"
    fi
    exit 0
fi

_prop() {
    busctl --user get-property org.freedesktop.secrets "$_item" \
        org.freedesktop.Secret.Item "$1" 2>/dev/null | awk '{print $2}' | tr -d '"'
}
_created_raw="$(_prop Created)"
_modified_raw="$(_prop Modified)"
_locked="$(_prop Locked)"
# EPOCH -> ISO, PORTABLY, AND VALIDATED BY SHAPE RATHER THAN BY EXIT CODE.
# GNU takes `-d @epoch`; BSD (macOS) takes `-r epoch`, and GNU must be tried
# FIRST because GNU's -r means --reference=FILE. The shape check is the
# load-bearing part: check-bash-dialect refuses a bare GNU form precisely
# because "BSD date succeeds with garbage output — exit-code guards cannot
# catch it", so `|| fallback` on status alone would let that garbage through.
# Anything that is not YYYY- falls to the next arm, and a total miss degrades to
# the raw epoch rather than inventing a timestamp — this probe's whole purpose
# is to stop a report claiming more than it measured.
_fmt_ts() {  # gnu-date: ok (shape-validated; BSD garbage fails the YYYY- match and falls through)
    _ts_e="${1:-}"
    [ -n "$_ts_e" ] || { printf 'unknown'; return; }
    _ts_out="$(date -u -d "@$_ts_e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
    case "$_ts_out" in [0-9][0-9][0-9][0-9]-*) printf '%s' "$_ts_out"; return ;; esac
    _ts_out="$(date -u -r "$_ts_e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
    case "$_ts_out" in [0-9][0-9][0-9][0-9]-*) printf '%s' "$_ts_out"; return ;; esac
    printf 'epoch:%s' "$_ts_e"
}
_created="$(_fmt_ts "$_created_raw")"
_modified="$(_fmt_ts "$_modified_raw")"

if [ "$FORMAT" = "md" ]; then
    printf '## Credential state\n\n- **verdict**: `credential-warm`\n- `%s` PRESENT in the host keychain (service `%s`)\n- created `%s`, modified `%s`, locked `%s`\n- `podman system reset --force` does not reach the host keychain, so Vault recovered this pre-existing share. **The keychain-volume resync path was NOT exercised by this run** (900-z3kv).\n- metadata only; the secret was never read.\n' \
        "$SHARE_ATTR" "$KEYCHAIN_SERVICE" "$_created" "$_modified" "$_locked"
else
    echo "credential-state:warm (share present, created=$_created modified=$_modified locked=$_locked; the resync path was NOT exercised by this run — 900-z3kv)"
fi
exit 0
