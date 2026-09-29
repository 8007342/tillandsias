#!/usr/bin/env bash
# @trace order:968-uhzg, spec:methodology-accountability
#
# check-exact-version-literal-added.sh — refuse a NEW exact-version comparison
# against a bare numeric literal unless it states why.
#
# THE DEFECT (968-uhzg, found by lenovinha 2026-09-02). host-capability-probe.sh
# validated `schema_version == 2` EXACTLY, so the bump to 3 — the change that
# made the row worth republishing — made the row unpublishable. An exact pin
# makes the FIRST bump fail, and stays latent until someone bumps. It is one of
# five same-day instances of a guard that stops observing what it guards
# (core.hooksPath hiding a spy hook, a mutation arm that silently stopped
# mutating, a fixture inheriting ambient env, and this).
#
# WHAT IS REFUSED: an ADDED line that compares a version-named field to a BARE
# NUMBER with an exact operator (== != -eq -ne), in shell, jq or Rust:
#     .schema_version == 2      [ "$v" -eq 3 ]      self.version != 1
# WHAT IS ADMITTED:
#   * a floor or range (>= <= > <): the right answer for a validator of a
#     document a newer writer may produce;
#   * a comparison against a NAMED constant (== SCHEMA_VERSION, != WIRE_VERSION):
#     one declaration, so a bump changes one place and cannot miss a copy;
#   * an exact literal that states its reason with an `exact-version: <why>`
#     marker on the line or in the four lines above — an exact pin is sometimes
#     right (a protocol, an on-disk format), and then it is a claim that no
#     other version is acceptable, written where the next person bumping reads it.
#
# DIFF-SCOPED: only lines this change ADDS (tracked and untracked), so standing
# code is not re-litigated. Test fixtures (scripts/test-*.sh) and Rust assert
# lines are skipped: a test states the expected value exactly by design.
#
#   ok:exact-version-literal-added:<n> checked
#   violation:exact-version-literal-added:<n>        (rc 1; each site on stderr)
#   ok:exact-version-literal-added:base-unavailable  (no base ref; nothing judged)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
base_ref="${TILLANDSIAS_EXACT_VERSION_BASE:-origin/linux-next}"

if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    echo "ok:exact-version-literal-added:base-unavailable"
    echo "  note: base ref '$base_ref' unavailable — added-line enforcement skipped" >&2
    exit 0
fi

# A version-named field compared EXACTLY to a bare number (shell/jq and Rust).
VER='([A-Za-z_]*[Vv][Ee][Rr][Ss][Ii][Oo][Nn][A-Za-z_]*)'
# Between the name and the operator: up to 8 characters that are not part of
# another comparison (quotes, brackets, spaces), so `>=`/`<=` never match.
PAT="${VER}[^=!<>]{0,8}(==|!=|-eq|-ne)[[:space:]]*[\"']?[0-9]+([^0-9A-Za-z_.]|\$)"

files="$( { git diff --name-only --diff-filter=AM "$base_ref" -- 'scripts/*.sh' 'build.sh' 'images/*.sh' 'images/**/*.sh' 'crates/**/*.rs' 2>/dev/null
           git ls-files --others --exclude-standard -- 'scripts/*.sh' 'build.sh' 'images/*.sh' 'images/**/*.sh' 'crates/**/*.rs' 2>/dev/null; } | sort -u)"

checked=0; violations=0
while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    case "$f" in scripts/test-*.sh|scripts/check-exact-version-literal-added.sh) continue ;; esac
    checked=$((checked + 1))
    # New-file line numbers of the ADDED lines (an untracked file: every line).
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        added="$(git diff -U0 "$base_ref" -- "$f" 2>/dev/null | awk '
            /^@@/ { split($3, a, ","); n = substr(a[1], 2) + 0; next }
            /^\+\+\+/ { next }
            /^\+/ { print n; n++; next }
            /^-/ { next }
        ')"
    else
        added="$(awk '{ print NR }' "$f")"
    fi
    [ -n "$added" ] || continue
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        line="$(sed -n "${ln}p" "$f")"
        # Comments and Rust asserts are not validators.
        case "$line" in
            *assert*) continue ;;
        esac
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in '#'*|'//'*) continue ;; esac
        grep -qE "$PAT" <<<"$line" || continue
        # A stated reason on the line or in the four lines above admits it.
        from=$((ln > 4 ? ln - 4 : 1))
        window="$(sed -n "${from},${ln}p" "$f")"
        if grep -q 'exact-version:' <<<"$window"; then
            continue
        fi
        violations=$((violations + 1))
        {
            echo "REFUSED: $f:$ln compares a version to a BARE NUMBER exactly:"
            echo "    $trimmed"
            echo "  An exact pin makes the FIRST bump fail and stays latent until someone"
            echo "  bumps (968-uhzg). Use a floor (>=) if newer versions are acceptable,"
            echo "  compare against a NAMED constant so a bump changes one place, or keep"
            echo "  it exact and say why: an \`exact-version: <reason>\` comment on the line"
            echo "  or just above it."
        } >&2
    done <<EOF
$added
EOF
done <<EOF
$files
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:exact-version-literal-added:$violations"
    echo "  why: each site above pins a version to a bare number exactly, so the first bump fails (968-uhzg)" >&2
    echo "  remedy: use a floor (>=), a named constant, or an exact-version: <reason> marker, as each REFUSED block says" >&2
    exit 1
fi
echo "ok:exact-version-literal-added:$checked checked"
exit 0
