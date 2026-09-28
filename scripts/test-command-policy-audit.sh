#!/usr/bin/env bash
# @trace order:1443-w9hf, spec:command-policies
#
# test-command-policy-audit.sh — every policy decision lands in the per-host
# audit log, with token-shaped literals redacted, and `policy audit` summarises
# it. Runs under a redirected HOME from a directory that is not a checkout, so
# the log resolves to $HOME/.cache/tillandsias/metrics/command-policy-audit.jsonl.
#
#   1  `policy eval -- gh auth token` appends decision=deny,
#      rule_id=no-credential-mutation, program=gh, and a sha256 argv_digest
#   2  a ghp_ token in the argv is <redacted:token> in the log and never
#      appears anywhere (log, stdout, stderr); PEM and AWS-style keys likewise
#   3  `policy audit --since 24h` prints one line per (rule_id, decision) and a
#      total; with no log it prints ok:policy-audit:empty and exits 0
#   4  NEGATIVE CONTROL: TILLANDSIAS_TIMING_LOG and /tmp/tillandsias-timing.jsonl
#      do not grow across a hundred evaluations
#   5  the Bash-tool bridge (1443-we89) writes to the SAME audit as
#      caller=pretooluse, with no raw command
#
# Pre-fix: FAILS at arm 1 (no log).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/command-policy-audit.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

export HOME="$W/home"
unset TILLANDSIAS_POLICY_AUDIT_LOG TILLANDSIAS_POLICY_AUDIT
mkdir -p "$HOME" "$W/cwd"
cd "$W/cwd" || exit 1
LOG="$HOME/.cache/tillandsias/metrics/command-policy-audit.jsonl"
jget() { "$PLAN" json get "$@"; }

# ── 3 (empty half first, before anything has written) ────────────────────────
out="$("$PLAN" policy audit --since 24h 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:policy-audit:empty" ] &&
    ok "arm 3: with no log, policy audit prints ok:policy-audit:empty and exits 0" ||
    bad "arm 3 empty: rc=$rc [$out]"

# ── 1 ───────────────────────────────────────────────────────────────────────
"$PLAN" policy eval -- gh auth token >/dev/null 2>&1
last="$(tail -n 1 "$LOG" 2>/dev/null)"
digest="$(jget -r '.argv_digest' <<<"$last" 2>/dev/null)"
if [ "$(jget -r '.decision' <<<"$last" 2>/dev/null)" = deny ] &&
    [ "$(jget -r '.rule_id' <<<"$last" 2>/dev/null)" = no-credential-mutation ] &&
    [ "$(jget -r '.program' <<<"$last" 2>/dev/null)" = gh ] &&
    [ "${#digest}" -eq 64 ] && [ -z "$(tr -d '0-9a-f' <<<"$digest")" ]; then
    ok "arm 1: gh auth token is audited: deny, no-credential-mutation, program gh, sha256 digest"
else
    bad "arm 1: last line [$last]"
fi

# ── 2 ───────────────────────────────────────────────────────────────────────
TOKEN="ghp_abcdefghijklmnopqrstuvwxyz0123456789"
out="$("$PLAN" policy eval -- curl -H "Authorization: token $TOKEN" 2>&1)"
last="$(tail -n 1 "$LOG" 2>/dev/null)"
if grep -qF '<redacted:token>' <<<"$last" && ! grep -qF 'ghp_' "$LOG" && ! grep -qF 'ghp_' <<<"$out"; then
    ok "arm 2: a ghp_ token is <redacted:token> in the log and absent from the log and the output"
else
    bad "arm 2: out=[$out] last=[$last]"
fi
"$PLAN" policy eval -- aws configure set aws_access_key_id AKIAABCDEFGHIJKLMNOP >/dev/null 2>&1
"$PLAN" policy eval -- printf '%s' "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAA
-----END OPENSSH PRIVATE KEY-----" >/dev/null 2>&1
leaks="$(grep -cE 'AKIAABCDEFGHIJKLMNOP|b3BlbnNzaC1rZXktdjEAAAAA' "$LOG")"
pems="$(grep -cF '<redacted:pem>' "$LOG")"
if [ "$leaks" = 0 ] && [ "$pems" -ge 1 ]; then
    ok "arm 2: AWS-style key ids and PEM blocks are redacted too"
else
    bad "arm 2: AWS/PEM leaked: [$(tail -n 2 "$LOG")]"
fi

# ── 3 (summary half) ────────────────────────────────────────────────────────
out="$("$PLAN" policy audit --since 24h 2>/dev/null)"; rc=$?
total="$(sed -n 's/^total=//p' <<<"$out")"
lines="$(wc -l <"$LOG" | tr -d ' ')"
if [ "$rc" -eq 0 ] && grep -qx '1 no-credential-mutation deny' <<<"$out" &&
    grep -qE '^[0-9]+ default allow$' <<<"$out" && [ "$total" = "$lines" ]; then
    ok "arm 3: policy audit --since 24h prints one line per (rule_id, decision) and total=$total"
else
    bad "arm 3 summary: rc=$rc total=[$total] lines=$lines [$out]"
fi
out="$("$PLAN" policy audit --since 1s 2>/dev/null)"
sleep 2
out="$("$PLAN" policy audit --since 1s 2>/dev/null)"
[ "$out" = "ok:policy-audit:empty" ] && ok "arm 3: --since excludes older decisions" || bad "arm 3 since: [$out]"

# ── 4: NEGATIVE CONTROL ─────────────────────────────────────────────────────
export TILLANDSIAS_TIMING_LOG="$W/timing.jsonl"
: >"$TILLANDSIAS_TIMING_LOG"
tmp_before="$( { [ -f /tmp/tillandsias-timing.jsonl ] && wc -c </tmp/tillandsias-timing.jsonl; } || echo absent)"
i=0
while [ "$i" -lt 100 ]; do
    "$PLAN" policy eval -- git status >/dev/null 2>&1
    i=$((i + 1))
done
tmp_after="$( { [ -f /tmp/tillandsias-timing.jsonl ] && wc -c </tmp/tillandsias-timing.jsonl; } || echo absent)"
audit_after="$(wc -l <"$LOG" | tr -d ' ')"
if [ ! -s "$TILLANDSIAS_TIMING_LOG" ] && [ "$tmp_before" = "$tmp_after" ] &&
    [ "$audit_after" -ge $((lines + 100)) ]; then
    ok "arm 4: 100 evaluations grow the audit by 100 and leave both timing logs untouched"
else
    bad "arm 4: timing=[$(wc -c <"$TILLANDSIAS_TIMING_LOG")] /tmp before=$tmp_before after=$tmp_after audit=$audit_after"
fi
unset TILLANDSIAS_TIMING_LOG

# ── 5: the bridge writes to the same audit ───────────────────────────────────
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"gh auth refresh --token %s"}}' "$W/cwd" "$TOKEN" |
    "$PLAN" policy classify-bash --hook >/dev/null 2>&1
last="$(tail -n 1 "$LOG")"
if [ "$(jget -r '.caller' <<<"$last")" = pretooluse ] && [ "$(jget -r '.decision' <<<"$last")" = deny ] &&
    [ "$(jget -r '.argv_shown' <<<"$last")" = null ] && ! grep -qF 'ghp_' "$LOG"; then
    ok "arm 5: the Bash-tool bridge audits as caller=pretooluse, digest only, no token"
else
    bad "arm 5: last=[$last]"
fi
status="$("$PLAN" policy classify-bash --status)"
grep -qE '^decisions=1/0/0 ' <<<"$status" && ok "arm 5: the bridge's --status counts only caller=pretooluse" ||
    bad "arm 5 status: [$status]"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: command-policy-audit $pass/$total (1443-w9hf)"
    exit 0
fi
echo "FAIL: command-policy-audit $pass/$total (1443-w9hf)"
exit 1
