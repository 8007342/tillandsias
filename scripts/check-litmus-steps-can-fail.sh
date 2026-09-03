#!/usr/bin/env bash
# @trace spec:litmus-framework, spec:methodology-accountability
# @trace order:972-cvdg
#
# ORDER 972-cvdg. Refuse a litmus step whose success and failure branches print
# the SAME token, because such a step passes whether the system works or not.
#
# THE DEFECT THIS EXISTS FOR, found by the tillandsias.org forge while writing
# the public explainer and confirmed line by line. Five steps in
# litmus-podman-idiomatic-security-flags.yaml — a `severity: critical` test of
# the container hardening envelope — were written as:
#
#     ... | grep -q 'keep-id' && echo 'USERNS_KEEP_ID_SET' || echo 'USERNS_KEEP_ID_SET'
#
# with `USERNS_KEEP_ID_SET` as the step's `expected_behavior`. The grep decides
# nothing: both branches emit the token the harness is looking for. The test
# reported PASS on every run for as long as it existed, and would have reported
# PASS with the hardening flags removed entirely.
#
# WHY A GUARD AND NOT A FIX. Fixing those five lines takes a minute; nothing
# stops the sixth being written tomorrow, and the failure is invisible by
# construction — a test that cannot fail looks exactly like a test that passes.
# No run, no log and no verdict distinguishes them, so a reviewer is the only
# control and reviewers were what missed these.
#
# THE SHAPE IS NARROW ON PURPOSE. `cmd && echo A || echo B` with DIFFERENT
# tokens is a legitimate and common idiom — it is how a step reports which of
# two states it found. Only identical tokens are refused, because only then is
# the branch a decoration. A guard that flagged the general idiom would be
# noise, and noise is how a guard stops being run.
#
# Verdict grammar, one line on stdout:
#   ok:litmus-steps-can-fail:<n> file(s) checked        exit 0
#   violation:litmus-steps-cannot-fail:<n> step(s)      exit 1
#   blocked:<reason>                                    exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

DIR="${TILLANDSIAS_LITMUS_DIR:-openspec/litmus-tests}"
[ -d "$DIR" ] || { echo "blocked:litmus-dir-missing:$DIR"; exit 2; }

violations=0
checked=0

# Normalise a branch's payload to the bare token it prints.
#
# ALL quote and backslash characters are deleted rather than one matching pair
# stripped, and the fixture is why: inside a YAML double-quoted command the two
# branches can legitimately be spelled `'SAME'` and `\"SAME\"`, which a
# pair-stripping version compared as different and let through. A guard that can
# be evaded by changing a quote style is a guard against typos, not against the
# defect.
#
# Only the FIRST word survives, so trailing shell (`; fi`, a closing quote, a
# redirect) cannot make two identical tokens compare unequal — that direction
# fails OPEN, which is the one failure this guard must not have.
branch_token() {
    printf '%s' "$1" \
        | tr -d '\\"'"'" \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]].*$//'
}

for f in "$DIR"/*.yaml; do
    [ -e "$f" ] || continue
    checked=$((checked + 1))
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        case "$line" in
            *'&& echo '*'|| echo '*) ;;
            *) continue ;;
        esac
        # The LAST `&& echo ... || echo ...` on the line is the one whose value
        # reaches stdout, and these commands routinely chain several.
        tail_expr="${line##*&& echo }"
        case "$tail_expr" in
            *'|| echo '*) ;;
            *) continue ;;
        esac
        ok_branch="${tail_expr%%'|| echo '*}"
        fail_branch="${tail_expr#*'|| echo '}"
        # Trim trailing shell noise and the YAML value's closing quote.
        ok_branch="$(branch_token "$ok_branch")"
        fail_branch="$(branch_token "$fail_branch")"
        [ -n "$ok_branch" ] || continue
        [ "$ok_branch" = "$fail_branch" ] || continue
        echo "  $f:$lineno" >&2
        echo "    both branches print '$ok_branch' — this step passes whether" >&2
        echo "    the check succeeded or failed. Give the failure branch a" >&2
        echo "    distinct token, or drop the fallback so the step exits non-zero." >&2
        violations=$((violations + 1))
    done < "$f"
done

if [ "$violations" -gt 0 ]; then
    echo "violation:litmus-steps-cannot-fail:$violations step(s)"
    exit 1
fi
echo "ok:litmus-steps-can-fail:$checked file(s) checked"
