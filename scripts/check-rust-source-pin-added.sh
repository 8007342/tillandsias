#!/usr/bin/env bash
# @trace order:1473-scdq, spec:ci-release
#
# check-rust-source-pin-added.sh — the Rust half of 634-39ik's rule: no NEWLY
# ADDED test may pin a literal in a SOURCE file without a negative control or a
# stated reason.
#
# WHY (827-d3dc, plan/issues/source-literal-pin-survey-2026-09-28.md). The
# survey found 92 Rust pins of the form
#     let src = include_str!("vz.rs");  …  assert!(src.contains("After=…"));
# and FOUR of the ten costliest pins were this shape. One of them kept a
# PRODUCT DEFECT green (1472-3d29: a fetch unit ordered after a retired mount).
# check-litmus-expression-pinning-added.sh guards litmus steps; nothing guarded
# this population. A literal in source can be present and never reach
# runtime, and it breaks on correct refactors: the pin is weaker than the
# assertion it stands in for.
#
# WHAT IS REFUSED: an ADDED line in crates/**/*.rs calling `<var>.contains(`,
# not negated, where <var> is bound by `include_str!(<*.rs|*.sh|*.toml|…>)`
# earlier in the same function.
# WHAT IS ADMITTED:
#   * an ABSENCE assertion (`!src.contains(…)`): a whole-file absence scan is the
#     legitimately source-shaped class (b) of the survey;
#   * a pin inside a test whose body names a NEGATIVE CONTROL (the same phrases
#     the litmus guard accepts: "negative control", "NEG-", "must FAIL");
#   * a `source-pin-ok: <reason>` comment on the line or up to 3 lines above;
#     the reason is required.
# The remedy the refusal names is the one every survey repair used: assert on
# the value a function BUILDS (provision_user_data_for_test, ready_unit, …),
# not on the text that builds it.
#
# DIFF-SCOPED: standing pins are not re-litigated.
#
#   ok:rust-source-pin-added:<n> checked
#   violation:rust-source-pin-added:<n>          (rc 1; each site on stderr)
#   ok:rust-source-pin-added:base-unavailable
#
# Seam for the fixture: --check-file <file> <added-line-numbers,comma-separated>
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
base_ref="${TILLANDSIAS_RUST_PIN_BASE:-origin/linux-next}"

INC='let[[:space:]]+(mut[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[^=]*=[[:space:]]*include_str!\(.*\.(rs|sh|ps1|toml|yaml|yml|json|plist|template)"'
NEG='negative control|NEG-|must FAIL|negative_control'

# judge <file> <line> -> 0 admitted, 1 refused (prints nothing)
judge() {
    local f="$1" ln="$2" line trimmed var from win fnstart fnbody
    line="$(sed -n "${ln}p" "$f")"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '//'*) return 0 ;; esac
    # the receiver of the first non-negated .contains( on the line
    var="$(sed -nE 's/.*[^!A-Za-z0-9_]([A-Za-z_][A-Za-z0-9_]*)\.contains\(.*/\1/p' <<<" $line")"
    [ -n "$var" ] || return 0
    # (A negated `!var.contains(` never matches above: the character before the
    # receiver must not be `!`. So an absence assertion is admitted by
    # construction, with no second pass.)
    # the enclosing fn: nearest `fn ` line above
    fnstart="$(awk -v n="$ln" 'NR<=n && /^[[:space:]]*(pub(\([a-z]+\))?[[:space:]]+)?fn[[:space:]]/ {s=NR} END{print s+0}' "$f")"
    [ "$fnstart" -gt 0 ] || return 0
    fnbody="$(sed -n "${fnstart},${ln}p" "$f")"
    # is <var> SOURCE TEXT? Bound by include_str! of a source file in this fn,
    # or by a `let` whose right-hand side uses such a variable (a window cut
    # with split/source_window/find): two hops cover every survey pin.
    local src_vars pass l lhs
    src_vars=" $(grep -E "$INC" <<<"$fnbody" | sed -nE 's/.*let[[:space:]]+(mut[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\2/p' | tr '\n' ' ')"
    for pass in 1 2; do
        while IFS= read -r l; do
            lhs="$(sed -nE 's/^[[:space:]]*let[[:space:]]+(mut[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\2/p' <<<"$l")"
            [ -n "$lhs" ] || continue
            case "$src_vars" in *" $lhs "*) continue ;; esac
            for v in $src_vars; do
                if grep -qE "(^|[^A-Za-z0-9_])${v}([^A-Za-z0-9_]|$)" <<<"${l#*=}"; then
                    src_vars="$src_vars$lhs "; break
                fi
            done
        done <<<"$(grep -E '^[[:space:]]*let[[:space:]]' <<<"$fnbody")"
    done
    case "$src_vars" in *" $var "*) ;; *) return 0 ;; esac
    # exemptions: a reasoned marker nearby, or a negative control in the test
    from=$((ln > 3 ? ln - 3 : 1))
    win="$(sed -n "${from},${ln}p" "$f")"
    grep -qE 'source-pin-ok:[[:space:]]*[^[:space:]]' <<<"$win" && return 0
    local fnend
    fnend="$(awk -v n="$ln" 'NR>n && /^[[:space:]]*(#\[test\]|(pub(\([a-z]+\))?[[:space:]]+)?fn[[:space:]])/ {print NR-1; exit} END{}' "$f")"
    [ -n "$fnend" ] || fnend="$(wc -l < "$f" | tr -d ' ')"
    grep -qiE "$NEG" <<<"$(sed -n "$((fnstart > 12 ? fnstart - 12 : 1)),${fnend}p" "$f")" && return 0
    return 1
}

report() {
    local f="$1" ln="$2" t
    t="$(sed -n "${ln}p" "$f")"; t="${t#"${t%%[![:space:]]*}"}"
    {
        echo "REFUSED: $f:$ln adds a test pinning a literal in SOURCE text read by include_str!:"
        echo "    $t"
        echo "  why: a literal in source can be present and never reach runtime, and it breaks"
        echo "       on correct refactors; this shape kept a product defect green (1472-3d29,"
        echo "       827-d3dc survey)."
        echo "  remedy: assert on the value a function BUILDS (e.g. provision_user_data_for_test(),"
        echo "       readiness::ready_unit()) instead of its source text; or add a negative"
        echo "       control to this test; or, if the source text IS the subject, mark the line"
        echo "       // source-pin-ok: <why the text itself is the contract>"
    } >&2
}

if [ "${1:-}" = "--check-file" ]; then
    f="${2:?file}"; lines="${3:-}"; bad=0
    for ln in ${lines//,/ }; do
        judge "$f" "$ln" || { report "$f" "$ln"; bad=$((bad+1)); }
    done
    if [ "$bad" -gt 0 ]; then
        echo "violation:rust-source-pin-added:$bad"
        echo "  why: the lines above pin source text with no negative control or reason" >&2
        echo "  remedy: apply the remedy each REFUSED block names, then re-run" >&2
        exit 1
    fi
    echo "ok:rust-source-pin-added:checked"
    exit 0
fi

if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    echo "ok:rust-source-pin-added:base-unavailable"
    echo "  note: base ref '$base_ref' unavailable — added-line enforcement skipped" >&2
    exit 0
fi

files="$( { git diff --name-only --diff-filter=AM "$base_ref" -- 'crates/**/*.rs' 2>/dev/null
           git ls-files --others --exclude-standard -- 'crates/**/*.rs' 2>/dev/null; } | sort -u)"
checked=0; violations=0
while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    checked=$((checked + 1))
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        added="$(git diff -U0 "$base_ref" -- "$f" 2>/dev/null | awk '
            /^@@/ { split($3, a, ","); n = substr(a[1], 2) + 0; next }
            /^\+\+\+/ { next }
            /^\+/ { print n; n++; next }
            /^-/ { next }')"
    else
        added="$(awk '{ print NR }' "$f")"
    fi
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        grep -q '\.contains(' <<<"$(sed -n "${ln}p" "$f")" || continue
        judge "$f" "$ln" && continue
        report "$f" "$ln"; violations=$((violations + 1))
    done <<EOF
$added
EOF
done <<EOF
$files
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:rust-source-pin-added:$violations"
    echo "  why: each site above pins source text read by include_str! with no negative control or reason (1473-scdq)" >&2
    echo "  remedy: apply the remedy each REFUSED block names, then re-run this check" >&2
    exit 1
fi
echo "ok:rust-source-pin-added:$checked checked"
exit 0
