#!/usr/bin/env bash
# check-unique-bin-names.sh — no two workspace crates may declare the same
# [[bin]] name. (1043-kvvn)
#
# WHY THIS IS NOT A STYLE RULE. Cargo writes every bin target to
# target/<profile>/<name>, so two crates sharing a name write the SAME FILE and
# whichever links last wins. Nothing warns. The observable effect is a test
# executing another crate's binary.
#
# MEASURED 2026-09-05: tillandsias-macos-tray and tillandsias-windows-tray both
# declared `name = "tillandsias-tray"`. In a full-workspace build the macOS
# tray's CLI tests ran the WINDOWS stub and got exit 1 with "runs on Windows
# only" where they asserted exit 2. It presented as an intermittent flake for
# three occurrences, because the winner depends on cargo's link order, and it
# NEVER appeared under `cargo test -p tillandsias-macos-tray` (the sibling is
# not built then) — so isolation, the usual first instinct, hid it every time.
#
# THE SHIPPED NAME IS A SEPARATE CONTRACT and is deliberately NOT checked here:
# release packaging renames the build output to tillandsias-tray.exe, the
# installers place that name, and the smoke runbook asserts it on both
# platforms. This guard governs the BUILD-TIME target only.
#
# A ZERO COUNT IS A FAILURE, NOT A PASS. The first draft of this script printed
# "ok:unique-bin-names: checked" with an empty count because its parsing
# collected nothing — a guard that inspected zero manifests reporting the same
# verdict as one that inspected all of them.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:unique-bin-names:[0-9]+ checked|violation:duplicate-bin-name:[0-9]+)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for manifest in crates/*/Cargo.toml; do
    [ -f "$manifest" ] || continue
    awk -v m="$manifest" '
        /^\[\[bin\]\]/ { inbin = 1; next }
        /^\[/          { inbin = 0 }
        inbin && /^[ \t]*name[ \t]*=/ {
            line = $0
            sub(/^[ \t]*name[ \t]*=[ \t]*"/, "", line)
            sub(/".*$/, "", line)
            print line "\t" m
        }
    ' "$manifest" >> "$TMP"
done

count="$(wc -l < "$TMP" | tr -d ' ')"
if [ "$count" -eq 0 ]; then
    echo "violation:duplicate-bin-name:0"
    echo "  no [[bin]] targets were found in crates/*/Cargo.toml — this guard inspected nothing and must not report ok (1043-kvvn)" >&2
    exit 1
fi

# `|| true` is LOAD-BEARING: sort|uniq -d prints nothing and exits 1 when there
# are no duplicates, and `set -o pipefail` would kill the script on the HAPPY
# path — reporting a guard crash as if it were a finding.
dups="$(cut -f1 "$TMP" | sort | uniq -d || true)"

if [ -n "$dups" ]; then
    n="$(printf '%s\n' "$dups" | grep -c . || true)"
    echo "violation:duplicate-bin-name:${n}"
    printf '%s\n' "$dups" | while IFS= read -r d; do
        [ -n "$d" ] || continue
        where="$(awk -F'\t' -v d="$d" '$1 == d {printf "%s ", $2}' "$TMP")"
        echo "  [[bin]] name '${d}' is declared by: ${where}" >&2
        echo "    Both write target/<profile>/${d}; the last link wins and the other crate's tests run the wrong binary (1043-kvvn)." >&2
    done
    exit 1
fi

echo "ok:unique-bin-names:${count} checked"
