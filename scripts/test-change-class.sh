#!/usr/bin/env bash
# @trace order:765-xpct, spec:ci-release
#
# THE FOUR FAIL-CLOSED PATHS ARE THE POINT OF THIS FIXTURE, and each gets a
# NEGATIVE test: unknown path -> FULL, unresolvable base ref -> FULL,
# build-tooling class -> FULL, last FULL run stale (or never) -> refuse to skip.
#
# AND EACH HAS A CONTROL, because "always answers FULL" passes every one of them
# and is useless. An arm that cannot distinguish the selector working from the
# selector being broken-shut is not evidence — it is the shape that let ARM 8b
# of test-land-queue.sh pass against a defect earlier tonight.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0; skipped=0
ok()      { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
skiparm() { printf 'skip: %s\n' "$1"; skipped=$((skipped + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# scaffold <name> — a repo with a trunk, the two real scripts copied in, and a
# FULL-gate marker that is fresh. Fresh by default so an arm that means to test
# staleness has to SAY so; a fixture whose default state is already failing
# cannot tell you which arm failed it.
scaffold() {
    local name="$1"
    W="$TMP/$name"
    mkdir -p "$W/scripts"
    cp "$ROOT/scripts/gate-stamp.sh" "$ROOT/scripts/change-class.sh" "$W/scripts/"
    git init -q "$W"
    git -C "$W" config user.email t@l; git -C "$W" config user.name t
    git -C "$W" config commit.gpgsign false
    echo base > "$W/base.txt"
    git -C "$W" add -A && git -C "$W" commit -q -m base
    git -C "$W" branch -M linux-next
    # A local "remote" ref so the default base resolves without a network.
    git -C "$W" update-ref refs/remotes/origin/linux-next "$(git -C "$W" rev-parse HEAD)"
    MARKER="$W/.git/tillandsias-last-full-gate"
    date -u +%s > "$MARKER"
}

# tier — the selector's verdict in the scaffold, with its evidence line.
tier() {
    ( cd "$W" && env TILLANDSIAS_FULL_GATE_MARKER="$MARKER" \
        bash -c '. scripts/change-class.sh; change_class_tier' 2>"$TMP/why" )
}
why() { cat "$TMP/why" 2>/dev/null; }

# ─────────────────────────────────────────────────── ARM 1 + CONTROL
# ONLY plan/ AND docs/ -> LIGHT. This is the control for everything below: if
# it does not pass, every FULL verdict in this file is uninformative.
scaffold light
mkdir -p "$W/plan/index.d" "$W/docs"
echo "packets: []" > "$W/plan/index.d/x.yaml"
echo "# note" > "$W/docs/a.md"
t1="$(tier)"
if [ "$t1" = "LIGHT" ]; then
    ok "ARM 1 (control): a change touching only plan/ and docs/ is LIGHT — the cheap tiers are reachable, so the FULL verdicts below mean something"
else
    bad "ARM 1 (control): wanted LIGHT, got '$t1' — every other arm in this file is now uninformative. why: $(why)"
fi

# ─────────────────────────────────────────────────── ARM 2 + CONTROL
# scripts/ AND openspec/ -> SCOPED, and adding one crates/ path makes it FULL.
scaffold scoped
mkdir -p "$W/scripts" "$W/openspec"
echo "echo hi" > "$W/scripts/helper.sh"
echo "spec: x" > "$W/openspec/a.yaml"
t2="$(tier)"
if [ "$t2" = "SCOPED" ]; then
    ok "ARM 2 (control): scripts/ plus openspec/ is SCOPED"
else
    bad "ARM 2 (control): wanted SCOPED, got '$t2'. why: $(why)"
fi
mkdir -p "$W/crates/x/src"
echo "fn main() {}" > "$W/crates/x/src/main.rs"
t2b="$(tier)"
if [ "$t2b" = "FULL" ]; then
    ok "ARM 2b: ONE crates/ path drags the same change from SCOPED to FULL — the tier is the union, not the majority"
else
    bad "ARM 2b: wanted FULL once crates/ was touched, got '$t2b'. why: $(why)"
fi

# ─────────────────────────────────────────────────── ARM 3
# AN UNKNOWN PATH -> FULL. Not because unknown paths are dangerous, but because
# an unclassified path is an unanswered question, and this selector must never
# treat an unanswered question as an absent constraint.
scaffold unknown
echo "whatever" > "$W/some-unclassified-thing"
t3="$(tier)"
if [ "$t3" = "FULL" ]; then
    ok "ARM 3: a path matching no class arm is FULL — 'other' by construction, never admitted to a cheap tier"
else
    bad "ARM 3: an unclassified path yielded '$t3'. why: $(why)"
fi

# ─────────────────────────────────────────────────── ARM 4
# AN UNRESOLVABLE BASE REF -> FULL, and the reason SAYS so.
scaffold nobase
t4="$( ( cd "$W" && env TILLANDSIAS_FULL_GATE_MARKER="$MARKER" \
    bash -c '. scripts/change-class.sh; change_class_tier refs/heads/no-such-base-765' 2>"$TMP/why" ) )"
case "$(why)" in
    *"could not be resolved"*)
        if [ "$t4" = "FULL" ]; then
            ok "ARM 4: an unresolvable base ref is FULL and the evidence line names it as unresolved, not as an empty diff"
        else
            bad "ARM 4: named the unresolved ref but answered '$t4'"
        fi ;;
    *) bad "ARM 4: an unresolvable base ref gave '$t4' with reason: $(why)" ;;
esac

# ─────────────────────────────────────────────────── ARM 5
# THE GATE'S OWN DECIDERS -> FULL even though build-scripts is a SCOPED class.
# A selector cannot judge a change to itself using itself.
# One case per GROUP pirria's composition measured, not one per file: the
# groups take different glob arms and a single representative would leave two
# arms untested. `ci` is checked too — it is a class the tiers never name, and
# the allow-list direction is supposed to put it in FULL silently.
for self in build.sh scripts/run-litmus-test.sh scripts/change-class.sh \
            scripts/gate-steps.d/999-probe.step scripts/check-probe-765.sh \
            scripts/hooks/probe-765.sh scripts/test-support/fake-765.sh \
            openspec/litmus-bindings.yaml; do
    scaffold "self-$(printf '%s' "$self" | tr '/.' '--')"
    mkdir -p "$W/$(dirname "$self")"
    echo "# touched" >> "$W/$self"
    t5="$(tier)"
    if [ "$t5" = "FULL" ]; then
        ok "ARM 5: editing $self is FULL, although build-scripts is otherwise a SCOPED class"
    else
        bad "ARM 5: editing $self gave '$t5' — the gate would be chosen by the file being changed. why: $(why)"
    fi
done

# ─────────────────────────────────────────────────── ARM 5b
# A `ci` PATH IS FULL THOUGH NO TIER NAMES IT. pirria's review noted that the
# classifier's vocabulary has nine classes and these tiers name seven; `ci` is
# unmentioned. Under allow-lists that means FULL, silently and correctly — and
# this arm is what makes "silently" auditable, because a reader checking the
# tiers against the vocabulary will otherwise wonder if it was forgotten.
scaffold ci-class
mkdir -p "$W/.github/workflows"
echo "on: push" > "$W/.github/workflows/x.yml"
t5b="$(tier)"
if [ "$t5b" = "FULL" ]; then
    ok "ARM 5b: a .github/ path is FULL although no tier names the 'ci' class — the allow-list direction handles an unnamed class without anyone having remembered it"
else
    bad "ARM 5b: a ci-class path gave '$t5b' — an unnamed class reached a cheap tier. why: $(why)"
fi

# ─────────────────────────────────────────────────── ARM 6
# A STALE LAST-FULL RUN REFUSES TO SKIP. The change itself qualifies LIGHT; only
# the age differs from ARM 1, which is what makes this arm about the bound and
# not about the classes.
scaffold stale
mkdir -p "$W/plan/index.d"
echo "packets: []" > "$W/plan/index.d/x.yaml"
printf '%s\n' "$(( $(date -u +%s) - 90000 ))" > "$MARKER"   # 25h ago
t6="$(tier)"
case "$(why)" in
    *"over the"*"bound"*)
        if [ "$t6" = "FULL" ]; then
            ok "ARM 6: a LIGHT-qualifying change is FULL when the last FULL gate is 25h old — a branch cannot ride cheap tiers indefinitely"
        else
            bad "ARM 6: named the bound but answered '$t6'"
        fi ;;
    *) bad "ARM 6: a 25h-old full run gave '$t6' with reason: $(why)" ;;
esac

# ARM 6b: THE SAME TREE, ONLY THE AGE CHANGED, IS LIGHT AGAIN. Without this the
# arm above would pass against a selector that had simply stopped emitting LIGHT.
date -u +%s > "$MARKER"
t6b="$(tier)"
if [ "$t6b" = "LIGHT" ]; then
    ok "ARM 6b (control): the identical tree with a FRESH full run is LIGHT — arm 6 is measuring the age and nothing else"
else
    bad "ARM 6b (control): with a fresh marker the same tree gave '$t6b', so arm 6 proved nothing. why: $(why)"
fi

# ─────────────────────────────────────────────────── ARM 7
# NEVER having had a FULL run is not the same as having had one long ago, and
# both refuse. An absent producer must not read as a favourable number.
scaffold never
mkdir -p "$W/plan/index.d"
echo "packets: []" > "$W/plan/index.d/x.yaml"
rm -f "$MARKER"
t7="$(tier)"
case "$(why)" in
    *last-full=never*)
        if [ "$t7" = "FULL" ]; then
            ok "ARM 7: with NO full gate ever recorded the answer is FULL, reported as never rather than as an age of zero"
        else
            bad "ARM 7: named 'never' but answered '$t7'"
        fi ;;
    *) bad "ARM 7: a missing marker gave '$t7' with reason: $(why)" ;;
esac

# A MALFORMED marker is the same question one step in: it must not parse as 0.
scaffold garbage
mkdir -p "$W/plan/index.d"
echo "packets: []" > "$W/plan/index.d/x.yaml"
echo "not-a-timestamp" > "$MARKER"
t7b="$(tier)"
case "$(why)" in
    *last-full=never*) ok "ARM 7b: a MALFORMED marker reads as never, not as epoch 0 (which would be maximally stale) and not as 0 seconds ago (which would be maximally fresh)" ;;
    *) bad "ARM 7b: a garbage marker gave '$t7b' with reason: $(why)" ;;
esac

# ─────────────────────────────────────────────────── ARM 8
# AN UNTRACKED FILE COUNTS. A gate runs over the WORKTREE, so a new .rs that
# nobody has added yet is invisible to every committed-only view and compiles
# all the same.
scaffold untracked
mkdir -p "$W/plan/index.d"
echo "packets: []" > "$W/plan/index.d/x.yaml"
t8_before="$(tier)"
mkdir -p "$W/crates/y/src"
echo "fn main() {}" > "$W/crates/y/src/main.rs"   # never git-added
t8="$(tier)"
if [ "$t8_before" = "LIGHT" ] && [ "$t8" = "FULL" ]; then
    ok "ARM 8: an UNTRACKED crates/ file moves the tier from LIGHT to FULL — the gate covers the worktree, so the selector must too"
else
    bad "ARM 8: before=$t8_before after=$t8 with an untracked .rs present. why: $(why)"
fi

# ─────────────────────────────────────────────────── ARM 9
# THE EVIDENCE LINE CARRIES WHAT A REVIEWER NEEDS: the base SHA, the classes and
# the age of the last full run. A tier printed without its reason is a verdict
# nobody can check, and this row exists because a green that does not say what it
# skipped is read as full coverage.
scaffold evidence
mkdir -p "$W/plan/index.d"
echo "packets: []" > "$W/plan/index.d/x.yaml"
tier >/dev/null
w9="$(why)"
miss=""
case "$w9" in *base=*)       ;; *) miss="$miss base" ;; esac
case "$w9" in *classes=*)    ;; *) miss="$miss classes" ;; esac
case "$w9" in *last-full=*)  ;; *) miss="$miss last-full" ;; esac
if [ -z "$miss" ]; then
    ok "ARM 9: the evidence line carries base, classes and last-full age — a reviewer can check the verdict without re-deriving it"
else
    bad "ARM 9: the evidence line is missing:$miss — got: $w9"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
        printf 'ok:change-class:%d/%d (%d skipped)\n' "$pass" "$((pass + fail))" "$skipped"
    else
        printf 'ok:change-class:%d/%d\n' "$pass" "$((pass + fail))"
    fi
    exit 0
fi
printf 'blocked:change-class:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1
