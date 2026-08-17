#!/usr/bin/env bash
# @trace spec:tray-ux
# freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-17 verdict=refreshed scope=792-77bt authoring
#
# Tray string corpus drift report (792-77bt, slice 2 of 628-c7qd).
#
# THE QUESTION THIS ANSWERS, and the reason it exists: 628-c7qd asks for a
# BYTE-IDENTICAL refactor that resolves every tray string from
# locales/en.toml. That is only possible if en.toml already holds what the
# trays render. It does not — and this script measures by how much, so the
# packet's direction is decided by a number anyone can reproduce rather than
# by whoever read the corpus most recently.
#
# WHAT IT MEASURES (deterministic, no judgment):
#   for each en.toml value, does the QUOTED literal "<value>" appear in the
#   production text of the tray sources?
# A verbatim appearance is necessary for byte-identical adoption of that key
# (not sufficient — the key may still be semantically wrong).
#
# ACCURACY, stated because two different methods give two different numbers
# and both were run: this grep does NOT decode Rust escapes, so a literal
# written `"\u{1F527} Maintenance"` will not match its decoded form. That
# makes `rendered` a LOWER bound and `unmatched` an UPPER bound. An
# escape-decoding cross-check on 2026-08-17 found 9 exact literal matches
# where this reports 5. Both agree on the only thing that decides the
# packet: over 90% of the corpus is not what the trays render.
#
# WHAT IT DELIBERATELY DOES NOT MEASURE: the inverse direction — shipped
# literals with no key. That needs a user-visible/log classification that no
# regex does honestly; the 2026-08-17 measurement hand-adjudicated it and
# reported ~111 GUI strings with a stated +/-5 boundary. A script that
# pretended to automate it would manufacture false precision, which is the
# defect this packet family keeps finding.
#
# Grammar (one line on stdout):
#   tray-string-drift: en_keys=<N> rendered=<N> unmatched=<N> rendered_pct=<N>
# Always exits 0: this is a REPORT. The pinned assertion lives in
# tillandsias-host-shell's test suite, so a corpus that converged (or drifted
# further) fails a test rather than silently changing a number nobody reads.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

EN="locales/en.toml"
[ -r "$EN" ] || { echo "tray-string-drift: cannot read $EN" >&2; exit 2; }

# Tray sources: the two native trays plus the shared menu builder and the
# Linux tray module.
#
# PRODUCTION TEXT ONLY, and this correction matters: the first cut fed raw
# files to the matcher, so a value counted as "rendered" when it appeared in
# a COMMENT or inside a `#[cfg(test)]` module. That inflated the headline
# 2x (18 vs 9), and worse, it began measuring this repo's own test code —
# a pin added the day before asserted `APP_NAME == "Tillandsias"`, which the
# next run then counted as the tray rendering that string. A measurement
# that reads its own assertions is not a measurement.
#
# So: drop `//` line comments and truncate each file at the first column-0
# `#[cfg(test)]`. Crude, and deliberately conservative — it can only UNDER-
# count matches, which keeps the unmatched figure a floor.
SOURCES=$(find crates/tillandsias-macos-tray/src \
               crates/tillandsias-windows-tray/src \
               crates/tillandsias-host-shell/src \
               crates/tillandsias-headless/src/tray \
               -name '*.rs' 2>/dev/null)
[ -n "$SOURCES" ] || { echo "tray-string-drift: no tray sources found" >&2; exit 2; }

CORPUS_TMP="$(mktemp "${TMPDIR:-/tmp}/tray-drift.XXXXXX")"
trap 'rm -f "$CORPUS_TMP"' EXIT
# One haystack, one pass. Per-key grep over ~170 keys x ~60 files was the
# shape that made another checker in this repo take minutes (734-sjb3).
for _f in $SOURCES; do
    awk '/^#\[cfg\(test\)\]/ { exit } { sub(/^[[:space:]]*\/\/.*$/, ""); print }' "$_f"
done > "$CORPUS_TMP" 2>/dev/null

total=0
rendered=0
unmatched_list=""
while IFS= read -r line; do
    case "$line" in
        \#*|\[*|'') continue ;;
    esac
    case "$line" in
        *" = "*) ;;
        *) continue ;;
    esac
    key="${line%% = *}"
    value="${line#* = }"
    # Strip the surrounding TOML quotes; skip anything that is not a simple
    # quoted scalar (arrays, numbers) rather than guessing at a rendering.
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        *) continue ;;
    esac
    [ -n "$value" ] || continue
    total=$((total + 1))
    # Match the QUOTED literal, not the bare value: a bare-substring search
    # counted `Maintenance` as rendered because `🔧 Maintenance` contains it,
    # while the tray renders a different string under a different key. Still
    # an upper bound — a literal written with `\u{...}` escapes will not
    # match its decoded form — so the unmatched figure stays a floor.
    if grep -qF -- "\"$value\"" "$CORPUS_TMP" 2>/dev/null; then
        rendered=$((rendered + 1))
    else
        unmatched_list="${unmatched_list}  ${key} = \"${value}\"
"
    fi
done < "$EN"

unmatched=$((total - rendered))
pct=0
[ "$total" -gt 0 ] && pct=$(( rendered * 100 / total ))

if [ "${1:-}" = "--list" ]; then
    printf 'en.toml values that appear NOWHERE in the tray sources:\n%s' "$unmatched_list"
fi
echo "tray-string-drift: en_keys=$total rendered=$rendered unmatched=$unmatched rendered_pct=$pct"
exit 0
