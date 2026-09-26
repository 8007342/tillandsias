#!/usr/bin/env bash
# @trace order:1188-vixu, order:1284-jf86, spec:tillandsias-vault
#
# test-clear-vault-credentials-partial-is-nonzero.sh — pins the two halves of
# 1284-jf86 that test-clear-vault-host-credentials.sh never exercised: every arm
# there plants a vault-data directory the invoking user can remove, so the
# subuid path (the one measured on pirria 2026-09-14 and 2026-09-19) was never
# run, and neither was the exit status of a partial clear.
#
# HOW A SUBUID-OWNED DIRECTORY IS SIMULATED WITHOUT ROOT. vault-data/ holds a
# subdirectory stripped of write permission, so the plain `rm -rf` fails on it
# exactly as a rootless rm fails on a subuid-owned tree. A stub `podman` on PATH
# plays `podman unshare`: in the resolving variant it restores the write bit and
# removes the tree (what the user namespace makes possible); in the refusing
# variant it exits 1. A stub `secret-tool` keeps the keychain out of it; nothing
# here reads or clears this host's keychain or cache.
#
# ARMS
#   1. rm refused, unshare resolves  -> vault-data gone, ok: line, rc 0
#   2. rm refused, unshare refuses   -> warn:...:partial AND rc != 0
#   3. rm refused, no podman at all  -> warn:...:partial AND rc != 0
#   4. NEGATIVE CONTROL: a removable vault-data -> ok: line, rc 0, and the
#      stub podman is NEVER called (the retry is only a fallback)
#
# Pre-fix result (2d99d3de8^): arm 1 FAILS (partial, rc 0) and arms 2-3 FAIL
# (rc 0) — measured on pirria 2026-09-14T19:34Z.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLEARER="${CLEARER:-$ROOT/scripts/clear-vault-host-credentials.sh}"
W="$(mktemp -d)"
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT

if [ "$(id -u)" = "0" ]; then
    # root removes a write-protected tree, so the refused-rm premise cannot be built.
    echo "skip:clear-vault-credentials-partial:running-as-root"
    exit 0
fi

pass=0; fail=0; total=4
ok()  { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

mkbin() { # mkbin <dir> <podman-mode: resolve|refuse|absent>
    local d="$1"; mkdir -p "$d"
    printf '#!/bin/sh\nexit 0\n' > "$d/secret-tool"
    case "$2" in
        resolve) cat > "$d/podman" <<'EOF'
#!/bin/sh
echo "$*" >> "$PODMAN_CALLS"
[ "$1" = "unshare" ] || exit 1
shift
for a in "$@"; do last="$a"; done
chmod -R u+w "$last" 2>/dev/null
exec "$@"
EOF
        ;;
        refuse) printf '#!/bin/sh\necho "$*" >> "$PODMAN_CALLS"\nexit 1\n' > "$d/podman" ;;
        absent) : ;;
    esac
    chmod +x "$d"/*
}

plant() { # plant <cache> <locked: 1|0>
    local t="$1/tillandsias"
    mkdir -p "$t/vault-data/core/sys"
    echo x > "$t/vault-data/core/sys/k"
    echo x > "$t/fallback_vault-shamir-share-v1"
    echo x > "$t/fallback_vault-root-token-v1"
    [ "$2" = "1" ] && chmod a-w "$t/vault-data/core"
    return 0
}

# PATH keeps coreutils but not the host's own podman/secret-tool.
basepath="$(dirname "$(command -v rm)"):$(dirname "$(command -v sed)"):/usr/bin:/bin"

run() { # run <case> <locked> <podman-mode>  -> sets out rc vd calls
    local c="$W/$1"; mkdir -p "$c"
    plant "$c/cache" "$2"
    mkbin "$c/bin" "$3"
    : > "$c/calls"
    # The "absent" arm gets a PATH of ONLY its own bin: coreutils the clearer
    # needs are linked in, so no host podman can leak through /usr/bin.
    local p="$c/bin:$basepath"
    if [ "$3" = "absent" ]; then
        for t in rm sed chmod cat; do ln -s "$(command -v "$t")" "$c/bin/$t"; done
        p="$c/bin"
    fi
    out="$(PATH="$p" XDG_CACHE_HOME="$c/cache" PODMAN_CALLS="$c/calls" \
        TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 "$BASH" "$CLEARER" 2>&1)"; rc=$?
    vd="$c/cache/tillandsias/vault-data"
    calls="$(cat "$c/calls")"
}

# ── 1. rm refused, podman unshare resolves ────────────────────────────────
run a1 1 resolve
if [ "$rc" -eq 0 ] && [ ! -e "$vd" ] && grep -q '^ok:clear-vault-credentials:' <<<"$out" \
   && grep -q 'via podman unshare' <<<"$out"; then
    ok "a subuid-like vault-data is removed through podman unshare, rc 0, ok: line"
else bad "arm 1: rc=$rc present=$([ -e "$vd" ] && echo y || echo n) last=$(printf '%s' "$out" | tail -1)"; fi

# ── 2. rm refused, podman unshare refuses ─────────────────────────────────
run a2 1 refuse
if [ "$rc" -ne 0 ] && [ -e "$vd" ] && grep -q '^warn:clear-vault-credentials:partial' <<<"$out"; then
    ok "both removals refused: warn:...:partial and rc=$rc (non-zero)"
else bad "arm 2: rc=$rc last=$(printf '%s' "$out" | tail -1) — a partial clear must not exit 0"; fi

# ── 3. rm refused, no podman on PATH ──────────────────────────────────────
run a3 1 absent
if [ "$rc" -ne 0 ] && [ -e "$vd" ] && grep -q '^warn:clear-vault-credentials:partial' <<<"$out"; then
    ok "no podman to retry with: warn:...:partial and rc=$rc (non-zero)"
else bad "arm 3: rc=$rc last=$(printf '%s' "$out" | tail -1)"; fi

# ── 4. NEGATIVE CONTROL: removable vault-data, podman never consulted ─────
run a4 0 refuse
if [ "$rc" -eq 0 ] && [ ! -e "$vd" ] && [ -z "$calls" ] && grep -q '^ok:clear-vault-credentials:' <<<"$out"; then
    ok "a removable vault-data clears with rc 0 and never calls podman"
else bad "arm 4: rc=$rc present=$([ -e "$vd" ] && echo y || echo n) podman-calls='$calls'"; fi

if [ "$fail" -eq 0 ]; then echo "ok:clear-vault-credentials-partial-is-nonzero:$pass/$total"; exit 0; fi
echo "violation:clear-vault-credentials-partial-is-nonzero:$pass/$total"; exit 1
