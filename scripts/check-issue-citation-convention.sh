#!/usr/bin/env bash
# @trace spec:meta-orchestration
# =============================================================================
# check-issue-citation-convention.sh — order 881-29me.
#
# A `plan/issues/` audit cites its evidence, and NOTHING checked that those
# citations still resolve. They rot silently while the document keeps reading as
# verified.
#
# MEASURED on yoga 2026-08-25 at linux-next 23671a86e, in
# plan/issues/network-architecture-audit-2026-07-09.md: every factual claim in
# its CONTAINER network matrix re-verified TRUE, and every `file:line` citation
# supporting them pointed at unrelated code. `main.rs:1136-1145`, cited for
# ENCLAVE_ONLY_NET, was a `format_age_secs` branch; the const had moved to
# ~1597. Five more the same way. The drift was TOTAL, not an offset —
# `main.rs` has passed 22,000 lines — which is the dangerous shape: a reader
# following one lands in plausible-looking NEIGHBOURING code and can "verify" a
# claim against something unrelated. A confidently wrong citation is worse than
# an absent one.
#
# WHY THIS IS A CONVENTION RATCHET AND NOT A RESOLVER. The packet's obvious
# gate — check the cited file has at least that many lines — would have PASSED
# every one of those six drifted citations, because the files are enormous and
# the line numbers are all in range. Relating a span to the prose claim it
# supports needs semantics no shell script has. So this takes the packet's
# second branch: SYMBOL citations (`main.rs` `build_git_run_args`) instead of
# line citations. A symbol survives every edit that does not rename it, and a
# rename is a real event worth noticing; a line number dies to any insertion
# above it. Order 797-8dzt reached the same conclusion for test source slices.
#
# DIFF-SCOPED, because 1,282 line citations already exist across 487 files and
# a fleet-wide refusal would flip every host red at once (the 699-dycj lesson).
# Only NEWLY ADDED lines are judged, against a base ref — the same shape as
# check-added-fragments-parse.sh. Existing citations burn down as documents are
# revised, which is exactly when someone is in a position to re-verify them.
#
# THE ESCAPE HATCH IS DELIBERATE AND NARROW. A line ending in
# `<!-- cite-ok: <reason> -->` is allowed, because a line number is sometimes
# the point: quoting a citation that has DRIFTED, as evidence, is how order 245
# recorded this very finding. The reason is mandatory — an unexplained opt-out
# is how a ratchet becomes decoration.
#
# Verdict grammar, one line on stdout:
#   ok:issue-citation-convention:<n> checked          exit 0
#   violation:issue-citation-line-numbers:<n>         exit 1
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

ISSUE_DIR="${TILLANDSIAS_ISSUE_CITATION_DIR:-plan/issues}"
base_ref="${TILLANDSIAS_ISSUE_CITATION_BASE:-origin/linux-next}"

# Source-ish extensions only. A citation into another markdown document is
# prose-to-prose and is left alone; the rot this gate exists for is prose
# citing CODE, which moves under it.
EXT_RE='(rs|sh|toml|conf|py|js|ts|c|h|cpp|go)'
CITE_RE="[A-Za-z0-9_./-]+\.${EXT_RE}:[0-9]+"

# Order 889-twhe: when a HEAD ref is named, the REF decides what exists, not the
# worktree — and ISSUE_DIR may legitimately be a single file pathspec, so the
# caller can scope a verdict to one document. The worktree existence test below
# is therefore skipped in that mode; without a HEAD ref it is unchanged, and an
# absent directory is still a clean zero rather than an error.
if [ -z "${TILLANDSIAS_ISSUE_CITATION_HEAD:-}" ] && [ ! -e "$ISSUE_DIR" ]; then
    echo "ok:issue-citation-convention:0 checked"
    exit 0
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    # An unavailable base is an UNKNOWN, not a pass, and says so on stderr —
    # but it must not fail the gate on a fresh clone with no remote ref.
    echo "ok:issue-citation-convention:0 checked"
    echo "  note: base ref '$base_ref' unavailable — added-citation enforcement skipped" >&2
    exit 0
fi

# Added lines only (`+` in the unified diff, excluding the +++ header), across
# tracked changes and wholly-untracked new documents alike.
# Order 889-twhe: an optional HEAD ref, so a caller can judge the bytes a PUSH
# will deliver rather than the bytes in the worktree. The pre-push plan-only
# lane needs exactly that — it vouches for what the remote receives, and the
# worktree can differ from the pushed commit (a rebase mid-cycle, a later edit).
# Unset, the behaviour is the pre-889 one: diff the base against the worktree
# and also read wholly-untracked new documents. SET, the untracked scan is
# skipped deliberately: a ref has no untracked files, and reading the worktree's
# would judge bytes that are not in the push.
head_ref="${TILLANDSIAS_ISSUE_CITATION_HEAD:-}"
if [ -n "$head_ref" ] && ! git rev-parse --verify "$head_ref" >/dev/null 2>&1; then
    # Fail CLOSED here, unlike the base-ref case above. An unavailable base is
    # a fresh-clone unknown; an unavailable HEAD was named explicitly by a
    # caller that believes it is validating something, and silently checking
    # nothing would hand it a pass it did not earn.
    echo "  error: head ref '$head_ref' unavailable — refusing to report a pass" >&2
    echo "violation:issue-citation-head-unavailable:1"
    exit 1
fi

added_lines() {
    if [ -n "$head_ref" ]; then
        git diff --unified=0 "$base_ref" "$head_ref" -- "$ISSUE_DIR" 2>/dev/null \
            | grep -E '^\+' | grep -Ev '^\+\+\+' | sed 's/^+//'
        return
    fi
    git diff --unified=0 "$base_ref" -- "$ISSUE_DIR" 2>/dev/null \
        | grep -E '^\+' | grep -Ev '^\+\+\+' | sed 's/^+//'
    # A brand-new document is usually untracked at the moment it is written.
    git ls-files --others --exclude-standard -- "$ISSUE_DIR" 2>/dev/null \
        | while IFS= read -r f; do [ -f "$f" ] && cat "$f"; done
}

violations=0
checked=0
while IFS= read -r line; do
    case "$line" in
        *'<!-- cite-ok:'*) continue ;;   # explicit, reasoned opt-out
    esac
    hits="$(printf '%s\n' "$line" | grep -oE "$CITE_RE" || true)"
    [ -z "$hits" ] && continue
    checked=$((checked + 1))
    violations=$((violations + 1))
    printf '%s\n' "$hits" | while IFS= read -r h; do
        echo "  new line-number citation: $h" >&2
    done
done <<EOF
$(added_lines)
EOF

if [ "$violations" -ne 0 ]; then
    echo "  Cite CODE by SYMBOL, not by line: \`main.rs\` \`build_git_run_args\`." >&2
    echo "  A symbol survives every edit that does not rename it; a line number does not." >&2
    echo "  Measured: 6 of 6 citations in one audit pointed at unrelated code (order 881-29me)." >&2
    echo "  If the line number IS the point (quoting a drifted citation as evidence)," >&2
    echo "  end the line with: <!-- cite-ok: why this needs a line number -->" >&2
    echo "violation:issue-citation-line-numbers:${violations}"
    exit 1
fi

echo "ok:issue-citation-convention:${checked} checked"
exit 0
