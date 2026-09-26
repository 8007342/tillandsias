#!/usr/bin/env bash
# test-json-get-help-names-its-subset.sh — order 1401-bcd7.
#
# `json get --help` is the onboarding for every jq-ratchet migration
# (1395-ue3i), so it must name the flags, the supported forms and the refused
# forms with a reshape — and it must not lie about any of them. Each arm checks
# the help text AND the parser, so a help line that drifts from the binary
# fails here instead of in the next migration.
#
#   1  `json get --help`, `json get -h` and `json --help` exit 0 on stdout
#   2  `yaml get --help` names yaml, not json
#   3  every flag the parser accepts has a help line
#   4  every SUPPORTED form is in the help and parses (--parse-only exit 0)
#   5  every REFUSED form is in the help and is refused (exit 3, unsupported:)
#   6  every recommended reshape that is a filter parses
#
#   PASS: json-get-help-names-its-subset <n>/<n>
#   blocked:json-get-help-absent     the binary prints no help (pre-fix)
#   skip:json-get-help:no-plan-binary
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
# Resolve inside the checkout, not the caller's cwd, and absolutise the answer
# (1401-x76w; the b17f6a8a3 shape). An explicit TILLANDSIAS_PLAN_BIN is the
# caller's choice and is kept as given.
_abs_plan() {
    local p
    p="$(resolve_plan_binary 2>/dev/null)" || return 1
    case "$p" in
        (/*) printf '%s' "$p" ;;
        (*) printf '%s/%s' "$PWD" "${p#./}" ;;
    esac
}
if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
    PLAN="$(resolve_plan_binary 2>/dev/null)"
else
    PLAN="$(cd "$ROOT" && _abs_plan)"
fi || { echo "skip:json-get-help:no-plan-binary"; exit 3; }

help="$("$PLAN" json get --help 2>/dev/null)"
help_rc=$?
case "$help" in
    *"supported:"*"refused"*) ;;
    *) echo "blocked:json-get-help-absent"; exit 1 ;;
esac

pass=0
fail=0
ok() { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
# Fixed-string containment, no pipeline (a `printf | grep -q` verdict is a
# SIGPIPE race under pipefail).
in_help() { case "$help" in *"$1"*) return 0 ;; esac; return 1; }

# ARM 1
short="$("$PLAN" json get -h 2>/dev/null)"; short_rc=$?
bare="$("$PLAN" json --help 2>/dev/null)"; bare_rc=$?
if [ "$help_rc" -eq 0 ] && [ "$short_rc" -eq 0 ] && [ "$bare_rc" -eq 0 ] &&
    [ "$short" = "$help" ] && [ "$bare" = "$help" ]; then
    ok "ARM 1: --help, -h and 'json --help' exit 0 with the same text"
else
    bad "ARM 1: rc --help=$help_rc -h=$short_rc 'json --help'=$bare_rc, or the texts differ"
fi

# ARM 2
yhelp="$("$PLAN" yaml get --help 2>/dev/null)"
case "$yhelp" in
    *"tillandsias-plan yaml get"*"over yaml input"*)
        case "$yhelp" in
            *"json get"*) bad "ARM 2: yaml help still says 'json get'" ;;
            *) ok "ARM 2: yaml get --help names yaml" ;;
        esac ;;
    *) bad "ARM 2: yaml get --help does not name yaml" ;;
esac

# ARM 3 — the flags json_query_dispatch accepts.
missing=""
for flag in "-r, --raw-output" "-c, --compact-output" "-e, --exit-status" \
    "-n, --null-input" "-s, --slurp" "-M" "--arg k v" "--argjson k v" \
    "--parse-only" "-h, --help" "reads stdin"; do
    in_help "$flag" || missing="$missing [$flag]"
done
if [ -z "$missing" ]; then ok "ARM 3: every flag has a help line"; else bad "ARM 3: missing$missing"; fi

# ARM 4 — each supported form: named in the help, and the parser takes it.
missing=""
# A line is `<text in the help>` or `<text in the help> => <concrete probe>`,
# where the help writes a placeholder (f, k, cond) the parser cannot take.
while IFS= read -r line; do
    [ -n "$line" ] || continue
    form="${line%% => *}"; probe="${line#* => }"
    in_help "$form" || { missing="$missing [help:$form]"; continue; }
    "$PLAN" json get --parse-only "$probe" >/dev/null 2>&1 || missing="$missing [parse:$probe]"
done <<'EOF'
.a.b
.["x-y"]
.a[-1]
.[$k]
keys[]
.a[]?
.a // "default"
[.a[] | .k]
select(f) => select(.a == 1)
has(k) => has("a")
keys_unsorted
ascii_downcase
tostring
EOF
if [ -z "$missing" ]; then ok "ARM 4: every supported form is named and parses"; else bad "ARM 4:$missing"; fi

# ARM 5 — each refused form: the help's spelling, then a probe the parser must
# refuse as unsupported (exit 3), not as a syntax error.
missing=""
while IFS='|' read -r named probe; do
    [ -n "$named" ] || continue
    in_help "$named" || { missing="$missing [help:$named]"; continue; }
    out="$("$PLAN" json get --parse-only "$probe" 2>&1)"; rc=$?
    case "$rc:$out" in
        3:unsupported:*) ;;
        *) missing="$missing [refuse:$probe rc=$rc $out]" ;;
    esac
done <<'EOF'
join(",")|join(",")
"\(.a) \(.b)"|"\(.a)"
{a: .a}|{a: .a}
map(f)|map(.a)
arithmetic|.a + 1
if/then/else|if . then 1 else 2 end
. as $v|. as $v | $v
slices .[1:3]|.[1:3]
@csv|@csv
test split startswith contains ltrimstr|test("a")
first last|first
sort unique|sort
to_entries values|to_entries
any|any
..  reduce  def  try|..
EOF
if [ -z "$missing" ]; then ok "ARM 5: every refused form is named and refused as unsupported"; else bad "ARM 5:$missing"; fi

# ARM 6 — the reshapes that are themselves filters must be in the subset.
missing=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    form="${line%% => *}"; probe="${line#* => }"
    in_help "$form" || { missing="$missing [help:$form]"; continue; }
    "$PLAN" json get --parse-only "$probe" >/dev/null 2>&1 || missing="$missing [parse:$probe]"
done <<'EOF'
[.[] | f] => [.[] | .a]
[.a, .b]
.[0]
[.[] | select(cond)] | length > 0 => [.[] | select(.a)] | length > 0
EOF
if [ -z "$missing" ]; then ok "ARM 6: every filter reshape parses"; else bad "ARM 6:$missing"; fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: json-get-help-names-its-subset $pass/$total"
    exit 0
fi
echo "FAIL: json-get-help-names-its-subset $pass/$total"
exit 1
