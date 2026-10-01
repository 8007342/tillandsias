#!/usr/bin/env bash
# @trace order:1384-bxhk
#
# test-shell-ratchet.sh — scripts/lua/check-shell-ratchet.lua counts the shell
# corpus on every --check, refuses what would grow it back, and its floors only
# descend (1384-bxhk verifiable_closure, arms in its order).
#
#   1 COUNTS     the one-line grammar; sh= equals an independent find of
#                scripts/{check,test,verify,guard}-*.sh at maxdepth 1
#   2 DECIDER    adding scripts/check-zzz.sh: violation:shell-ratchet:new-decider,
#                exit 1, and the remedy names `tillandsias-plan script run`
#   3 LITMUS     once a steps: litmus exists, a new command: with `a | b` outside
#                quotes is refused; the same pipe inside a single-quoted literal
#                is accepted
#   4 FLOORS     a commit RAISING a floor is refused; a commit LOWERING one (with
#                the pipe really removed) is accepted
#   5 EMPTY      an empty scan population is could-not-run (exit 3), never ok
#   6 STRINGS    an allow_shell_strings=true declaration in scripts/lua is counted
#   7 FIXTURE    a NEW test-*.sh is counted and warned, not refused (coordinator
#                scope 2026-10-01: fixtures stay shell until scripts/lua can spawn)
#   8 PIPES      a NEW pipe site in a script is counted and warned, not refused
#
# HERMETIC, AND IT ENCODES NO MOMENT: every arm runs in a FRESH scratch git repo
# seeded from this tree's scripts/ and litmus files, with TILLANDSIAS_REPO_ROOT
# pinned to it, so the floor-history commits never touch the real repo and no
# arm compares against a ref that moves when this row lands.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ] || ! grep -qx script <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "could-not-run:shell-ratchet-fixture:no-script-runner — build it: cargo build --release -p tillandsias-plan"
    exit 3
fi
mkdir -p "$ROOT/target/plan-scratch"
W="$(mktemp -d "$ROOT/target/plan-scratch/shell-ratchet.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM
GC=(-c user.email=f@f -c user.name=f -c commit.gpgsign=false)
RATCHET="$ROOT/scripts/lua/check-shell-ratchet.lua"

seed() { # seed <dir>: a fresh repo holding this tree's scripts/ and litmus files
    mkdir -p "$1/openspec"
    cp -R "$ROOT/scripts" "$1/scripts"
    cp -R "$ROOT/openspec/litmus-tests" "$1/openspec/litmus-tests"
    git -C "$1" init -q
    git -C "$1" "${GC[@]}" add -A
    git -C "$1" "${GC[@]}" commit -qm seed
}
run() { # run <dir> [args] -> OUT ERR RC
    OUT="$(cd "$1" && TILLANDSIAS_REPO_ROOT="$1" "$PLAN" script run "$RATCHET" "${@:2}" 2>"$W/err")"; RC=$?
    ERR="$(cat "$W/err")"
}
commit() { git -C "$1" "${GC[@]}" add -A && git -C "$1" "${GC[@]}" commit -qm "$2"; }

# ── ARM 1: COUNTS ──────────────────────────────────────────────────────────
S="$W/s1"; seed "$S"
run "$S"
want="$(find "$S/scripts" -maxdepth 1 \( -name 'check-*.sh' -o -name 'test-*.sh' -o -name 'verify-*.sh' -o -name 'guard-*.sh' \) | grep -vxF -f <(sed -e '/^#/d' -e '/^$/d' -e "s#^#$S/#" "$S/scripts/portability/bootstrap-shell-allowlist.txt") | wc -l | tr -d ' ')"
if [ "$RC" = 0 ] && grep -qE '^ok:shell-ratchet:sh=[0-9]+:floor:[0-9]+ pipes=[0-9]+:floor:[0-9]+ litmus-form:command=[0-9]+:steps=[0-9]+:rust_queries=[0-9]+ gate-steps:sh=[0-9]+:lua=[0-9]+ shell-strings=[0-9]+$' <<<"$OUT" \
   && grep -q "^ok:shell-ratchet:sh=$want:" <<<"$OUT"; then
    ok "ARM 1: the grammar line, with sh=$want equal to an independent find"
else
    bad "ARM 1: rc=$RC out=[$OUT] want sh=$want"
fi

# ── ARM 2: a NEW .sh decider ───────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho ok:zzz\n' > "$S/scripts/check-zzz.sh"
run "$S"
if [ "$RC" = 1 ] && grep -qx 'violation:shell-ratchet:new-decider:scripts/check-zzz.sh' <<<"$OUT" && grep -q 'tillandsias-plan script run' <<<"$ERR"; then
    ok "ARM 2: a new scripts/check-zzz.sh is refused (exit 1), naming script run as the remedy"
else
    bad "ARM 2: rc=$RC out=[$OUT]"
fi
rm -f "$S/scripts/check-zzz.sh"

# ── ARM 3: a NEW piped litmus command, once steps: exists ──────────────────
# The scratch litmus names are ASSEMBLED, never spelled whole, or
# check-litmus-pin-claims reads them as claims on litmus tests that do not exist.
LP="litmus"
printf 'name: %s:zz-steps\nsteps:\n  - run: x\n' "$LP" > "$S/openspec/litmus-tests/zz-steps.yaml"
commit "$S" "a steps: litmus exists"
printf 'name: %s:zz-quoted\ncritical_path:\n  - command: "echo %s"\n' "$LP" "'a | b'" > "$S/openspec/litmus-tests/zz-quoted.yaml"
run "$S"; q_rc=$RC; q_out="$OUT"
printf 'name: %s:zz-piped\ncritical_path:\n  - command: "printf x | grep -q x"\n' "$LP" > "$S/openspec/litmus-tests/zz-piped.yaml"
run "$S"
if [ "$q_rc" = 0 ] && [ "$RC" = 1 ] && grep -qx 'violation:shell-ratchet:new-piped-command:openspec/litmus-tests/zz-piped.yaml' <<<"$OUT"; then
    ok "ARM 3: with steps: present, a new piped command: is refused; a pipe inside a single-quoted literal is accepted"
else
    bad "ARM 3: quoted rc=$q_rc out=[$q_out]; piped rc=$RC out=[$OUT]"
fi
rm -f "$S/openspec/litmus-tests/zz-piped.yaml" "$S/openspec/litmus-tests/zz-quoted.yaml"
commit "$S" "drop the arm-3 litmus" >/dev/null 2>&1 || true

# ── ARM 4: floors only descend, judged over the floor file's own history ───
F="$S/scripts/portability/pipe-site-floor.txt"
victim="$(awk '$1=="scripts" && $3>1 {print $2; exit}' "$F")"
vn="$(awk -v p="$victim" '$1=="scripts" && $2==p {print $3}' "$F")"
awk -v p="$victim" '$1=="scripts" && $2==p {$3=$3+5} {print}' "$F" > "$F.new" && mv "$F.new" "$F"
commit "$S" "raise a floor"
run "$S"; up_rc=$RC; up_out="$OUT"
git -C "$S" "${GC[@]}" revert --no-edit HEAD >/dev/null
# LOWER honestly: remove one real pipe site from the victim and lower its floor by one
lnum="$(grep -nE '[^|]\|[^|]' "$S/$victim" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -vE "'[^']*\|[^']*'|\"[^\"]*\|[^\"]*\"" | head -1 | cut -d: -f1)"
sed -i "${lnum}d" "$S/$victim"
awk -v p="$victim" -v n="$vn" '$1=="scripts" && $2==p {$3=n-1} {print}' "$F" > "$F.new" && mv "$F.new" "$F"
run "$S" --dump-floors; actual="$(grep -E "^scripts $victim " <<<"$OUT" | awk '{print $3}')"
awk -v p="$victim" -v n="${actual:-0}" '$1=="scripts" && $2==p {$3=n} {print}' "$F" > "$F.new" && mv "$F.new" "$F"
commit "$S" "port a pipe away and lower its floor"
run "$S"; down_rc=$RC; down_out="$OUT"
if [ "$up_rc" = 1 ] && grep -q "^violation:shell-ratchet:floor-raised:scripts/portability/pipe-site-floor.txt:scripts $victim" <<<"$up_out" \
   && [ "$down_rc" = 0 ] && [ "${actual:-x}" -lt "$vn" ]; then
    ok "ARM 4: raising $victim's floor is refused; lowering it ($vn -> $actual) with the pipe removed is accepted"
else
    bad "ARM 4: up rc=$up_rc out=[$up_out]; down rc=$down_rc out=[$down_out] floor $vn -> ${actual:-?}"
fi

# ── ARM 5: an empty population is could-not-run ────────────────────────────
E="$W/empty"; mkdir -p "$E/scripts/portability"; git -C "$E" init -q
run "$E"
if [ "$RC" = 3 ] && [ "$OUT" = "could-not-run:shell-ratchet:empty-population" ]; then
    ok "ARM 5: an empty population is could-not-run:shell-ratchet:empty-population (exit 3), never ok"
else
    bad "ARM 5: rc=$RC out=[$OUT]"
fi

# ── ARM 6: allow_shell_strings is counted ──────────────────────────────────
printf -- '-- script{allow_shell_strings=true}\nverdict.ok("x")\n' > "$S/scripts/lua/zz-strings.lua"
run "$S"
if grep -q 'shell-strings=1$' <<<"$OUT"; then
    ok "ARM 6: an allow_shell_strings=true declaration in scripts/lua is counted (shell-strings=1)"
else
    bad "ARM 6: out=[$OUT]"
fi


# ── ARM 7: a NEW .sh FIXTURE is counted, not refused (coordinator scope) ────
# The row refuses new shell DECIDERS; a test-*.sh is a fixture, warned and
# counted while scripts/lua cannot spawn (1384-aixy). Pre-scope: refused.
S="$W/s7"; seed "$S"
printf '#!/usr/bin/env bash\necho ok:zzz-fixture\n' > "$S/scripts/test-zzz.sh"
run "$S"
if [ "$RC" = 0 ] && grep -q '^ok:shell-ratchet:' <<<"$OUT" && grep -q 'warn:shell-ratchet:new-shell-fixture:scripts/test-zzz.sh' <<<"$ERR"; then
    ok "ARM 7: a new scripts/test-zzz.sh passes with a warn:shell-ratchet:new-shell-fixture line"
else
    bad "ARM 7: rc=$RC out=[$OUT] err=[$(head -c 300 <<<"$ERR")]"
fi

# ── ARM 8: a NEW pipe site in a script is counted, not refused ─────────────
S="$W/s8"; seed "$S"
printf '#!/usr/bin/env bash\necho a | cat\n' > "$S/scripts/zzz-helper.sh"
run "$S"
if [ "$RC" = 0 ] && grep -q '^ok:shell-ratchet:' <<<"$OUT" && grep -q 'warn:shell-ratchet:new-pipes:scripts/zzz-helper.sh:1>floor:0' <<<"$ERR"; then
    ok "ARM 8: a new pipe site passes with a warn:shell-ratchet:new-pipes line"
else
    bad "ARM 8: rc=$RC out=[$OUT] err=[$(head -c 300 <<<"$ERR")]"
fi
echo "shell-ratchet: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
