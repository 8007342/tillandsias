#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-gate-stamp-names-content-movers.sh — falsify `gate-stamp.sh movers`.
#
# Order 970-7fqk.
#
# REGIME: fully hermetic. Every arm builds a throwaway git repo under a temp
# dir, copies gate-stamp.sh into it, and stamps THERE with
# GATE_STAMP_REQUIRE_TOKEN=0. It never writes a stamp into the real .git — an
# unearned stamp in the live checkout could let an ungated tree reach trunk,
# which is the one thing 940-f77j exists to prevent, and a fixture that creates
# that condition to test a diagnostic would be trading a guarantee for a test.
#
# NO ABSOLUTE TIMESTAMP APPEARS HERE. Arm 2 needs an OLD mtime and sets one
# RELATIVE to the stamp file (`touch -r` then `touch -d '-1 hour'`), because the
# property under test is "content moved while mtime did not" — a property of the
# pair, not of any clock reading.
#
# THE TWO ARMS THAT MATTER ARE 2 AND 3, and they are opposites:
#   2. content changed, mtime OLD  -> movers NAMES it; the mtime signal cannot.
#   3. bytes identical, mtime NEW  -> movers is SILENT; the mtime signal names it.
# Either alone is satisfiable by a guard that always answers the same way.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GS="$ROOT/scripts/gate-stamp.sh"
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
[ -f "$GS" ] || { echo "FAIL: $GS absent"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-stamp-movers-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

_mkrepo() {
    local r="$1"; mkdir -p "$r/scripts"
    cp "$GS" "$r/scripts/gate-stamp.sh"
    ( cd "$r" && git init -q . && git config user.email t@e && git config user.name t \
      && printf 'alpha\n' > a.txt && printf 'beta\n' > b.txt \
      && git add -A && git commit -qm base ) >/dev/null 2>&1
}
_stamp() { ( cd "$1" && GATE_STAMP_REQUIRE_TOKEN=0 bash scripts/gate-stamp.sh write ) >/dev/null 2>&1; }
_movers(){ ( cd "$1" && bash scripts/gate-stamp.sh movers 2>/dev/null ); }

echo "ARM 1: a stamp write emits a manifest, and movers is SILENT on an unchanged tree"
R="$TMP/r1"; _mkrepo "$R"; _stamp "$R"
if [ -s "$R/.git/tillandsias-gate-stamp-manifest" ]; then
    out="$(_movers "$R")"
    [ -z "$out" ] && ok "manifest written; unchanged tree reports no movers" \
                  || bad "unchanged tree reported movers: [$out]"
else
    bad "no manifest was written by the stamp"
fi

echo "ARM 2: CONTENT changed with an OLD mtime is NAMED (the mtime signal cannot see it)"
R="$TMP/r2"; _mkrepo "$R"; _stamp "$R"
printf 'alpha-CHANGED\n' > "$R/a.txt"
# Make the edit look older than the stamp: the defect is that mtime and content
# answer different questions, so the arm must drive them apart deliberately.
touch -r "$R/.git/tillandsias-gate-stamp" "$R/a.txt"
touch -d '-1 hour' "$R/a.txt" 2>/dev/null || touch -t 200001010000 "$R/a.txt"
_mtime_sees="$( [ "$R/a.txt" -nt "$R/.git/tillandsias-gate-stamp" ] && echo yes || echo no )"
out="$(_movers "$R")"
if printf '%s' "$out" | /usr/bin/grep -q "^modified	a.txt$"; then
    ok "movers names a.txt as modified (mtime signal would have said: $_mtime_sees)"
    [ "$_mtime_sees" = "no" ] && ok "and the mtime signal indeed could NOT see it — the arms are not measuring the same thing" \
                              || bad "the mtime signal also saw it; this arm did not separate the two questions"
else
    bad "movers did not name a.txt as modified: [$out]"
fi

echo "ARM 3: an IDENTICAL rewrite with a NEW mtime is NOT named as a content mover"
R="$TMP/r3"; _mkrepo "$R"; _stamp "$R"
_bytes="$(cat "$R/a.txt")"; printf '%s\n' "$_bytes" > "$R/a.txt"; touch "$R/a.txt"
_mtime_sees="$( [ "$R/a.txt" -nt "$R/.git/tillandsias-gate-stamp" ] && echo yes || echo no )"
out="$(_movers "$R")"
if [ -z "$out" ]; then
    ok "identical rewrite reports NO content mover (mtime signal would have said: $_mtime_sees)"
    [ "$_mtime_sees" = "yes" ] && ok "and the mtime signal DID name it — the innocent-file case is reproduced" \
                               || echo "  note: mtime did not move here either, so this arm did not exercise the contrast"
else
    bad "an identical rewrite was reported as a content mover: [$out]"
fi

echo "ARM 4: an ADDED and a DELETED path are both named"
R="$TMP/r4"; _mkrepo "$R"; _stamp "$R"
printf 'new\n' > "$R/c.txt"; rm -f "$R/b.txt"
out="$(_movers "$R")"
printf '%s' "$out" | /usr/bin/grep -q "^added	c.txt$"   && ok "an added path is named" \
    || bad "added path not named: [$out]"
printf '%s' "$out" | /usr/bin/grep -q "^deleted	b.txt$" && ok "a deleted path is named" \
    || bad "deleted path not named: [$out]"

echo "ARM 5: NO MANIFEST must refuse, never report a clean tree"
R="$TMP/r5"; _mkrepo "$R"; _stamp "$R"
rm -f "$R/.git/tillandsias-gate-stamp-manifest"
printf 'alpha-CHANGED\n' > "$R/a.txt"
out="$( cd "$R" && bash scripts/gate-stamp.sh movers 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | /usr/bin/grep -q 'unavailable:no-manifest'; then
    ok "a missing manifest answers unavailable at rc=2, not an empty clean list"
else
    bad "expected rc=2 unavailable:no-manifest; got rc=$rc [$out]"
fi

echo "ARM 6: the manifest describes the STAMPED tree, not the tree being verified"
# A verify that rewrote the manifest would make the refusal diff the tree
# against itself and always report clean -- the failure this whole order is
# about, reintroduced one layer down.
R="$TMP/r6"; _mkrepo "$R"; _stamp "$R"
_before="$(cat "$R/.git/tillandsias-gate-stamp-manifest")"
printf 'alpha-CHANGED\n' > "$R/a.txt"
( cd "$R" && GATE_STAMP_EMIT_MANIFEST=1 bash scripts/gate-stamp.sh verify ) >/dev/null 2>&1
_after="$(cat "$R/.git/tillandsias-gate-stamp-manifest")"
[ "$_before" = "$_after" ] && ok "verify did not rewrite the manifest, even with the flag exported" \
                           || bad "verify REWROTE the manifest; the refusal would diff the tree against itself"

echo "ARM 8: PLAN FAST-LANE paths are excluded, exactly as compute excludes them"
# FOUND IN PRODUCTION, NOT HERE, and that is the point of the arm. compute skips
# plan/index.d/*.yaml and its siblings (930-i6x4, 1142-85zx), so those paths are
# absent from the manifest by design. movers first enumerated without that skip
# and reported EVERY fragment as `added` — 40+ phantom paths on a clean
# checkout, naming files that cannot be the cause, which is this order's own
# defect committed inside its own remedy. The earlier arms could not see it:
# their throwaway repos have no plan/ tree at all.
R="$TMP/r8"; _mkrepo "$R"
mkdir -p "$R/plan/index.d" "$R/plan/issues"
printf 'packets: []\n' > "$R/plan/index.d/00000000t000000z-probe-linux.yaml"
printf 'note\n'        > "$R/plan/issues/a-top-level-note.md"
( cd "$R" && git add -A && git commit -qm plan ) >/dev/null 2>&1
_stamp "$R"
# Move a fast-lane path's CONTENT. The digest ignores it, so movers must too.
printf 'packets: [changed]\n' > "$R/plan/index.d/00000000t000000z-probe-linux.yaml"
printf 'changed\n'            > "$R/plan/issues/a-top-level-note.md"
out="$(_movers "$R")"
if [ -z "$out" ]; then
    ok "fast-lane paths are excluded from movers, as they are from the digest"
else
    bad "movers named a path the digest ignores — it cannot be the cause: [$out]"
fi
# And a NON-fast-lane path under plan/issues/ subdir IS covered, per 1142-85zx's
# top-level-only rule, so the exclusion is not over-broad.
mkdir -p "$R/plan/issues/research"
printf 'deep\n' > "$R/plan/issues/research/deep.md"
( cd "$R" && git add -A && git commit -qm deep ) >/dev/null 2>&1
_stamp "$R"
printf 'deep-CHANGED\n' > "$R/plan/issues/research/deep.md"
out="$(_movers "$R")"
# ASSERT THE STATE, not merely the path. An over-broad skip drops the path from
# the CURRENT enumeration, so it surfaces as `deleted` -- and a grep for the bare
# path matches that too, passing for the wrong reason. MEASURED: the loose
# version stayed green under exactly that mutation.
printf '%s' "$out" | /usr/bin/grep -q "^modified	plan/issues/research/deep.md$" \
    && ok "a plan/issues SUBDIRECTORY path is still covered (the skip is top-level only)" \
    || bad "the exclusion is over-broad: a subdirectory path was skipped too: [$out]"

echo "ARM 7: the REFUSAL PATH itself runs — it is only reached when someone is blocked"
# The hook calls `gate-stamp.sh movers` from $REPO_ROOT. An undefined variable
# there (the first version of this change used $HOOK_ROOT, which the composition
# wrapper defines and this script does not) would break the refusal under
# `set -u` — and a refusal path that errors is invisible until the moment it is
# needed. Assert the script this hook invokes is reachable the way the hook
# spells it, and that the block naming the cause is present.
_hook="$ROOT/scripts/hooks/pre-push-local-gate.sh"
if [[ -f "$_hook" ]]; then
    if /usr/bin/grep -q 'REPO_ROOT/scripts/gate-stamp.sh" movers' "$_hook" \
       && ! /usr/bin/grep -q 'HOOK_ROOT' "$_hook"; then
        ok "the hook invokes movers via a variable it defines itself"
    else
        bad "the hook's movers invocation uses a root variable it does not define"
    fi
    if /usr/bin/grep -q 'A LIVE-WRITER HINT, NOT THE CAUSE' "$_hook"; then
        ok "the mtime list survives, relabelled as the live-writer hint it was built to be"
    else
        bad "the mtime list is gone or unlabelled — 864-q7dm's live-writer case needs it"
    fi
    bash -n "$_hook" 2>/dev/null && ok "the hook still parses" || bad "the hook does not parse"
else
    echo "  skip: hook script absent"
fi

echo
echo "gate-stamp-names-content-movers: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
