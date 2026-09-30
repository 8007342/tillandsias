#!/usr/bin/env bash
# @trace order:1462-qvxj, spec:command-policies
#
# test-smoke-skill-reset-env-matches-policy.sh — the two smoke skills tell an
# agent to set exactly the env the consent engine honours (1443-9f5w), and the
# Bash-tool bridge agrees with `policy eval` under it. Doc-vs-code: the
# variables are EXTRACTED from each skill's text, never restated here.
#
#   1  each smoke SKILL.md carries exactly one prefix line
#      `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=<its own dir name>`;
#      "unset or" appears in neither skill nor methodology.yaml, and `=0` stays
#      the documented opt-out                                      (every host)
#   2  `policy eval -- tillandsias --reset-state` under the extracted env is
#      ok:policy:soft-reset:env-preauthorised, audited consent_source=env; with
#      the skill renamed to an unregistered one it is consent:policy:soft-reset
#   3  the bridge (`policy classify-bash --command`) allows the reset exactly as
#      the skill prescribes it (prefix form) and with the pair in the hook's own
#      env; without TILLANDSIAS_DESTRUCTIVE_RESET_OK it asks
#   4  hard reset is untouched: under the same env, `wsl --unregister x` is
#      consent:policy:hard-reset through eval and an ask through the bridge
# Arms 2-4 need bare-metal EVIDENCE (no /run/.containerenv); in a forge they
# are a NAMED skip, as in test-command-policy-consent.sh.
#
# Pre-fix: FAILS at arm 1 (both skills said "unset or 1" and set no skill).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/smoke-reset-env.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
skipped=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
skip() { echo "skip: $1"; skipped=$((skipped + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

unset TILLANDSIAS_SKILL TILLANDSIAS_DESTRUCTIVE_RESET_OK TILLANDSIAS_HOST_KIND TILLANDSIAS_PRETOOLUSE_HOOK
export TILLANDSIAS_CONSENT_DIR="$W/consent"
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/audit.jsonl"
mkdir -p "$W/cwd"
SKILLS=(smoke-curl-install-and-test-e2e build-install-and-smoke-test-e2e)
PAIR_RE='TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=[A-Za-z0-9_-]*'

# ── 1 ───────────────────────────────────────────────────────────────────────
# Indexed, not associative: bash 3.2 (the macOS /bin/bash) has no declare -A.
PREFIXES=()
idx=0
for s in "${SKILLS[@]}"; do
    PREFIXES[idx]=""
    f="$ROOT/skills/$s/SKILL.md"
    found="$(/usr/bin/grep -o -- "$PAIR_RE" "$f")"
    n="$(printf '%s\n' "$found" | /usr/bin/grep -c .)"
    unset_n="$(/usr/bin/grep -c 'unset or' "$f")"
    optout_n="$(/usr/bin/grep -c 'TILLANDSIAS_DESTRUCTIVE_RESET_OK=0' "$f")"
    if [ "$n" = 1 ] && [ "$found" = "TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=$s" ] &&
        [ "$unset_n" = 0 ] && [ "$optout_n" -ge 1 ]; then
        ok "arm 1: $s prescribes [$found]; no 'unset or'; =0 opt-out documented"
        PREFIXES[idx]="$found"
    else
        bad "arm 1: $s pair_lines=$n found=[$found] unset_or=$unset_n optout=$optout_n"
    fi
    idx=$((idx + 1))
done
m_unset="$(/usr/bin/grep -c 'unset or 1' "$ROOT/methodology.yaml")"
[ "$m_unset" = 0 ] && ok "arm 1: methodology.yaml no longer says 'unset or 1'" ||
    bad "arm 1: methodology.yaml still says 'unset or 1' ($m_unset)"

cd "$W/cwd" || exit 1
if [ -e /run/.containerenv ]; then
    skip "arms 2, 3, 4: /run/.containerenv is present, so the evidence says forge; run on bare metal, and see cargo test -p tillandsias-plan --lib bash_policy command_policy"
else
    idx=0
    for s in "${SKILLS[@]}"; do
        pfx="${PREFIXES[idx]:-}"
        idx=$((idx + 1))
        [ -n "$pfx" ] || { bad "arms 2-4: $s has no extracted prefix (arm 1 failed)"; continue; }
        read -r -a ENVW <<<"$pfx"
        # ── 2 ───────────────────────────────────────────────────────────────
        out="$(env "${ENVW[@]}" "$PLAN" policy eval -- tillandsias --reset-state 2>/dev/null)"; rc=$?
        src="$("$PLAN" json get -r '.consent_source' <<<"$(tail -n 1 "$TILLANDSIAS_POLICY_AUDIT_LOG")" 2>/dev/null)"
        outu="$(env "${ENVW[0]}" TILLANDSIAS_SKILL=not-a-smoke-skill "$PLAN" policy eval -- tillandsias --reset-state 2>/dev/null)"; rcu=$?
        if [ "$rc" -eq 0 ] && [ "$out" = "ok:policy:soft-reset:env-preauthorised" ] && [ "$src" = env ] &&
            [ "$rcu" -eq 4 ] && [ "$outu" = "consent:policy:soft-reset" ]; then
            ok "arm 2: $s env is env-preauthorised (consent_source=env); an unregistered skill asks"
        else
            bad "arm 2: $s [$out] rc=$rc src=[$src]; unregistered [$outu] rc=$rcu"
        fi
        # ── 3 ───────────────────────────────────────────────────────────────
        "$PLAN" policy classify-bash --command "$pfx tillandsias --reset-state" --cwd "$W/cwd" >/dev/null 2>&1; rp=$?
        env "${ENVW[@]}" "$PLAN" policy classify-bash --command "tillandsias --reset-state" --cwd "$W/cwd" >/dev/null 2>&1; re=$?
        "$PLAN" policy classify-bash --command "${ENVW[1]} tillandsias --reset-state" --cwd "$W/cwd" >/dev/null 2>&1; rn=$?
        if [ "$rp" -eq 0 ] && [ "$re" -eq 0 ] && [ "$rn" -eq 4 ]; then
            ok "arm 3: $s the bridge allows the prescribed reset (prefix and hook env); without RESET_OK it asks"
        else
            bad "arm 3: $s prefix rc=$rp env rc=$re no-reset-ok rc=$rn (0 allow, 4 ask)"
        fi
        # ── 4 ───────────────────────────────────────────────────────────────
        outh="$(env "${ENVW[@]}" "$PLAN" policy eval -- wsl --unregister x 2>/dev/null)"; rch=$?
        "$PLAN" policy classify-bash --command "$pfx wsl --unregister x" --cwd "$W/cwd" >/dev/null 2>&1; rbh=$?
        if [ "$rch" -eq 4 ] && [ "$outh" = "consent:policy:hard-reset" ] && [ "$rbh" -eq 4 ]; then
            ok "arm 4: $s hard reset stays consent:policy:hard-reset (eval) and an ask (bridge)"
        else
            bad "arm 4: $s eval [$outh] rc=$rch bridge rc=$rbh"
        fi
    done
fi

echo "summary: pass=$pass fail=$fail skipped=$skipped"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: smoke-skill-reset-env-matches-policy"
