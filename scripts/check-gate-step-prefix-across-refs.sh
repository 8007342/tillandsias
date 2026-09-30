#!/usr/bin/env bash
# @trace order:1512-3afc
#
# Refuse a NEWLY ADDED gate step whose numeric prefix another host already
# holds, on trunk or on any other unlanded work ref, before it costs a relaunch.
#
# WHY. An author picks "the next free number" from their own ref's view, which
# cannot see other hosts' unlanded origin/work/* refs. MEASURED 2026-09-30:
# three collisions in one day (1266-dh2d vs 1494-kkbi, 1494-kkbi vs 815-yace,
# 1508-7s4w vs 1504-4tty), each a rename and a relaunch. allocate-gate-step-
# prefix.sh (1162-qbrx) reallocates at LAND time against the refs that land
# integrated; it cannot see refs queued for later lands.
#
# WHAT IT READS. It reads remote-tracking refs as fetched; it does not fetch.
#   added    scripts/gate-steps.d/NNN-*.step in HEAD and absent from $TRUNK
#   holders  every step file on $TRUNK, plus on each origin/work/* ref that
#            (a) was committed to within $WINDOW days, (b) is NOT already in
#            $TRUNK, and (c) is NOT already in HEAD (a ref this land carries
#            is the same step, not a rival).
# The window keeps abandoned refs from pinning numbers forever (386 work refs
# existed on 2026-09-30, most long landed or dead).
#
# VERDICTS (stdout, last line):
#   ok:gate-step-prefix-across-refs:<n> added, <m> refs scanned
#   ok:gate-step-prefix-across-refs:no-new-steps
#   refused:gate-step-prefix-across-refs:<file>:<holder-ref>:<holder-file>
#   skip:gate-step-prefix-across-refs:no-trunk-ref (the trunk ref is not fetched here)
#
# Seams: TILLANDSIAS_STEP_PREFIX_TRUNK (default origin/linux-next),
# TILLANDSIAS_STEP_PREFIX_REFS (default refs/remotes/origin/work/),
# TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS (default 14).
set -uo pipefail
TRUNK="${TILLANDSIAS_STEP_PREFIX_TRUNK:-origin/linux-next}"
REFS="${TILLANDSIAS_STEP_PREFIX_REFS:-refs/remotes/origin/work/}"
WINDOW="${TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS:-14}"
DIR=scripts/gate-steps.d

_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }

if ! git rev-parse -q --verify "$TRUNK^{commit}" >/dev/null 2>&1; then
    echo "skip:gate-step-prefix-across-refs:no-trunk-ref ($TRUNK is not fetched here, so there is nothing to compare against)"
    exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

git diff --no-renames --name-only --diff-filter=A "$TRUNK" HEAD -- "$DIR/" 2>/dev/null \
    | grep -E "^$DIR/[0-9]+-[^/]*\.step$" > "$tmp/added" || true
if [ ! -s "$tmp/added" ]; then
    echo "ok:gate-step-prefix-across-refs:no-new-steps"
    exit 0
fi

# holders: "<ref>\t<file basename>"
git ls-tree --name-only "$TRUNK" "$DIR/" 2>/dev/null | sed "s#^.*/##; s#^#$TRUNK\t#" > "$tmp/holders"
cutoff=$(( $(date +%s) - WINDOW * 86400 ))
n_refs=0
git for-each-ref --format='%(committerdate:unix) %(refname:short)' "$REFS" 2>/dev/null > "$tmp/refs"
while read -r ts ref; do
    [ -n "$ref" ] && [ "${ts:-0}" -ge "$cutoff" ] || continue
    git merge-base --is-ancestor "$ref" "$TRUNK" 2>/dev/null && continue
    git merge-base --is-ancestor "$ref" HEAD 2>/dev/null && continue
    n_refs=$((n_refs + 1))
    git ls-tree --name-only "$ref" "$DIR/" 2>/dev/null | sed "s#^.*/##; s#^#$ref\t#" >> "$tmp/holders"
done < "$tmp/refs"

grep -oE '^[0-9]+' <<<"$(cut -f2 "$tmp/holders"; sed 's#^.*/##' "$tmp/added")" | sort -n -u > "$tmp/used"

n_added=0
while IFS= read -r f; do
    base="${f##*/}"; pfx="${base%%-*}"
    n_added=$((n_added + 1))
    hit="$(awk -F'\t' -v p="$pfx" -v b="$base" '{ q=$2; sub(/-.*/, "", q) } q == p && $2 != b { print; exit }' "$tmp/holders")"
    [ -n "$hit" ] || continue
    holder_ref="${hit%%	*}"; holder_file="${hit#*	}"
    free=$(( (pfx / 10 + 1) * 10 ))
    while grep -qx "$free" "$tmp/used"; do free=$((free + 10)); done
    echo "gate-step-prefix-across-refs: $base takes prefix $pfx, which $holder_ref already holds as $holder_file" >&2
    echo "refused:gate-step-prefix-across-refs:$base:$holder_ref:$holder_file"
    _afford "two steps sharing one prefix collide when both land, and the loser pays a rename and a relaunch" \
        "rename it to a free prefix, e.g. git mv $f $DIR/$free-${base#*-} (checked against $TRUNK and $n_refs unlanded work refs)"
    exit 1
done < "$tmp/added"

echo "ok:gate-step-prefix-across-refs:$n_added added, $n_refs refs scanned"
exit 0
