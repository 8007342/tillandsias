#!/usr/bin/env bash
# @trace order:1084-nzqc
# @trace order:1069-c9w6 (the live instance both escapes hid)
#
# REGIME: hermetic, in throwaway git repositories. Every arm builds a repo,
# commits a base, adds a shell file, and runs the guard against it through
# TILLANDSIAS_SIGPIPE_ROOT/TILLANDSIAS_SIGPIPE_BASE. Nothing here reads this
# checkout's diff, contacts a remote, or depends on what happens to be
# uncommitted while it runs — the guard is diff-scoped, so a fixture that let it
# see the real working tree would assert about whatever the author was editing.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE.
#
# THE TWO ESCAPES (1084-nzqc), each sufficient alone, and both present in the
# one live instance:
#   1. `/usr/bin/grep` — the producer anchor required a delimiter immediately
#      before the command, and in an absolute path that character is `/`.
#      validate-traces.sh calls /usr/bin/grep eight times, deliberately, so
#      macOS gets BSD grep regardless of Homebrew.
#   2. a pipeline split across `\` continuations — the guard was line-oriented,
#      so the verdict context sat on the first physical line and the
#      early-exiting consumer on the last, and no single line carried both.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-sigpipe-verdict-pipelines-added.sh"
[ -x "$GUARD" ] || { echo "could-not-run:sigpipe-guard:missing-guard"; exit 3; }

pass=0; fail=0
_rc=0

# THE FIXTURE MUST CONTAIN THE PATTERNS IT TESTS, AND THE GUARD SCANS THE DIFF,
# so writing them literally made this file refuse its own land: four REFUSED
# lines, every one a heredoc holding test data. That is the project's own
# "quoted history lives in comments; guards scan declarations" lesson arriving
# in a fixture instead of a class guard, and the established answer is the same
# one macneo used on 980-ja2m — ASSEMBLE THE NEEDLE AT RUNTIME so the literal
# never appears in the source. $P is the pipe character; the file written into
# each scratch repo carries the real pipeline, byte for byte.
#
# NOT `# sigpipe-ok:`. That marker would have silenced the land just as well and
# would have been a lie: these lines are not reviewed-and-bounded, they are
# deliberate violations, and one arm below exists precisely to test that the
# marker still exempts a folded line. Marking every arm would have made that arm
# assert nothing.
P='|'
# ONE backslash, and it matters: BS='\\' writes TWO, which is an escaped
# backslash rather than a line continuation — the arms would have exercised the
# fold against shell that does not continue at all, and passed while testing a
# shape nobody writes. Verified by cat -A on the generated file.
BS='\'

ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/sigpipe-guard.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

# _repo <<'EOS' ... EOS   — base commit, then the heredoc becomes the ADDED file
_repo() {
    local d; d="$(mktemp -d "$W/r.XXXXXX")"
    mkdir -p "$d/scripts"
    git -C "$d" init -q
    git -C "$d" config user.email t@example.invalid
    git -C "$d" config user.name t
    printf '#!/usr/bin/env bash\nset -euo pipefail\necho base\n' > "$d/scripts/subject.sh"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -qm base >/dev/null 2>&1
    git -C "$d" branch -f base-ref >/dev/null 2>&1
    cat > "$d/scripts/subject.sh"
    printf '%s' "$d"
}

# THE RC CROSSES BACK THROUGH A FILE, not through a variable. The first version
# set `_rc=$?` inside this function while the caller ran it as `out="$(_run …)"`
# — a COMMAND SUBSTITUTION, so the function executed in a subshell and its
# assignment died with it. The outer _rc stayed 0, every flagging arm reported
# "still escapes", and — far worse — every NEGATIVE CONTROL passed, because
# `[ "$_rc" -eq 0 ]` was trivially true. Four green arms asserting nothing.
_run() { # _run <repo> -> prints output; the rc lands in $W/rc
    TILLANDSIAS_SIGPIPE_ROOT="$1" TILLANDSIAS_SIGPIPE_BASE=base-ref bash "$GUARD" 2>&1
    printf '%s' "$?" > "$W/rc"
}
_rc_of() { cat "$W/rc" 2>/dev/null || echo 99; }

# ── 1. THE LIVE INSTANCE: absolute path AND continuation, together ──────────
#    This is the 1069-c9w6 shape, reproduced rather than reverted in place:
#    mutating a real instrument to test a guard would leave the tree one
#    interrupted fixture away from a broken validate-traces.sh.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
for spec_dir in "\$ROOT"/openspec/specs/*/; do
  spec_name="\$(basename "\$spec_dir")"
  if /usr/bin/grep -rl --include='*.rs' --include='*.sh' ${BS}
      "spec:\${spec_name}" ${BS}
      "\$ROOT/scripts" "\$ROOT/crates" 2>/dev/null ${BS}
      ${P} grep -q .; then
    :
  fi
done
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
if [ "$_rc" -ne 0 ] && case "$out" in *violation:sigpipe-verdict-added:*) true ;; *) false ;; esac; then
    ok "the 1069-c9w6 shape is flagged: /usr/bin/grep across continuations into grep -q"
else
    bad "the live instance still escapes (rc=$_rc): $(printf '%s' "$out" | tail -1)"
fi

# ── 2. ESCAPE 1 ALONE: an absolute path on ONE line ─────────────────────────
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
if /usr/bin/grep -rn foo . ${P} grep -q bar; then :; fi
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "an absolute-path producer on one line is flagged" \
                 || bad "an absolute-path producer escaped on a single line (rc=$_rc)"

# ── 3. ESCAPE 2 ALONE: a bare command across continuations ─────────────────
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
if find . -name '*.rs' ${BS}
     -print ${BS}
     ${P} head -1 ${P} grep -q x; then :; fi
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "a continued pipeline is flagged even with a bare command" \
                 || bad "a continued pipeline escaped (rc=$_rc)"

# ── 4. NEGATIVE CONTROL: a consumer that reads to EOF stays unflagged ──────
#    The row names this explicitly: the guard must not start flagging every
#    multi-line `if`. wc/sort/sha256sum consume everything, so SIGPIPE cannot
#    decide the verdict and there is nothing to refuse.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
if /usr/bin/grep -rn foo . ${BS}
     ${P} sort ${BS}
     ${P} wc -l; then :; fi
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "NC: a continued pipeline whose consumer reads to EOF is NOT flagged" \
                 || bad "NC: an EOF-reading consumer was flagged — the guard now refuses correct code: $(printf '%s' "$out" | tail -2)"

# ── 5. THIS CONTROL WAS RETIRED BY MEASUREMENT (order 1307-ermc) ──────────
#
# IT USED TO ASSERT THE OPPOSITE, and the change is deliberate, so the old
# assertion is recorded here rather than deleted. Until 1307-ermc this arm
# required that `v="some text"; if printf '%s' "$v" | grep -q text` be NOT
# flagged — a printf of a variable was not a producer, which was 792-ksr8's
# recorded decision on the grounds that the dominant idiom emits a SHA or a
# branch name and the race needs a large producer.
#
# WHAT OVERTURNED IT: 1306-ifhv, measured on yoga 2026-09-20. The flaking line
# was a printf of a variable holding a 15,569-byte captured transcript. Under a
# 64 KB pipe it fits one write and never flakes — forty replays clean — and
# under the 8 KB pipes a loaded host hands out once its open pipes pass
# /proc/sys/fs/pipe-user-pages-soft it flaked 2 in 20. "The benign shape is
# small" is a property of the VARIABLE, not of the shape, and the variable is
# not visible from the text.
#
# THE CONTRACT CHANGED WITH IT, and this arm is where that is written down: the
# guard now flags CORRECT CODE in the bounded case, on purpose, because it
# cannot tell the bounded case from the dangerous one. What makes that
# tolerable is measured, not assumed — the guard is diff-scoped, and over the 7
# days to 2026-09-20 exactly 9 added lines fleet-wide come into scope. Each one
# pays a `<<<` rewrite, which removes the hazard, or one `# sigpipe-ok:` line.
#
# (The provenance a narrower rule would need IS visible in this very case — `v`
# is assigned a literal two lines up. It was not implemented: it works here and
# fails for any variable assigned from a command substitution, which is every
# instance that has actually bitten this fleet, and a rule that is right about
# the safe cases and wrong about the dangerous ones is worse than a broad one.)
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
v="some text"
if printf '%s' "\$v" ${BS}
     ${P} grep -q text; then :; fi
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "5: a printf-of-a-variable producer IS now flagged even when a reader can see it is bounded — the breadth is chosen, and this arm is its record" \
                 || bad "5: the bounded case was NOT flagged, so the producer admission did not land (or was narrowed without updating this arm)"

# ── 5b. AND THE RELIEF VALVE FOR EXACTLY THAT CASE ────────────────────────
# Arm 5 only reads as a deliberate choice if the cost of the choice is one
# line. This is that line, on the same code.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
v="some text"
if printf '%s' "\$v" ${BS}
     ${P} grep -q text; then :; fi  # sigpipe-ok: v is a literal assigned above
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "5b: the same bounded line answers the guard with one \`# sigpipe-ok:\` — the breadth costs a line, not a rewrite" \
                 || bad "5b: the escape hatch does not clear the bounded case, so arm 5 is a refusal with no remedy"

# ── 6. NEGATIVE CONTROL: the escape hatch still works on a folded line ─────
#    A reviewed pipeline marks itself. If the marker were only honoured on
#    single lines, closing escape 2 would have quietly retired it.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
if /usr/bin/grep -rn foo . ${BS}
     ${P} grep -q bar; then :; fi   # sigpipe-ok: reviewed, producer is one file
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "NC: a sigpipe-ok marker on the last physical line still exempts the folded line" \
                 || bad "NC: the escape hatch stopped working once lines are folded (rc=$_rc)"

# ── 7. NEGATIVE CONTROL: an UNCHANGED file is never flagged ───────────────
#    The guard is diff-scoped and says so in its own refusal. Folding reads the
#    whole FILE, so this is the arm that proves the fold did not turn a
#    diff-scoped guard into a corpus scan.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
echo base
EOS
)"
printf '#!/usr/bin/env bash\nset -euo pipefail\nif /usr/bin/grep -rn foo . | grep -q bar; then :; fi\n' > "$d/scripts/preexisting.sh"
git -C "$d" add scripts/preexisting.sh >/dev/null 2>&1
git -C "$d" commit -qm preexisting >/dev/null 2>&1
git -C "$d" branch -f base-ref >/dev/null 2>&1
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "NC: a pre-existing violation in an unchanged file is NOT flagged (still diff-scoped)" \
                 || bad "NC: folding turned the guard into a corpus scan — it flagged an unchanged file: $(printf '%s' "$out" | tail -2)"

# ── 8. NEGATIVE CONTROL: an UNTOUCHED violation in a CHANGED file ─────────
#    Arm 7 proves the FILE-level scoping (an unchanged file is never opened).
#    This proves the LINE-level scoping, and it exists because a mutation that
#    deleted the line-level check left arm 7 green: the file in arm 7 is not in
#    the diff at all, so nothing inside the file loop could be exercised by it.
#    A negative control that cannot be reached by the code it guards asserts
#    nothing, and only the mutation said so.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -euo pipefail
if /usr/bin/grep -rn foo . ${P} grep -q bar; then :; fi
echo base
EOS
)"
git -C "$d" add -A >/dev/null 2>&1
git -C "$d" commit -qm "the violation is now PRE-EXISTING" >/dev/null 2>&1
git -C "$d" branch -f base-ref >/dev/null 2>&1
printf 'echo an unrelated added line\n' >> "$d/scripts/subject.sh"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "NC: an untouched violation in a CHANGED file is NOT flagged (line-level scoping)" \
                 || bad "NC: the guard flagged a pre-existing line because the file was touched: $(printf '%s' "$out" | tail -2)"

# ══ ORDER 1307-ermc — THE AND-OR SPELLING AND THE printf PRODUCER ══════════
#
# Two escapes from the same guard, and either one alone hid 1306-ifhv. They are
# tested together and apart, because "it flags the line" would pass with only
# one of the two admissions in place and the row would close on half a fix.
#
# THE NEEDLES ARE ASSEMBLED FROM $P AND $BS like every arm above, and the first
# version of these arms was not — which made check-no-spawn-in-if-not.sh refuse
# this file over ARM A3's `if !` line sitting in a heredoc as test data. The
# fixture's own header warns about exactly that, forty lines up, and I wrote the
# arms without reading it. The whole-repo checker scans TEXT and cannot tell a
# specimen from a use.

# ARM A1: the and-or spelling, on ONE physical line.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -uo pipefail
printf '%s' "\$out" ${P} grep -q 'pat' && ok "matched" ${P}${P} bad "absent"
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "A1: the and-or spelling is NAMED — a verdict is a verdict without a leading if" \
                 || bad "A1: the and-or spelling still escapes"

# ARM A2: the same defect across BACKSLASH CONTINUATIONS, which is how
# 1306-ifhv was actually written. A REGRESSION arm, not a new capability: the
# folding has existed since 1084-nzqc. It is here because the and-or test had to
# be taught to survive the fold, and an arm testing only the one-line form would
# not have noticed if it had not.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -uo pipefail
printf '%s' "\$out" ${P} grep -qi 'ANCESTRY IS NOT USED' ${BS}
    && ok "the disclaimer is present" ${BS}
    ${P}${P} bad "the disclaimer is gone"
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "A2: the 1306-ifhv line, in its real continued form, is NAMED" \
                 || bad "A2: the continued and-or form escapes — the fold and the new context test do not compose"

# ARM A3 (REGRESSION): the spelling this guard already caught still reds. A
# change that admits a new shape must not move the old one.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -uo pipefail
if ! git log --oneline ${P} grep -q 'pat'; then echo no; fi
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "A3 (regression): the if-not spelling is still named" \
                 || bad "A3: admitting the and-or spelling LOST the if-not one"

# ARM B: printf OF A VARIABLE is a producer of unknown size. A1 and A2 already
# use one, so this arm ISOLATES the producer admission from the context
# admission: a leading-if line, always a verdict context, whose only reason to
# be missed was the producer. If this reds while A1 passes, the row shipped the
# context half and not the producer half.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -uo pipefail
if printf '%s' "\$out" ${P} grep -q 'pat'; then echo yes; fi
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -ne 0 ] && ok "B: printf of a VARIABLE counts as a producer in a plain if-context — the producer half landed independently of the context half" \
                 || bad "B: a printf-of-a-variable producer is still invisible; 1306-ifhv would still escape"

# ARM C: the escape hatch covers the newly admitted shape. It is the only thing
# that keeps B's breadth tolerable.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -uo pipefail
printf '%s' "\$sha" ${P} grep -q 'pat' && ok "m" ${P}${P} bad "a"  # sigpipe-ok: one 40-char line
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "C: a sigpipe-ok marker still exempts the and-or spelling too" \
                 || bad "C: the escape hatch does not cover the newly admitted shape, so B has no relief valve"

# ARM C2 (NEGATIVE CONTROL): a pipeline whose status NOBODY READS is not a
# verdict and must not be flagged. Without this, "flag every printf into a
# grep -q" would pass every arm above — the always-answers-yes shape that makes
# a guard look strong and prove nothing.
d="$(_repo <<EOS
#!/usr/bin/env bash
set -uo pipefail
printf '%s' "\$out" ${P} grep -q 'pat'
echo unrelated
EOS
)"
out="$(_run "$d")"; _rc="$(_rc_of)"
[ "$_rc" -eq 0 ] && ok "C2 (negative control): a pipeline with no branch on its status is NOT flagged — the guard tests for a verdict, not for a pipe" \
                 || bad "C2: a statusless pipeline was flagged; the rule is 'any printf into grep -q', which will cry wolf on every new fixture"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: sigpipe guard sees paths and continuations $pass/$total (1084-nzqc)"
    exit 0
fi
echo "FAIL: sigpipe guard sees paths and continuations $pass/$total (1084-nzqc)"
exit 1
