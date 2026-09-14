#!/usr/bin/env bash
# test-gate-step-prefix-allocation.sh — 1162-qbrx: a gate-step prefix taken
# by the integrate is reallocated at land time, after the integrate and
# before the gate, so two lands that chose the same prefix both land.
#
# Hermetic: scratch git repos under target/plan-scratch. The "land" is
# modelled as the integrate (merge of the remote tip) followed by
# scripts/allocate-gate-step-prefix.sh --base <tip> --commit, which is what
# the land tool runs in that window; arm 9 then EXECUTES the land tool's own
# block (extracted by its anchors) against a stub allocator, so the binding
# is proved by what ran, not by a grep — a first draft grepped the call and
# was green for a commented-out call (the reviewer's mutant).
#
# Arms:
#   1. two sequential lands choosing 280: the second moves to 285 (the
#      midpoint of the (280, 290) interval, so the gap survives another
#      collision), committed, the first land's 280 untouched, no shared
#      prefix afterwards. PRE-FIX CONTROL: arm 7's check over the integrated
#      tree BEFORE allocation reports the shared prefix.
#   2. NEGATIVE CONTROL: an explicit ordering is preserved — a step chosen
#      at 285 (between 280 and 290) lands at 287 when 285 is taken, still
#      after 285 and before 290.
#   3. no collision: no rename, no commit, tree hash unchanged.
#   4. no gap: 300..310 occupied, an added 300 is refused, nothing renamed,
#      the tree is clean (nothing left staged), non-zero exit.
#   5. two added files sharing a prefix with each other keep the first and
#      move the second; two added files colliding with a remote step from
#      the SAME prefix both move to distinct free slots (115, 116) — the
#      bound comes from the entry occupancy, freeness from the live one.
#   6. --dry-run reports exactly the plan --commit then performs, and moves nothing.
#   7. refusals with the tree untouched: an unknown flag (exit 2); a --base
#      that is not an ancestor of HEAD (integrate first); a 999 that would
#      overflow the width; and a non-numeric zzz-common.step LAST in the
#      tree still yields a verdict (the pipefail trap the reviewer found).
#   8. PLATFORM BRANCH: with --exclude origin/linux-next, a trunk step the
#      trunk merge brought in is NOT renamed (control: without --exclude it
#      would be — the reviewer's blocker).
#   9. THE LAND TOOL'S BLOCK, executed: extracted between its anchors, run
#      under a driver with a stub allocator that records its arguments —
#      the stub is called with --base origin/<branch> --commit, plus
#      --exclude origin/linux-next only on a platform branch; a
#      no-collision verdict prints nothing; a rename verdict is echoed with
#      the attempt prefix; a non-zero stub stops the land with
#      refused:land:gate-step-prefix and exit 8. Plus the line-order pin:
#      the block sits after the integrate and before ./build.sh --check.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOC="$ROOT/scripts/allocate-gate-step-prefix.sh"
LAND="$ROOT/scripts/land-on-platform-branch.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
[ -f "$ALLOC" ] || { echo "FAIL: missing $ALLOC"; echo "FAIL: gate-step-prefix-allocation 0/1 (1162-qbrx)"; exit 1; }

_tmpbase="$ROOT/target/plan-scratch"
mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/gate-step-prefix.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
G() { git -c user.email=t@t -c user.name=t "$@"; }
alloc() { bash "$ALLOC" "$@"; }
# The arm-7 check of test-gate-step-append-no-conflict.sh over a directory.
dups() { for f in "$1"/*.step; do [ -e "$f" ] || continue; b="${f##*/}"; printf '%s\n' "${b%%-*}"; done | sort | uniq -d | tr '\n' ' '; }
step() { printf 'STEP_DESC="%s"\nSTEP_SCRIPT="scripts/test-%s.sh"\n' "$1" "$1" > "scripts/gate-steps.d/$1"; }
names() { ls scripts/gate-steps.d | tr '\n' ' '; }
new_repo() { # new_repo <dir> <prefixes...> — baseline with one step per prefix
    local d="$1"; shift
    git init -q -b main "$d"; ( cd "$d" && git config core.autocrlf false && mkdir -p scripts/gate-steps.d \
      && for p in "$@"; do printf 'STEP_SCRIPT="scripts/test-base-%s.sh"\n' "$p" > "scripts/gate-steps.d/${p}-base-${p}.step"; done \
      && G add -A >/dev/null && G commit -q -m baseline )
}

# ── ARM 1: two sequential lands choosing 280 ───────────────────────────────
R="$W/r1"; new_repo "$R" 010 270 290; cd "$R" || exit 2
base0="$(git rev-parse HEAD)"
G checkout -q -b hostA; step 280-1111-aaaa.step; G add -A >/dev/null; G commit -q -m "hostA adds 280"
G checkout -q main; G merge -q --no-edit hostA >/dev/null 2>&1      # the first land
G checkout -q -b hostB "$base0"
step 280-2222-bbbb.step; G add -A >/dev/null; G commit -q -m "hostB adds 280 too"
G merge -q --no-edit main >/dev/null 2>&1                            # hostB's land integrates the remote tip
pre="$(dups scripts/gate-steps.d)"
[ "$pre" = "280 " ] && ok "ARM 1 PRE-FIX CONTROL: after the integrate the tree carries a shared prefix (280) — the gate's arm 7 would refuse it" || bad "ARM 1 control: dups='$pre'"
head_before="$(git rev-parse HEAD)"
out="$(alloc --base main --commit 2>"$W/err1" | tail -1)"
if [ "$out" = "ok:gate-step-prefix:reallocated:1" ] && [ -f scripts/gate-steps.d/285-2222-bbbb.step ] && [ ! -e scripts/gate-steps.d/280-2222-bbbb.step ]; then
    ok "ARM 1: the second land's step moved 280 -> 285, the midpoint of (280, 290), so the gap survives another collision"
else
    bad "ARM 1: '$out' $(names)"; sed 's/^/      /' "$W/err1" | tail -4
fi
[ -f scripts/gate-steps.d/280-1111-aaaa.step ] && ok "ARM 1: the first land's 280 is untouched" || bad "ARM 1: the first land's step was renamed"
subj="$(git log -1 --format=%s)"
if [ "$(git rev-parse HEAD)" != "$head_before" ] && [ "${subj#*1162-qbrx}" != "$subj" ] && [ -z "$(git status --porcelain)" ]; then
    ok "ARM 1: the rename is committed (subject names 1162-qbrx) and the tree is clean"
else
    bad "ARM 1: no commit / dirty tree: $(git status --porcelain | tr '\n' ' ')"
fi
post="$(dups scripts/gate-steps.d)"
[ -z "$post" ] && ok "ARM 1: no two .step files share a numeric prefix after allocation — the second land passes the check the first would have failed" || bad "ARM 1: dups after='$post'"

# ── ARM 2: NEGATIVE CONTROL — explicit ordering preserved ──────────────────
R="$W/r2"; new_repo "$R" 280 285 290; cd "$R" || exit 2
G checkout -q -b hostC; step 285-3333-cccc.step; G add -A >/dev/null; G commit -q -m "hostC adds 285"
out="$(alloc --base main --commit 2>/dev/null | tail -1)"
if [ "$out" = "ok:gate-step-prefix:reallocated:1" ] && [ -f scripts/gate-steps.d/287-3333-cccc.step ]; then
    order="$(ls scripts/gate-steps.d | sed -E 's/^([0-9]+)-.*/\1/' | tr '\n' ' ')"
    case "$order" in *"280 285 287 290"*) ok "ARM 2 (negative control): a step chosen between 280 and 290 lands at 287 — still after 285 and before 290" ;; *) bad "ARM 2: order '$order'" ;; esac
else
    bad "ARM 2: '$out' $(names)"
fi

# ── ARM 3: no collision ────────────────────────────────────────────────────
R="$W/r3"; new_repo "$R" 010 020; cd "$R" || exit 2
G checkout -q -b hostD; step 030-4444-dddd.step; G add -A >/dev/null; G commit -q -m "hostD adds 030"
h="$(git rev-parse HEAD)"; t="$(git write-tree)"
out="$(alloc --base main --commit 2>/dev/null | tail -1)"
[ "$out" = "ok:gate-step-prefix:no-collision" ] && [ "$(git rev-parse HEAD)" = "$h" ] && [ "$(git write-tree)" = "$t" ] \
    && ok "ARM 3: no collision -> no rename, no commit, tree unchanged" || bad "ARM 3: '$out' head-moved=$([ "$(git rev-parse HEAD)" = "$h" ] && echo no || echo yes)"

# ── ARM 4: no gap, and the tree is left exactly as found ───────────────────
R="$W/r4"; new_repo "$R" 300 301 302 303 304 305 306 307 308 309 310; cd "$R" || exit 2
G checkout -q -b hostE; step 300-5555-eeee.step; G add -A >/dev/null; G commit -q -m "hostE adds 300"
h="$(git rev-parse HEAD)"
out="$(alloc --base main --commit 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -ne 0 ] && [ "$out" = "refused:gate-step-prefix:no-gap:scripts/gate-steps.d/300-5555-eeee.step" ] && [ "$(git rev-parse HEAD)" = "$h" ] \
    && [ -f scripts/gate-steps.d/300-5555-eeee.step ] && [ -z "$(git status --porcelain)" ] \
    && ok "ARM 4: with 300..310 all occupied the added 300 is refused (no-gap), nothing renamed, nothing staged, non-zero exit" || bad "ARM 4: rc=$rc '$out' status=$(git status --porcelain | tr '\n' ' ')"

# ── ARM 5: siblings ────────────────────────────────────────────────────────
R="$W/r5"; new_repo "$R" 100 120; cd "$R" || exit 2
G checkout -q -b hostF; step 110-6666-ffff.step; step 110-7777-gggg.step; G add -A >/dev/null; G commit -q -m "hostF adds two at 110"
out="$(alloc --base main --commit 2>/dev/null | tail -1)"
[ "$out" = "ok:gate-step-prefix:reallocated:1" ] && [ -f scripts/gate-steps.d/110-6666-ffff.step ] && [ -f scripts/gate-steps.d/115-7777-gggg.step ] \
    && ok "ARM 5: of two added files sharing 110 the first keeps it and the second moves to 115" || bad "ARM 5a: '$out' $(names)"
R="$W/r5b"; new_repo "$R" 110 120; cd "$R" || exit 2
G checkout -q -b hostH; step 110-8888-aaaa.step; step 110-9999-bbbb.step; G add -A >/dev/null; G commit -q -m "hostH adds two at 110 against a remote 110"
out="$(alloc --base main --commit 2>"$W/err5b" | tail -1)"
[ "$out" = "ok:gate-step-prefix:reallocated:2" ] && [ -f scripts/gate-steps.d/115-8888-aaaa.step ] && [ -f scripts/gate-steps.d/116-9999-bbbb.step ] && [ -z "$(dups scripts/gate-steps.d)" ] \
    && ok "ARM 5: two added files colliding with a remote 110 move to 115 and 116 — the bound from the entry occupancy, freeness from the live one" || { bad "ARM 5b: '$out' $(names)"; sed 's/^/      /' "$W/err5b" | tail -3; }

# ── ARM 6: --dry-run previews exactly the plan --commit performs ───────────
R="$W/r6"; new_repo "$R" 110 120; cd "$R" || exit 2
G checkout -q -b hostG; step 110-8888-aaaa.step; step 110-9999-bbbb.step; G add -A >/dev/null; G commit -q -m "hostG adds two at 110"
h="$(git rev-parse HEAD)"
dry="$(alloc --base main --dry-run 2>/dev/null)"
if [ "$(printf '%s\n' "$dry" | tail -1)" = "ok:gate-step-prefix:dry-run:2" ] && printf '%s\n' "$dry" | grep -q '110-8888-aaaa.step -> 115-8888-aaaa.step' \
   && printf '%s\n' "$dry" | grep -q '110-9999-bbbb.step -> 116-9999-bbbb.step' && [ "$(git rev-parse HEAD)" = "$h" ] && [ -z "$(git status --porcelain)" ]; then
    real="$(alloc --base main --commit 2>/dev/null | grep '^gate-step-prefix:')"
    [ "$real" = "$(printf '%s\n' "$dry" | grep '^gate-step-prefix:')" ] && ok "ARM 6: --dry-run names 115 and 116 and moves nothing; --commit then performs exactly that plan" || bad "ARM 6: plans differ: dry='$(printf '%s' "$dry" | tr '\n' '|')' real='$(printf '%s' "$real" | tr '\n' '|')'"
else
    bad "ARM 6: '$(printf '%s' "$dry" | tr '\n' '|')'"
fi

# ── ARM 7: refusals with the tree untouched; a verdict always ──────────────
out="$(alloc --bogus 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -eq 2 ] && [ "$out" = "refused:gate-step-prefix:usage:--bogus" ] && ok "ARM 7: an unknown flag is refused with exit 2" || bad "ARM 7a: rc=$rc '$out'"
R="$W/r7"; new_repo "$R" 010 020; cd "$R" || exit 2
G checkout -q -b hostI; step 020-1212-iiii.step; G add -A >/dev/null; G commit -q -m "hostI adds 020, not integrated"
G checkout -q main; step 030-base-030.step; G add -A >/dev/null; G commit -q -m "remote moves on"; G checkout -q hostI
out="$(alloc --base main --commit 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -eq 2 ] && [ "${out#refused:gate-step-prefix:usage:main is not an ancestor}" != "$out" ] && [ -f scripts/gate-steps.d/020-1212-iiii.step ] \
    && ok "ARM 7: a --base that is not an ancestor of HEAD is refused (integrate first) instead of a silent no-collision" || bad "ARM 7b: rc=$rc '$out'"
R="$W/r7c"; new_repo "$R" 990 999; cd "$R" || exit 2
G checkout -q -b hostJ; step 999-1313-jjjj.step; G add -A >/dev/null; G commit -q -m "hostJ adds 999"
out="$(alloc --base main --commit 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -ne 0 ] && [ "$out" = "refused:gate-step-prefix:overflow:scripts/gate-steps.d/999-1313-jjjj.step" ] && [ -f scripts/gate-steps.d/999-1313-jjjj.step ] && [ -z "$(git status --porcelain)" ] \
    && ok "ARM 7: a 999 that would widen to 1000 (sorting FIRST under the glob) is refused, tree untouched" || bad "ARM 7c: rc=$rc '$out'"
R="$W/r7d"; new_repo "$R" 010 020; cd "$R" || exit 2
printf 'STEP_SCRIPT="scripts/test-common.sh"\n' > scripts/gate-steps.d/zzz-common.step; G add -A >/dev/null; G commit -q -m "a non-numeric step, last in the tree"
G checkout -q -b hostK; step 030-1414-kkkk.step; G add -A >/dev/null; G commit -q -m "hostK adds 030"
out="$(alloc --base main --commit 2>/dev/null | tail -1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:gate-step-prefix:no-collision" ] && ok "ARM 7: a non-numeric .step file last in the tree does not kill the run under pipefail — a verdict is printed" || bad "ARM 7d: rc=$rc '$out'"

# ── ARM 8: PLATFORM BRANCH — trunk's steps are never renamed ───────────────
R="$W/r8"; new_repo "$R" 100 200; cd "$R" || exit 2
git branch -q -m main linux-next
G checkout -q -b windows-next; step 150-windows-local.step; G add -A >/dev/null; G commit -q -m "windows-next carries an unrelayed local step"
G checkout -q linux-next; step 150-1177-linux.step; G add -A >/dev/null; G commit -q -m "trunk lands a step at 150"
git update-ref refs/remotes/origin/linux-next linux-next; git update-ref refs/remotes/origin/windows-next windows-next
G checkout -q windows-next; printf 'unrelated\n' > note.txt; G add -A >/dev/null; G commit -q -m "yolanda lands an unrelated change"
G merge -q --no-edit origin/linux-next >/dev/null 2>&1              # the land tool's mandated trunk merge
h="$(git rev-parse HEAD)"
ctrl="$(alloc --base origin/windows-next --dry-run 2>/dev/null | tail -1)"
out="$(alloc --base origin/windows-next --exclude origin/linux-next --commit 2>/dev/null | tail -1)"
if [ "$ctrl" = "ok:gate-step-prefix:dry-run:1" ] && [ "$out" = "ok:gate-step-prefix:no-collision" ] && [ "$(git rev-parse HEAD)" = "$h" ] \
   && [ -f scripts/gate-steps.d/150-1177-linux.step ] && [ -f scripts/gate-steps.d/150-windows-local.step ]; then
    ok "ARM 8 (platform branch): with --exclude origin/linux-next the trunk step the merge brought in is not renamed (control: without the exclude it would have been)"
else
    bad "ARM 8: ctrl='$ctrl' out='$out' $(names)"
fi

# ── ARM 9: THE LAND TOOL'S BLOCK, executed ─────────────────────────────────
cd "$ROOT" || exit 2
if [ -f "$LAND" ]; then
    call_line="$(grep -n '^    if \[ -f scripts/allocate-gate-step-prefix.sh \]; then$' "$LAND" | head -1 | cut -d: -f1)"
    integ_line="$(grep -n '_integrated=1' "$LAND" | tail -1 | cut -d: -f1)"
    gate_line="$(grep -n '^ *\./build\.sh --check' "$LAND" | head -1 | cut -d: -f1)"
    if [ -n "$call_line" ] && [ -n "$integ_line" ] && [ -n "$gate_line" ] && [ "$integ_line" -lt "$call_line" ] && [ "$call_line" -lt "$gate_line" ]; then
        ok "ARM 9: the block sits after the integrate (line $integ_line) and before ./build.sh --check (line $gate_line)"
    else
        bad "ARM 9: placement call=$call_line integrate=$integ_line gate=$gate_line"
    fi
    awk '/^    if \[ -f scripts\/allocate-gate-step-prefix.sh \]; then$/{p=1} p{print} p&&/^    fi$/{exit}' "$LAND" > "$W/block.sh"
    if [ "$(wc -l < "$W/block.sh" | tr -d ' ')" -lt 5 ]; then
        bad "ARM 9: could not extract the allocator block from the land tool (anchors moved?)"
    else
        D="$W/land"; mkdir -p "$D/scripts"
        cat > "$D/scripts/allocate-gate-step-prefix.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_ARGS"
printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
STUB
        drive() { # drive <BRANCH> <STUB_OUT> <STUB_RC> -> stdout+stderr in $W/drv.out, rc in $W/drv.rc
            ( cd "$D" && STUB_ARGS="$W/stub.args" STUB_OUT="$2" STUB_RC="$3" BRANCH="$1" TRUNK="linux-next" attempt=1 \
                bash -c '. "$1"; echo "block-completed"' _ "$W/block.sh" ) > "$W/drv.out" 2>&1; echo $? > "$W/drv.rc"
        }
        drive osx-next "ok:gate-step-prefix:no-collision" 0
        if [ "$(cat "$W/stub.args")" = "--base origin/osx-next --exclude origin/linux-next --commit" ] && grep -q '^block-completed$' "$W/drv.out" && ! grep -q 'gate-step-prefix' "$W/drv.out"; then
            ok "ARM 9 (executed): on a platform branch the block calls the allocator with --base origin/osx-next --exclude origin/linux-next --commit, and a no-collision verdict prints nothing"
        else
            bad "ARM 9 platform: args='$(cat "$W/stub.args")' out='$(tr '\n' '|' < "$W/drv.out")'"
        fi
        drive linux-next "gate-step-prefix: 280-x.step -> 285-x.step (280 taken by 280-y.step)
ok:gate-step-prefix:reallocated:1" 0
        if [ "$(cat "$W/stub.args")" = "--base origin/linux-next --commit" ] && grep -q '^land: attempt 1 — gate-step-prefix: 280-x.step -> 285-x.step' "$W/drv.out" && grep -q '^block-completed$' "$W/drv.out"; then
            ok "ARM 9 (executed): on trunk there is no --exclude, and a rename verdict is echoed with the attempt prefix while the land continues"
        else
            bad "ARM 9 trunk: args='$(cat "$W/stub.args")' out='$(tr '\n' '|' < "$W/drv.out")'"
        fi
        drive osx-next "refused:gate-step-prefix:no-gap:scripts/gate-steps.d/280-x.step" 1
        if [ "$(cat "$W/drv.rc")" = "8" ] && grep -q '^refused:land:gate-step-prefix — refused:gate-step-prefix:no-gap' "$W/drv.out" && ! grep -q '^block-completed$' "$W/drv.out"; then
            ok "ARM 9 (executed): a refusing allocator stops the land with refused:land:gate-step-prefix and exit 8 before the gate"
        else
            bad "ARM 9 refusal: rc=$(cat "$W/drv.rc") out='$(tr '\n' '|' < "$W/drv.out")'"
        fi
    fi
else
    bad "ARM 9: $LAND missing"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: gate-step-prefix-allocation $pass/$total (1162-qbrx)"; exit 0; fi
echo "FAIL: gate-step-prefix-allocation $pass/$total (1162-qbrx)"; exit 1
