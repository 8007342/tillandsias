#!/usr/bin/env bash
# @trace order:1570-25iq, order:599-4wzr, order:1087-h2z9, order:831-ezea
#
# test-audit-guard-activation.sh — the auditor that proves every guard is wired
# (scripts/lua/audit-guard-activation.lua, ported from the .sh by 1570-25iq)
# had no fixture of its own. Each arm exists because a weaker auditor could
# pass it:
#
#   1 PARITY     on the live tree, the port and the pre-port .sh (pinned from
#                git) give the same counts and the same active/ORPHAN status
#                for every guard.
#   2 ORPHAN     NEGATIVE CONTROL: in a scratch repo an unreferenced
#                scripts/check-*.sh is reported ORPHAN, named on the
#                `orphans:` line, and the verdict refuses (exit 1).
#   3 WIRED      the same tree with the orphan removed passes (exit 0).
#   4 SYMLINK    the 1087-h2z9 shape: a guard referenced ONLY from a skill that
#                the runtime dir .claude/skills reaches through a SYMLINK onto
#                the canonical skills/ tree. The port (whose walker never
#                follows links) reports it active, and so does the pinned .sh
#                (`find -L`, which does) — the answer no longer depends on the
#                walker, the grep or the PATH.
#   5 EMPTY      831-ezea: a tree with no check-*.sh is REFUSED, never ok.
#
# Scratch repos live under target/plan-scratch (never /tmp) and each is its own
# git repo, so the runner roots there and nothing touches this checkout.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
GUARD="$ROOT/scripts/lua/audit-guard-activation.lua"
PINNED_SHA="${GUARD_ACTIVATION_PINNED_SHA:-}"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
plan_from_checkout() {
    local p
    p="$(cd "$ROOT" && resolve_plan_binary)" || return 1
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *)  printf '%s/%s\n' "$ROOT" "${p#./}" ;;
    esac
}
PLAN="$(plan_from_checkout)" || PLAN=""
if [ -z "$PLAN" ] || ! grep -qx script <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:audit-guard-activation-fixture:no-script-runner"
    exit 0
fi
# The .sh this was ported from, at its last commit; resolved from history so
# the fixture never pins a SHA that a rebase could orphan.
# After the port lands: the deletion commit's parent. Before it (the deleting
# commit not yet made): the last commit that touched the .sh.
if [ -z "$PINNED_SHA" ]; then
    PINNED_SHA="$(git log -n 1 --format=%H --diff-filter=D -- scripts/audit-guard-activation.sh 2>/dev/null)"
    if [ -n "$PINNED_SHA" ]; then
        PINNED_SHA="${PINNED_SHA}^"
    else
        PINNED_SHA="$(git log -n 1 --format=%H -- scripts/audit-guard-activation.sh 2>/dev/null)"
    fi
fi

mkdir -p "$ROOT/target/plan-scratch"
W="$(mktemp -d "$ROOT/target/plan-scratch/guard-activation.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM
GC=(-c user.email=f@f -c user.name=f -c commit.gpgsign=false)

run_port() { # run_port <dir> -> stdout+stderr in OUT, rc in RC
    OUT="$(cd "$1" && env -u TILLANDSIAS_REPO_ROOT "$PLAN" script run "$GUARD" 2>&1)"; RC=$?
}
pinned_sh() { # pinned_sh <dest>: the pre-port .sh, or fail
    [ -n "$PINNED_SHA" ] && git show "$PINNED_SHA:scripts/audit-guard-activation.sh" > "$1" 2>/dev/null
}
status_set() { # status_set <file> -> "active|ORPHAN name" per guard, sorted
    awk '$1 == "active:" || $1 == "ORPHAN:" { print $1, $2 }' "$1" > "$1.st"
    LC_ALL=C sort -o "$1.st" "$1.st"
}

# ── 1. PARITY on the live tree ─────────────────────────────────────────────
if pinned_sh "$W/pinned.sh"; then
    # The .sh roots itself at its own `..`; its ROOT line is rewritten to read
    # AUDIT_ROOT so it audits THIS tree from the scratch dir. Nothing is ever
    # copied into the checkout (1564-lk9f: a killed run must not leak a file).
    sed 's|^ROOT=.*|ROOT="$AUDIT_ROOT"|' "$W/pinned.sh" > "$W/pinned-rooted.sh"
    AUDIT_ROOT="$ROOT" bash "$W/pinned-rooted.sh" > "$W/sh.out" 2>&1
    run_port "$ROOT"; printf '%s\n' "$OUT" > "$W/lua.out"
    status_set "$W/sh.out"; status_set "$W/lua.out"
    shv="$(grep -m1 '^guard-activation:' "$W/sh.out")"
    luav="$(grep -m1 -E '^(ok|violation):guard-activation:' "$W/lua.out")"
    n="$(wc -l < "$W/sh.out.st")"; n=$((n + 0))
    if [ "$n" -lt 10 ]; then
        bad "PARITY: the pinned .sh enumerated only $n guards — the pin is not exercising the population"
    elif ! cmp -s "$W/sh.out.st" "$W/lua.out.st"; then
        bad "PARITY: per-guard status differs: $(diff "$W/sh.out.st" "$W/lua.out.st" | tr '\n' ' ')"
    elif [ "${luav#*:guard-activation:}" != "${shv#guard-activation: }" ]; then
        bad "PARITY: counts differ — .sh [$shv] vs port [$luav]"
    else
        ok "PARITY: $n guards, same status for each, same counts as the pinned .sh (${shv#guard-activation: })"
    fi
else
    ok "PARITY (skip: the pre-port .sh is unreachable in this clone's history)"
fi

# A scratch repo: build.sh names check-wired.sh; skills/demo/SKILL.md names
# check-skill.sh; .claude/skills/demo is a SYMLINK onto skills/demo.
scratch() { # scratch <dir> [with-orphan]
    mkdir -p "$1/scripts" "$1/skills/demo" "$1/.claude/skills"
    printf '#!/usr/bin/env bash\necho ok\n' > "$1/scripts/check-wired.sh"
    printf '#!/usr/bin/env bash\necho ok\n' > "$1/scripts/check-skill.sh"
    printf '#!/usr/bin/env bash\nbash scripts/check-wired.sh\n' > "$1/build.sh"
    printf -- '---\nname: demo\n---\nRun `bash scripts/check-skill.sh`.\n' > "$1/skills/demo/SKILL.md"
    ln -s ../../skills/demo "$1/.claude/skills/demo"
    [ "${2:-}" = with-orphan ] && printf '#!/usr/bin/env bash\necho ok\n' > "$1/scripts/check-orphan.sh"
    git -C "$1" init -q
    git -C "$1" "${GC[@]}" add -A
    git -C "$1" "${GC[@]}" commit -qm seed
}

# ── 2. NEGATIVE CONTROL: an unreferenced guard refuses ──────────────────────
scratch "$W/orphan" with-orphan
run_port "$W/orphan"
if [ "$RC" -eq 1 ] && grep -qx 'orphans: check-orphan.sh' <<<"$OUT" \
   && grep -q '^ORPHAN:  check-orphan.sh' <<<"$OUT" \
   && grep -qx 'violation:guard-activation:population=3 total=3 active=2 orphan=1 verdict=orphans-found' <<<"$OUT"; then
    ok "ORPHAN: an unreferenced check-orphan.sh is named and the verdict refuses (exit 1)"
else
    bad "ORPHAN: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

# ── 3. the same tree, every guard referenced, passes ───────────────────────
scratch "$W/wired"
run_port "$W/wired"
if [ "$RC" -eq 0 ] && grep -qx 'ok:guard-activation:population=2 total=2 active=2 orphan=0 verdict=ok' <<<"$OUT"; then
    ok "WIRED: every referenced guard is active and the verdict passes"
else
    bad "WIRED: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

# ── 4. the symlink-farm shape, judged the same by both walkers ─────────────
if grep -q '^active:  check-skill.sh' <<<"$OUT"; then
    if pinned_sh "$W/wired/scripts/audit-guard-activation.sh"; then
        (cd "$W/wired" && bash scripts/audit-guard-activation.sh) > "$W/wired.sh.out" 2>&1
        if grep -q '^active:  check-skill.sh' "$W/wired.sh.out"; then
            ok "SYMLINK: a guard named only in a symlinked skill is active for the port (no link-following) and for the pinned .sh (find -L)"
        else
            bad "SYMLINK: the pinned .sh disagrees: $(tr '\n' ' ' < "$W/wired.sh.out")"
        fi
    else
        ok "SYMLINK: a guard named only in a symlinked skill is active for the port (pinned .sh unreachable; comparison skipped)"
    fi
else
    bad "SYMLINK: check-skill.sh was not reported active: $(tr '\n' ' ' <<<"$OUT")"
fi

# ── 5. an empty population is a refusal (831-ezea) ─────────────────────────
mkdir -p "$W/empty/scripts"
printf '#!/usr/bin/env bash\n' > "$W/empty/build.sh"
git -C "$W/empty" init -q; git -C "$W/empty" "${GC[@]}" add -A; git -C "$W/empty" "${GC[@]}" commit -qm seed
run_port "$W/empty"
if [ "$RC" -eq 1 ] && grep -q 'verdict=unavailable:no-guards-enumerated' <<<"$OUT"; then
    ok "EMPTY: no check-*.sh is refused as unavailable, never reported ok"
else
    bad "EMPTY: rc=$RC out=$(tr '\n' ' ' <<<"$OUT")"
fi

echo "audit-guard-activation-fixture: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:audit-guard-activation-fixture:$pass"
