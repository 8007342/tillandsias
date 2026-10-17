#!/usr/bin/env bash
# @trace order:1443-9f5w, spec:command-policies
#
# test-command-policy-consent.sh — per-run consent tokens and the smoke-skill
# env mapping (operator ruling 3, 2026-09-27: "Forges should keep
# pre-authorizing SOFT RESET always. HARD RESET should require explicit
# approval each time."). Runs under a redirected consent dir and audit log,
# from a scratch directory that is not a checkout.
#
# BARE-METAL ARMS (need host-kind EVIDENCE of bare metal: no forge image record;
# in a forge they are a NAMED skip, and `cargo test -p tillandsias-plan --lib
# command_policy` covers the same rules with an injected host kind):
#   1  `policy consent grant soft-reset --ttl 30m -- podman system reset --force`
#      prints ok:consent:soft-reset:until=<iso> and writes one 0600 token
#   2  `policy eval` of that argv prints ok:policy:soft-reset:consented, exit 0,
#      audited consent_source=token; the SAME eval again is
#      consent:policy:soft-reset, exit 4, and says the token was already spent
#   3  a foreign-host or expired token is refused:consent:invalid:<reason> and
#      deleted; a token for a DIFFERENT argv is refused:consent:invalid:
#      argv-mismatch and kept
#   5  TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 + TILLANDSIAS_SKILL=<registered smoke
#      skill> allows soft-reset with consent_source=env; the env without a
#      registered skill still asks; hard-reset never takes the env
# EVERY-HOST ARMS:
#   4  with TILLANDSIAS_HOST_KIND=forge, `consent grant` prints
#      refused:consent:not-grantable-in-forge, exits 1, and writes nothing
#   6  minting through an agent door is refused: `policy eval -- tillandsias-plan
#      policy consent grant …` is refused:policy:no-self-consent
#   7  a grant with no argv is refused:consent:no-argv (a token approves ONE
#      exact run); an unknown class is refused:consent:unknown-class
#   9  (bare metal) the run door spends a token for one run exactly as eval does
#   8  FORGE ONLY: a well-formed token for this host planted in the store is NOT
#      honoured (consent is never granted from a forge) and is not spent
#
# Pre-fix: FAILS at arm 4 (no `policy consent` verb; the usage error is 2).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/command-policy-consent.XXXXXX")"
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
jget() { "$PLAN" json get "$@"; }

unset TILLANDSIAS_SKILL TILLANDSIAS_DESTRUCTIVE_RESET_OK TILLANDSIAS_HOST_KIND TILLANDSIAS_POLICY_AUDIT
export TILLANDSIAS_CONSENT_DIR="$W/consent"
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/audit.jsonl"
mkdir -p "$W/cwd"
cd "$W/cwd" || exit 1
HOST="$(uname -n | tr '[:upper:]' '[:lower:]')"
# ORDER 1764-ca9x: the arms now drive the RUN door, which executes what it
# allows, so the reset argv names STUB executables by absolute path. The policy
# classifies by program basename, so the class is unchanged; an honoured token
# runs the stub, never a real `podman system reset` or `wsl --unregister`.
mkdir -p "$W/bin"
for p in podman wsl; do
    printf '#!/bin/sh\necho "STUB-%s $*"\n' "$p" >"$W/bin/$p"
    chmod +x "$W/bin/$p"
done
SOFT=("$W/bin/podman" system reset --force)
WSL=("$W/bin/wsl" --unregister)
# PREMISE: the stub argv is still in the destructive classes. If it were not,
# every arm below would be judged on an argv the policy simply allows.
pe="$("$PLAN" policy eval -- "${SOFT[@]}" 2>/dev/null)"
pw="$("$PLAN" policy eval -- "${WSL[@]}" x 2>/dev/null)"
if [ "$pe" != "consent:policy:soft-reset" ] || [ "$pw" != "consent:policy:hard-reset" ]; then
    echo "FAIL: PREMISE — the stub argv left its class (soft=[$pe] hard=[$pw]); refusing to run the arms" >&2
    exit 1
fi
tokens() { find "$TILLANDSIAS_CONSENT_DIR" -name '*.json' 2>/dev/null | grep -c .; }
plant() { # plant <file> <class> <host> <expires_at>
    mkdir -p "$TILLANDSIAS_CONSENT_DIR"
    printf '{"version":1,"id":"%s","class":"%s","host":"%s","argv_digest":"x","argv_shown":"x","granted_at":"2026-01-01T00:00:00Z","expires_at":"%s"}\n' \
        "${1%.json}" "$2" "$3" "$4" >"$TILLANDSIAS_CONSENT_DIR/$1"
}

# ── 4 ───────────────────────────────────────────────────────────────────────
out="$(TILLANDSIAS_HOST_KIND=forge "$PLAN" policy consent grant soft-reset -- "${SOFT[@]}" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "refused:consent:not-grantable-in-forge" ] && [ "$(tokens)" = 0 ]; then
    ok "arm 4: with TILLANDSIAS_HOST_KIND=forge the grant is refused:consent:not-grantable-in-forge and writes nothing"
else
    bad "arm 4: rc=$rc out=[$out] tokens=$(tokens)"
fi

# ── 6 ───────────────────────────────────────────────────────────────────────
out="$("$PLAN" policy eval -- tillandsias-plan policy consent grant hard-reset -- wsl --unregister x 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "refused:policy:no-self-consent" ] &&
    ok "arm 6: minting through an agent door is refused:policy:no-self-consent" || bad "arm 6: rc=$rc out=[$out]"

# ── 7 ───────────────────────────────────────────────────────────────────────
out1="$("$PLAN" policy consent grant hard-reset 2>/dev/null)"; rc1=$?
out2="$("$PLAN" policy consent grant everything -- true 2>/dev/null)"; rc2=$?
if [ "$rc1" -eq 1 ] && [ "$out1" = "refused:consent:no-argv" ] &&
    [ "$rc2" -eq 1 ] && [ "$out2" = "refused:consent:unknown-class:everything" ]; then
    ok "arm 7: a grant without an argv, or for an unknown class, is refused by name"
else
    bad "arm 7: [$out1] rc=$rc1 [$out2] rc=$rc2"
fi

# A forge is the container record naming the forge image (1467-c8qg); a
# toolbox or other container has the record too and is NOT a forge.
in_forge=0
[ -r /run/.containerenv ] &&
    /usr/bin/grep -qE '^image="([^"]*/)?tillandsias-forge(:[^"@]*)?(@[^"]*)?"$' /run/.containerenv &&
    in_forge=1
if [ "$in_forge" = 1 ]; then
    # ── 8 (forge only) ──────────────────────────────────────────────────────
    plant "workspace-destroy-planted.json" workspace-destroy "$HOST" "2099-01-01T00:00:00Z"
    out="$("$PLAN" policy eval -- rm -rf /srv/elsewhere 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 4 ] && [ "$out" = "consent:policy:workspace-destroy" ] &&
        [ -e "$TILLANDSIAS_CONSENT_DIR/workspace-destroy-planted.json" ]; then
        ok "arm 8: in a forge a planted token for this host is not honoured and not spent"
    else
        bad "arm 8: rc=$rc out=[$out]"
    fi
    rm -rf "$TILLANDSIAS_CONSENT_DIR"
    skip "arms 1, 2, 3, 5: /run/.containerenv names the forge image, so the evidence says forge and consent is (correctly) never granted here; run on bare metal, and see cargo test -p tillandsias-plan --lib command_policy"
else
    skip "arm 8: not a forge (no container record naming the forge image)"

    # ── 1 ───────────────────────────────────────────────────────────────────
    out="$("$PLAN" policy consent grant soft-reset --ttl 30m -- "${SOFT[@]}" 2>/dev/null)"; rc=$?
    file="$(find "$TILLANDSIAS_CONSENT_DIR" -name '*.json' 2>/dev/null | head -n 1)"
    mode="$( { stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null; } )"
    if [ "$rc" -eq 0 ] && grep -qE '^ok:consent:soft-reset:until=20[0-9-]+T[0-9:]+Z$' <<<"$out" &&
        [ "$(tokens)" = 1 ] && [ "$mode" = 600 ]; then
        ok "arm 1: grant prints $out and writes one 0600 token"
    else
        bad "arm 1: rc=$rc out=[$out] tokens=$(tokens) mode=[$mode]"
    fi

    # ── 2 ───────────────────────────────────────────────────────────────────
    # ORDER 1764-ca9x: `policy eval` is inspection and never spends (87c7e9bdc);
    # the run door is the one that spends. The argv is the STUB podman, so an
    # honoured token runs the stub, never a real reset.
    out="$("$PLAN" policy eval -- "${SOFT[@]}" 2>/dev/null)"; rce=$?
    te="$(tokens)"
    r1="$("$PLAN" run --json -- "${SOFT[@]}" 2>/dev/null)"; rc1=$?
    src="$(jget -r '.consent_source' <<<"$(tail -n 1 "$TILLANDSIAS_POLICY_AUDIT_LOG")" 2>/dev/null)"
    r2="$("$PLAN" run --json -- "${SOFT[@]}" 2>/dev/null)"; rc2=$?
    if [ "$rce" -eq 4 ] && [ "$out" = "consent:policy:soft-reset" ] && [ "$te" = 1 ] &&
        [ "$rc1" -eq 0 ] && [ "$(jget -r '.status' <<<"$r1")" = exited ] &&
        grep -qF 'STUB-podman system reset --force' <<<"$(jget -r '.stdout' <<<"$r1")" && [ "$src" = token ] &&
        [ "$rc2" -eq 4 ] && [ "$(jget -r '.status' <<<"$r2")" = policy_consent ] &&
        grep -qF 'already spent' <<<"$(jget -r '.policy.why' <<<"$r2")"; then
        ok "arm 2: eval inspects without spending; the run door spends the token for ONE run (consent_source=token); the replay asks again and says the token was spent"
    else
        bad "arm 2: eval [$out] rc=$rce tokens=$te; run1 rc=$rc1 [$r1] src=[$src]; run2 rc=$rc2 [$r2]"
    fi

    # ── 3 ───────────────────────────────────────────────────────────────────
    plant "soft-reset-foreign.json" soft-reset "not-$HOST" "2099-01-01T00:00:00Z"
    r="$("$PLAN" run --json -- "${SOFT[@]}" 2>/dev/null)"; rc=$?
    gone1=0; [ -e "$TILLANDSIAS_CONSENT_DIR/soft-reset-foreign.json" ] || gone1=1
    plant "soft-reset-old.json" soft-reset "$HOST" "2020-01-01T00:00:00Z"
    rb="$("$PLAN" run --json -- "${SOFT[@]}" 2>/dev/null)"; rcb=$?
    gone2=0; [ -e "$TILLANDSIAS_CONSENT_DIR/soft-reset-old.json" ] || gone2=1
    if [ "$rc" -eq 1 ] && [ "$(jget -r '.status' <<<"$r")" = policy_denied ] &&
        grep -qF 'minted on another host' <<<"$(jget -r '.policy.why' <<<"$r")" && [ "$gone1" = 1 ] &&
        [ "$rcb" -eq 1 ] && grep -qF 'expired unused' <<<"$(jget -r '.policy.why' <<<"$rb")" && [ "$gone2" = 1 ]; then
        ok "arm 3: foreign-host and expired tokens are refused at the run door, named, and deleted"
    else
        bad "arm 3: foreign rc=$rc [$r] gone=$gone1; expired rc=$rcb [$rb] gone=$gone2"
    fi
    "$PLAN" policy consent grant hard-reset -- "${WSL[@]}" distro-a >/dev/null 2>&1
    r="$("$PLAN" run --json -- "${WSL[@]}" distro-b 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 1 ] && grep -qF 'DIFFERENT argv' <<<"$(jget -r '.policy.why' <<<"$r")" && [ "$(tokens)" = 1 ]; then
        ok "arm 3: a token for a different argv is refused at the run door (argv-mismatch) and kept for its own run"
    else
        bad "arm 3 mismatch: rc=$rc [$r] tokens=$(tokens)"
    fi
    rm -rf "$TILLANDSIAS_CONSENT_DIR"

    # ── 5 ───────────────────────────────────────────────────────────────────
    r="$(TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=smoke-curl-install-and-test-e2e \
        "$PLAN" run --json -- "${SOFT[@]}" 2>/dev/null)"; rc=$?
    src="$(jget -r '.consent_source' <<<"$(tail -n 1 "$TILLANDSIAS_POLICY_AUDIT_LOG")" 2>/dev/null)"
    outi="$(TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=smoke-curl-install-and-test-e2e \
        "$PLAN" policy eval -- "${SOFT[@]}" 2>/dev/null)"; rci=$?
    rn="$(TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 "$PLAN" run --json -- "${SOFT[@]}" 2>/dev/null)"; rcn=$?
    rh="$(TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 TILLANDSIAS_SKILL=smoke-curl-install-and-test-e2e \
        "$PLAN" run --json -- "${WSL[@]}" x 2>/dev/null)"; rch=$?
    if [ "$rc" -eq 0 ] && [ "$(jget -r '.status' <<<"$r")" = exited ] && [ "$src" = env ] &&
        [ "$rci" -eq 4 ] && [ "$outi" = "consent:policy:soft-reset" ] &&
        [ "$rcn" -eq 4 ] && [ "$(jget -r '.policy.rule_id' <<<"$rn")" = soft-reset ] &&
        [ "$rch" -eq 4 ] && [ "$(jget -r '.policy.rule_id' <<<"$rh")" = hard-reset ]; then
        ok "arm 5: the registered smoke skill's env runs soft-reset at the run door (consent_source=env) while eval still only inspects; without the skill it asks; hard-reset never takes it"
    else
        bad "arm 5: run rc=$rc [$r] src=[$src]; eval [$outi] rc=$rci; no skill rc=$rcn [$rn]; hard rc=$rch [$rh]"
    fi

    # ── 9: the run door spends a token for a workspace destroy too ──────────
    mkdir -p "$W/victim"
    "$PLAN" policy consent grant workspace-destroy -- rm -rf "$W/victim" >/dev/null 2>&1
    out="$("$PLAN" run --json -- rm -rf "$W/victim" 2>/dev/null)"; rc=$?
    gone=0; [ -e "$W/victim" ] || gone=1
    mkdir -p "$W/victim"
    out2="$("$PLAN" run --json -- rm -rf "$W/victim" 2>/dev/null)"; rc2=$?
    if [ "$rc" -eq 0 ] && [ "$(jget -r '.status' <<<"$out")" = exited ] && [ "$gone" = 1 ] &&
        [ "$(jget -r '.policy.rule_id' <<<"$out")" = workspace-destroy ] &&
        [ "$rc2" -eq 4 ] && [ "$(jget -r '.status' <<<"$out2")" = policy_consent ] && [ -d "$W/victim" ]; then
        ok "arm 9: the run door spends the token for one run; the next identical run is policy_consent and spawns nothing"
    else
        bad "arm 9: [$out] rc=$rc gone=$gone; [$out2] rc=$rc2"
    fi
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: command-policy-consent $pass/$total skipped=$skipped (1443-9f5w)"
    exit 0
fi
echo "FAIL: command-policy-consent $pass/$total skipped=$skipped (1443-9f5w)"
exit 1
