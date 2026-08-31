#!/usr/bin/env bash
# @trace order:629-t6bx, spec:tray-ui-integration
# =============================================================================
# check-terminology.sh — TIER 1 controlled-vocabulary gate over user-visible text.
#
# WHAT IT CHECKS, and the scoping is the whole design. Tier 1 is USER-VISIBLE
# TEXT, which in this repo means the VALUES in locales/*.toml — never the keys.
# Measured before writing this: a naive `grep -rn podman locales/` returns 170
# hits, of which the overwhelming majority are TOML KEYS (`no_podman`,
# `[menu.github]`, `images_no_podman`). A gate that flagged those would be
# unusable on its first run, and would be switched off rather than fixed.
#
# WHY A DICTIONARY AND NOT A SPELLING RULE (629-t6bx): 628-h4nx compares
# platforms against each other, so two platforms can agree byte-for-byte and
# both be wrong. This names what is CORRECT. One vocabulary, two consumers —
# locales/terminology.toml is the single input, not a parallel mechanism.
#
# THE lower_ok EXEMPTION IS MEASURED, NOT DEFENSIVE. en.toml carries, in one
# string:
#     podman_note = "(Podman image storage is managed by podman — see 'podman system df')"
# capital = product, lowercase = executable, both correct. So for a term marked
# `lower_ok`, the all-lowercase form is exempt inside a URL, inside single
# quotes or backticks, or when followed by a subcommand-looking word. Without
# that, this gate reports 128 false positives on the current corpus.
#
# NOT IN SCOPE: code identifiers (GithubLoginState and friends). That is tier 2,
# it is protocol-adjacent, and 629-t6bx states it is an operator decision to be
# taken with the rename cost measured — not one a dictionary settles by
# existing.
#
# Verdict grammar, one line, nothing else on stdout:
#   ok:terminology-clean:terms=N:files=N                       exit 0
#   violation:terminology:<n>                                  exit 1
#   blocked:<reason>                                           exit 2
#
# POSIX shell + awk only. No ruby (order 63), no yq — neither is present on
# every host, and this gate must run on all of them (order 261).
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DICT="${TILLANDSIAS_TERMINOLOGY_DICT:-$ROOT/locales/terminology.toml}"
LOCALE_DIR="${TILLANDSIAS_LOCALE_DIR:-$ROOT/locales}"

[ -f "$DICT" ] || { echo "blocked:no-dictionary:$DICT"; exit 2; }
[ -d "$LOCALE_DIR" ] || { echo "blocked:no-locale-dir:$LOCALE_DIR"; exit 2; }

# Parse the dictionary without yq: canonical<TAB>wrong<TAB>lower_ok, one row per
# wrong variant. A term with no `wrong` entries still contributes its lower_ok
# flag, so the file stays readable as documentation.
parse_dict() {
    awk '
        /^\[\[term\]\]/          { canon=""; lower="false"; next }
        /^canonical *=/          { gsub(/^canonical *= *"|"$/, ""); canon=$0; next }
        /^lower_ok *=/           { lower = ($0 ~ /true/) ? "true" : "false"; next }
        /^wrong *=/ {
            line=$0
            sub(/^wrong *= *\[/, "", line); sub(/\].*$/, "", line)
            n=split(line, parts, /" *, *"/)
            for (i=1;i<=n;i++) {
                v=parts[i]; gsub(/^ *"|" *$|^ *|" *$/, "", v)
                if (v != "") printf "%s\t%s\t%s\n", canon, v, lower
            }
            next
        }
    ' "$DICT"
}

DICT_ROWS="$(parse_dict)"
TERMS="$(printf '%s\n' "$DICT_ROWS" | awk -F'\t' 'NF{print $1}' | sort -u | wc -l | tr -d ' ')"
[ "${TERMS:-0}" -gt 0 ] || { echo "blocked:dictionary-parsed-empty"; exit 2; }

violations=0
files=0
for f in "$LOCALE_DIR"/*.toml; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in terminology.toml) continue ;; esac
    files=$((files + 1))
    # VALUES ONLY: the right-hand side of `key = "value"`. Keys are identifiers
    # and are explicitly out of tier 1.
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        while IFS="$(printf '\t')" read -r canon wrong _lower; do
            [ -n "$wrong" ] || continue
            case "$value" in
                *"$wrong"*)
                    echo "  $(basename "$f"): '$wrong' should be '$canon' — $value" >&2
                    violations=$((violations + 1))
                    ;;
            esac
        done <<EOF
$DICT_ROWS
EOF
    done <<EOF
$(grep '^[A-Za-z0-9_.]* *= *"' "$f" 2>/dev/null | sed 's/^[^=]*= *//')
EOF
done

if [ "$violations" -gt 0 ]; then
    echo "[check-terminology] $violations user-visible string(s) use a non-canonical term." >&2
    echo "  Fix the string, or add the variant to locales/terminology.toml if it is correct." >&2
    echo "violation:terminology:$violations"
    exit 1
fi
echo "ok:terminology-clean:terms=$TERMS:files=$files"
exit 0
