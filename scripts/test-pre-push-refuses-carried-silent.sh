#!/usr/bin/env bash
# @trace order:2194-cspr, order:1577-g96z
#
# test-pre-push-refuses-carried-silent.sh — a work/<order> push whose change is
# carried-silent (due to a carried obligation, neither paying an item nor
# carrying a Carried-Waiver) is REFUSED by the pre-push hook, not warned and
# pushed only to be evicted by the land queue an hour later.
#
# The hook's own carried-obligations block is extracted and run against a STUB
# plan binary (TILLANDSIAS_PLAN_BIN, which resolve_plan_binary honours first),
# so each arm chooses exactly what the guard answers:
#   A  REFUSED   a `carried:<backlog>:due:<item>` line -> exit 1, the refusal
#                line names it, and the waiver line is printed as the remedy
#   B  WAIVED    `carried:<backlog>:waived:<reason>` -> the block falls through
#   C  NOT DUE   `carried:<backlog>:not-due` -> the block falls through
#   D  OFF LANE  WORK_REF_LANE != 1 -> the block never runs the guard, even on due
#   E  MERGED    merge-then-push: the frozen base is the merge base with the
#                merged trunk, so trunk's own changes are never counted as this push's
# PRE-FIX: arm A FAILS (the block called `refuse`, which only warns on the work lane).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/pre-push-local-gate.sh"
pass=0; fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

BLOCK="$(awk '/^# ORDER 1577-g96z — A WORK PUSH IS TOLD WHAT IT OWES/,/^fi$/' "$HOOK")"
if ! grep -q 'check-carried-obligations.lua' <<<"$BLOCK"; then
    echo "FAIL: could not extract the hook's carried-obligations block — the fixture has drifted from the hook"
    exit 1
fi

mkdir -p "$ROOT/target"
W="$(mktemp -d "$ROOT/target/test-pre-push-carried.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts/lua"
: > "$W/scripts/lua/check-carried-obligations.lua"
cp "$ROOT/scripts/plan-binary-probe.sh" "$W/scripts/plan-binary-probe.sh"

# stub <verdict line> — a plan binary that has `script` and prints that line
stub() {
    cat > "$W/plan" <<EOF
#!/usr/bin/env bash
case "\$1" in
  capabilities) echo script ;;
  script) printf '%s\n' "$1"; printf '    candidate: scripts/x.sh\nCarried-Waiver: shell-to-lua <reason>\n' >&2 ;;
esac
EOF
    chmod +x "$W/plan"
}
# block <lane> — run the extracted block in the scratch tree; prints rc last
block() {
    ( cd "$W" && env TILLANDSIAS_PLAN_BIN="$W/plan" WORK_REF_LANE="$1" RED= RST= \
        bash -c 'refuse() { echo "WARNED-NOT-REFUSED: $1" >&2; return 0; }; eval "$1"; echo "fell-through"' _ "$BLOCK" 2>&1
      echo "rc=$?" )
}

# A
stub "carried:shell-to-lua:due:scripts/check-cheatsheet-tiers.sh (110 lines)"
out="$(block 1)"
if grep -q '^rc=1$' <<<"$out" && grep -q 'pre-push refused: carried:shell-to-lua:due:' <<<"$out" \
    && grep -q 'Carried-Waiver: shell-to-lua' <<<"$out" && ! grep -q 'fell-through\|WARNED-NOT-REFUSED' <<<"$out"; then
    ok "A: a carried-silent work push is REFUSED (exit 1) and the waiver line is shown"
else
    bad "A: wanted rc=1, a refusal and the waiver line, no fall-through; got: $(tr '\n' '|' <<<"$out")"
fi
# B
stub "carried:shell-to-lua:waived:blocked-by #1109"
out="$(block 1)"
if grep -q 'fell-through' <<<"$out" && grep -q '^rc=0$' <<<"$out" && ! grep -q 'refused' <<<"$out"; then
    ok "B: a waived change passes"
else
    bad "B: got: $(tr '\n' '|' <<<"$out")"
fi
# C
stub "carried:shell-to-lua:not-due"
out="$(block 1)"
if grep -q 'fell-through' <<<"$out" && grep -q '^rc=0$' <<<"$out"; then
    ok "C: a change that owes nothing passes"
else
    bad "C: got: $(tr '\n' '|' <<<"$out")"
fi
# D
stub "carried:shell-to-lua:due:scripts/x.sh (1 lines)"
out="$(block 0)"
if grep -q 'fell-through' <<<"$out" && grep -q '^rc=0$' <<<"$out" && ! grep -q 'refused' <<<"$out"; then
    ok "D: outside the work lane the guard is not run at all"
else
    bad "D: got: $(tr '\n' '|' <<<"$out")"
fi


# E  MERGE-THEN-PUSH: the hook freezes its diff base as the merge base with
#    origin/linux-next, so trunk changes a push merged are not counted as its
#    own. (2026-11-21: a refusal first blamed on a merge was this branch's own
#    new .sh, which the carried check rightly counted.)
BASEBLOCK="$(awk '/^# ORDER 1592-idmu: freeze the diff-scoped guards/{p=1} p{print} p&&/^fi$/{n++; if (n==2) exit}' "$HOOK")"
G="$W/merge"; mkdir -p "$G"
gq() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=linux-next "$@"; }
gq init -q --bare "$G/remote.git" && gq clone -q "$G/remote.git" "$G/c" 2>/dev/null && (
    cd "$G/c" && echo a > a && gq add a && gq commit -qm T0 && gq push -q origin HEAD:linux-next &&
    gq switch -q -c work/x && echo own > own && gq add own && gq commit -qm own &&
    gq switch -q --detach origin/linux-next && echo t1 > trunk && gq add trunk && gq commit -qm T1 &&
    gq push -q origin HEAD:linux-next && git rev-parse HEAD > "$G/t1" &&
    gq switch -q work/x && gq merge -q --no-edit "$(cat "$G/t1")" &&
    true )
T0="$(git -C "$G/c" rev-list --max-parents=0 HEAD)"; T1="$(cat "$G/t1" 2>/dev/null)"
stale="$(git -C "$G/c" rev-parse refs/remotes/origin/linux-next)"
got="$(cd "$G/c" && env -u TILLANDSIAS_GATE_DIFF_BASE -u TILLANDSIAS_GATE_DIFF_BASE_ROOT REPO_ROOT="$G/c" B="$BASEBLOCK" bash -c 'set -- origin; eval "$B"; echo "BASE=${TILLANDSIAS_GATE_DIFF_BASE:-}"' 2>&1)"
if [ -n "$T1" ] && [ "$stale" = "$T1" ] && [ "$T0" != "$T1" ] && grep -qx "BASE=$T1" <<<"$got" \
    && [ -z "$(git -C "$G/c" diff --name-only "$T1"...HEAD -- trunk)" ]; then
    ok "E: merge-then-push freezes the merged trunk as its base, so trunk's file is not this push's"
else
    bad "E: premise stale=$stale T0=$T0 T1=$T1; got: $(tr '\n' '|' <<<"$got")"
fi
if [ "$fail" -eq 0 ]; then echo "ok:pre-push-refuses-carried-silent:$pass"; exit 0; fi
echo "fail:pre-push-refuses-carried-silent:$fail failed, $pass passed"; exit 1
