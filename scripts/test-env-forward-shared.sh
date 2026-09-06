#!/usr/bin/env bash
# @trace order:891-5shq
#
# Fixture: the TILLANDSIAS_* namespace forward has ONE implementation, it does
# not manufacture values, and it cannot be re-implemented per boundary.
#
# WHAT WENT WRONG. Neither `toolbox run` nor `wsl.exe` forwards the caller's
# environment, so every TILLANDSIAS_* control flag died silently at each
# dispatch. The toolbox boundary was fixed and the reasoning written down; the
# WSL boundary in the same repo then got its own separate copy of the same four
# lines. Two copies of one fix is what 891-5shq's fourth criterion forbids: "a
# third boundary must not be able to diverge silently the way this one did".
#
# ARM 2 IS THE NEGATIVE CONTROL AND IT IS THE SCORABLE HALF. A forward that
# exported every name it could think of would pass arm 1 and be WRONG: the
# packet's third criterion is that a flag NOT set on the host must not appear
# set on the far side. From the near side, "forwards correctly" and "exports
# everything" look identical — only the unset case separates them.
#
# ARM 4 IS THE ONE THAT KEEPS THE FIX FIXED. It requires both dispatches to
# reach the shared helper and neither to carry its own compgen loop. Arm 5
# proves arm 4 can actually fail, by re-introducing a bespoke loop in a scratch
# copy: a structural assertion that cannot red is decoration.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/lib-env-forward.sh"
[ -f "$LIB" ] || { echo "SKIP: lib-env-forward.sh not present" >&2; exit 0; }

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

# shellcheck source=scripts/lib-env-forward.sh
. "$LIB"

echo "== 891-5shq: one namespace forward, shared by every dispatch boundary"

# ---- ARM 1: a set flag is carried -------------------------------------------
TILLANDSIAS_FIXTURE_SET=1 \
    && export TILLANDSIAS_FIXTURE_SET=1
frag="$(tillandsias_env_forward_prefix)"
case "$frag" in
    *TILLANDSIAS_FIXTURE_SET=1*) carried=yes ;;
    *) carried=no ;;
esac
_result "arm1-a-set-flag-is-carried" "yes" "$carried"

# ---- ARM 2: NEGATIVE CONTROL — an UNSET flag is not invented ----------------
unset TILLANDSIAS_FIXTURE_NEVER_SET 2>/dev/null || true
case "$frag" in
    *TILLANDSIAS_FIXTURE_NEVER_SET*) invented=yes ;;
    *) invented=no ;;
esac
_result "arm2-an-unset-flag-is-NOT-manufactured" "no" "$invented"

# An empty-but-SET flag is a different thing from an unset one and must cross,
# because `TILLANDSIAS_X=` is how an operator turns something off explicitly.
export TILLANDSIAS_FIXTURE_EMPTY=""
frag_empty="$(tillandsias_env_forward_prefix)"
case "$frag_empty" in
    *TILLANDSIAS_FIXTURE_EMPTY=*) empty_crossed=yes ;;
    *) empty_crossed=no ;;
esac
_result "arm2-an-empty-but-SET-flag-still-crosses" "yes" "$empty_crossed"

# ---- ARM 3: values are quoted, so a value cannot become a command -----------
# The fragment is evaluated by a remote `bash -c`. An unquoted value carrying a
# `;` would be an injection seam rather than a forwarded flag.
export TILLANDSIAS_FIXTURE_TRICKY='a b; touch /tmp/tillandsias-fixture-pwned'
rm -f /tmp/tillandsias-fixture-pwned 2>/dev/null || true
frag_tricky="$(tillandsias_env_forward_prefix)"
got="$(bash -c "$frag_tricky printf '%s' \"\$TILLANDSIAS_FIXTURE_TRICKY\"")"
_result "arm3-value-survives-verbatim" 'a b; touch /tmp/tillandsias-fixture-pwned' "$got"
if [ -e /tmp/tillandsias-fixture-pwned ]; then executed=yes; else executed=no; fi
_result "arm3-value-is-data-not-a-command" "no" "$executed"
rm -f /tmp/tillandsias-fixture-pwned 2>/dev/null || true
unset TILLANDSIAS_FIXTURE_TRICKY TILLANDSIAS_FIXTURE_EMPTY TILLANDSIAS_FIXTURE_SET

# ---- ARM 4: both dispatches use the shared helper, neither rolls its own ----
_uses_helper() { grep -q 'lib-env-forward.sh' "$1" && echo yes || echo no; }
_rolls_own()   { grep -qE "compgen -v[[:space:]]*\|[[:space:]]*grep" "$1" && echo yes || echo no; }

for d in with-wsl2-builder.sh with-tillandsias-builder.sh; do
    f="$ROOT/$d"
    if [ ! -f "$f" ]; then
        echo "  SKIP $d (absent)" >&2
        continue
    fi
    _result "arm4-$d-uses-the-shared-helper" "yes" "$(_uses_helper "$f")"
    _result "arm4-$d-does-not-roll-its-own" "no" "$(_rolls_own "$f")"
done

# ---- ARM 5: the arm-4 detector must be able to RED -------------------------
# A structural assertion that cannot fail is decoration. Re-introduce a bespoke
# loop in a scratch copy and require the detector to catch it.
W="$(mktemp -d)"
cp "$ROOT/with-wsl2-builder.sh" "$W/regressed.sh"
cat >> "$W/regressed.sh" <<'REGRESS'
# a boundary that reimplements the forward instead of sharing it
_MINE=""
while IFS= read -r v; do _MINE="${_MINE}export $v=${!v}; "; done < <(compgen -v | grep '^TILLANDSIAS_')
REGRESS
_result "arm5-control-detector-catches-a-reintroduced-copy" "yes" "$(_rolls_own "$W/regressed.sh")"
rm -rf "$W"

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:env-forward-shared:$fail arm(s) failed"
    exit 1
fi
echo "ok:env-forward-shared:$pass arm(s)"
