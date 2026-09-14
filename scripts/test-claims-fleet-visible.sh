#!/usr/bin/env bash
# test-claims-fleet-visible.sh — 1153-j2nm: a claim written on a platform
# branch reaches origin/linux-next through scripts/push-plan-fragments-to-trunk.sh,
# accepted by the REAL pre-push hook's plan-only lane with no build stamp,
# and nothing else moves.
#
# Harness: the bare-remote + working copy + core.hooksPath shape of
# scripts/test-pre-push-plan-lane-after-merge.sh, but the hook is installed as
# a real .git/hooks/pre-push so each push exercises the lane the way git
# drives it (a raw-sha refspec, not a piped stdin line), and the lane's own
# checkers (status-loss, added-fragments-parse, scorable-obligation, base64)
# are copied in beside the hook so "the hook took the lane" is measured with
# them RUNNING, not skipped as absent (the first draft of this fixture copied
# four siblings and the hook printed three 'absent — skipped' notes). The
# plan binary is the checkout's own, resolved HERE where the probe can see
# it, the lesson that fixture recorded after it took macOS out of the landing
# path.
#
# Arms (a bare remote holds linux-next and osx-next; the working copy is on
# osx-next with a CODE commit ahead of trunk, the fleet's normal shape):
#   1. the claim fragment reaches trunk: origin/linux-next advances by exactly
#      one commit parented on the old tip whose diff is that one fragment; the
#      code commit is NOT carried; the hook took the plan-only lane; no gate
#      stamp existed; HEAD, the branch, the index and the worktree are
#      byte-identical before and after; trunk's fold now reads in_progress.
#   2. the later relay merges clean: osx-next into linux-next, no conflict,
#      one copy of the fragment with the pusher's blob.
#   3. NEGATIVE CONTROL: an explicit non-plan path is refused (scope), trunk stays.
#   4. NEGATIVE CONTROL: an event on a packet trunk has never seen is refused
#      (trunk-fold) and trunk stays; the default selection, which carries the
#      filing too, is accepted — and a MUTANT without the trunk-fold check
#      pushes the dangling event and trunk's own check goes red (teeth).
#   5. default selection SKIPS a dotfile and a nested path with a note; an
#      explicit dotfile is refused; nothing-new is a skip; trunk stays.
#   6. a changed copy of a fragment already on trunk is refused (exists).
#   7. --dry-run builds and validates an UNTRACKED fragment, pushes nothing;
#      STAGED (not committed) the same fragment rides the default selection
#      and stays staged here.
#   8. a good loop-status fragment rides the default selection and the hook
#      validates it; a bad one is skipped by default and refused explicitly.
#   9. NEGATIVE CONTROL (the packet's own): the platform branch carrying the
#      ungated code is still refused by its own gate; origin/osx-next stays.
#  10. a completion EVENT without its status fragment is refused as
#      status-loss (trunk would offer a closed row as ready); with the status
#      fragment the default push lands and trunk folds completed.
#  11. RACE: trunk moves after the helper's fetch; the hook refuses attempt 1,
#      the refetch sees the moved tip, the rebuilt commit lands on it.
#  12. usage: an unknown flag is refused with exit 2 and pushes nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/push-plan-fragments-to-trunk.sh"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

for f in "$HELPER" "$GUARD"; do
    [ -f "$f" ] || { echo "FAIL: missing $f"; echo "FAIL: claims-fleet-visible 0/1 (1153-j2nm)"; exit 1; }
done

_validator="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _validator=""
case "$_validator" in ./*) _validator="$ROOT/${_validator#./}" ;; esac
if [ -z "$_validator" ]; then
    echo "skip:claims-fleet-visible:no-validator — no runnable tillandsias-plan on this host, so neither the helper's trunk-fold check nor the lane can validate; build it (cargo build --release -p tillandsias-plan)"
    echo "claims-fleet-visible: 0 passed, 0 failed (skipped)"
    exit 0
fi
export TILLANDSIAS_PLAN_BIN="$_validator"
PLAN="$_validator"
export TILLANDSIAS_AGENT_ID="macos-fixture-osx-fixture-20200101t000000z"

_tmpbase="$ROOT/target/plan-scratch"
mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/claims-fleet-visible.XXXXXX")"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }
remote_tip() { git ls-remote "$W/bare.git" refs/heads/linux-next | cut -f1; }
osx_tip() { git ls-remote "$W/bare.git" refs/heads/osx-next | cut -f1; }
helper() { bash scripts/push-plan-fragments-to-trunk.sh "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
git config core.autocrlf false
mkdir -p scripts/hooks plan/index.d plan/loop_status.d
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
cp "$HELPER" scripts/push-plan-fragments-to-trunk.sh
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-issue-citation-convention.sh \
         check-fragment-status-loss.sh check-added-fragments-parse.sh \
         check-scorable-obligation-added.sh check-no-base64-script-injection.sh; do
    cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true
done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null || true
cat > plan/index.yaml <<'EOF'
packets:
  - packet_id: fixture-packet-one
    order: 1-aaaa
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: fixture packet one
    unscoreable: "fixture packet; not scored"
EOF
printf 'base\n' > README.md
printf 'fn main() {}\n' > src_placeholder.rs
printf '# loop status\n' > plan/loop_status.d/README.md
G add -A >/dev/null; G commit -q -m base
# The hook is installed the way git runs it, so every push below is gated
# exactly as a host's push is. The seeding pushes happen BEFORE it exists.
git push -q -u origin linux-next
git push -q origin linux-next:osx-next
printf '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push

# The platform host: on osx-next, a code commit ahead of trunk (never gated —
# there is no target/ and no stamp in this scratch), then a claim.
G checkout -q -B osx-next origin/osx-next
printf 'fn main() { /* macOS work */ }\n' > src_placeholder.rs
G add -A >/dev/null; G commit -q -m "feat: platform code, ungated"
"$PLAN" --index "$W/wc/plan/index.yaml" set-field 1-aaaa status in_progress --host fixture-osx --reason "claimed on osx-next" >/dev/null 2>&1
frag="$(ls plan/index.d/*.yaml | head -1)"
[ -n "$frag" ] || { echo "FAIL: set-field wrote no fragment"; echo "FAIL: claims-fleet-visible 0/1 (1153-j2nm)"; exit 1; }
G add plan/index.d >/dev/null; G commit -q -m "claim(1-aaaa): fixture-osx"

# ── ARM 1 ──────────────────────────────────────────────────────────────────
old_tip="$(remote_tip)"
b_head="$(git rev-parse HEAD)"; b_branch="$(git symbolic-ref --short HEAD)"
b_status="$(git status --porcelain --untracked-files=all)"; b_index="$(git write-tree)"
stamp_before="$(bash scripts/gate-stamp.sh verify 2>&1 | tail -1)"
out="$(helper 2>"$W/err1")"; rc=$?
verdict="$(printf '%s\n' "$out" | tail -1)"
case "$verdict" in
    ok:fragments-on-trunk:*:1)
        sha="${verdict#ok:fragments-on-trunk:}"; sha="${sha%:1}"
        new_tip="$(remote_tip)"
        if [ "$new_tip" = "$sha" ] && [ "$(git rev-parse "$sha^")" = "$old_tip" ]; then
            ok "ARM 1: origin/linux-next advanced by exactly one commit parented on the old tip"
        else
            bad "ARM 1: tip=$new_tip sha=$sha parent=$(git rev-parse "$sha^" 2>/dev/null) old=$old_tip"
        fi
        ns="$(git diff --name-status "$old_tip" "$sha")"
        if [ "$ns" = "$(printf 'A\t%s' "$frag")" ]; then
            ok "ARM 1: the pushed commit's whole diff is the one claim fragment"
        else
            bad "ARM 1: pushed diff is not the fragment alone: $(printf '%s' "$ns" | tr '\n' ' ')"
        fi
        if git diff --quiet "$old_tip" "$sha" -- src_placeholder.rs; then
            ok "ARM 1: the ungated platform code commit was NOT carried to trunk"
        else
            bad "ARM 1: platform code rode to trunk"
        fi
        if grep -q "plan-only lane: validated $frag" "$W/err1"; then
            ok "ARM 1: the real hook took the plan-only lane for the fragment"
        else
            bad "ARM 1: no 'plan-only lane: validated' line from the hook: $(grep -m2 'plan-only lane' "$W/err1" | tr '\n' ' ')"
        fi
        if grep -q 'absent — skipped' "$W/err1"; then
            bad "ARM 1: the lane skipped a checker as absent, so the lane was measured short: $(grep -m3 'absent — skipped' "$W/err1" | tr '\n' ' ')"
        else
            ok "ARM 1: none of the lane's checkers was skipped as absent (status-loss, added-fragments-parse, scorable-obligation, base64 all ran)"
        fi
        case "$stamp_before" in
            ok:*) bad "ARM 1: a gate stamp existed ($stamp_before), so the arm did not prove the no-stamp case" ;;
            *)    ok "ARM 1: no gate stamp existed (verify: ${stamp_before:-<empty>}) and the push was still accepted" ;;
        esac
        ;;
    *) bad "ARM 1: helper verdict '$verdict'"; sed 's/^/      /' "$W/err1" | tail -12 ;;
esac
a_head="$(git rev-parse HEAD)"; a_branch="$(git symbolic-ref --short HEAD)"
a_status="$(git status --porcelain --untracked-files=all)"; a_index="$(git write-tree)"
if [ "$a_head" = "$b_head" ] && [ "$a_branch" = "$b_branch" ] && [ "$a_status" = "$b_status" ] && [ "$a_index" = "$b_index" ]; then
    ok "ARM 1: HEAD, the branch, the index and the worktree are byte-identical before and after"
else
    bad "ARM 1: local state moved (head $b_head->$a_head branch $b_branch->$a_branch index $b_index->$a_index)"
fi
rm -rf "$W/reader"; git clone -q -b linux-next "$W/bare.git" "$W/reader" 2>/dev/null
fold="$("$PLAN" --index "$W/reader/plan/index.yaml" status 1-aaaa 2>/dev/null | head -1 | cut -f2)"
if [ "$fold" = "in_progress" ]; then
    ok "ARM 1: a trunk reader's fold now shows 1-aaaa in_progress — the claim separates"
else
    bad "ARM 1: trunk's fold reads '$fold' for 1-aaaa"
fi

# ── ARM 2: the relay merges clean ──────────────────────────────────────────
( cd "$W/reader" && git fetch -q origin osx-next && G merge -q --no-edit origin/osx-next >/dev/null 2>&1 ); rc=$?
pusher_blob="$(git hash-object -- "$frag")"
merged_blob="$(cd "$W/reader" && git rev-parse "HEAD:$frag" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$(cd "$W/reader" && git ls-files plan/index.d | wc -l | tr -d ' ')" = "1" ] && [ "$merged_blob" = "$pusher_blob" ]; then
    ok "ARM 2: relaying osx-next into linux-next after the push merges clean with one copy of the fragment, the pusher's blob"
else
    bad "ARM 2: relay merge rc=$rc, fragments on trunk: $(cd "$W/reader" && git ls-files plan/index.d | wc -l), blob $merged_blob vs $pusher_blob"
fi

# ── ARM 3: NEGATIVE CONTROL — an explicit non-plan path ────────────────────
tip3="$(remote_tip)"
out="$(helper README.md 2>/dev/null | tail -1)"
if [ "$out" = "refused:fragments-to-trunk:scope:README.md" ] && [ "$(remote_tip)" = "$tip3" ]; then
    ok "ARM 3 (negative control): an explicit non-plan path is refused by scope and trunk does not move"
else
    bad "ARM 3: '$out' (tip moved: $([ "$(remote_tip)" = "$tip3" ] && echo no || echo yes))"
fi

# ── ARM 4: NEGATIVE CONTROL — an event on a packet trunk has never seen ────
# Filing fragments are dated in the past so they fold BEFORE the clock-stamped
# set-field fragments on any day this fixture runs.
cat > plan/index.d/20200101t000100z-filing-fixture-osx.yaml <<'EOF'
packets:
  - packet_id: fixture-packet-two
    order: 2-bbbb
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: macos
    title: fixture packet two, filed on osx-next only
    unscoreable: "fixture packet; not scored"
EOF
G add plan/index.d >/dev/null; G commit -q -m "file(2-bbbb): on osx-next"
"$PLAN" --index "$W/wc/plan/index.yaml" set-field 2-bbbb status in_progress --host fixture-osx --reason "claimed on osx-next" >/dev/null 2>&1
frag2="$(ls -t plan/index.d/*.yaml | head -1)"
G add plan/index.d >/dev/null; G commit -q -m "claim(2-bbbb): fixture-osx"
tip4="$(remote_tip)"
out="$(helper "$frag2" 2>"$W/err4" | tail -1)"
case "$out" in
    refused:fragments-to-trunk:trunk-fold:*)
        if [ "$(remote_tip)" = "$tip4" ]; then
            ok "ARM 4 (negative control): the claim alone is refused — trunk's fold cannot use an event on a packet it has never seen — and trunk does not move"
        else
            bad "ARM 4: refused but trunk moved"
        fi ;;
    *) bad "ARM 4: '$out'"; sed 's/^/      /' "$W/err4" | tail -6 ;;
esac
out="$(helper 2>"$W/err4b" | tail -1)"
case "$out" in
    ok:fragments-on-trunk:*:2)
        rm -rf "$W/reader"; git clone -q -b linux-next "$W/bare.git" "$W/reader" 2>/dev/null
        fold="$("$PLAN" --index "$W/reader/plan/index.yaml" status 2-bbbb 2>/dev/null | head -1 | cut -f2)"
        chk="$(cd "$W/reader" && "$PLAN" check --strict-fragments 2>&1 | grep -v OpenSpec | tail -1)"
        if [ "$fold" = "in_progress" ] && [ "${chk#ok:}" != "$chk" ]; then
            ok "ARM 4: the default selection carries the filing with the claim; trunk reads 2-bbbb in_progress and its own check is green"
        else
            bad "ARM 4: after the default push fold='$fold' check='$chk'"
        fi ;;
    *) bad "ARM 4: default push '$out'"; sed 's/^/      /' "$W/err4b" | tail -6 ;;
esac
# TEETH: a mutant without the trunk-fold check pushes a dangling event. Built
# from CONTENT (the strip is proven to change the file), never from provenance.
cat > plan/index.d/20200101t000200z-filing3-fixture-osx.yaml <<'EOF'
packets:
  - packet_id: fixture-packet-three
    order: 3-cccc
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: macos
    title: fixture packet three, filed on osx-next only
    unscoreable: "fixture packet; not scored"
EOF
G add plan/index.d >/dev/null; G commit -q -m "file(3-cccc): on osx-next"
"$PLAN" --index "$W/wc/plan/index.yaml" set-field 3-cccc status in_progress --host fixture-osx --reason "claimed on osx-next" >/dev/null 2>&1
frag4="$(ls -t plan/index.d/*.yaml | head -1)"
G add plan/index.d >/dev/null; G commit -q -m "claim(3-cccc): fixture-osx"
sed '/^    _trunk_fold_check "\$base"$/d' scripts/push-plan-fragments-to-trunk.sh > "$W/mutant.sh"
if cmp -s "$W/mutant.sh" scripts/push-plan-fragments-to-trunk.sh; then
    bad "ARM 4 MUTANT SETUP: the strip is a no-op — the trunk-fold call line no longer matches"
else
    cp scripts/push-plan-fragments-to-trunk.sh "$W/helper.swap"
    cp "$W/mutant.sh" scripts/push-plan-fragments-to-trunk.sh
    out="$(helper "$frag4" 2>"$W/errm" | tail -1)"
    cp "$W/helper.swap" scripts/push-plan-fragments-to-trunk.sh
    case "$out" in
        ok:fragments-on-trunk:*)
            rm -rf "$W/reader"; git clone -q -b linux-next "$W/bare.git" "$W/reader" 2>/dev/null
            chk="$(cd "$W/reader" && "$PLAN" check --strict-fragments 2>&1 | grep -v OpenSpec | tail -1)"
            case "$chk" in
                refusing*|*incomplete*) ok "ARM 4 MUTANT: without the trunk-fold check the dangling claim lands and trunk's own check goes red ('${chk%% *}…') — the check has teeth" ;;
                *) bad "ARM 4 MUTANT: dangling claim landed but trunk's check reads '$chk'" ;;
            esac
            # Repair trunk for the arms below: push the filing the mutant left behind.
            helper >/dev/null 2>&1 || true ;;
        refused:fragments-to-trunk:trunk-fold:*) bad "ARM 4 MUTANT: still refused by trunk-fold with the check stripped — the mutant did not take" ;;
        *) bad "ARM 4 MUTANT: '$out'"; sed 's/^/      /' "$W/errm" | tail -6 ;;
    esac
fi

# ── ARM 5: default selection skips what cannot ride; nothing-new is a skip ─
mkdir -p plan/index.d/sub
printf 'junk\n' > plan/index.d/.DS_Store
printf 'packets: []\n' > plan/index.d/sub/nested.yaml
printf 'packets: []\n' > plan/index.d/wrong-extension.txt
tip5="$(remote_tip)"
out="$(helper 2>"$W/err5" | tail -1)"
if [ "$out" = "skip:fragments-to-trunk:nothing-new" ] && [ "$(remote_tip)" = "$tip5" ] \
   && [ "$(grep -c 'note: .* skipped' "$W/err5")" -ge 3 ]; then
    ok "ARM 5: a dotfile, a nested path and a wrong extension are skipped with notes by the default selection; nothing new -> skip; trunk does not move"
else
    bad "ARM 5: '$out' notes=$(grep -c 'skipped' "$W/err5") (tip moved: $([ "$(remote_tip)" = "$tip5" ] && echo no || echo yes))"
fi
out="$(helper plan/index.d/.DS_Store 2>/dev/null | tail -1)"
if [ "$out" = "refused:fragments-to-trunk:scope:plan/index.d/.DS_Store" ] && [ "$(remote_tip)" = "$tip5" ]; then
    ok "ARM 5: the same dotfile named EXPLICITLY is refused by scope"
else
    bad "ARM 5: explicit dotfile '$out'"
fi
rm -rf plan/index.d/sub plan/index.d/.DS_Store plan/index.d/wrong-extension.txt

# ── ARM 6: a changed copy of a fragment already on trunk ───────────────────
printf '# edited after landing\n' >> "$frag"
tip6="$(remote_tip)"
out="$(helper "$frag" 2>/dev/null | tail -1)"
G checkout -q -- "$frag"
if [ "$out" = "refused:fragments-to-trunk:exists:$frag" ] && [ "$(remote_tip)" = "$tip6" ]; then
    ok "ARM 6: a changed copy of a landed fragment is refused (immutable) and trunk does not move"
else
    bad "ARM 6: '$out'"
fi

# ── ARM 7: --dry-run on an UNTRACKED fragment; STAGED it rides the default ─
"$PLAN" --index "$W/wc/plan/index.yaml" set-field 1-aaaa status implemented --host fixture-osx --reason "implemented on osx-next, fragment not yet committed" >/dev/null 2>&1
frag7="$(git ls-files --others --exclude-standard -- plan/index.d | head -1)"
tip7="$(remote_tip)"
out="$(helper --dry-run 2>/dev/null | tail -1)"
case "$out" in
    ok:fragments-to-trunk:dry-run:*:1)
        if [ "$(remote_tip)" = "$tip7" ]; then ok "ARM 7: --dry-run builds and validates the untracked fragment and pushes nothing"; else bad "ARM 7: dry-run moved trunk"; fi ;;
    *) bad "ARM 7: dry-run '$out'" ;;
esac
G add -- "$frag7"    # staged, NOT committed: the third state (1101-b5rc's lesson)
out="$(helper 2>/dev/null | tail -1)"
case "$out" in
    ok:fragments-on-trunk:*:1)
        sha="${out#ok:fragments-on-trunk:}"; sha="${sha%:1}"
        if [ "$(git diff --name-status "$tip7" "$sha")" = "$(printf 'A\t%s' "$frag7")" ] && [ "$(git status --porcelain -- "$frag7" | cut -c1-2)" = "A " ]; then
            ok "ARM 7: the STAGED, uncommitted fragment reached trunk and is still staged and uncommitted here"
        else
            bad "ARM 7: pushed diff or local status wrong ($(git status --porcelain -- "$frag7"))"
        fi ;;
    *) bad "ARM 7: staged push '$out'" ;;
esac
G commit -q -m "record(1-aaaa): implemented" >/dev/null

# ── ARM 8: loop-status fragments ───────────────────────────────────────────
printf '## Cycle 2020-01-01T00:00:00Z — fixture-osx\n\nfixture cycle\n' > plan/loop_status.d/20200101t000000z-fixture-osx.md
tip8="$(remote_tip)"
out="$(helper 2>"$W/err8" | tail -1)"
case "$out" in
    ok:fragments-on-trunk:*:1)
        if grep -q 'plan-only lane: validated plan/loop_status.d/20200101t000000z-fixture-osx.md' "$W/err8"; then
            ok "ARM 8: a loop-status fragment rides the default selection and the hook validates it"
        else
            bad "ARM 8: loop-status fragment pushed but the hook did not name it"
        fi ;;
    *) bad "ARM 8: '$out'"; sed 's/^/      /' "$W/err8" | tail -6 ;;
esac
printf '## Cycle 2020-01-01T00:01:00Z — fixture-osx\n\n## Notes\n\nnot allowed\n' > plan/loop_status.d/20200101t000100z-bad-fixture-osx.md
tip8b="$(remote_tip)"
out="$(helper plan/loop_status.d/20200101t000100z-bad-fixture-osx.md 2>/dev/null | tail -1)"
out2="$(helper 2>"$W/err8b" | tail -1)"
if [ "$out" = "refused:fragments-to-trunk:loop-status:plan/loop_status.d/20200101t000100z-bad-fixture-osx.md" ] \
   && [ "$out2" = "skip:fragments-to-trunk:nothing-new" ] && grep -q 'loop-status grammar' "$W/err8b" && [ "$(remote_tip)" = "$tip8b" ]; then
    ok "ARM 8: a loop-status fragment with a second '## ' section is refused explicitly and skipped with a note by default; trunk does not move"
else
    bad "ARM 8: bad loop-status explicit='$out' default='$out2'"
fi
rm -f plan/loop_status.d/20200101t000100z-bad-fixture-osx.md
G add plan/loop_status.d >/dev/null; G commit -q -m "loop-status: fixture cycle" >/dev/null

# ── ARM 9: NEGATIVE CONTROL — the platform branch's own gate still refuses ─
otip="$(osx_tip)"
G push -q origin osx-next >"$W/err9" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(osx_tip)" = "$otip" ] && grep -q 'refused' "$W/err9"; then
    ok "ARM 9 (negative control): pushing osx-next itself, which carries the ungated code, is refused by the hook and origin/osx-next does not move"
else
    bad "ARM 9: rc=$rc osx tip moved: $([ "$(osx_tip)" = "$otip" ] && echo no || echo yes): $(grep -m1 -E 'refused|error' "$W/err9")"
fi

# ── ARM 10: a completion EVENT without its status fragment ─────────────────
printf 'closed on osx-next\n' > "$W/summary.txt"
"$PLAN" --index "$W/wc/plan/index.yaml" append-event 1-aaaa completed --summary-file "$W/summary.txt" --host fixture-osx --agent macos-fixture-osx-fixture-20200101t000000z >/dev/null 2>&1
frag10="$(git ls-files --others --exclude-standard -- plan/index.d | head -1)"
tip10="$(remote_tip)"
out="$(helper "$frag10" 2>"$W/err10" | tail -1)"
if [ "$out" = "refused:fragments-to-trunk:trunk-fold:status-loss:fixture-packet-one" ] && [ "$(remote_tip)" = "$tip10" ]; then
    ok "ARM 10: a completion event without the status fragment is refused as status-loss — trunk would offer a closed row as ready — and trunk does not move"
else
    bad "ARM 10: '$out'"; sed 's/^/      /' "$W/err10" | tail -6
fi
"$PLAN" --index "$W/wc/plan/index.yaml" set-field 1-aaaa status completed --host fixture-osx --evidence "fixture: 0000000 PASS: fixture" --reason "completed on osx-next" >/dev/null 2>&1
out="$(helper 2>"$W/err10b" | tail -1)"
case "$out" in
    ok:fragments-on-trunk:*:2)
        rm -rf "$W/reader"; git clone -q -b linux-next "$W/bare.git" "$W/reader" 2>/dev/null
        fold="$("$PLAN" --index "$W/reader/plan/index.yaml" status 1-aaaa 2>/dev/null | head -1 | cut -f2)"
        if [ "$fold" = "completed" ]; then
            ok "ARM 10: with the status fragment the default push lands both and trunk folds 1-aaaa completed"
        else
            bad "ARM 10: trunk folds '$fold' after the paired push"
        fi ;;
    *) bad "ARM 10: paired push '$out'"; sed 's/^/      /' "$W/err10b" | tail -6 ;;
esac
G add plan/index.d >/dev/null; G commit -q -m "close(1-aaaa): fixture-osx" >/dev/null

# ── ARM 11: the race is detected by STATE and the commit is rebuilt ────────
# Git hands the hook the remote's CURRENT tip; a trunk that moved after the
# helper's fetch makes the hook refuse ("remote base … not present locally")
# with no "[rejected]" line ever printed (the reviewer's measurement that
# replaced a wording regex). Reproduced with a fetch URL pointing at a stale
# MIRROR and the push URL at the real bare: the first attempt's hook refuses,
# a wrapper syncs the mirror (the world catching up), the helper's refetch sees
# the moved tip and rebuilds on it, the second attempt lands.
git clone -q --bare "$W/bare.git" "$W/mirror.git"
git remote set-url origin "$W/mirror.git"
git remote set-url --push origin "$W/bare.git"
pre_move_tip="$(remote_tip)"
# A FRESH reader: an older clone's push would be rejected as non-fast-forward
# and the "move" would silently not happen (the first run of this arm passed
# with parent == tip and no retry line for exactly that reason).
rm -rf "$W/reader"; git clone -q -b linux-next "$W/bare.git" "$W/reader" 2>/dev/null
( cd "$W/reader" && git config core.hooksPath .git/hooks && printf 'moved by another host\n' >> README.md \
  && G add README.md >/dev/null && G commit -q -m "another host lands on trunk" && git push -q origin linux-next ) >/dev/null 2>&1
moved_tip="$(remote_tip)"
if [ "$moved_tip" = "$pre_move_tip" ]; then
    bad "ARM 11 SETUP: trunk did not move — the race cannot be constructed"
fi
rm -f "$W/synced"
cat > .git/hooks/pre-push <<EOF
#!/bin/sh
if [ ! -f "$W/synced" ]; then
    touch "$W/synced"
    git -C "$W/mirror.git" fetch -q "$W/bare.git" '+refs/heads/*:refs/heads/*'
fi
exec bash scripts/hooks/pre-push-local-gate.sh "\$@"
EOF
chmod +x .git/hooks/pre-push
"$PLAN" --index "$W/wc/plan/index.yaml" set-field 2-bbbb status implemented --host fixture-osx --reason "implemented on osx-next" >/dev/null 2>&1
frag11="$(git ls-files --others --exclude-standard -- plan/index.d | head -1)"
out="$(helper 2>"$W/err11" | tail -1)"
case "$out" in
    ok:fragments-on-trunk:*:1)
        sha="${out#ok:fragments-on-trunk:}"; sha="${sha%:1}"
        if grep -q 'moved during attempt 1; rebuilding' "$W/err11" && [ "$(git rev-parse "$sha^")" = "$moved_tip" ] && [ "$(remote_tip)" = "$sha" ]; then
            ok "ARM 11: the first attempt was refused by the hook on the moved base, the refetch saw the move, and the rebuilt commit landed on the new tip"
        else
            bad "ARM 11: landed but not through the race path (parent $(git rev-parse "$sha^") vs moved $moved_tip; retry line: $(grep -c 'rebuilding' "$W/err11"))"
        fi ;;
    *) bad "ARM 11: '$out'"; sed 's/^/      /' "$W/err11" | tail -8 ;;
esac
git remote set-url origin "$W/bare.git"
git remote set-url --delete --push origin "$W/bare.git" 2>/dev/null || git remote set-url --push origin "$W/bare.git"
printf '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n' > .git/hooks/pre-push
G add plan/index.d >/dev/null; G commit -q -m "record(2-bbbb): implemented" >/dev/null

# ── ARM 11b: THE REAL LEDGER'S REGIME — the trunk fold this repository's ──
#     helper would build must pass check. The scratch ledgers above have no
#     plan/archive; the real one resolves live rows' depends_on edges INTO
#     archived packets, and a fold built without the archive reported 96 of
#     them unresolved and refused every relay from every host (macbookair,
#     2026-09-14). This arm materialises trunk's fold the way the helper
#     does, from origin/linux-next when the ref exists (else HEAD), and
#     requires check to pass — so the regime the first fixture lacked is
#     measured on every gate, not discovered by a host that happens to relay.
cd "$ROOT" || exit 2
_base_ref="$(git rev-parse --verify --quiet refs/remotes/origin/linux-next 2>/dev/null || git rev-parse HEAD)"
rm -rf "$W/realfold"; mkdir -p "$W/realfold/plan"
git show "$_base_ref:plan/index.yaml" > "$W/realfold/plan/index.yaml" 2>/dev/null
for d in plan/index.d plan/archive; do
    [ -n "$(git ls-tree -d "$_base_ref" "$d" 2>/dev/null)" ] && git archive "$_base_ref" "$d" | tar -x -f - -C "$W/realfold"
done
git cat-file -e "$_base_ref:plan/schema.yaml" 2>/dev/null && git show "$_base_ref:plan/schema.yaml" > "$W/realfold/plan/schema.yaml"
chk="$("$PLAN" --index "$W/realfold/plan/index.yaml" check --strict-fragments 2>&1 | grep -v OpenSpec | tail -1)"
case "$chk" in
    ok:*) ok "ARM 11b (real ledger): the trunk fold the helper builds from $(git rev-parse --short "$_base_ref") — index.yaml + index.d + archive — passes check ('${chk%% *}…')" ;;
    *)    bad "ARM 11b (real ledger): the trunk fold the helper builds fails check — every relay would be refused: $chk" ;;
esac
# Control: the same fold WITHOUT the archive must fail, or this arm proves
# nothing about the archive being load-bearing. Skipped (named) when this
# ledger has no archive or no edge into it.
if [ -d "$W/realfold/plan/archive" ]; then
    rm -rf "$W/realfold/plan/archive"
    chk2="$("$PLAN" --index "$W/realfold/plan/index.yaml" check --strict-fragments 2>&1 | grep -v OpenSpec | tail -1)"
    case "$chk2" in
        ok:*) echo "note: ARM 11b control: this ledger has no live edge into its archive, so the archive is not load-bearing here (the arm above still holds)" ;;
        *)    ok "ARM 11b control: the same fold without the archive fails check ('$(printf '%s' "$chk2" | cut -c1-60)…') — the archive is load-bearing and the helper must carry it" ;;
    esac
fi
cd "$W/wc" || exit 2

# ── ARM 12: usage ──────────────────────────────────────────────────────────
tip12="$(remote_tip)"
out="$(helper --bogus 2>/dev/null | tail -1)"; rc=$?
if [ "$rc" -eq 2 ] && [ "$out" = "refused:fragments-to-trunk:usage:--bogus" ] && [ "$(remote_tip)" = "$tip12" ]; then
    ok "ARM 12: an unknown flag is refused with exit 2 and pushes nothing"
else
    bad "ARM 12: rc=$rc '$out'"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: claims-fleet-visible $pass/$total (1153-j2nm)"
    exit 0
fi
echo "FAIL: claims-fleet-visible $pass/$total (1153-j2nm)"
exit 1
