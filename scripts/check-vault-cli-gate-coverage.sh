#!/usr/bin/env bash
# check-vault-cli-gate-coverage.sh — every verb a vault-cli.sh DISPATCHES must be
# in its central CA gate, so a new verb cannot reach Vault unverified.
# @trace order:1406-9ctt, spec:tillandsias-vault
#
# WHY A PROPERTY, NOT A LIST. litmus:vault-cli-verifies-tls used to grep for a
# literal verb list; when write-json was added (1381-za6b/1383-5hpk) the GATE
# grew correctly and the PIN went red, because a pinned list tests the list, not
# the guarantee. This compares the two lists the script itself carries: the
# `<verbs>) require_cacert` gate line, and the dispatcher's `<verb>) … cmd_…`
# arms. usage/help (no I/O) are exempt, as the script's own comment says.
#
# OUTPUT: ok:vault-cli-gate-coverage:<file>:<n> verbs                    exit 0
#         refused:vault-cli-gate-coverage:<file>:ungated=<verbs>         exit 1
#         could-not-run:vault-cli-gate-coverage:<file>:<why>             exit 3
set -uo pipefail
f="${1:-}"
[ -f "$f" ] || { echo "could-not-run:vault-cli-gate-coverage:${f:-<none>}:no-such-file"; exit 3; }
gate_line="$(grep -E '^[[:space:]]*[a-z|-]+\)[[:space:]]*require_cacert' "$f" | head -1)"
[ -n "$gate_line" ] || { echo "could-not-run:vault-cli-gate-coverage:$f:no-gate-line"; exit 3; }
gate=" $(printf '%s' "$gate_line" | sed -E 's/^[[:space:]]*([a-z|-]+)\).*/\1/' | tr '|' ' ') "
# dispatcher arms: a single-verb arm whose body calls a cmd_ function
verbs="$(grep -E '^[[:space:]]*[a-z-]+\)[[:space:]].*cmd_' "$f" | sed -E 's/^[[:space:]]*([a-z-]+)\).*/\1/' | sort -u)"
[ -n "$verbs" ] || { echo "could-not-run:vault-cli-gate-coverage:$f:no-dispatch-arms"; exit 3; }
n=0; missing=""
for v in $verbs; do
    n=$((n + 1))
    case "$gate" in *" $v "*) ;; *) missing="$missing $v" ;; esac
done
if [ -n "$missing" ]; then
    echo "refused:vault-cli-gate-coverage:$f:ungated=$(printf '%s' "$missing" | sed 's/^ //; s/ /,/g')"
    exit 1
fi
echo "ok:vault-cli-gate-coverage:$f:$n verbs"
