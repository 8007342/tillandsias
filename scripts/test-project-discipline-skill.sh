#!/usr/bin/env bash
# @trace order:1446-qkx4, spec:branch-discipline
#
# Fixture for skills/project-discipline (order 1446-qkx4), the skill every
# discipline refusal names ("use /project-discipline for instructions").
#
#   1. the skill exists, is registered in methodology.yaml shared_skills, and
#      scripts/check-skills-single-source.sh stays green;
#   2. its FIRST command block runs `tillandsias-plan discipline show` and
#      `discipline derive`, and its ladder names the operator's three rungs;
#   3. every hook-template refusal family of 1446-xqi6 has a section whose
#      heading is that family (`hook:<event>`), seven in all;
#   4. the forge wiring: sourcing images/default/config-overlay/mcp/
#      agent-profile.sh (as every forge entrypoint does, under set -euo
#      pipefail) links the skill into each harness's USER skill directory for
#      a project with no scripts/ at all, is idempotent, and never overwrites
#      an entry that is already there.
#
# PRE-FIX RESULT: FAILS at arm 1 — there was no such skill, and nothing linked
# /opt/skills anywhere a harness looks.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/project-discipline/SKILL.md"
PROFILE="$ROOT/images/default/config-overlay/mcp/agent-profile.sh"
pass=0; total=4
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/project-discipline-skill.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# 1 — exists, registered, single-sourced.
reg="$(awk '/^  shared_skills:/{s=1} s&&/^      project-discipline:$/{f=1} f&&/path: skills\/project-discipline\/SKILL.md/{print "yes"; exit}' "$ROOT/methodology.yaml")"
single="$(bash "$ROOT/scripts/check-skills-single-source.sh" 2>/dev/null)"; single_rc=$?
if [ -f "$SKILL" ] && [ "$reg" = "yes" ] && [ "$single_rc" -eq 0 ] && [ "${single#ok:skills-single-source}" != "$single" ]; then
    ok "arm 1: skill exists, registered in methodology.yaml shared_skills, $single"
else
    bad "arm 1: file=$([ -f "$SKILL" ] && echo yes || echo no) registered=${reg:-no} single-source rc=$single_rc [$single]"
fi

# 2 — the first command block asks the project; the ladder names three rungs.
first_block="$(awk '/^```/{n++; next} n==1{print} n>=2{exit}' "$SKILL")"
arm2=1
grep -q 'tillandsias-plan discipline show' <<<"$first_block" || arm2=0
grep -q 'tillandsias-plan discipline derive' <<<"$first_block" || arm2=0
grep -q '^| \*\*0\*\* |.*Push to main freely' "$SKILL" || arm2=0
grep -q '^| \*\*1\*\* |.*integration branch and pull requests' "$SKILL" || arm2=0
grep -q '^| \*\*2\*\* |.*Work refs into the integration branch' "$SKILL" || arm2=0
if [ "$arm2" = 1 ]; then
    ok "arm 2: first command block runs discipline show + derive; ladder names levels 0, 1, 2"
else
    bad "arm 2: first block=[$first_block]"
fi

# 3 — one section per hook-template refusal family (1446-xqi6's seven events).
missing=""
for ev in pre-commit post-commit pre-push post-merge post-checkout pre-receive post-receive; do
    grep -q "^### \`hook:$ev\`\$" "$SKILL" || missing="$missing $ev"
done
if [ -z "$missing" ]; then
    ok "arm 3: all seven hook refusal families have a section (hook:<event>)"
else
    bad "arm 3: no section for:$missing"
fi

# 4 — the forge links it for any project, idempotently, without clobbering.
H="$W/home"; P="$W/some-project"; mkdir -p "$H/.codex/skills/project-discipline" "$P"   # a user-owned entry
: > "$H/.codex/skills/project-discipline/SKILL.md"
src="$(cd "$P" && HOME="$H" TILLANDSIAS_SHARED_SKILLS_ROOT="$ROOT/skills" TILLANDSIAS_AGENT=claude \
       bash -c 'set -euo pipefail; source "$1"; source "$1"; echo sourced' _ "$PROFILE" 2>&1)"; src_rc=$?
arm4=1; detail=""
[ "$src_rc" -eq 0 ] && [ "${src##*$'\n'}" = "sourced" ] || { arm4=0; detail="$detail source rc=$src_rc [$src]"; }
for d in .claude/skills .gemini/skills .config/opencode/skill; do
    [ -L "$H/$d/project-discipline" ] && [ -f "$H/$d/project-discipline/SKILL.md" ] || { arm4=0; detail="$detail missing:$d"; }
done
[ ! -L "$H/.codex/skills/project-discipline" ] || { arm4=0; detail="$detail clobbered:.codex"; }
[ ! -e "$P/scripts" ] || { arm4=0; detail="$detail project-has-scripts"; }
if [ "$arm4" = 1 ]; then
    ok "arm 4: sourcing agent-profile.sh (twice, set -euo pipefail) links the skill for a project with no scripts/, and leaves a user-owned entry alone"
else
    bad "arm 4:$detail"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:project-discipline-skill:$pass/$total"
    exit 0
fi
echo "fail:project-discipline-skill:$pass/$total"
exit 1
