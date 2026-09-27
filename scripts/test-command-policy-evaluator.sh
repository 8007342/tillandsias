#!/usr/bin/env bash
# @trace order:1443-isrk, spec:command-policies
#
# The command policy evaluator: `tillandsias-plan policy eval -- <argv>` and the
# proc.run gate. Six arms, one per exit criterion of 1443-isrk, with arm 3 as
# re-scoped by the operator rulings of 2026-09-27 (plan fragment 1446-xqi6):
# `podman system reset` is SOFT (consent on bare metal, pre-authorised in a
# forge) and a guest-regime `--reset-guest` is HARD (consent every time, no env
# override, never grantable in a forge).
#
#   1 gh auth refresh in a forge: refused:policy:no-credential-mutation, exit 1,
#     why: + remedy: naming `tillandsias --github-login --with-token`
#   2 bash -c "a | b": refused:policy:no-shell-strings, remedy names the argv form
#   3 soft and hard reset per host kind, and no env variable pre-authorises HARD
#   4 a seed that loosens a floor rule is refused WHOLE at load; the answer comes
#     from the floor alone, and the seed's other (tightening) rule is dropped too
#   5 proc.run{gh auth login}: status=policy_denied with rule/why/remedy, and the
#     fake gh on PATH never runs (it would write a marker); premise: an allowed
#     gh call through the same PATH DOES write it
#   6 NEGATIVE CONTROL: git status --porcelain is ok:policy:allow:default, exit 0,
#     and proc.run of it runs
#
# PRE-FIX RESULT: FAILS at arm 1 — the binary had no `policy` verb.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=6
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "skip:command-policy-evaluator:no-plan-binary — build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
PLAN="$_plan"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# eval <args...>: sets OUT (stdout), ERR (stderr), RC.
ev() {
    OUT="$(cd "$ROOT" && "$PLAN" policy eval "$@" 2>"$T/err")"; RC=$?
    ERR="$(cat "$T/err")"
}
has() { grep -qF -- "$1" <<<"$2"; }

# ── arm 1 ────────────────────────────────────────────────────────────────────
ev --host-kind forge --regime interactive -- gh auth refresh
if [ "$OUT" = "refused:policy:no-credential-mutation" ] && [ "$RC" = 1 ] \
   && has "  why: " "$ERR" && has "  remedy: " "$ERR" \
   && has "tillandsias --github-login --with-token" "$ERR"; then
    ok "1 gh auth refresh: no-credential-mutation, exit 1, why + remedy naming the operator token path"
else bad "1 out=[$OUT] rc=$RC err=[$ERR]"; fi

# ── arm 2 ────────────────────────────────────────────────────────────────────
ev -- bash -c "a | b"
if [ "$OUT" = "refused:policy:no-shell-strings" ] && [ "$RC" = 1 ] && has "argv" "$ERR"; then
    ok "2 bash -c string: no-shell-strings with a remedy naming the argv form"
else bad "2 out=[$OUT] rc=$RC err=[$ERR]"; fi

# ── arm 3 ────────────────────────────────────────────────────────────────────
a3=""
ev --host-kind bare-metal -- podman system reset --force
[ "$OUT" = "consent:policy:soft-reset" ] && [ "$RC" = 4 ] || a3="$a3 soft/bare-metal=[$OUT/$RC]"
ev --host-kind forge -- podman system reset --force
[ "$OUT" = "ok:policy:soft-reset:forge-preauthorised" ] && [ "$RC" = 0 ] || a3="$a3 soft/forge=[$OUT/$RC]"
ev --host-kind forge -- tillandsias --reset-state
[ "$OUT" = "ok:policy:soft-reset:forge-preauthorised" ] && [ "$RC" = 0 ] || a3="$a3 reset-state/forge=[$OUT/$RC]"
OUT="$(cd "$ROOT" && TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=smoke-curl-install-and-test-e2e \
       "$PLAN" policy eval --host-kind bare-metal -- tillandsias-tray --reset-guest 2>/dev/null)"; RC=$?
[ "$OUT" = "consent:policy:hard-reset" ] && [ "$RC" = 4 ] || a3="$a3 hard/bare-metal+env=[$OUT/$RC]"
ev --host-kind forge -- tillandsias-tray --reset-guest
[ "$OUT" = "refused:policy:hard-reset:not-grantable-in-forge" ] && [ "$RC" = 1 ] || a3="$a3 hard/forge=[$OUT/$RC]"
if [ -z "$a3" ]; then
    ok "3 soft reset: consent on bare metal, pre-authorised in a forge; hard reset: consent even with the smoke env, refused in a forge"
else bad "3$a3"; fi

# ── arm 4 ────────────────────────────────────────────────────────────────────
cat >"$T/loosen.yaml" <<'YAML'
version: 1
default: allow
rules:
  - id: tighten-make
    program: make
    decision: deny
  - id: let-me-refresh
    program: gh
    args: [auth, refresh]
    decision: allow
YAML
# Premise: the tightening rule alone DOES bite, so its absence below means the
# seed was dropped whole rather than never having worked.
head -n 6 "$T/loosen.yaml" >"$T/tighten-only.yaml"
ev --seed "$T/tighten-only.yaml" -- make
p4="$OUT"
ev --seed "$T/loosen.yaml" -- gh auth refresh
o4="$OUT"; r4=$RC; e4="$ERR"
ev --seed "$T/loosen.yaml" -- make
m4="$OUT"
if [ "$p4" = "refused:policy:tighten-make" ] \
   && [ "$o4" = "refused:policy:no-credential-mutation" ] && [ "$r4" = 1 ] \
   && has "refused:policy-seed:cannot-loosen:no-credential-mutation" "$e4" \
   && [ "$m4" = "ok:policy:allow:default" ]; then
    ok "4 a loosening seed is refused whole at load; floor answers, and its tightening rule is dropped too"
else bad "4 premise=[$p4] out=[$o4] rc=$r4 make=[$m4] err=[$e4]"; fi

# ── arm 5 ────────────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<EOF
#!/bin/sh
: > "$T/gh-ran"
EOF
chmod +x "$T/bin/gh"
lua_out="$(cd "$ROOT" && PATH="$T/bin:$PATH" "$PLAN" lua -e '
local r = proc.run{argv = {"gh", "auth", "login"}}
local function set(s) return type(s) == "string" and #s > 0 end
print(r.status, r.rule_id, set(r.why) and "why" or "", set(r.remedy) and "remedy" or "")' 2>&1)"
denied_ran=no; [ -e "$T/gh-ran" ] && denied_ran=yes
premise="$(cd "$ROOT" && PATH="$T/bin:$PATH" "$PLAN" lua -e 'print(proc.run{argv = {"gh", "api", "user"}}.status)' 2>&1)"
allowed_ran=no; [ -e "$T/gh-ran" ] && allowed_ran=yes
tab=$'\t'
if [ "$lua_out" = "policy_denied${tab}no-credential-mutation${tab}why${tab}remedy" ] \
   && [ "$denied_ran" = no ] && [ "$premise" = "exited" ] && [ "$allowed_ran" = yes ]; then
    ok "5 proc.run gh auth login: policy_denied with rule/why/remedy and no spawn (an allowed gh call on the same PATH does spawn)"
else bad "5 lua=[$lua_out] denied_ran=$denied_ran premise=[$premise] allowed_ran=$allowed_ran"; fi

# ── arm 6 ────────────────────────────────────────────────────────────────────
ev -- git status --porcelain
o6="$OUT"; r6=$RC
run6="$(cd "$ROOT" && "$PLAN" lua -e 'local r = proc.run{argv = {"git", "status", "--porcelain"}}; print(r.status, r.ok)' 2>&1)"
if [ "$o6" = "ok:policy:allow:default" ] && [ "$r6" = 0 ] && [ "$run6" = "exited${tab}true" ]; then
    ok "6 negative control: git status is allowed by default and proc.run runs it"
else bad "6 out=[$o6] rc=$r6 run=[$run6]"; fi

if [ "$pass" = "$total" ]; then
    echo "ok:command-policy-evaluator:${pass}/${total}"
else
    echo "fail:command-policy-evaluator:${pass}/${total}"
    exit 1
fi
