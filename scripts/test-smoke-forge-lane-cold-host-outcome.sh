#!/usr/bin/env bash
# test-smoke-forge-lane-cold-host-outcome.sh — order 1190-swen
#
# §2 of the smoke runbook resets the substrate, so Vault is COLD and holds no
# GitHub token. The in-forge lane therefore reaches the Credential Channel Guard
# and hard-stops there, deterministically, before any committable work. That is
# the CORRECT outcome on a post-reset host — but the lane still exits 0, and a
# reader who takes `opencode_exit=0` as the pass condition concludes the forge
# did a cycle's worth of work. It did not; it could not have.
#
# Coordinator ruling 2026-09-14, option (a): the guard-stop IS §4's expected
# cold-host outcome. Option (b) — a scoped token after §3 — was declined,
# because a clean room that holds a credential is not a clean room.
#
# MEASURED on pirria 2026-09-14 (04-opencode.log:848-862).
#
# HERMETIC: synthesises lane logs under mktemp. Never launches a forge, never
# touches podman, and needs no toolchain — this is floor-host work by design.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNBOOK="$ROOT/skills/smoke-curl-install-and-test-e2e/SKILL.md"
fails=0
step() { printf '  %-58s %s\n' "$1" "$2"; [ "$2" = PASS ] || fails=$((fails + 1)); }

echo "test-smoke-forge-lane-cold-host-outcome (1190-swen)"

# The predicate the runbook tells the operator to assert. Kept here in ONE
# place so the fixture and the runbook cannot drift into two different rules.
GUARD_RE='blocked:upstream-(no-credential|auth-unpublished)'

cold_host_verdict() { # <lane-log> <lane-exit> -> prints PASS-token or FINDING
    if grep -qE "$GUARD_RE" "$1"; then
        echo "cold-host-pass"
    else
        echo "finding-no-guard-stop"
    fi
}

# ── STEP 1: the runbook carries the assertion and the ruling ──────────────────
if grep -q '4a-cold' "$RUNBOOK" \
   && grep -qE "$GUARD_RE" "$RUNBOOK" \
   && grep -q 'forge_lane_outcome' "$RUNBOOK"; then
    step "runbook carries §4a-cold and forge_lane_outcome" PASS
else
    step "runbook carries §4a-cold and forge_lane_outcome" FAIL
fi

# The old wording is the sentence this packet exists to remove. If it comes
# back, this fixture should say so rather than pass quietly.
if grep -q 'init clean, forge run clean' "$RUNBOOK"; then
    step "the 'forge run clean' PASS wording is gone" FAIL
    echo "      the runbook still tells the operator to write 'forge run clean'"
else
    step "the 'forge run clean' PASS wording is gone" PASS
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/smoke-cold-host.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT

# ── STEP 2: a real cold-host lane log PASSES ──────────────────────────────────
cat > "$tmp/cold.log" <<'LOG'
tillandsias forge lane starting
enclave: vault proxy router git inference forge up
scripts/check-credential-channel.sh
blocked:upstream-no-credential
agent: claimed nothing, drained nothing, filed nothing, committed nothing
LOG
if [ "$(cold_host_verdict "$tmp/cold.log" 0)" = cold-host-pass ]; then
    step "cold-host lane log reads as PASS" PASS
else
    step "cold-host lane log reads as PASS" FAIL
fi

# ── STEP 3: NEGATIVE CONTROL — exit 0 WITHOUT the guard line FAILS ────────────
# This is the whole packet. The two signals are independent, and only the
# second is evidence. A fixture that omitted this would pass a lane that
# skipped the guard entirely.
cat > "$tmp/exit0-no-guard.log" <<'LOG'
tillandsias forge lane starting
enclave: vault proxy router git inference forge up
agent: ran a cycle
LOG
if [ "$(cold_host_verdict "$tmp/exit0-no-guard.log" 0)" = finding-no-guard-stop ]; then
    step "NEGATIVE CONTROL: exit 0 without the guard line FAILS" PASS
else
    step "NEGATIVE CONTROL: exit 0 without the guard line FAILS" FAIL
    echo "      a lane that never reached the guard was accepted as a pass"
fi

# ── STEP 4: the verdict does not depend on the exit code at all ───────────────
# Stated as its own step because 'exit 0 and a guard-stop are the same number'
# is the sentence the runbook now carries, and a rule that quietly consulted
# the exit code would contradict it while still passing step 3.
v_zero="$(cold_host_verdict "$tmp/cold.log" 0)"
v_one="$(cold_host_verdict "$tmp/cold.log" 1)"
if [ "$v_zero" = "$v_one" ]; then
    step "verdict is independent of the lane exit code" PASS
else
    step "verdict is independent of the lane exit code" FAIL
    echo "      exit 0 -> $v_zero but exit 1 -> $v_one"
fi

# ── STEP 5: the ABSENT MO-FULL marker is the correct cold-host residue ────────
# A lane that stopped at the guard has not completed its exit contract and must
# not claim it did; the missing marker is the loud part, so assert its absence
# rather than tolerating it.
if grep -qE '^MO-FULL: ' "$tmp/cold.log"; then
    step "cold-host lane emits NO MO-FULL marker" FAIL
else
    step "cold-host lane emits NO MO-FULL marker" PASS
fi

cat > "$tmp/warm.log" <<'LOG'
tillandsias forge lane starting
ok:gh-keyring-push-verified
MO-FULL: COMPLETE deadbeef linux-next deadbeef
LOG
if [ "$(cold_host_verdict "$tmp/warm.log" 0)" = finding-no-guard-stop ] \
   && grep -qE '^MO-FULL: ' "$tmp/warm.log"; then
    step "a warm-room lane is reported as a FINDING, not a pass" PASS
else
    step "a warm-room lane is reported as a FINDING, not a pass" FAIL
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ok:smoke-forge-lane-cold-host-outcome:7 step(s)"
    exit 0
fi
echo "fail:smoke-forge-lane-cold-host-outcome:$fails step(s) failed"
exit 1
