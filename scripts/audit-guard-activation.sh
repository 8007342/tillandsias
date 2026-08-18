#!/usr/bin/env bash
# audit-guard-activation.sh — order 599-4wzr criterion 2: "a guard nobody can
# prove is running is not a guard." Enumerate every check-*.sh guard the repo
# ships and prove each is invoked by at least one ACTIVATION SURFACE. A guard
# with no invoker is an ORPHAN — it exists in the tree but fails silently and
# looks exactly like a passing one (the 599-w5jd failure class).
#
# Activation surfaces searched (a guard is ACTIVE if referenced by ANY of these):
#   - build.sh                         (the --check / --ci gate)
#   - scripts/local-ci.sh + other      orchestration scripts under scripts/
#   - openspec/litmus-tests/*.yaml     (a litmus that executes the guard)
#   - .github/workflows/*.yml          (CI)
#   - scripts/install-hooks.sh         (installed as/inside a git hook)
#   - .claude/skills/**, methodology*  (run directly by the orchestration loop)
#
# Output: one line per guard, then a machine verdict line matching
#   ^guard-activation: total=<n> active=<n> orphan=<n> verdict=(ok|orphans-found)$
# Exit 0 when every guard is active; exit 1 when any orphan is found (fail loud).
#
# Scope note: this proves a guard is WIRED on this checkout. Per 599-4wzr
# criterion 3, hook INSTALLATION is per-checkout — each platform (Linux, Windows,
# macOS) must run this itself; a green run here says nothing about theirs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Activation surfaces (files/globs). Missing ones are skipped, not fatal.
surfaces=(
  "build.sh"
  scripts/local-ci.sh
  scripts/run-litmus-test.sh
  scripts/mo-full-attest.sh
  openspec/litmus-tests
  .github/workflows
  scripts/install-hooks.sh
  .claude/skills
  methodology.yaml
  methodology
)

# Self-reference guard: don't count a script referencing its OWN name, and don't
# count this auditor itself as an invoker.
find_invoker() { # find_invoker <basename>
  local name="$1" s hit
  for s in "${surfaces[@]}"; do
    [ -e "$s" ] || continue
    # grep the surface for the guard's basename; exclude the guard file itself
    # and this auditor from counting as an invoker.
    # -R, not -r: the skill surfaces are SYMLINK FARMS by construction. There is
    # one canonical skills/<name>/ and each runtime (.claude, .opencode, .codex,
    # .gemini, .github) reaches it through a symlink, so there is exactly one
    # source of truth. `grep -r` does not follow symlinks found during traversal,
    # so it read `.claude/skills` as empty and every guard invoked ONLY from a
    # skill was reported "shipped but never invoked".
    #
    # Measured 2026-08-17: check-daily-maintenance.sh (order 801-qasc, windows)
    # is referenced twice in skills/meta-orchestration/SKILL.md and was still
    # counted an ORPHAN, failing ./build.sh --ci-full. `grep -rl` over
    # .claude/skills returned nothing; `grep -Rl` returned
    # .claude/skills/meta-orchestration/SKILL.md. The guard was wired correctly
    # and the auditor could not see it — a false accusation that blocks a gate
    # is worse than no audit, because the fix it demands is to re-wire something
    # that is already wired.
    hit="$(grep -Rl -- "$name" "$s" 2>/dev/null \
            | grep -vE "scripts/${name}$|scripts/audit-guard-activation.sh$" \
            | head -1)"
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
  done
  return 1
}

total=0 active=0 orphan=0
orphans=()
for f in scripts/check-*.sh; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  total=$((total+1))
  if invoker="$(find_invoker "$name")"; then
    active=$((active+1))
    printf 'active:  %-45s <- %s\n' "$name" "$invoker"
  else
    orphan=$((orphan+1))
    orphans+=("$name")
    printf 'ORPHAN:  %-45s (no invoker on any activation surface)\n' "$name"
  fi
done

if [ "$orphan" -eq 0 ]; then
  echo "guard-activation: total=$total active=$active orphan=0 verdict=ok"
  exit 0
else
  echo "guard-activation: total=$total active=$active orphan=$orphan verdict=orphans-found"
  printf 'orphans: %s\n' "${orphans[*]}"
  exit 1
fi
