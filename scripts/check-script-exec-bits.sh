#!/usr/bin/env bash
# @trace order:731-d89b, spec:ci-release
#
# check-script-exec-bits.sh — refuse a script that callers RUN by path but git
# tracks as non-executable.
#
# THE DEFECT THIS CLOSES. scripts/resolve-release-run.sh was committed from the
# Windows host at mode 100644. The release runbook invokes it directly —
# `run_id="$(scripts/resolve-release-run.sh "${new_tag}")"` — which on Linux is
# a permission error, not a verdict. The irony is exact: that script exists to
# stop a release step from mistaking absence for health, and it would itself
# have failed in a way the caller reads as output. Nothing would have caught it
# until the next release ran; it surfaced only because a new litmus asserted
# `test -x`. The osx host landed two more mode flips in the same window, so the
# class is live across all three platforms.
#
# WHAT IS *NOT* A DEFECT, and why the rule is narrow. Most scripts here are
# invoked as `bash scripts/x.sh`, which works at any mode, and several
# (common.sh, help*.sh) are SOURCED libraries that should not be executable at
# all. A blanket "shebang implies +x" rule would flag 27 files, nearly all of
# them correct. The property that actually breaks is narrower: **someone runs
# this path without naming an interpreter.**
#
# So callers are read from places that EXECUTE — shell scripts, build.sh, skill
# runbooks, and litmus `command:` lines — never from prose. plan/index.yaml
# mentions script paths constantly in event summaries; treating those as callers
# would make this checker a random-noise generator.
#
# GRAMMAR (exactly one line on stdout)
#   ok:script-exec-bits:<n> checked
#   violation:script-not-executable:<n>
#
# Exit 0 when every bare-invoked script is mode 100755.
#
# Pinned by litmus:script-exec-bit-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Files that EXECUTE things. Prose is deliberately excluded — see above.
# `.github/workflows/*.yml` joined the set with order 770-dyqr: CI runs scripts
# by path too, and a bare invocation there fails in a lane no local gate walks.
# (`.claude/skills/*` needs no entry — those paths are symlinks, mode 120000,
# pointing at the `skills/*/SKILL.md` already covered here.)
caller_files="$(git ls-files 'scripts/*.sh' 'build.sh' 'skills/*/SKILL.md' 'openspec/litmus-tests/*.yaml' '.github/workflows/*.yml' 2>/dev/null)"
if [ -z "$caller_files" ]; then
    echo "ok:script-exec-bits:0 checked"
    echo "  note: no caller files found (not a git checkout?)" >&2
    exit 0
fi

violations=0

# ── Candidates: tracked 100644, with a shebang ───────────────────────────────
# The shebang test was `head -c2 "$path" | grep -q '#!'` — two processes for
# each of 260 tracked files. Bash reads the first line without spawning.
candidates=()
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    mode="${entry%% *}"
    path="${entry##*$'\t'}"
    [ "$mode" = "100644" ] || continue
    [ -f "$path" ] || continue
    IFS= read -r first_line < "$path" 2>/dev/null || continue
    case "$first_line" in '#!'*) ;; *) continue ;; esac
    candidates+=("$path")
done <<EOF
$(git ls-files -s scripts/ 2>/dev/null)
EOF
checked="${#candidates[@]}"

# ── One sweep, one filter pass (order 758-jw6v) ──────────────────────────────
# Was: `xargs grep` over all 612 caller files ONCE PER CANDIDATE (about sixteen
# thousand file-greps), then a four-process filter chain per candidate. 16.3s
# standalone, 30s inside ./build.sh --check, which a cycle runs three or four
# times. The filtering lives in scripts/lib/exec-bits-filter.awk — a FILE,
# because two inline attempts were broken by shell quoting rather than by
# logic, once by an apostrophe inside an awk comment.
_eb_awk="$REPO_ROOT/scripts/lib/exec-bits-filter.awk"
# REFUSE rather than report zero. Splitting the filter into a second file gave
# this checker a dependency it did not have before, and a missing dependency
# that yields "no violations found" is indistinguishable from a clean tree —
# the exact failure this whole milestone is about. 752-8hqx was the same shape:
# the push-lane hook gained a dependency on plan-binary-probe.sh and its
# fixture, which did not copy it, read the resulting fail-closed path as a lane
# defect. Absent evidence is not evidence of absence.
if [ ! -f "$_eb_awk" ]; then
    echo "violation:script-not-executable:0"
    echo "  REFUSED: $_eb_awk is missing — this checker cannot run and will not" >&2
    echo "  report a clean tree it never examined." >&2
    exit 2
fi

if [ "${#candidates[@]}" -gt 0 ]; then
    _eb_tmp="$(mktemp -d)" || exit 2
    trap 'rm -rf "$_eb_tmp"' EXIT
    printf '%s\n' "${candidates[@]}" > "$_eb_tmp/cands"

    # The sweep pattern is the union over all candidates. Its per-candidate
    # precision does not matter here — the awk pass re-tests each hit against
    # each candidate — so this only has to be a superset.
    alt="$(printf '%s|' "${candidates[@]}")"; alt="${alt%|}"
    printf '%s\n' "$caller_files" \
        | xargs -r grep -nHE "((^|[;&|(])[[:space:]]*\"?(${alt}))|(\\\$\\([[:space:]]*\"?(${alt}))|(command:[[:space:]]*\"?(${alt}))" \
            > "$_eb_tmp/hits" 2>/dev/null

    while IFS=$'\t' read -r path hit; do
        [ -n "$path" ] || continue
        violations=$((violations + 1))
        {
            echo "REFUSED: $path is invoked by path but tracked as mode 100644 —"
            echo "         on a POSIX host that invocation is a permission error, not a verdict."
            echo "         Fix: git update-index --chmod=+x $path"
            printf '   caller: %s\n' "$(printf '%s' "$hit" | cut -c1-140)"
        } >&2
    done < <(awk -f "$REPO_ROOT/scripts/lib/exec-bits-filter.awk" \
                 "$_eb_tmp/cands" "$_eb_tmp/hits")
fi

if [ "$violations" -gt 0 ]; then
    echo "violation:script-not-executable:$violations"
    exit 1
fi
echo "ok:script-exec-bits:$checked checked"
exit 0
