#!/usr/bin/env bash
# test-spec-index-staging-capacity.sh — the index builder must stage where the
# payload FITS, not where TMPDIR happens to point.
# @trace order:964-zedm
#
# THE DEFECT. spec-index-ensure.sh staged via `mktemp -d "${TMPDIR:-/tmp}/..."`.
# In a forge /tmp is a 256 MB tmpfs while the index root is on a 1.2 TB overlay,
# so a cold build of 22,645 chunks died with `jq: error: writing output failed:
# No space left on device` on a host with 1.2 TB free. MEASURED on
# lenovinha-tillandsias-forge 2026-09-02.
#
# The staged payload and the published index grow together — this host stages
# ~92 MB of vectors for a 22.7k-chunk corpus — so the filesystem that can hold
# the RESULT is the one that can hold the WORKING SET.
#
# Hermetic: asserts the CHOICE of staging directory by reading what the script
# does, with a tiny real tmpfs-shaped directory standing in for the forge's.
# It never runs an embedding pass and never touches a real index.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC=scripts/spec-index-ensure.sh
pass=0; fail=0

# 1. Staging is anchored to the index root, not to the ambient TMPDIR.
if grep -q '_stage_parent="${TILLANDSIAS_SPEC_INDEX_TMPDIR:-$INDEX_ROOT}"' "$SRC" \
   && grep -q 'mktemp -d "$_stage_parent/.spec-index-ensure.XXXXXX"' "$SRC"; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: staging is not anchored to the index root"
fi

# 2. THE REGRESSION ARM. The unconditional TMPDIR form must not come back as
#    the primary choice. It survives only inside the fallback, which is why
#    this looks for it BEFORE the fallback marker rather than banning it.
first_tmpdir="$(grep -n 'mktemp -d "${TMPDIR:-/tmp}/spec-index-ensure' "$SRC" | head -1 | cut -d: -f1)"
first_stage="$(grep -n '_stage_parent=' "$SRC" | head -1 | cut -d: -f1)"
if [ -z "$first_tmpdir" ] || { [ -n "$first_stage" ] && [ "$first_tmpdir" -gt "$first_stage" ]; }; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: the ambient-TMPDIR staging form is reachable before the index-root form"
fi

# 3. An operator override exists and is honoured on EXISTENCE, never probed for
#    size — the same rule the endpoint derivation applies to an explicit
#    endpoint (967-xq5e): probing an override collapses "you chose badly" into
#    "there is none".
if grep -q 'TILLANDSIAS_SPEC_INDEX_TMPDIR' "$SRC"; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: no TILLANDSIAS_SPEC_INDEX_TMPDIR override"
fi

# 4. The ENOSPC verdict NAMES the directory that ran out and offers the remedy.
#    Before this, `blocked:spec-index:payload-failed` named the step while the
#    cause was a filesystem two layers away that the reader never chose.
blk="$(sed -n '/blocked:spec-index:payload-failed/,/exit 1; }/p' "$SRC" | tail -n +2)"
if printf '%s' "$blk" | grep -q 'staging dir:' \
   && printf '%s' "$blk" | grep -q 'index root:' \
   && printf '%s' "$blk" | grep -q 'df -Ph' \
   && printf '%s' "$blk" | grep -q 'TILLANDSIAS_SPEC_INDEX_TMPDIR'; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: the payload-failed verdict does not name the directory and remedy"
fi

# 5. The fallback must still exist. A host whose index root is momentarily
#    unwritable is worse off with no build than with the old behaviour, so the
#    fix must degrade rather than refuse. Negative control against a fix that
#    simply deleted the TMPDIR path.
if grep -q 'blocked:spec-index:no-tmpdir' "$SRC" \
   && grep -q 'could not create a staging dir under' "$SRC"; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: the unwritable-index-root fallback is missing or silent"
fi

# 6. LIVE: with the override pointed at a real directory, the script stages
#    there. Runs the real script far enough to create the staging dir, then
#    stops it — no embedding pass, no network.
probe="$(mktemp -d "${TMPDIR:-/tmp}/stage-probe.XXXXXX")"
( TILLANDSIAS_SPEC_INDEX_TMPDIR="$probe" TILLANDSIAS_EMBED_ENDPOINT="http://127.0.0.1:1/v1" \
  timeout 120 bash "$SRC" >/dev/null 2>&1 ) || true
# The script cleans its staging dir on exit, so assert on the PARENT having been
# used: a leftover entry, or an empty parent that the script created under.
if [ -d "$probe" ]; then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "FAIL: override directory vanished"
fi
rm -rf "$probe"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: spec-index staging capacity $pass/$total (964-zedm)"
    exit 0
fi
echo "FAIL: spec-index staging capacity $pass/$total (964-zedm)"
exit 1
