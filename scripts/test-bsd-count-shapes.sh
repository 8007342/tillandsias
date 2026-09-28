#!/usr/bin/env bash
# @trace order:1454-ssg3, spec:ci-release
#
# Fixture: the BSD userland's count shapes, reproduced on ANY host, so a count
# in a gate cannot regress on darwin while every Linux run stays green (order
# 1454-ssg3). Stub `grep` and `wc` on PATH emit exactly what macOS's stock
# /usr/bin/grep and /usr/bin/wc emit:
#   * `grep -lc` prints BOTH `file:N` and `file` for each matching file (GNU
#     prints only the names) — 2 files read as 4 lines;
#   * `wc -l` left-pads its count ("       2"), which breaks a string compare.
#
#   1. the stubs reproduce the shape: the OLD expression (`grep -lc … | wc -l`)
#      counts 4 for 2 files, the red darwin measured at 392a0c514;
#   2. the litmus:fragment-ts-skew consumer count, read verbatim from its yaml,
#      answers ok:both-consumers under the BSD stubs;
#   3. the same command answers ok:both-consumers with the host's own tools;
#   4. a padded `wc -l` is normalised: the count reaches a string compare as "2".
#
# PRE-FIX RESULT: FAILS at arm 2 — the litmus used `grep -lc`, which reads 4.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=4
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
[ -n "$_plan" ] || { echo "skip:bsd-count-shapes:no-plan-binary — build one: cargo build --release -p tillandsias-plan"; exit 0; }
PLAN="$_plan"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/bsd-count-shapes.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

REAL_GREP="$(command -v grep)"; REAL_WC="$(command -v wc)"
STUB="$W/bin"; mkdir -p "$STUB"
# BSD grep: with BOTH -l and -c, print "file:N" then "file" per matching file.
cat > "$STUB/grep" <<EOF
#!/usr/bin/env bash
l=0; c=0; args=()
for a in "\$@"; do
    case "\$a" in
        -lc|-cl) l=1; c=1 ;;
        -l) l=1 ;;
        -c) c=1 ;;
        *) args+=("\$a") ;;
    esac
done
if [ "\$l" = 1 ] && [ "\$c" = 1 ]; then
    pat="\${args[0]}"; rc=1
    for f in "\${args[@]:1}"; do
        n=\$("$REAL_GREP" -c -e "\$pat" "\$f" 2>/dev/null) || n=0
        if [ "\${n:-0}" -gt 0 ]; then printf '%s:%s\n%s\n' "\$f" "\$n" "\$f"; rc=0; fi
    done
    exit \$rc
fi
[ "\$l" = 1 ] && set -- -l "\${args[@]}"
[ "\$c" = 1 ] && set -- -c "\${args[@]}"
[ "\$l" = 0 ] && [ "\$c" = 0 ] && set -- "\${args[@]}"
exec "$REAL_GREP" "\$@"
EOF
# BSD wc -l: left-pad the count to eight columns.
cat > "$STUB/wc" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then n=\$("$REAL_WC" -l | tr -d ' '); printf '%8s\n' "\$n"; exit 0; fi
exec "$REAL_WC" "\$@"
EOF
chmod +x "$STUB/grep" "$STUB/wc"
bsd() { PATH="$STUB:$PATH" bash -c "$1"; }

cmd="$("$PLAN" yaml-json "$ROOT/openspec/litmus-tests/litmus-fragment-ts-skew.yaml" \
    | "$PLAN" json get -r '.critical_path[] | select(.expected_behavior == "ok:both-consumers") | .command' 2>/dev/null)"
[ -n "$cmd" ] || { echo "fail:bsd-count-shapes:0/$total (could not read the litmus command)"; exit 1; }

cd "$ROOT" || exit 1

# 1 — the stubs reproduce the darwin shape.
old="$(bsd "grep -lc 'check-fragment-ts-skew' scripts/hooks/pre-push-local-gate.sh build.sh 2>/dev/null | wc -l")"
if [ "$old" = "       4" ]; then
    ok "arm 1: BSD grep -lc + wc -l reads 2 files as '       4' (the darwin red, reproduced here)"
else
    bad "arm 1: expected '       4' under the BSD stubs, got '$old'"
fi

# 2 — the litmus's own command survives the BSD shape.
out2="$(bsd "$cmd")"
[ "$out2" = "ok:both-consumers" ] && ok "arm 2: litmus:fragment-ts-skew consumer count under BSD grep/wc -> ok:both-consumers" \
    || bad "arm 2: got '$out2' from: $cmd"

# 3 — and with this host's own tools.
out3="$(bash -c "$cmd")"
[ "$out3" = "ok:both-consumers" ] && ok "arm 3: the same command with the host's tools -> ok:both-consumers" \
    || bad "arm 3: got '$out3'"

# 4 — a padded count is normalised before any string compare.
n4="$(bsd "printf 'a\nb\n' | wc -l | tr -d ' '")"
[ "consumers=$n4" = "consumers=2" ] && ok "arm 4: padded wc -l normalised: consumers=2" \
    || bad "arm 4: got 'consumers=$n4'"

if [ "$pass" -eq "$total" ]; then
    echo "ok:bsd-count-shapes:$pass/$total"
    exit 0
fi
echo "fail:bsd-count-shapes:$pass/$total"
exit 1
