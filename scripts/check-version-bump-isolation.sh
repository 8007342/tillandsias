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
# SCOPE: only commits THIS PUSH PUBLISHES FOR THE FIRST TIME (order 723-b9cn).
#
# The default range was `@{upstream}..HEAD`, which is not the same set. A
# platform branch MUST merge origin/linux-next before every push
# (methodology pull_merge_cadence.pre_push_gate), and its own remote head lags,
# so `@{upstream}..HEAD` includes every commit the integration branch published
# while this host was away. Measured on osx-next 2026-08-13: 89 non-merge
# commits in range, two of them flagged — bad35b4928c8 (windows) and
# dd8fd63fac57 (linux), both already immutable on origin/linux-next and
# origin/windows-next. This host can neither fix nor drop them, so the mandated
# merge produced a permanently unpushable branch and the only way out was
# `--no-verify`, which also disables the local gate that replaced push CI.
#
# That is the SAME failure shape as order 643-64bx one layer up, and the same
# rule resolves it: a branch is answerable for what it AUTHORS, not for what it
# ACCEPTS from a host that owns it. A commit reachable from any origin
# remote-tracking ref has already been published and was already gate-checked at
# its own first push, so re-policing it here can only produce a false refusal.
#
# This is a NARROWING, not a relaxation. The class the guard exists for — this
# host sweeping a build-number bump into an unrelated commit of its own — is
# still refused, because such a commit is by definition not yet on any remote.
#
# Usage:
#   check-version-bump-isolation.sh [--range A..B | --commit SHA]
# Default: commits reachable from HEAD but from no origin remote-tracking ref.
# An EXPLICIT --range/--commit is honoured literally (no publication filter), so
# a fixture can still interrogate published history on purpose.
# With no origin refs at all, fall back to @{upstream}..HEAD; with neither, the
# guard is a no-op (nothing to push-check).
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

# rev_args is what we hand `git rev-list`. An explicit --range/--commit is used
# verbatim; the default asks the publication question instead of the ahead-of-
# upstream one (see SCOPE above).
rev_args=()
if [ -n "$range" ]; then
  rev_args=(--no-merges "$range")
elif [ -n "$(git for-each-ref --count=1 --format='%(refname)' refs/remotes/origin 2>/dev/null)" ]; then
  rev_args=(--no-merges HEAD --not --remotes=origin)
elif up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" && [ -n "$up" ]; then
  rev_args=(--no-merges "${up}..HEAD")
else
  echo "version-bump-isolation: commits=0 version-touching=0 violations=0 verdict=ok"
  exit 0
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
  # Match in-shell, never `... | grep -qx VERSION`. Under `pipefail` grep -q
  # exits on the first match, the writer takes SIGPIPE and reports 141, and
  # pipefail promotes that to the pipeline status — so the test reads FALSE
  # precisely BECAUSE the match was found, and the commit is skipped. That is
  # order 702-pwhc, which failed the pre-push VERSION guard OPEN as a function
  # of diff size; the identical shape was still live here. `VERSION` sorts first
  # in diff-tree output, so a large commit would hit it every time.
  case $'\n'"$files"$'\n' in
    *$'\n'VERSION$'\n'*) ;;
    *) continue ;;
  esac
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
done < <(git rev-list "${rev_args[@]}" 2>/dev/null)

if [ "$violations" -eq 0 ]; then
  echo "version-bump-isolation: commits=$commits version-touching=$vtouch violations=0 verdict=ok"
  exit 0
else
  echo "version-bump-isolation: commits=$commits version-touching=$vtouch violations=$violations verdict=version-swept-with-unrelated-files"
  echo "A build-number bump must land alone (VERSION + Cargo.lock/Cargo.toml/crates only), via a release/version-bump-* branch — never swept into an unrelated commit (702-eusw)."
  exit 1
fi
