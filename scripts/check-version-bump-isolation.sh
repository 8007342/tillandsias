#!/usr/bin/env bash
# check-version-bump-isolation.sh — order 702-eusw criterion 3.
#
# A build-number VERSION bump must NEVER be swept into an unrelated commit. The
# 702-eusw P0 began when commit dd8fd63f (a security fix) also carried a
# `VERSION 0.4.260810.1 -> 0.4.260812.1` bump via `git add -A`; the mandated
# linux-next merge then imported that divergent VERSION and the mandated
# pre-push gate refused every downstream platform push — the whole fleet blocked
# by a bump nobody meant to make on an integration branch.
#
# This guard refuses any NON-MERGE commit that changes VERSION together with any
# file OUTSIDE the version-companion set (Cargo.lock, the workspace Cargo.toml,
# and crate Cargo.toml files — the files a real version bump legitimately moves
# alongside VERSION). A genuine release-bump commit (VERSION + those files ONLY)
# still passes — that is the negative control.
#
# Merge commits are EXEMPT: a merge that inherits a VERSION change from main or
# the integration branch is a legitimate catch-up (order 643-64bx), not a sweep.
#
# Usage:
#   check-version-bump-isolation.sh [--range A..B | --commit SHA]
# Default range: @{upstream}..HEAD (the outgoing commits about to be pushed);
# if there is no upstream, the guard is a no-op (nothing to push-check).
#
# Verdict (last line):
#   version-bump-isolation: commits=<n> version-touching=<n> violations=<n> verdict=(ok|version-swept-with-unrelated-files)
# Exit 0 when clean; exit 1 when a sweep is found (fail loud, naming the commit).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not-a-git-repo"; exit 0; }
cd "$ROOT"

range=""
while [ $# -gt 0 ]; do
  case "$1" in
    --range) range="$2"; shift 2 ;;
    --commit) range="$2~1..$2"; shift 2 ;;
    *) echo "check-version-bump-isolation: unknown arg $1" >&2; exit 2 ;;
  esac
done

if [ -z "$range" ]; then
  if up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" && [ -n "$up" ]; then
    range="${up}..HEAD"
  else
    echo "version-bump-isolation: commits=0 version-touching=0 violations=0 verdict=ok"
    exit 0
  fi
fi

# A file is a legitimate version-bump companion iff it is one of these.
is_companion() {
  case "$1" in
    VERSION|Cargo.lock|Cargo.toml) return 0 ;;
    crates/*/Cargo.toml) return 0 ;;
    *) return 1 ;;
  esac
}

commits=0 vtouch=0 violations=0
# --no-merges: merge commits inheriting a VERSION change are legitimate catch-ups.
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  commits=$((commits+1))
  files="$(git diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null)"
  printf '%s\n' "$files" | grep -qx "VERSION" || continue
  vtouch=$((vtouch+1))
  # VERSION changed in this non-merge commit — every other file must be a companion.
  offenders=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_companion "$f" || offenders+=("$f")
  done <<< "$files"
  if [ "${#offenders[@]}" -gt 0 ]; then
    violations=$((violations+1))
    echo "VIOLATION ${sha:0:12}: VERSION changed alongside non-companion file(s): ${offenders[*]}"
  fi
done < <(git rev-list --no-merges "$range" 2>/dev/null)

if [ "$violations" -eq 0 ]; then
  echo "version-bump-isolation: commits=$commits version-touching=$vtouch violations=0 verdict=ok"
  exit 0
else
  echo "version-bump-isolation: commits=$commits version-touching=$vtouch violations=$violations verdict=version-swept-with-unrelated-files"
  echo "A build-number bump must land alone (VERSION + Cargo.lock/Cargo.toml/crates only), via a release/version-bump-* branch — never swept into an unrelated commit (702-eusw)."
  exit 1
fi
