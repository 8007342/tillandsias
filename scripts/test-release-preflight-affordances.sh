#!/usr/bin/env bash
# @trace order:1505-hedu, order:1247-amcu
#
# test-release-preflight-affordances.sh — every blocked: verdict of
# release-preflight.sh says why and what clears it, keeps its token and exit
# code, and an actionable remedy is carried out and clears its refusal.
#
# HERMETIC: release-preflight.sh and plan-binary-probe.sh are copied into a
# scratch repository. Gate 1's monotonicity script is a stub that passes;
# there is no built binary (Gate 2 has nothing to inspect), and the scratch
# ledger is a minimal valid one (Gate 3 passes whether or not a plan binary
# resolves from PATH), so Gate 4 is reached. HOME and system git config
# point into the scratch dir; TILLANDSIAS_PLAN_BIN is unset.
#
# Arms:
#   1 AUDIT     the slice-4 audit counts 0 bare sites in release-preflight.sh
#   2 CONTRACT  the ten verdict tokens and their exit codes are unchanged
#   3 REMEDY    blocked:unsanctioned-workflow is reproduced, the remedy it
#               prints (git rm the listed workflow) is carried out, and the
#               re-run no longer refuses with that token. NEGATIVE CONTROL:
#               without it the refusal stands
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RP="$ROOT/scripts/release-preflight.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

# ── ARM 1 ────────────────────────────────────────────────────────────────
audit="$(bash "$ROOT/scripts/check-refusal-affordance-added.sh" --audit 2>/dev/null)"
bare="$(grep -c '^bare scripts/release-preflight.sh:' <<<"$audit")"
covered="$(grep -c '^covered scripts/release-preflight.sh:' <<<"$audit")"
if [ "$bare" -eq 0 ] && [ "$covered" -ge 10 ]; then
    ok "ARM1 0 bare verdict sites in release-preflight.sh ($covered covered; pre-fix 10 bare)"
else bad "ARM1 bare=$bare covered=$covered"; fi

# ── ARM 2 ────────────────────────────────────────────────────────────────
contract="not-a-git-repo:2 cannot-enter-repo-root:2 version-not-monotonic:1 version-monotonic-script-missing:1 retired-flag-advertised:1 retired-flag-in-usage-text:1 plan-ledger-incomplete:1 plan-ledger-invalid:1 unsanctioned-workflow:1"
missing=""
for pair in $contract; do
    tok="${pair%%:*}"; code="${pair#*:}"
    awk -v t="blocked:$tok\"" -v c="exit $code" '
        index($0, t) { w = 3 } w > 0 { if (index($0, c)) found = 1; w-- }
        END { exit found ? 0 : 1 }' "$RP" || missing="$missing $tok:$code"
done
[ -z "$missing" ] && ok "ARM2 every verdict keeps its token and exit code" || bad "ARM2 changed:$missing"

# ── ARM 3 ────────────────────────────────────────────────────────────────
W="$(mktemp -d "${TMPDIR:-/tmp}/release-afford.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
unset TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR
R="$W/root"; mkdir -p "$R/scripts" "$R/.github/workflows" "$R/plan/index.d"
printf 'plan_index:\n  steps: []\n' > "$R/plan/index.yaml"
cp "$RP" "$ROOT/scripts/plan-binary-probe.sh" "$R/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/verify-version-monotonic.sh"
chmod +x "$R"/scripts/*.sh
printf 'name: release\n' > "$R/.github/workflows/release.yml"
printf 'name: nightly\n' > "$R/.github/workflows/nightly.yml"   # the unsanctioned one
git init -q -b linux-next "$R"
git -C "$R" config user.email f@f; git -C "$R" config user.name f
git -C "$R" add -A; git -C "$R" commit -qm base

pre() { ( cd "$R" && bash scripts/release-preflight.sh >"$W/out" 2>"$W/err" ); }
pre; rc1=$?
if [ "$rc1" -eq 1 ] && grep -q 'blocked:unsanctioned-workflow' "$W/out" \
   && grep -q '  remedy: remove the workflow files listed above' "$W/err"; then
    pre; rc_nc=$?; grep -q 'blocked:unsanctioned-workflow' "$W/out"; still=$?   # negative control
    git -C "$R" rm -q .github/workflows/nightly.yml && git -C "$R" commit -qm "remove unsanctioned workflow"   # the remedy
    pre; rc2=$?
    if [ "$still" -eq 0 ] && ! grep -q 'blocked:unsanctioned-workflow' "$W/out"; then
        ok "ARM3 carrying out the remedy clears unsanctioned-workflow (re-run rc=$rc2, later gates may still speak); without it the refusal stands"
    else bad "ARM3 negative-control still=$still after rc=$rc2 out='$(tr '\n' '|' < "$W/out")'"; fi
else bad "ARM3 could not reproduce unsanctioned-workflow with its remedy: rc=$rc1 out='$(tr '\n' '|' < "$W/out")' err='$(tail -3 "$W/err" | tr '\n' '|')'"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: release-preflight-affordances (1505-hedu)"; exit 0; }
echo "FAILED: release-preflight-affordances (1505-hedu)"; exit 1
