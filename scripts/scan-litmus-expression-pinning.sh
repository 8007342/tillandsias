#!/usr/bin/env bash
# @trace spec:ci-release
#
# scan-litmus-expression-pinning.sh — rank litmus steps that pin an EXPRESSION
# rather than a PROPERTY.
#
# Packet 622-rmit, approved by The Tlatoani 2026-08-09.
#
# WHY. A guard should assert what must be TRUE, not how it is currently WRITTEN.
# Those agree until someone refactors, and then only the property is still
# right. On 2026-08-09 three steps went red in a single `--ci-full` run with no
# guarded property violated: two from order 619-vwau moving a `&` onto an
# enclosing subshell and writing through a local variable, one from 621-2re2
# moving a default into a `case`. Two had been red for a day and cost a cycle to
# prove pre-existing.
#
# That cost is the point. Push CI was removed 2026-08-03 (order 599-w5jd), so
# the local gate is the ONLY verification left. False reds train agents to treat
# reds as noise, which is how a sole remaining gate stops working.
#
# SCOPE. This RANKS candidates. It does not fix anything and it does not fail a
# build — enforcement is a separate, Tlatoani-gated rung
# (methodology/convergence.yaml -> bar_raise_governance). A high score is a
# smell, not a verdict: some steps legitimately assert that an exact string is
# present, and those are expected to score high and stay as they are.
#
# GRAMMAR. One line per candidate step on stdout, highest score first:
#   ^candidate\t<score>\t<test-name>\t<step-index>\t<signals>\t<step-title>$
# then exactly one summary line:
#   ^summary\tsteps=<n>\tcandidates=<n>\tfiles=<n>$
# Exit 0 whenever the scan completed, regardless of what it found.
#
# SIGNALS (each +1, joined by ','):
#   literal-grep   uses grep -F or a quoted fixed string match
#   no-exec        never runs a project binary/script; only greps/tests files
#   no-negative    the corpus has no negative-control step for this test
#   src-pinned     greps a source file (.sh/.rs/.ps1/.yml) rather than output
#   long-literal   the matched literal is >= 40 chars (brittle to any edit)

set -uo pipefail

LITMUS_DIR="${1:-openspec/litmus-tests}"

if [ ! -d "$LITMUS_DIR" ]; then
    echo "summary	steps=0	candidates=0	files=0"
    exit 0
fi

total_steps=0
total_candidates=0
total_files=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "$LITMUS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    total_files=$((total_files + 1))

    test_name="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
    [ -n "$test_name" ] || test_name="$(basename "$f" .yaml)"

    # Does this test carry ANY negative control? Checked per FILE, because a
    # negative control anywhere in the test means the author thought about the
    # failure direction at all.
    has_negative=0
    if grep -qiE 'negative control|NEG-|negative_control|must FAIL|really is present' "$f"; then
        has_negative=1
    fi

    step_idx=0
    # Read step titles and their commands as pairs. Steps are `- step: "..."`
    # followed within a few lines by `command: "..."`.
    while IFS= read -r line; do
        case "$line" in
            *'- step:'*)
                step_idx=$((step_idx + 1))
                current_step="${line#*- step:}"
                current_step="$(printf '%s' "$current_step" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
                total_steps=$((total_steps + 1))
                ;;
            *'command:'*)
                [ "$step_idx" -gt 0 ] || continue
                cmd="${line#*command:}"

                score=0
                signals=""

                # literal-grep: grep -F, or grep -q with no regex metacharacters.
                if printf '%s' "$cmd" | grep -qE 'grep [^|]*-[A-Za-z]*F'; then
                    score=$((score + 1)); signals="${signals},literal-grep"
                fi

                # no-exec: the command never invokes anything from the project.
                if ! printf '%s' "$cmd" | grep -qE '(scripts/[a-z0-9-]+\.sh|\./build\.sh|target/release/|cargo |tillandsias-[a-z]+ |bash -c)'; then
                    score=$((score + 1)); signals="${signals},no-exec"
                fi

                # no-negative: whole test lacks a negative control.
                if [ "$has_negative" -eq 0 ]; then
                    score=$((score + 1)); signals="${signals},no-negative"
                fi

                # src-pinned: greps a source file rather than produced output.
                if printf '%s' "$cmd" | grep -qE '\.(sh|rs|ps1|yml|yaml|toml)([^a-z]|$)'; then
                    score=$((score + 1)); signals="${signals},src-pinned"
                fi

                # long-literal: any quoted literal >= 40 chars.
                if printf '%s' "$cmd" | grep -qE "'[^']{40,}'"; then
                    score=$((score + 1)); signals="${signals},long-literal"
                fi

                # A candidate needs literal-grep AND src-pinned: it must be
                # matching fixed text against source. Everything else only
                # ranks. Without both, a high score is just a simple check.
                case "$signals" in
                    *literal-grep*)
                        case "$signals" in
                            *src-pinned*)
                                signals="${signals#,}"
                                printf '%s\t%s\t%s\t%s\t%s\n' \
                                    "$score" "$test_name" "$step_idx" "$signals" "$current_step" >> "$tmp"
                                total_candidates=$((total_candidates + 1))
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done < "$f"
done

# Highest score first, then test name, then step index — deterministic.
if [ -s "$tmp" ]; then
    sort -t"$(printf '\t')" -k1,1nr -k2,2 -k3,3n "$tmp" \
        | while IFS=$'\t' read -r score name idx sig title; do
            printf 'candidate\t%s\t%s\t%s\t%s\t%s\n' "$score" "$name" "$idx" "$sig" "$title"
        done
fi

printf 'summary\tsteps=%s\tcandidates=%s\tfiles=%s\n' "$total_steps" "$total_candidates" "$total_files"
