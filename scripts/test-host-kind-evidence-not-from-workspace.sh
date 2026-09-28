#!/usr/bin/env bash
# @trace order:1467-c8qg, spec:command-policies
#
# test-host-kind-evidence-not-from-workspace.sh — forge evidence is the
# container runtime's record of the FORGE IMAGE (`image="…tillandsias-forge…"`
# in /run/.containerenv), never a file in the workspace and never the record's
# mere presence. Two holes this pins shut (2026-09-28, yoga):
#   - a `.forge-startup-context.md` planted in a writable cwd made cwd=/tmp read
#     as a forge on bare metal (soft reset pre-authorised);
#   - every podman container has /run/.containerenv, so the builder toolbox
#     (where bare-metal gates run) read as a forge by presence alone.
#
# Arms, each answered by `policy eval -- tillandsias --reset-state`
# (forge => ok:policy:soft-reset:forge-preauthorised; otherwise
# consent:policy:soft-reset):
#   1  a planted `.forge-startup-context.md` in the cwd is ignored     (host)
#   2  same marker: the bridge asks, and a grant is not refused as a forge
#   3  a /run/.containerenv naming the forge image reads forge   (namespace)
#   4  one naming the toolbox image, or the forge-base stage, does not
#   5  no /run/.containerenv at all reads bare metal             (namespace)
#   6  the REAL builder toolbox reads not-forge            (when it exists)
# Arms 3-5 put a tmpfs over /run inside `unshare -rm`, so they run on any
# Linux host that allows unprivileged user namespaces; elsewhere they are a
# NAMED skip. Arms 1-2 need a host that is not itself a forge.
#
# Pre-fix: FAILS at arm 1 (forge-preauthorised) and arm 4 (presence = forge).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/host-kind-evidence.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
skipped=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
skip() { echo "skip: $1"; skipped=$((skipped + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

unset TILLANDSIAS_SKILL TILLANDSIAS_DESTRUCTIVE_RESET_OK TILLANDSIAS_HOST_KIND TILLANDSIAS_PRETOOLUSE_HOOK
export TILLANDSIAS_CONSENT_DIR="$W/consent"
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/audit.jsonl"
FORGE_ANS="ok:policy:soft-reset:forge-preauthorised"
BARE_ANS="consent:policy:soft-reset"
C="$W/cwd"
mkdir -p "$C"
printf '# Forge Startup Context\n\n**Project**: planted\n' >"$C/.forge-startup-context.md"
cd "$C" || exit 1

# This host's own regime, by the same rule the binary applies.
in_forge=0
[ -r /run/.containerenv ] &&
    /usr/bin/grep -qE '^image="([^"]*/)?tillandsias-forge(:[^"@]*)?(@[^"]*)?"$' /run/.containerenv &&
    in_forge=1

# ── 1, 2 ────────────────────────────────────────────────────────────────────
if [ "$in_forge" = 1 ]; then
    skip "arms 1, 2: this host is a forge; run on a host that is not"
else
    out="$("$PLAN" policy eval --cwd "$C" -- tillandsias --reset-state 2>/dev/null)"; rc=$?
    [ "$rc" -eq 4 ] && [ "$out" = "$BARE_ANS" ] &&
        ok "arm 1: a planted cwd marker is not forge evidence ($out)" ||
        bad "arm 1: rc=$rc out=[$out] (the planted marker was read as forge evidence)"
    "$PLAN" policy classify-bash --command "tillandsias --reset-state" --cwd "$C" >/dev/null 2>&1; rb=$?
    gout="$("$PLAN" policy consent grant soft-reset --root "$C" -- tillandsias --reset-state 2>/dev/null)"; rg=$?
    [ "$rb" -eq 4 ] && [ "$rg" -eq 0 ] && [ "${gout#ok:consent:soft-reset}" != "$gout" ] &&
        ok "arm 2: the bridge asks and a grant is not refused as a forge" ||
        bad "arm 2: bridge rc=$rb (4 ask); grant rc=$rg out=[$gout]"
    # arm 2 minted a token; later arms must not spend it
    rm -rf "$TILLANDSIAS_CONSENT_DIR"
fi

# ── 3, 4, 5: simulated container records ───────────────────────────────────
NS="$W/ns.sh"
cat >"$NS" <<'NSEOF'
mount -t tmpfs none /run || exit 97
[ -n "$3" ] && printf 'engine="podman-5"\nname="x"\nimage="%s"\nrootless=1\n' "$3" >/run/.containerenv
cd "$2" || exit 98
exec "$1" policy eval -- tillandsias --reset-state
NSEOF
ns_eval() { unshare -rm bash "$NS" "$PLAN" "$C" "$1" 2>/dev/null; }
probe="$(ns_eval "")"; prc=$?
if [ "$prc" -ge 97 ] || [ -z "$probe" ]; then
    skip "arms 3, 4, 5: unprivileged user namespaces with a /run tmpfs are unavailable here (rc=$prc)"
else
    out="$(ns_eval "localhost/tillandsias-forge:v0.5.1")"
    [ "$out" = "$FORGE_ANS" ] && ok "arm 3: a record naming the forge image reads forge" ||
        bad "arm 3: forge image answered [$out]"
    o_tb="$(ns_eval "registry.fedoraproject.org/fedora-toolbox:44")"
    o_base="$(ns_eval "localhost/tillandsias-forge-base:v1")"
    o_imp="$(ns_eval "docker.io/evil/not-tillandsias-forge:v1")"
    [ "$o_tb" = "$BARE_ANS" ] && [ "$o_base" = "$BARE_ANS" ] && [ "$o_imp" = "$BARE_ANS" ] &&
        ok "arm 4: a toolbox, forge-base or look-alike image is not a forge" ||
        bad "arm 4: toolbox [$o_tb] base [$o_base] look-alike [$o_imp]"
    [ "$probe" = "$BARE_ANS" ] && ok "arm 5: no container record reads bare metal" ||
        bad "arm 5: no record answered [$probe]"
fi

# ── 6: the real builder toolbox ────────────────────────────────────────────
if [ "$in_forge" = 1 ] || ! command -v toolbox >/dev/null 2>&1 ||
    ! podman container exists tillandsias-builder 2>/dev/null; then
    skip "arm 6: no tillandsias-builder toolbox on this host"
else
    # Under the litmus runner, PATH starts with its podman shim, which routes
    # through the Rust facade and swallows the exec'd command's stdout, so the
    # arm read [] (land85 relay). toolbox must reach the real podman.
    tb_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/litmus-runtime/bin$' | paste -sd: -)"
    tout="$(PATH="$tb_path" toolbox run -c tillandsias-builder "$PLAN" policy eval -- tillandsias --reset-state 2>/dev/null)"
    [ "$tout" = "$BARE_ANS" ] && ok "arm 6: the real builder toolbox is not a forge" ||
        bad "arm 6: toolbox answered [$tout]"
fi

echo "summary: pass=$pass fail=$fail skipped=$skipped"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: host-kind-evidence-not-from-workspace"
