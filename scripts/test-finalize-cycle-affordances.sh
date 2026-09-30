#!/usr/bin/env bash
# @trace order:1504-4tty, order:1247-amcu
#
# test-finalize-cycle-affordances.sh — every refused:finalize:* verdict of
# finalize-cycle.sh says why and what clears it, keeps its token and exit
# code, and an actionable remedy is carried out and clears its refusal.
#
# HERMETIC: finalize-cycle.sh is copied into a scratch repository whose
# collaborators are stubs (the boundary guard refuses while the tree is dirty;
# land, record and the claims report succeed). HOME and system git config
# point into the scratch dir. Nothing touches this checkout or any remote.
#
# Arms:
#   1 AUDIT     the slice-4 audit counts 0 bare sites in finalize-cycle.sh
#   2 CONTRACT  the nine verdict tokens and their exit codes are unchanged
#   3 REMEDY    boundary-verify-failed is reproduced with a stray file, the
#               action its remedy names is carried out (commit this cycle's
#               changes), and the re-run passes that step and completes.
#               NEGATIVE CONTROL: re-running without it still refuses (rc 3).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FC="$ROOT/scripts/finalize-cycle.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

# ── ARM 1 ────────────────────────────────────────────────────────────────
audit="$(bash "$ROOT/scripts/check-refusal-affordance-added.sh" --audit 2>/dev/null)"
bare="$(grep -c '^bare scripts/finalize-cycle.sh:' <<<"$audit")"
covered="$(grep -c '^covered scripts/finalize-cycle.sh:' <<<"$audit")"
if [ "$bare" -eq 0 ] && [ "$covered" -ge 9 ]; then
    ok "ARM1 0 bare verdict sites in finalize-cycle.sh ($covered covered; pre-fix 9 bare)"
else bad "ARM1 bare=$bare covered=$covered"; fi

# ── ARM 2 ────────────────────────────────────────────────────────────────
contract="no-boundary-state:2 boundary-verify-failed:3 work-land-failed:6 boundary-verify-failed-post-land:3 record-failed:4 commit-failed:5 ledger-land-failed:6 boundary-verify-failed-post-record:3"
missing=""
for pair in $contract; do
    tok="${pair%%:*}"; code="${pair#*:}"
    # the verdict line, then the exit that follows it within two lines
    awk -v t="refused:finalize:$tok\"" -v t2="refused:finalize:$tok " -v c="exit $code" '
        index($0, t) || index($0, t2) { w = 3 } w > 0 { if (index($0, c)) found = 1; w-- }
        END { exit found ? 0 : 1 }' "$FC" || missing="$missing $tok:$code"
done
[ -z "$missing" ] && ok "ARM2 every verdict keeps its token and exit code" || bad "ARM2 changed:$missing"

# ── ARM 3 ────────────────────────────────────────────────────────────────
W="$(mktemp -d "${TMPDIR:-/tmp}/finalize-afford.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
R="$W/root"; mkdir -p "$R/scripts" "$R/plan/mo-full-attestations.d"
cp "$FC" "$R/scripts/finalize-cycle.sh"
cat > "$R/scripts/meta-orchestration-worktree-guard.sh" <<'EOF'
#!/bin/sh
# stub: the boundary holds exactly when nothing is uncommitted
[ -z "$(git status --porcelain)" ]
EOF
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/report-held-claims.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/scripts/land-on-platform-branch.sh"
printf '#!/bin/sh\ncase "$1" in record) echo "MO-FULL: COMPLETE stub" ;; *) echo "MO-FULL: marker" ;; esac\n' > "$R/scripts/mo-full-attest.sh"
chmod +x "$R"/scripts/*.sh
git init -q -b linux-next "$R"
git -C "$R" config user.email f@f; git -C "$R" config user.name f
git -C "$R" add -A; git -C "$R" commit -qm base
mkdir -p "$W/boundary"; printf '%s' "$W/boundary" > "$(git -C "$R" rev-parse --absolute-git-dir)/boundary-state"
echo stray > "$R/cycle-output.txt"   # the cycle's own, uncommitted change

fin() { ( cd "$R" && bash scripts/finalize-cycle.sh linux-next 2>"$W/err" ); }
out1="$(fin)"; rc1=$?
if [ "$rc1" -eq 3 ] && grep -q 'refused:finalize:boundary-verify-failed' "$W/err" \
   && grep -q '  remedy: run git status: commit' "$W/err"; then
    fin >/dev/null; rc_nc=$?                                  # negative control
    git -C "$R" add -A && git -C "$R" commit -qm "the cycle's own change"   # the remedy's action
    out2="$(fin)"; rc2=$?
    if [ "$rc_nc" -eq 3 ] && [ "$rc2" -eq 0 ] && ! grep -q 'refused:finalize' "$W/err"; then
        ok "ARM3 the remedy clears boundary-verify-failed (re-run rc=0); without it the refusal stands (rc=3)"
    else bad "ARM3 negative-control rc=$rc_nc after-remedy rc=$rc2 err='$(tr '\n' '|' < "$W/err")'"; fi
else bad "ARM3 could not reproduce boundary-verify-failed with its remedy: rc=$rc1 err='$(tr '\n' '|' < "$W/err")'"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: finalize-cycle-affordances (1504-4tty)"; exit 0; }
echo "FAILED: finalize-cycle-affordances (1504-4tty)"; exit 1
