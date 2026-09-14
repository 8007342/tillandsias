#!/usr/bin/env bash
# @trace order:1177-k4jq
# @trace order:872-c9nd (the salvage exemption this points at)
# @trace order:1146-8j7i (the clean-but-stranded case that makes it usable here)
#
# REGIME: source text plus one real invocation of the salvage script's
# already-safe path. No arm pushes anything, creates a remote ref, or invokes
# the pre-push hook against origin — a fixture that pushed to prove a push works
# would be doing the thing it is testing, on the fleet's trunk.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE.
#
# WHY THIS FILE IS NOT NAMED scripts/test-work-ref-accepts-ungated-tree.sh, the
# name 1177-k4jq reserved: that name describes the design the row was FILED with
# — admitting an ungated tree onto a work/ ref — and lenovinha's reduction
# replaced it. The work/ lane is the GATED hand-off by design and salvage/ is
# the ungated one, so nothing in this change makes a work/ ref accept an ungated
# tree, and a fixture promising that in its filename would be a false claim in
# the tree. The deviation is flagged on the row rather than hidden behind the
# reserved name.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

HOOK="scripts/hooks/pre-push-local-gate.sh"
SALVAGE="scripts/salvage-dirty-worktree.sh"
SKILL="skills/meta-orchestration/SKILL.md"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

for f in "$HOOK" "$SALVAGE"; do
    [ -f "$f" ] || { echo "could-not-run:refusal-names-ungated-lane:missing:$f"; exit 3; }
done

# The refusal body: from `refuse() {` to its closing brace. Scoped, so a mention
# anywhere else in this 900-line hook cannot be credited to the refusal a user
# actually reads.
# WHAT THE USER ACTUALLY READS, which is the `echo` lines and nothing else.
# The first version of this arm took the whole function body, and two mutations
# that DELETED the echoes still passed 8/8 — because the comment block above them
# explains the remedy and names the same command. A file that documents itself
# contains every string it emits, so a matcher over the body is matching the
# prose about the fix rather than the fix. Scan declarations, not substrings.
_refusal="$(awk '/^refuse\(\) \{/{inb=1} inb&&/^[[:space:]]*echo /{print} inb&&/^\}$/{exit}' "$HOOK")"
if [ -z "$_refusal" ]; then
    echo "could-not-run:refusal-names-ungated-lane:no-refuse-function"
    exit 3
fi

# ── 1. the refusal NAMES the sanctioned lane, by command ────────────────────
case "$_refusal" in
    *"salvage-dirty-worktree.sh"*)
        ok "the refusal names the ungated hand-off by the command that performs it" ;;
    *)
        bad "the refusal never names salvage-dirty-worktree.sh — a host that cannot gate is still offered only --no-verify" ;;
esac

# ── 2. it says which lane is which, so the reader cannot pick the wrong one ──
_has_work=0; _has_gated=0
case "$_refusal" in *"work/"*) _has_work=1 ;; esac
case "$_refusal" in *GATED*|*"demands the stamp"*) _has_gated=1 ;; esac
if [ "$_has_work" = 1 ] && [ "$_has_gated" = 1 ]; then
    ok "the refusal distinguishes the GATED work/ lane from the ungated salvage one"
else
    bad "the refusal points at salvage without saying that work/ is the gated lane — the reader can still take the closed route (work:$_has_work gated:$_has_gated)"
fi

# ── 3. NEGATIVE CONTROL 1: this is a POINTER, not a new bypass ──────────────
#    The refusal must not have acquired a way to skip the stamp for a platform
#    branch or main. The salvage exemption is section 0's and predates this.
if printf '%s\n' "$_refusal" | /usr/bin/grep -qE 'exit 0|TILLANDSIAS_.*SKIP|--no-verify.*exec|return 0'; then
    bad "the refusal function now contains an exit-0 or skip path — a refusal that can pass is not a refusal"
else
    ok "NC1: the refusal still only refuses; it gained a sentence, not an escape"
fi
_exempt="$(/usr/bin/grep -c 'refs/heads/salvage/' "$HOOK")"
if [ "$_exempt" -ge 1 ]; then
    ok "NC1: the salvage exemption is still scoped to refs/heads/salvage/ (872-c9nd), not widened"
else
    bad "the salvage exemption's ref scoping is gone — the exemption may no longer be narrow"
fi

# ── 4. NEGATIVE CONTROL 2: --no-verify is still LAST, not the remedy ────────
#    The row asks that --no-verify remain unnecessary on this path. It stays
#    mentioned because the hook's own header says a bypassable hook is
#    deliberate — but it must not be the first thing a stuck host reads.
_nv_line="$(printf '%s\n' "$_refusal" | /usr/bin/grep -n 'no-verify' | head -1 | cut -d: -f1)"
_sv_line="$(printf '%s\n' "$_refusal" | /usr/bin/grep -n 'salvage-dirty-worktree.sh' | head -1 | cut -d: -f1)"
if [ -n "$_nv_line" ] && [ -n "$_sv_line" ] && [ "$_sv_line" -lt "$_nv_line" ]; then
    ok "NC2: the sanctioned lane is offered BEFORE --no-verify, so the forbidden route is not the first remedy"
elif [ -z "$_nv_line" ]; then
    ok "NC2: --no-verify is not offered at all"
else
    bad "NC2: --no-verify still appears before the sanctioned lane (no-verify:$_nv_line salvage:$_sv_line)"
fi

# ── 5. THE REMEDY MUST ACTUALLY EXIST for the state that reaches it ─────────
#    A refusal naming a command that cannot help the reader is worse than one
#    naming nothing: it costs a cycle to discover. The state here is CLEAN and
#    COMMITTED (the host gated, was killed or staled, and cannot re-gate), which
#    is 1146-8j7i's case, not the dirty-worktree one the script is named for.
if /usr/bin/grep -q '1146-8j7i' "$SALVAGE"; then
    ok "the salvage script covers the clean-but-stranded commit (1146-8j7i), which is the state that reaches this refusal"
else
    bad "the salvage script has no clean-tree path — the refusal would send a stuck host to a script that answers ok:salvage-not-needed"
fi
_sv_out="$(bash "$SALVAGE" --help 2>&1 || true)"
case "$_sv_out" in
    *salvage*|*slug*) ok "the named command is runnable and self-describing" ;;
    *) bad "the named command did not respond to --help: $(printf '%s' "$_sv_out" | head -1)" ;;
esac

# ── 6. the doc and the refusal agree on which lane is which ────────────────
#    Two sources that disagree about the same rule is how a host ends up taking
#    the closed route with a citation for it.
if [ -f "$SKILL" ] && /usr/bin/grep -q '1177-k4jq' "$SKILL"; then
    ok "the meta-orchestration skill carries the same rule, so the refusal is not the only place it lives"
else
    bad "the skill does not carry the rule — a reader outside the refusal has nothing to find"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: the refusal names the ungated lane $pass/$total (1177-k4jq)"
    exit 0
fi
echo "FAIL: the refusal names the ungated lane $pass/$total (1177-k4jq)"
exit 1
