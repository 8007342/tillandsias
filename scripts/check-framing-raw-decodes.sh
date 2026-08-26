#!/bin/bash
# @trace spec:vsock-transport
# @trace order:795-5itp
#
# ORDER 795-5itp. The named closure for "nine hand-rolled copies of
# `u32-BE length ‖ postcard` framing": a source scan over `crates/` that
# counts RAW frame-length decodes (`u32::from_be_bytes` outside a comment)
# and compares them against a committed per-file baseline.
#
# WHY A RATCHET AND NOT "AT MOST ONE". The packet's exit criterion asks for
# at most one raw decode tree-wide. At the time this guard landed there were
# 18, across ten files, and several are dispositioned as deliberate keeps
# (a blocking std::os::unix UnixStream registry that Framed cannot own; a
# #[cfg(test)] interop peer whose whole value is being an INDEPENDENT
# hand-rolled decoder). A scan that simply asserts the end state fails on
# day one, gets marked expected-fail, and then protects nothing during the
# months the migration actually takes. A ratchet is falsifiable every day:
# it fails loud the moment a NEW hand-rolled copy appears, and it fails
# equally loud when the baseline is left stale after a slice lands, so the
# recorded ceiling cannot drift above the truth.
#
# That second refusal is the one that matters for 884-hfsj: a `next_action`
# describing which slice is next goes stale silently, but a baseline that
# must be tightened in the same commit as the migration cannot.
#
# Verdict grammar (exactly one line on stdout):
#   ok:framing-ratchet:sites=<n>:files=<n>
#   blocked:framing-ratchet-new-site:<path>
#   blocked:framing-ratchet-regressed:<path>:<actual>>:<baseline>
#   blocked:framing-ratchet-stale:<path>:<actual><:<baseline>
#   blocked:framing-ratchet-no-baseline
#   blocked:framing-ratchet-not-a-git-repo
# Exit 0 only on ok:.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || { echo "blocked:framing-ratchet-not-a-git-repo"; exit 1; }
[ -d .git ] || [ -f .git ] || { echo "blocked:framing-ratchet-not-a-git-repo"; exit 1; }

baseline_file="scripts/framing-raw-decode-baseline.tsv"
[ -f "$baseline_file" ] || { echo "blocked:framing-ratchet-no-baseline"; exit 1; }

# Count raw frame-length decodes per file. A decode is `u32::from_be_bytes`
# on a source line that is not a comment — the tray's own explanatory comment
# names the mechanics it keeps, and counting prose as a site would make the
# ratchet unfixable by explaining it.
scan_counts() {
    find crates -name '*.rs' -type f \
    | LC_ALL=C sort \
    | while IFS= read -r f; do
        n=$(grep -c 'u32::from_be_bytes' "$f" 2>/dev/null || true)
        [ "${n:-0}" -gt 0 ] || continue
        # drop comment-only lines from the count
        c=$(grep -n 'u32::from_be_bytes' "$f" \
            | sed 's/^[0-9][0-9]*://' \
            | sed 's/^[[:space:]]*//' \
            | grep -c -v '^\(//\|\*\)' || true)
        [ "${c:-0}" -gt 0 ] || continue
        printf '%s\t%s\n' "$c" "$f"
      done
}

actual="$(scan_counts)"

baseline_count_for() {
    awk -F'\t' -v p="$1" '$1 !~ /^#/ && $2 == p { print $1; found=1 } END { if (!found) print "" }' \
        "$baseline_file"
}

total_sites=0
total_files=0

# (1) every scanned file must be in the baseline, and must not exceed it.
while IFS="$(printf '\t')" read -r count path; do
    [ -n "${path:-}" ] || continue
    total_sites=$((total_sites + count))
    total_files=$((total_files + 1))
    base="$(baseline_count_for "$path")"
    if [ -z "$base" ]; then
        echo "blocked:framing-ratchet-new-site:$path"
        exit 1
    fi
    if [ "$count" -gt "$base" ]; then
        echo "blocked:framing-ratchet-regressed:$path:$count>$base"
        exit 1
    fi
    if [ "$count" -lt "$base" ]; then
        echo "blocked:framing-ratchet-stale:$path:$count<$base"
        exit 1
    fi
done <<EOF
$actual
EOF

# (2) a baseline entry whose file no longer has any site is also stale —
# the migration landed and the ceiling was not lowered to zero/removed.
while IFS="$(printf '\t')" read -r bcount bpath _rest; do
    case "$bcount" in ''|'#'*) continue ;; esac
    [ -n "${bpath:-}" ] || continue
    if ! printf '%s\n' "$actual" | grep -q "	$bpath\$"; then
        echo "blocked:framing-ratchet-stale:$bpath:0<$bcount"
        exit 1
    fi
done < "$baseline_file"

echo "ok:framing-ratchet:sites=$total_sites:files=$total_files"
