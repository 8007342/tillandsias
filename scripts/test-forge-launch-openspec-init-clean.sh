#!/usr/bin/env bash
# @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 1422-w3p8)
#
# Fixture for openspec_init_if_absent (images/default/lib-common.sh).
#
# WHY THIS EXISTS — every forge entrypoint ran `openspec init` against the
# project checkout at launch with a CLI refreshed to @latest, so the first
# launch after any openspec release rewrote the committed /opsx set and the
# forge started DIRTY (18 tracked files at t=0, twice, on 2026-09-26/27).
# Operator ruling 2026-09-27: a launch must land on a clean checkout.
#
# The stub CLI below behaves like a NEWER openspec: init for a tool rewrites
# that tool's set, bare init rewrites every configured tool. Case 1 is the
# load-bearing one: it reproduces the dirt with the pre-fix call, then proves
# the helper leaves `git status --porcelain` empty. If case 1 cannot fail,
# this fixture is decorative.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
trace_lifecycle() { :; }

command -v git >/dev/null 2>&1 || { echo "skip:forge-launch-openspec-init-clean:no-git"; exit 0; }
[ -r "$LIB" ] || fail "cannot read $LIB"

# Load only the function under test — sourcing all of lib-common.sh would run
# forge-container setup that must not execute on a build host.
eval "$(sed -n '/^openspec_init_if_absent()/,/^}/p' "$LIB")"
command -v openspec_init_if_absent >/dev/null 2>&1 \
    || fail "could not load openspec_init_if_absent from lib-common.sh"

# ── stub CLI: a newer openspec release ───────────────────────────────────────
OS_BIN="$WORK/openspec"
cat >"$OS_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = init ] || exit 2
gen() {
    case "$1" in
        claude)   mkdir -p .claude/commands/opsx .claude/skills/openspec-explore
                  echo 'generatedBy: "NEW"' > .claude/commands/opsx/explore.md
                  echo 'generatedBy: "NEW"' > .claude/skills/openspec-explore/SKILL.md ;;
        opencode) mkdir -p .opencode/commands .opencode/skills/openspec-explore
                  echo 'generatedBy: "NEW"' > .opencode/commands/opsx-explore.md
                  echo 'generatedBy: "NEW"' > .opencode/skills/openspec-explore/SKILL.md ;;
    esac
    mkdir -p openspec; [ -e openspec/config.yaml ] || echo 'schema: x' > openspec/config.yaml
}
if [ "${2:-}" = --tools ]; then gen "$3"; exit 0; fi
# bare init: refresh every tool already configured; none configured -> error
n=0
[ -d .claude/commands/opsx ] && { gen claude; n=1; }
[ -d .opencode/commands ] && { gen opencode; n=1; }
[ "$n" = 1 ] || { echo "No tools detected. Use --tools" >&2; exit 1; }
STUB
chmod +x "$OS_BIN"

# A checkout whose committed /opsx sets came from an OLDER CLI.
make_repo() {
    local d="$1"
    mkdir -p "$d/.claude/commands/opsx" "$d/.claude/skills/openspec-explore" \
             "$d/.opencode/commands" "$d/.opencode/skills/openspec-explore" "$d/openspec"
    for f in .claude/commands/opsx/explore.md .claude/skills/openspec-explore/SKILL.md \
             .opencode/commands/opsx-explore.md .opencode/skills/openspec-explore/SKILL.md; do
        echo 'generatedBy: "OLD"' > "$d/$f"
    done
    echo 'schema: x' > "$d/openspec/config.yaml"
    git -C "$d" init -q .
    git -C "$d" add -A >/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
}
porcelain() { git -C "$1" status --porcelain --untracked-files=all; }

# ── case 1: pre-fix call dirties; helper leaves the tree clean ───────────────
R="$WORK/prefix"; make_repo "$R"
(cd "$R" && "$OS_BIN" init --tools claude </dev/null >/dev/null 2>&1)
[ -n "$(porcelain "$R")" ] || fail "case1: stub did not reproduce the launch dirt — fixture is decorative"
for tool in claude opencode ""; do
    R="$WORK/fixed-${tool:-bare}"; make_repo "$R"
    openspec_init_if_absent "$R" $tool
    [ -z "$(porcelain "$R")" ] || fail "case1(${tool:-bare}): launch dirtied the checkout: $(porcelain "$R" | tr '\n' ' ')"
done
echo "case 1 ok: committed /opsx sets untouched for claude, opencode and bare launches"

# ── case 2: a tool whose set is absent still gets its /opsx commands ────────
R="$WORK/absent"; make_repo "$R"
git -C "$R" rm -rq .opencode && git -C "$R" -c user.email=t@t -c user.name=t commit -qm drop
openspec_init_if_absent "$R" opencode
[ -f "$R/.opencode/commands/opsx-explore.md" ] || fail "case2: absent opencode set was not generated"
[ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ] \
    || fail "case2: generating an absent set modified tracked files"
echo "case 2 ok: absent set generated as new files only"

# ── case 3: no project dir / no CLI is a silent no-op ───────────────────────
( OS_BIN=""; openspec_init_if_absent "$WORK/prefix" claude ) || fail "case3: missing CLI must not fail"
openspec_init_if_absent "" claude || fail "case3: empty project dir must not fail"
echo "case 3 ok: missing CLI or project is a no-op"

# ── case 4: every forge entrypoint routes through the helper ────────────────
for ep in entrypoint-forge-claude.sh entrypoint-forge-opencode.sh \
          entrypoint-forge-opencode-web.sh entrypoint-terminal.sh; do
    f="$ROOT/images/default/$ep"
    grep -qF 'openspec_init_if_absent "$PROJECT_DIR"' "$f" || fail "case4: $ep does not call openspec_init_if_absent"
    if grep -qE '"\$OS_BIN"[[:space:]]+(init|update)' "$f"; then
        fail "case4: $ep runs openspec init/update against the checkout directly"
    fi
done
echo "case 4 ok: no entrypoint calls openspec init directly"

# ── case 5 (optional): the real CLI against a scratch checkout ──────────────
if REAL="$(command -v openspec 2>/dev/null)"; then
    R="$WORK/real"; mkdir -p "$R"; git -C "$R" init -q .
    (cd "$R" && "$REAL" init --tools claude </dev/null >/dev/null 2>&1) || fail "case5: real init failed"
    # age the committed set so any rewrite shows as a diff
    for f in "$R"/.claude/skills/openspec-*/SKILL.md; do sed -i.bak 's/generatedBy: ".*"/generatedBy: "0.0.0"/' "$f" && rm -f "$f.bak"; done
    git -C "$R" add -A >/dev/null && git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
    OS_BIN="$REAL" openspec_init_if_absent "$R" claude
    OS_BIN="$REAL" openspec_init_if_absent "$R" ""
    [ -z "$(porcelain "$R")" ] || fail "case5: real CLI launch dirtied the checkout: $(porcelain "$R" | head -3 | tr '\n' ' ')"
    echo "case 5 ok: real openspec $("$REAL" --version 2>/dev/null | tail -1) leaves the checkout clean"
else
    echo "skip:case5:no-openspec-cli"
fi

echo "ok:forge-launch-openspec-init-clean"
