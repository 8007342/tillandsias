#!/usr/bin/env bash
# test-start-a-new-project-skill.sh — order 1705-bgen.
#
# The end-user onboarding skill must exist, reach a forge on ANY project, set
# a new project up without overwriting anything, and speak to end users
# without Tillandsias-internal vocabulary.
#
# ARM 1 the skill and its scaffold exist in canonical skills/
# ARM 2 agent-profile.sh links it into a non-Tillandsias forge's harness dirs
# ARM 3 in an empty repo the scaffold creates openspec/, plan/ and README.md
# ARM 4 a second run creates nothing, and an existing README.md is kept
# ARM 5 --no-specs creates no openspec/; a usage error exits 2
# ARM 6 SKILL.md and every created file carry no internal vocabulary
#
# Prints ok:start-a-new-project-skill:<n> or FAIL lines and exits 1.
#
# @trace spec:project-bootstrap-readme
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/start-a-new-project"
W="$(mktemp -d "${TMPDIR:-/tmp}/start-a-new-project.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0 failed=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

# Internal words an end user must never be shown.
INTERNAL='plan_answer|methodology_ask|methodology|cheatsheet|@trace|litmus|centicolon|tillandsias-plan|\bmcp\b|git mirror'

# ARM 1
if [ -f "$SKILL/SKILL.md" ] && [ -f "$SKILL/scaffold.sh" ] \
    && grep -q '^name: start-a-new-project$' "$SKILL/SKILL.md"; then
    ok "ARM 1: skills/start-a-new-project carries SKILL.md and scaffold.sh"
else
    bad "ARM 1: skills/start-a-new-project/SKILL.md or scaffold.sh missing"
fi

# ARM 2: the forge's agent profile links generic skills from /opt/skills.
H="$W/home"; mkdir -p "$H" "$W/opt-skills"
cp -R "$SKILL" "$W/opt-skills/" 2>/dev/null
if (HOME="$H" TILLANDSIAS_SHARED_SKILLS_ROOT="$W/opt-skills" \
        bash -c 'set -e; . "$1" >/dev/null 2>&1' _ "$ROOT/images/default/config-overlay/mcp/agent-profile.sh") \
    && [ -L "$H/.claude/skills/start-a-new-project" ] \
    && [ -L "$H/.codex/skills/start-a-new-project" ] \
    && [ -L "$H/.config/opencode/skills/start-a-new-project" ]; then
    ok "ARM 2: a forge on any project links start-a-new-project for Claude Code, Codex and OpenCode"
else
    bad "ARM 2: agent-profile.sh did not link start-a-new-project into every harness's skill dir"
fi

# ARM 3: an empty repo, with no openspec CLI on PATH (the files are enough).
P="$W/proj"; mkdir -p "$P"; git -C "$P" init -q 2>/dev/null
NOCLI="$W/bin"; mkdir -p "$NOCLI"
for t in bash cat mkdir dirname tr sed git env; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$NOCLI/$t"
done
out="$(PATH="$NOCLI" bash "$SKILL/scaffold.sh" --dir "$P" --name "Pong Party" \
    --summary "A two-player pong game for phones." --stack flutter-flame 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$P/README.md" ] && [ -f "$P/openspec/project.md" ] \
    && [ -f "$P/openspec/specs/pong-party/spec.md" ] && [ -f "$P/plan/README.md" ] \
    && [ -f "$P/plan/roadmap.md" ] && [ -f "$P/research/README.md" ] && grep -q 'Flame' "$P/README.md" \
    && grep -qx 'ok:scaffold:6' <<<"$out"; then
    ok "ARM 3: an empty repo gains openspec/, plan/, research/ and README.md (ok:scaffold:6)"
else
    bad "ARM 3: rc=$rc out='$(tail -3 <<<"$out" | tr '\n' ' ')'"
fi

# ARM 4: idempotent, and the user's own README is never overwritten.
printf 'mine\n' > "$W/readme.keep"
P2="$W/proj2"; mkdir -p "$P2"; cp "$W/readme.keep" "$P2/README.md"
PATH="$NOCLI" bash "$SKILL/scaffold.sh" --dir "$P2" --name A --summary B >/dev/null 2>&1
out2="$(PATH="$NOCLI" bash "$SKILL/scaffold.sh" --dir "$P2" --name A --summary B 2>&1)"
if cmp -s "$P2/README.md" "$W/readme.keep" && grep -qx 'ok:scaffold:0' <<<"$out2"; then
    ok "ARM 4: a second run creates nothing and an existing README.md is kept"
else
    bad "ARM 4: README overwritten or second run created files: '$(tail -1 <<<"$out2")'"
fi

# ARM 5
P3="$W/proj3"; mkdir -p "$P3"
PATH="$NOCLI" bash "$SKILL/scaffold.sh" --dir "$P3" --name A --summary B --no-specs >/dev/null 2>&1
bash "$SKILL/scaffold.sh" --name A >/dev/null 2>&1; urc=$?
if [ ! -e "$P3/openspec" ] && [ -f "$P3/plan/roadmap.md" ] && [ "$urc" -eq 2 ]; then
    ok "ARM 5: --no-specs creates no openspec/, and a usage error exits 2"
else
    bad "ARM 5: openspec=$([ -e "$P3/openspec" ] && echo present || echo absent) usage_rc=$urc"
fi

# ARM 6
hits="$(grep -n -i -E "$INTERNAL" "$SKILL/SKILL.md" 2>/dev/null; \
    find "$P" -path "$P/.git" -prune -o -type f -print0 | xargs -0 grep -n -i -E "$INTERNAL" 2>/dev/null)"
if [ -f "$SKILL/SKILL.md" ] && [ -f "$P/README.md" ] && [ -f "$P/plan/roadmap.md" ] && [ -z "$hits" ]; then
    ok "ARM 6: SKILL.md and the created files carry no internal vocabulary"
else
    bad "ARM 6: nothing to scan, or internal vocabulary shown to the user: $(head -3 <<<"$hits" | tr '\n' ' ')"
fi

if [ "$failed" -eq 0 ]; then
    echo "ok:start-a-new-project-skill:$pass"
    exit 0
fi
echo "FAIL: start-a-new-project skill $pass passed, $failed failed (1705-bgen)"
exit 1
