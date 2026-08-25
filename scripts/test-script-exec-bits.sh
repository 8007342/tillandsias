#!/usr/bin/env bash
# @trace order:731-d89b, spec:ci-release
set -uo pipefail

# Fixture for scripts/check-script-exec-bits.sh.
#
# This ABSORBS the four-scenario fixture order 731-d89b wrote here. A rewrite
# under 758-jw6v replaced the file wholesale instead of extending it, which
# broke litmus:script-exec-bit-shape step 2 (it matches the pinned
# "PASS: script-exec-bits fixture" line) and would have dropped the original
# scenario names from the record. Coverage was never lost -- all four are
# below under clearer names -- but the pinned grammar was, and a fixture that
# silently stops satisfying its own litmus is the failure this repo keeps
# filing.
#
# WHY IT EXISTS NOW (order 758-jw6v). The checker was rewritten for speed —
# 16.3s to 1.3s, by replacing 26 sweeps over 612 caller files with one sweep,
# and a four-process filter chain per candidate with one awk pass. Its output on
# the real tree was byte-identical before and after, which proves almost
# nothing: the tree has ZERO violations, so both versions were agreeing on an
# empty answer. An optimisation verified only against a passing tree is
# verified against the one case that cannot detect a broken checker.
#
# So the contract is exercised in both directions, in a THROWAWAY repo. An
# earlier attempt built these cases in the real checkout with `git add -N` plus
# `git update-index --chmod`, which mutates shared index state and produced a
# misleading comparison; do not do that.
#
# THE CONTRACT (from the checker's own header):
#   * a tracked-100644 script with a shebang, invoked BY PATH, is REFUSED
#   * the same script invoked as `bash <path>` is not a defect
#   * the same script SOURCED is not a defect
#   * a script with no shebang is not a candidate at all
#   * a 100755 script invoked by path is fine

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-script-exec-bits.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/script-exec-bits-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=()

# scenario <name> <expected-rc> <expected-stdout-substring> <caller-body> [mode] [caller-path]
#
# caller-path (order 770-dyqr) defaults to scripts/caller.sh. A `.yaml`/`.yml`
# caller is written VERBATIM — no shebang — because the surfaces that broke were
# a litmus `command:` line and a CI workflow, not a shell script.
scenario() {
    local name="$1" want_rc="$2" want="$3" caller_body="$4" mode="${5:-100644}"
    local caller_path="${6:-scripts/caller.sh}"
    local repo="$work/$name"
    rm -rf "$repo"; mkdir -p "$repo/scripts" "$repo/$(dirname "$caller_path")"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email f@example.invalid
    git -C "$repo" config user.name fixture
    cp "$CHECK" "$repo/scripts/check-script-exec-bits.sh"
    # The checker gained a helper file (758-jw6v). A fixture that copies the
    # script but not its dependency exercises the missing-dependency path and
    # calls it a pass — which is how 752-8hqx wasted a diagnosis.
    mkdir -p "$repo/scripts/lib"
    cp "$ROOT/scripts/lib/exec-bits-filter.awk" "$repo/scripts/lib/"
    printf '#!/usr/bin/env bash\necho target\n' > "$repo/scripts/target.sh"
    case "$caller_path" in
        *.yaml|*.yml) printf '%s\n' "$caller_body" > "$repo/$caller_path" ;;
        *)            printf '#!/usr/bin/env bash\n%s\n' "$caller_body" > "$repo/$caller_path" ;;
    esac
    git -C "$repo" add -A >/dev/null 2>&1
    # The mode is the whole point of the check, so set it explicitly rather
    # than relying on whatever the filesystem reported.
    #
    # ORDER 887-bz88 — MATERIALIZE THE MODE ON DISK TOO, not just in the index.
    # `update-index --chmod` alone leaves the worktree file at whatever printf
    # created (644), so `executable-bare-ok` used to build a tree whose index
    # said 100755 while the file on disk was not executable. Real git never
    # produces that: checking out a 100755 entry materializes an executable
    # file. The checker now reads BOTH views (a worktree-only regression is the
    # pre-staging shape that let the 2026-08-25 credential-guard regression
    # through), so it correctly condemned the fixture's impossible tree — the
    # scenario was asserting on a state that cannot occur.
    if [ "$mode" = "100644" ]; then
        git -C "$repo" update-index --chmod=-x scripts/target.sh
        chmod -x "$repo/scripts/target.sh"
    else
        git -C "$repo" update-index --chmod=+x scripts/target.sh
        chmod +x "$repo/scripts/target.sh"
    fi

    local rc=0 out
    out="$(cd "$repo" && bash scripts/check-script-exec-bits.sh 2>/dev/null)" || rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$want"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name: want rc=$want_rc matching [$want], got rc=$rc [$out]"
        failures+=("$name")
    fi
}

# 1. THE DEFECT ITSELF. Without this passing, the checker is decoration.
scenario "bare-invocation-refused" 1 "violation:script-not-executable:1" \
    'scripts/target.sh'

# 2-3. NOT defects: naming an interpreter works at any mode, and a sourced
# library should not be executable at all.
scenario "interpreter-prefixed-ok" 0 "ok:script-exec-bits:" \
    'bash scripts/target.sh'
scenario "sourced-ok" 0 "ok:script-exec-bits:" \
    '. scripts/target.sh'

# 4. Already executable: nothing to fix.
scenario "executable-bare-ok" 0 "ok:script-exec-bits:" \
    'scripts/target.sh' 100755

# 5. A bare invocation inside a command substitution is still an invocation —
# this is the shape that produced the original defect
# (`run_id="$(scripts/resolve-release-run.sh ...)"`).
scenario "command-substitution-refused" 1 "violation:script-not-executable:1" \
    'x="$(scripts/target.sh)"; echo "$x"'

# 6. Piped/chained position counts too.
scenario "after-pipe-refused" 1 "violation:script-not-executable:1" \
    'echo hi | scripts/target.sh'

# 8-10. ORDER 770-dyqr. The caller surfaces that are not shell.
#
# THE LIVE BREACH: on 2026-08-16 two scripts reached linux-next at mode 100644
# from the windows lane and litmus:release-artifact-integrity STEP 5 died with
# rc=126 Permission denied -- while THIS guard printed `ok:script-exec-bits:26
# checked` and the gate went green. The litmus corpus was already in the caller
# set; what was missing is that a step's path is preceded by `: "`, and the
# invocation patterns only accepted start-of-line or one of `;&|(`. So the
# breach form was unreachable, and scenario 8 is the regression that proves it
# is reachable now. Scenario 9 is the control that keeps the rule narrow: the
# overwhelming majority of litmus steps name an interpreter and must stay
# silent, or this checker becomes noise inside 400+ litmus files.
scenario "litmus-command-bare-refused" 1 "violation:script-not-executable:1" \
    '    command: "scripts/target.sh 2>&1 | tail -1"' 100644 \
    "openspec/litmus-tests/litmus-demo.yaml"
scenario "litmus-command-interpreter-ok" 0 "ok:script-exec-bits:" \
    '    command: "bash scripts/target.sh 2>&1"' 100644 \
    "openspec/litmus-tests/litmus-demo.yaml"
scenario "workflow-bare-refused" 1 "violation:script-not-executable:1" \
    '          scripts/target.sh --verify' 100644 \
    ".github/workflows/release.yml"

# ORDER 754-kptj. Two more lead-ins that the 770-dyqr pattern could not reach,
# both live in this corpus:
#   litmus-clickable-trace-index-observatorium-skeleton.yaml:23 carries BOTH at
#     once — `OBSERVATORIUM_BROWSER=none ... ./scripts/run-observatorium.sh`
#   litmus-image-build-convergence-shape.yaml:16 carries the env prefix alone
# Both scripts are 100755 today, so the widening flags nothing new on this tree;
# what it buys is that a future mode regression on either is caught instead of
# becoming an rc=126 at runtime.
scenario "litmus-command-dotslash-refused" 1 "violation:script-not-executable:1" \
    '    command: "./scripts/target.sh"' 100644 \
    "openspec/litmus-tests/litmus-demo.yaml"
scenario "litmus-command-envprefix-refused" 1 "violation:script-not-executable:1" \
    '    command: "LITMUS_PODMAN_MODE=fake ./scripts/target.sh proxy"' 100644 \
    "openspec/litmus-tests/litmus-demo.yaml"
# NARROWNESS CONTROL: `bash ./scripts/x.sh` must stay silent at any mode, so the
# ./ widening cannot turn the majority of litmus steps — which name an
# interpreter — into noise.
#
# HONEST NOTE ON WHAT THIS DOES AND DOES NOT PROVE, because the first draft of
# this comment claimed more than the scenario delivers. It pins the OUTCOME
# (silence), not the mechanism. It does NOT discriminate the interpreter
# exclusion: with `bash ` between the lead-in and the path, none of the three
# positive patterns match at all, so the exclusion is never reached and this
# scenario passes whether or not that line carries the ./ prefix — measured,
# both ways. It is kept because the outcome is worth pinning: if a future
# widening ever makes the interpreter form match positively, this goes red.
scenario "litmus-command-dotslash-interpreter-ok" 0 "ok:script-exec-bits:" \
    '    command: "bash ./scripts/target.sh"' 100644 \
    "openspec/litmus-tests/litmus-demo.yaml"

# 7. The checker must REFUSE when its filter helper is absent, not report a
# clean tree it never examined. Without this the perf split could regress into
# a checker that always passes.
repo="$work/missing-helper"
rm -rf "$repo"; mkdir -p "$repo/scripts"
git -C "$repo" init -q -b main
git -C "$repo" config user.email f@example.invalid
git -C "$repo" config user.name fixture
cp "$CHECK" "$repo/scripts/check-script-exec-bits.sh"
printf '#!/usr/bin/env bash
echo target
' > "$repo/scripts/target.sh"
printf '#!/usr/bin/env bash
scripts/target.sh
' > "$repo/scripts/caller.sh"
git -C "$repo" add -A >/dev/null 2>&1
git -C "$repo" update-index --chmod=-x scripts/target.sh
rc=0
out="$(cd "$repo" && bash scripts/check-script-exec-bits.sh 2>/dev/null)" || rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "violation:script-not-executable:0"; then
    echo "PASS  missing-helper-refuses"
else
    echo "FAIL  missing-helper-refuses: want rc=2 with a violation line, got rc=$rc [$out]"
    failures+=("missing-helper-refuses")
fi

# ── portable-xargs (order 851-gpb5) ──────────────────────────────────────────
# `xargs -r` is GNU findutils syntax; the first macOS host hit it during fleet
# onboarding. The empty-input case -r guards against is unreachable in the
# checker ($caller_files is verified non-empty before the sweep), so the flag
# was dropped rather than emulated. Pinned so it cannot come back: re-adding
# -r turns this line red on every host.
if grep -q 'xargs -r' "$CHECK"; then
    echo "FAIL  portable-xargs: GNU-only 'xargs -r' reappeared in the checker"
    failures+=("portable-xargs")
else
    echo "PASS  portable-xargs"
fi

if [ "${#failures[@]}" -gt 0 ]; then
    echo "FAIL: ${#failures[@]} scenario(s): ${failures[*]}"
    exit 1
fi
# The pinned line litmus:script-exec-bit-shape step 2 matches. It predates this
# file being rewritten and must survive: order 731-d89b wrote the original
# four-scenario fixture, and a later edit here replaced it wholesale, silently
# breaking that step. All four of the original scenarios are still covered,
# under clearer names:
#   bare-invocation-non-executable      -> bare-invocation-refused
#   bare-invocation-executable          -> executable-bare-ok
#   interpreter-prefixed-non-executable -> interpreter-prefixed-ok
#   sourced-library-non-executable      -> sourced-ok
echo "PASS: script-exec-bits fixture 14/14 scenarios green (bare-invocation-refused, interpreter-prefixed-ok, sourced-ok, executable-bare-ok, command-substitution-refused, after-pipe-refused, missing-helper-refuses, litmus-command-bare-refused, litmus-command-interpreter-ok, workflow-bare-refused, portable-xargs, litmus-command-dotslash-refused, litmus-command-envprefix-refused, litmus-command-dotslash-interpreter-ok)"
echo "ok:script-exec-bits-fixture:14"
exit 0
