#!/usr/bin/env bash
# @trace order:1446-xqi6, spec:branch-discipline
#
# test-discipline-install-hooks.sh — the seven arms of 1446-xqi6: hook
# templates embedded in the plan binary, installed on demand per project.
#
#   1  no seed: install-hooks installs the level-0 set into a repo-LOCAL
#      core.hooksPath (and refuses a global one with the 1442-wyf9 token); a
#      push to main is not refused and prints nothing
#   2  raise --to 1: the seed reads level 1, a push to main is refused with the
#      affordance naming the integration branch and /project-discipline;
#      raise --to 0 is refused (forward-only)
#   3  level 0 with two committer identities: post-commit advises the raise,
#      refuses nothing
#   4  a project override .tillandsias/hooks/pre-push.lua runs instead
#   5  every stub is under sixty lines, bash-dialect clean, and refuses with
#      blocked:hook:<event>:no-plan-binary when the binary is not runnable
#   6  the forge's install_project_guard_hooks installs them for a checkout
#      that is NOT Tillandsias and traces the level
#   7  NEGATIVE CONTROL: a second install is a no-op; a hook that is not ours
#      (Tillandsias's own gate) is left untouched
#
# Pre-fix: FAILS at arm 1 (`discipline install-hooks` does not exist).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/discipline-install-hooks.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac

# A scratch HOME, so no real global git config (a forge's global hooksPath
# included) reaches these repositories.
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 TILLANDSIAS_PLAN_BIN="$PLAN"
unset GIT_CONFIG_GLOBAL TILLANDSIAS_HOST_KIND
# A forge exports its (anonymised) identity in these, and they override
# `-c user.name`; arm 3 needs two DIFFERENT committers, so the fixture owns them.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
mkdir -p "$HOME"
git config --global user.name fixture
git config --global user.email fixture@example.invalid
git config --global init.defaultBranch main

# new_project <name>: a project with one commit and a bare remote as origin.
new_project() {
    local p="$W/$1"
    git init -q --bare "$p-remote.git"
    git init -q "$p"
    printf 'one\n' > "$p/README"
    git -C "$p" add README
    git -C "$p" commit -qm one
    git -C "$p" remote add origin "$p-remote.git"
    printf '%s\n' "$p"
}

# ── arm 1 ────────────────────────────────────────────────────────────────────
P1="$(new_project bare)"
out="$(cd "$P1" && "$PLAN" discipline install-hooks 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ok:discipline:hooks-installed:level=0:3 hooks" ] &&
    [ "$(git -C "$P1" config --show-scope --get core.hooksPath | cut -f1)" = local ]; then
    ok "arm 1: no seed installs the level-0 set into a repo-local core.hooksPath"
else
    bad "arm 1: rc=$rc [$out] scope=[$(git -C "$P1" config --show-scope --get core.hooksPath)]"
fi
push_out="$(git -C "$P1" push origin main 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qE 'refused|advised|warn|blocked' <<<"$push_out"; then
    ok "arm 1: a push to main at level 0 is not refused and prints no warning"
else
    bad "arm 1: level-0 push rc=$rc [$push_out]"
fi
PG="$(new_project globalpath)"
mkdir -p "$W/global-hooks"
git config --global core.hooksPath "$W/global-hooks"
out="$(cd "$PG" && "$PLAN" discipline install-hooks 2>/dev/null)"; rc=$?
git config --global --unset core.hooksPath
if [ "$rc" -eq 3 ] && [ "$out" = "refused:install-hooks:global-hooks-path:$W/global-hooks" ] &&
    [ -z "$(ls -A "$W/global-hooks")" ]; then
    ok "arm 1: a global core.hooksPath is refused with the 1442-wyf9 token, nothing written"
else
    bad "arm 1: global hooksPath: rc=$rc [$out] wrote=[$(ls -A "$W/global-hooks")]"
fi

# ── arm 2 ────────────────────────────────────────────────────────────────────
raise_out="$(cd "$P1" && "$PLAN" discipline raise --to 1 2>/dev/null)"; rc=$?
level="$(cd "$P1" && "$PLAN" discipline show --json 2>/dev/null | "$PLAN" json get -r '.level')"
if [ "$rc" -eq 0 ] && [ "$level" = 1 ] &&
    grep -qx 'ok:discipline:hooks-installed:level=1:5 hooks' <<<"$raise_out"; then
    ok "arm 2: raise --to 1 writes a level-1 seed and installs the level-1 set"
else
    bad "arm 2: raise rc=$rc level=[$level] [$raise_out]"
fi
printf 'two\n' >> "$P1/README"
git -C "$P1" commit -qam two >/dev/null 2>&1
push_out="$(git -C "$P1" push origin main 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] &&
    grep -qx 'refused:hook:pre-push:default-branch-protected:enforced' <<<"$push_out" &&
    grep -qx 'this project at level 1 (default_branch enforced) needs pushes on develop; use /project-discipline for instructions' <<<"$push_out"; then
    ok "arm 2: a push to main at level 1 is refused with the affordance"
else
    bad "arm 2: level-1 push rc=$rc [$push_out]"
fi
git -C "$P1" push -q origin HEAD:develop >/dev/null 2>&1 &&
    ok "arm 2: a push to the integration branch passes" || bad "arm 2: push to develop refused"
out="$(cd "$P1" && "$PLAN" discipline raise --to 0 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "refused:discipline:raise:forward-only:1->0" ] &&
    ok "arm 2: raise --to 0 is refused (forward-only)" || bad "arm 2: raise --to 0: rc=$rc [$out]"

# ── arm 3 ────────────────────────────────────────────────────────────────────
P3="$(new_project committers)"
(cd "$P3" && "$PLAN" discipline install-hooks >/dev/null 2>&1)
printf 'x\n' > "$P3/x"
git -C "$P3" add x
commit_out="$(git -C "$P3" -c user.name=someone-else -c user.email=else@example.invalid commit -m second 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'advised:hook:post-commit:multiple-committers' <<<"$commit_out" &&
    grep -q 'use /project-discipline for how to raise to level 1' <<<"$commit_out"; then
    ok "arm 3: two committer identities at level 0 advise the raise and refuse nothing"
else
    bad "arm 3: rc=$rc [$commit_out]"
fi

# ── arm 4 ────────────────────────────────────────────────────────────────────
mkdir -p "$P3/.tillandsias/hooks"
cat > "$P3/.tillandsias/hooks/pre-push.lua" <<'EOF'
io.stderr:write("OVERRIDE-MARKER-1446\n")
return "ok:hook:pre-push:override"
EOF
push_out="$(git -C "$P3" push origin main 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'OVERRIDE-MARKER-1446' <<<"$push_out"; then
    ok "arm 4: .tillandsias/hooks/pre-push.lua runs instead of the embedded template"
else
    bad "arm 4: rc=$rc [$push_out]"
fi

# ── arm 5 ────────────────────────────────────────────────────────────────────
HOOKS="$P1/.git/hooks"
for ev in pre-commit post-commit post-merge post-checkout pre-push; do
    f="$HOOKS/$ev"
    n="$(wc -l < "$f" | tr -d ' ')"
    dialect="$(TILLANDSIAS_DIALECT_SCAN_DIR="$f" bash "$ROOT/scripts/check-bash-dialect.sh" 2>/dev/null)"
    blocked="$(cd "$P1" && TILLANDSIAS_PLAN_BIN="$W/not-runnable" bash "$f" </dev/null 2>/dev/null)"; rc=$?
    if [ "$n" -lt 60 ] && [ "$dialect" = "ok:bash-dialect-clean" ] &&
        [ "$rc" -eq 1 ] && [ "$blocked" = "blocked:hook:$ev:no-plan-binary" ]; then
        ok "arm 5: $ev stub is $n lines, bash-dialect clean, and refuses without a plan binary"
    else
        bad "arm 5: $ev lines=$n dialect=[$dialect] rc=$rc [$blocked]"
    fi
done

# ── arm 6 ────────────────────────────────────────────────────────────────────
TRACE="$W/trace.log"
trace_lifecycle() { printf '%s %s\n' "$1" "$2" >> "$TRACE"; }
for fn in install_project_guard_hooks install_project_discipline_hooks; do
    eval "$(sed -n "/^$fn()/,/^}/p" "$ROOT/images/default/lib-common.sh")"
done
P6="$(new_project forgeproject)"
install_project_guard_hooks "$P6"
if [ -x "$P6/.git/hooks/pre-push" ] && grep -q 'tillandsias-discipline-hook v1' "$P6/.git/hooks/pre-push" &&
    grep -q 'discipline hooks installed: level=0:3 hooks' "$TRACE"; then
    ok "arm 6: the forge installs discipline hooks for a non-Tillandsias checkout and traces the level"
else
    bad "arm 6: trace=[$(cat "$TRACE" 2>/dev/null)] hooks=[$(ls "$P6/.git/hooks" | grep -v sample | tr '\n' ' ')]"
fi

# ── arm 7: NEGATIVE CONTROL ─────────────────────────────────────────────────
before="$(cd "$HOOKS" && cat pre-commit post-commit post-merge post-checkout pre-push | cksum)"
out="$(cd "$P1" && "$PLAN" discipline install-hooks 2>&1)"
after="$(cd "$HOOKS" && cat pre-commit post-commit post-merge post-checkout pre-push | cksum)"
if [ "$before" = "$after" ] && grep -q '0 written this run' <<<"$out"; then
    ok "arm 7: a second install is a no-op"
else
    bad "arm 7: second install changed hooks or wrote [$out]"
fi
P7="$(new_project tillandsias-like)"
mkdir -p "$P7/.git/hooks"
printf '#!/usr/bin/env bash\n# tillandsias-pre-push-v8\nexit 0\n' > "$P7/.git/hooks/pre-push"
chmod +x "$P7/.git/hooks/pre-push"
gate="$(cksum < "$P7/.git/hooks/pre-push")"
out="$(cd "$P7" && "$PLAN" discipline install-hooks 2>&1)"
if [ "$(cksum < "$P7/.git/hooks/pre-push")" = "$gate" ] &&
    grep -q '^skip:discipline:hook-not-ours:pre-push' <<<"$out"; then
    ok "arm 7: a pre-push that is not ours (Tillandsias's own gate) is left untouched"
else
    bad "arm 7: foreign pre-push changed or not reported: [$out]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: discipline-install-hooks $pass/$total (1446-xqi6)"
    exit 0
fi
echo "FAIL: discipline-install-hooks $pass/$total (1446-xqi6)"
exit 1
