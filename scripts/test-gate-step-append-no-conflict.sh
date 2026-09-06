#!/usr/bin/env bash
# @trace order:1072-b7eq
#
# test-gate-step-append-no-conflict.sh — pin the property 1072-b7eq exists for:
# two hosts adding a gate step must not conflict.
#
# WHY THIS AND NOT A SPELLING CHECK. The four conflicts on 2026-09-05 were
# CONTENT-FREE: both sides were additions and every resolution was "keep both in
# sequence". The cost was never the resolution. It was that resolving one is a
# CODE EDIT to build.sh, which sits outside the plan-only push lane, so a
# conflict that changed nothing anyone reviewed obliged a full ~25-minute
# re-gate on whichever host merged. One was committed with its markers still in
# it. So the property worth pinning is mergeability, and the control arm proves
# the old shape really did conflict — without it this suite would pass on a tree
# that had never been fixed.
#
# Hermetic: scratch git repos under a temp dir. Nothing touches this checkout,
# nothing runs the gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0; pass=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/gate-step-append.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# A scratch repo with a committed baseline, then two branches off it.
# core.autocrlf=false: on MSYS a rewritten line ending is a spurious diff, and
# this suite is about whether git can merge, not about newline policy.
new_repo() { # new_repo <dir> <seed-file> <seed-content>
    git init -q "$1"
    git -C "$1" config user.name  esmeraldinha
    git -C "$1" config user.email esmeraldinha@example.invalid
    git -C "$1" config core.autocrlf false
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add -A && git -C "$1" commit -q -m baseline
}

# ── 1. THE FIXED SHAPE: two hosts each add a .step FILE. Different paths, so
#      git merges them with no conflict and both steps survive.
R="$W/data"
new_repo "$R" "scripts/gate-steps.d/010-existing.step" 'STEP_SCRIPT="scripts/test-existing.sh"'
git -C "$R" checkout -q -b hostA
printf 'STEP_SCRIPT="scripts/test-a.sh"\n' > "$R/scripts/gate-steps.d/060-order-a.step"
git -C "$R" add -A && git -C "$R" commit -q -m "hostA adds a step"
git -C "$R" checkout -q master 2>/dev/null || git -C "$R" checkout -q main
git -C "$R" checkout -q -b hostB
printf 'STEP_SCRIPT="scripts/test-b.sh"\n' > "$R/scripts/gate-steps.d/070-order-b.step"
git -C "$R" add -A && git -C "$R" commit -q -m "hostB adds a step"
if git -C "$R" merge -q --no-edit hostA >/dev/null 2>&1; then
    a=$(ls "$R/scripts/gate-steps.d" | grep -c 'order-a'); b=$(ls "$R/scripts/gate-steps.d" | grep -c 'order-b')
    if [ "$a" = 1 ] && [ "$b" = 1 ]; then
        ok "two hosts adding .step files merge with no conflict and both steps survive"
    else
        bad "merge succeeded but a step was lost (a=$a b=$b)"
    fi
else
    bad "two .step files conflicted — the whole point of 1072-b7eq is that they cannot"
fi

# ── 2. CONTROL: the OLD shape really did conflict. Two hosts appending to the
#      same region of one file must fail to merge, or arm 1 proves nothing.
R2="$W/inline"
new_repo "$R2" "build.sh" '    _step "existing"
    _info "existing passed"'
git -C "$R2" checkout -q -b hostA
printf '    _step "existing"\n    _info "existing passed"\n    _step "hostA"\n    _info "hostA passed"\n' > "$R2/build.sh"
git -C "$R2" add -A && git -C "$R2" commit -q -m "hostA appends inline"
git -C "$R2" checkout -q master 2>/dev/null || git -C "$R2" checkout -q main
git -C "$R2" checkout -q -b hostB
printf '    _step "existing"\n    _info "existing passed"\n    _step "hostB"\n    _info "hostB passed"\n' > "$R2/build.sh"
git -C "$R2" add -A && git -C "$R2" commit -q -m "hostB appends inline"
if git -C "$R2" merge -q --no-edit hostA >/dev/null 2>&1; then
    bad "CONTROL: two inline appends merged cleanly — this suite cannot tell the shapes apart"
else
    git -C "$R2" merge --abort 2>/dev/null || true
    ok "CONTROL: two inline appends to one region DO conflict — arm 1 has teeth"
fi

# ── 3. THE CONSTRAINT (1063-nraf): every .step file names its script as a
#      LITERAL, greppable string, and the script exists. A binding assembled
#      from a variable is invisible to every name-based scan, including the
#      bound-or-retired guard — and thirty fixtures were already invoked by
#      nothing when that was measured.
missing=""; nonliteral=""
for f in "$ROOT"/scripts/gate-steps.d/*.step; do
    [ -e "$f" ] || continue
    line="$(grep -m1 '^STEP_SCRIPT=' "$f" || true)"
    case "$line" in
        *'$'*|*'`'*|'') nonliteral="$nonliteral ${f##*/}" ; continue ;;
    esac
    p="$(printf '%s' "$line" | sed 's/^STEP_SCRIPT="//; s/"$//')"
    [ -f "$ROOT/$p" ] || missing="$missing ${f##*/}:$p"
done
[ -z "$nonliteral" ] \
    && ok "every .step names its script as a literal string a grep can find" \
    || bad "a .step assembles its script path from a variable — invisible to name-based scans:$nonliteral"
[ -z "$missing" ] \
    && ok "every .step names a script that exists" \
    || bad "a .step names a script that does not exist:$missing"

# ── 4. THE LOOP REFUSES rather than skips. A step file naming a missing script
#      must stop the gate; silently skipping it is how a suite comes to report
#      PASS having run less than it was asked to (1049-s35z's shape).
if grep -q 'a step that cannot run must refuse, not skip' "$ROOT/build.sh"; then
    ok "the loop refuses a .step whose script is missing rather than skipping it"
else
    bad "build.sh no longer refuses a missing step script — the skip-is-a-green hazard is back"
fi

# ── 5. NO TWO .step FILES NAME THE SAME SCRIPT. This is the data-shaped form of
#      the fourth conflict macuahuitl resolved on 2026-09-05, and it is the one
#      worth pinning hardest: that conflict was not two hosts adding DIFFERENT
#      steps, it was two hosts adding the SAME step at different offsets, so the
#      correct resolution leaves exactly one copy and the obvious resolution
#      leaves two. In data form a duplicate is two well-formed files whose
#      STEP_SCRIPT matches — syntactically perfect, silently running the step
#      twice, and invisible to `bash -n` because there is no script to parse.
dupes="$(for f in "$ROOT"/scripts/gate-steps.d/*.step; do
             [ -e "$f" ] || continue
             grep -m1 '^STEP_SCRIPT=' "$f" | sed 's/^STEP_SCRIPT="//; s/"$//'
         done | sort | uniq -d)"
[ -z "$dupes" ] \
    && ok "no two .step files name the same script — a duplicated entry cannot hide" \
    || bad "two .step files name the same script, so the gate would run it twice:$(printf ' %s' $dupes)"

# ── 6. EVERY .step IS COMPLETE. A conflict resolved by truncation produces a
#      file that is still valid shell and still sources without error, but with
#      a field missing — the loop would then run with an empty description or an
#      empty error string. `bash -n` cannot see this either: the failure mode of
#      data is not a syntax error, it is a well-formed file that says less than
#      it should.
incomplete=""
for f in "$ROOT"/scripts/gate-steps.d/*.step; do
    [ -e "$f" ] || continue
    for k in STEP_DESC STEP_SCRIPT STEP_ERROR STEP_OK; do
        grep -q "^$k=\"..*\"$" "$f" || incomplete="$incomplete ${f##*/}:$k"
    done
done
[ -z "$incomplete" ] \
    && ok "every .step declares all four fields non-empty — a truncated resolution cannot pass" \
    || bad "a .step is missing or has an empty field:$incomplete"

# ── 7. NO TWO .step FILES SHARE A NUMERIC PREFIX. This is the blind spot the
#      migration itself created, and it was found the only way it can be: two
#      hosts picked 090 on the same day and nothing complained. 1072-b7eq made
#      file-level conflicts IMPOSSIBLE — two hosts adding steps touch two
#      different files and git merges them silently — so a collision that would
#      once have been a loud conflict in build.sh is now a silent ordering
#      decision, resolved by whatever the rest of the filename sorts as, which
#      neither author chose.
#
#      Nothing breaks when it happens: both files exist and both steps run. What
#      is lost is the property the ten-spacing exists for — that a later step can
#      land BETWEEN two without renaming either. A doubly-occupied 090 with 095
#      already taken leaves no gap at all, and the next author discovers that at
#      the moment they need it.
dupnum="$(for f in "$ROOT"/scripts/gate-steps.d/*.step; do
              [ -e "$f" ] || continue
              b="${f##*/}"; printf '%s\n' "${b%%-*}"
          done | sort | uniq -d)"
[ -z "$dupnum" ] \
    && ok "no two .step files share a numeric prefix — the ordering gap survives" \
    || bad "two .step files share a numeric prefix, so their order is decided by the rest of the filename and no gap remains between them:$(printf ' %s' $dupnum)"

echo "gate-step-append-no-conflict: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
