#!/usr/bin/env bash
# @trace order:1459-mqvd
#
# test-litmus-self-match.sh — a litmus step must not pkill/pgrep -f a
# hard-coded pattern that its own `bash -c` shell carries in argv.
#
# The runner executes each step's `command:` under `bash -c "<command>"`, so
# the pattern text of `pkill -f tillandsias` is part of that shell's command
# line, and the pkill can match and kill the step executing it (1266-75tr).
# The fix idiom is a one-character class, `pkill -f 'tillandsia[s]'`: the
# regex matches the process, never its own literal spelling.
#
# The decision is made by `tillandsias-litmus-rust litmus-self-match`, which
# parses the YAML and the bash (tree-sitter), not by grep. This wrapper only
# resolves the binary, runs the fixture arms, and applies DECLARED.
#
# Arms:
#   1 HAZARD     a scratch litmus with an unbracketed pkill -f is REFUSED
#   2 IDIOM      (negative control) the same step with a bracketed pattern passes
#   3 TREE       every openspec/litmus-tests/*.yaml passes, minus DECLARED
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

# Known instances, each owned by a row. Remove an entry when its row lands.
# 1266-75tr landed in land86 (the second of the pair), which removed its two
# entries here as agreed between its author and 1459-mqvd's.
DECLARED=""

# A blocking guard never skips for want of a binary: build it if absent.
BIN=""
for cand in "$ROOT/target/release/tillandsias-litmus-rust" "${CARGO_TARGET_DIR:-$ROOT/target}/release/tillandsias-litmus-rust"; do
    [ -x "$cand" ] || continue
    _usage="$("$cand" 2>&1)"
    case "$_usage" in *litmus-self-match*) BIN="$cand"; break ;; esac
done
if [ -z "$BIN" ]; then
    cargo build -q --release -p tillandsias-litmus-rust >&2 || { echo "blocked:litmus-self-match:build-failed"; exit 2; }
    BIN="${CARGO_TARGET_DIR:-$ROOT/target}/release/tillandsias-litmus-rust"
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/litmus-self-match.XXXXXX")"
trap 'rm -rf "$W"' EXIT
_pat="tillandsia""s"
printf 'steps:\n  - name: stop\n    command: "pkill -f %s 2>/dev/null; echo DONE"\n' "$_pat" > "$W/hazard.yaml"
printf 'steps:\n  - name: stop\n    command: "pkill -f \047%s[s]\047 2>/dev/null; echo DONE"\n' "tillandsia" > "$W/idiom.yaml"

out1="$("$BIN" litmus-self-match "$W/hazard.yaml" 2>&1)"; rc1=$?
if [ "$rc1" -ne 0 ] && grep -q "violation:litmus-self-match:1" <<<"$out1"; then
    ok "ARM1 an unbracketed pkill -f in a step command is refused"
else bad "ARM1 rc=$rc1 out='$out1'"; fi

out2="$("$BIN" litmus-self-match "$W/idiom.yaml" 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ] && grep -q "^ok:litmus-self-match:scanned=1:commands=1" <<<"$out2"; then
    ok "ARM2 the bracketed spelling passes: the idiom is the fix, not a finding"
else bad "ARM2 rc=$rc2 out='$out2'"; fi

files=()
for f in openspec/litmus-tests/*.yaml; do
    case " $DECLARED " in *" $f:"*) continue ;; esac
    files+=("$f")
done
out3="$("$BIN" litmus-self-match "${files[@]}" 2>&1)"; rc3=$?
if [ "$rc3" -eq 0 ]; then
    ok "ARM3 the litmus tree is clean outside DECLARED: ${out3%%$'\n'*}"
else
    printf '%s\n' "$out3"
    bad "ARM3 a litmus step can kill its own shell; bracket one character of the pattern, e.g. 'name[s]'"
fi
# A DECLARED entry that no longer fires is stale: say so, so it gets removed.
for d in $DECLARED; do
    f="${d%%:*}"
    [ -f "$f" ] || { bad "DECLARED names a missing file: $f"; continue; }
    if "$BIN" litmus-self-match "$f" >/dev/null 2>&1; then
        bad "DECLARED entry $d no longer fires: remove it"
    fi
done

[ "$FAIL" -eq 0 ] && { echo "PASS: litmus-self-match (1459-mqvd)"; exit 0; }
echo "FAILED: litmus-self-match (1459-mqvd)"; exit 1
