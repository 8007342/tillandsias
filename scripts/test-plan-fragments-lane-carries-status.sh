#!/usr/bin/env bash
# @trace order:1266-dh2d
#
# The plan-only lane must never report ok while dropping a claim's STATUS
# fragment. MEASURED on esmeraldinha 2026-09-19 (793-zumy): the default
# selection carried a claim's notes and dropped its set-field status
# fragment, so trunk kept offering the claimed row as ready.
#
# THE MECHANISM, reproduced here: trunk gains ANOTHER host's set-field
# fragment after this branch last merged. The base->HEAD diff sees that file
# as deleted, pairs this branch's near-identical new status fragment with it
# as a RENAME, and --diff-filter=A drops it. The notes, whose text differs,
# still ride.
#
# REGIME: a scratch repo with a bare remote. Every run is --dry-run, which
# builds and validates the commit (trunk-fold checks included) and pushes
# nothing.
#
#   1  default selection CARRIES the status fragment in the rename-collision
#      shape, and the stderr note counts 1 status write
#   2  MUTANT with the pre-fix selection (renames on): the status fragment is
#      dropped, and the new status-loss guard REFUSES, naming it (teeth for
#      guard c; also proves the collision really happens here)
#   3  an explicit subset naming only the note is refused as status-loss
#   4  MUTATION ARM: explicit note + status is accepted, so the guard does not
#      simply always refuse
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/push-plan-fragments-to-trunk.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ]; then
    echo "skip:plan-fragments-lane-carries-status:no-plan-binary (build one: cargo build --release -p tillandsias-plan)"
    exit 0
fi
export TILLANDSIAS_PLAN_BIN="$PLAN"
export TILLANDSIAS_AGENT_ID="windows-fixture-claude-20200101t000000z"
export GIT_TERMINAL_PROMPT=0

W="$(mktemp -d "${TMPDIR:-/tmp}/lane-carries-status.XXXXXX")"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$W"' EXIT INT TERM
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.autocrlf false
mkdir -p scripts plan/index.d plan/loop_status.d
cp "$HELPER" scripts/push-plan-fragments-to-trunk.sh
for f in plan-binary-probe.sh agent-identity.sh common.sh gate-stamp.sh; do
    cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true
    [ -f "scripts/$f" ] || { echo "FAIL: fixture scratch is missing scripts/$f"; exit 2; }
done
cat > plan/index.yaml <<'EOF'
packets:
  - packet_id: fixture-packet-one-claimed-by-another-host-on-trunk
    order: 1-aaaa
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: windows
    title: fixture packet one
    unscoreable: "fixture packet; not scored"
  - packet_id: fixture-packet-two-claimed-on-this-branch
    order: 2-bbbb
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: windows
    title: fixture packet two
    unscoreable: "fixture packet; not scored"
EOF
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

# This branch forks here, BEFORE trunk moves.
G checkout -q -b windows-next

# Trunk moves: ANOTHER host claims 1-aaaa with a set-field fragment.
G checkout -q linux-next
"$PLAN" --index plan/index.yaml set-field 1-aaaa status in_progress --host other-host --reason "claimed elsewhere" >/dev/null 2>&1
G add plan/index.d >/dev/null; G commit -q -m "claim(1-aaaa): other-host"
git push -q origin linux-next
G checkout -q windows-next

# This branch claims 2-bbbb: a status fragment and a note, both committed.
"$PLAN" --index plan/index.yaml set-field 2-bbbb status in_progress --host fixture --reason "claimed here" >/dev/null 2>&1
status_frag="$(git ls-files --others --exclude-standard plan/index.d | head -n 1)"
printf '%s\n' "fixture note on the claimed row" > "$W/note.txt"
"$PLAN" --index plan/index.yaml append-event 2-bbbb note --summary-file "$W/note.txt" --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --host fixture --agent "$TILLANDSIAS_AGENT_ID" >/dev/null 2>&1
note_frag="$(git ls-files --others --exclude-standard plan/index.d | grep -vxF "$status_frag" | head -n 1)"
G add plan/index.d >/dev/null; G commit -q -m "claim(2-bbbb): fixture"
git fetch -q origin
if [ -z "$status_frag" ] || [ -z "$note_frag" ]; then
    bad "setup: set-field or append-event wrote no fragment (status=[$status_frag] note=[$note_frag])"
    echo "violation:plan-fragments-lane-carries-status:$pass/$((pass+fail))"; exit 1
fi

# 1
out="$(bash scripts/push-plan-fragments-to-trunk.sh --dry-run 2>"$W/err1")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^ok:fragments-to-trunk:dry-run:' <<<"$out" \
   && grep -qF "$(basename "$status_frag")" "$W/err1" \
   && grep -q 'carrying 2 fragment(s), 1 writing a status field' "$W/err1"; then
    ok "arm 1: the default selection carries the status fragment through the rename collision (2 carried, 1 status write)"
else
    bad "arm 1: rc=$rc out=[$out] err=[$(tr '\n' ' ' < "$W/err1" | cut -c1-400)]"
fi

# 2
sed 's/git diff --no-renames /git diff /' scripts/push-plan-fragments-to-trunk.sh > "$W/mutant.sh"
n_mut="$(grep -c 'git diff --no-renames ' "$W/mutant.sh")"
out="$(bash "$W/mutant.sh" --dry-run 2>"$W/err2")"; rc=$?
if [ "$n_mut" -ne 0 ]; then
    bad "arm 2: the mutation did not land ($n_mut --no-renames left)"
elif [ "$rc" -ne 0 ] && grep -q '^refused:fragments-to-trunk:trunk-fold:status-loss:fixture-packet-two-claimed-on-this-branch$' <<<"$out" \
     && grep -qF "$status_frag" "$W/err2"; then
    ok "arm 2: with renames on, the collision drops the status fragment and the new guard refuses, naming it"
else
    bad "arm 2: rc=$rc out=[$out] err=[$(tr '\n' ' ' < "$W/err2" | cut -c1-400)]"
fi

# 3
out="$(bash scripts/push-plan-fragments-to-trunk.sh --dry-run "$note_frag" 2>"$W/err3")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^refused:fragments-to-trunk:trunk-fold:status-loss:' <<<"$out"; then
    ok "arm 3: an explicit subset without the status fragment is refused as status-loss"
else
    bad "arm 3: rc=$rc out=[$out]"
fi

# 4
out="$(bash scripts/push-plan-fragments-to-trunk.sh --dry-run "$note_frag" "$status_frag" 2>"$W/err4")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^ok:fragments-to-trunk:dry-run:' <<<"$out"; then
    ok "arm 4: note and status together are accepted (the guard does not always refuse)"
else
    bad "arm 4: rc=$rc out=[$out] err=[$(tr '\n' ' ' < "$W/err4" | cut -c1-300)]"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:plan-fragments-lane-carries-status:$pass/$total"; exit 0; fi
echo "violation:plan-fragments-lane-carries-status:$pass/$total"; exit 1
