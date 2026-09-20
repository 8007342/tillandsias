#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1307-kic6
#
# EQUIVALENCE FIRST, SPEED SECOND. scripts/gate-stamp.sh is shared gate code:
# if the batched digest differs from the per-file one by so much as a byte,
# every path reads as `modified` and every host's push is refused. So this
# fixture does not test that the new form is fast -- it tests that it computes
# the SAME THING as the form it replaced.
#
# PRE-FIX RESULT (the cost that forced the change), same movers output both ways:
#   per-file hash, yolanda (Windows 11, MSYS)  675 ms/path over 30 real files
#                                              7073 paths -> ~4774 s (~80 min)
#   per-file hash, macuahuitl (Fedora 44)      4.7 s over 7076 files
# A thousand-fold ratio, the same one the enumeration had -- so batching is a
# gain on Linux too and not a Windows accommodation.
#
# THE OLD IMPLEMENTATION IS INLINED BELOW rather than read out of git history,
# so this fixture keeps working when the old form is gone. It is a transcription
# of gate-stamp.sh's loop as it stood at 1307-kic6: the same enumeration, the
# same plan/* skips, symlinks hashed by LINK TEXT and regular files by content.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum)
elif command -v shasum  >/dev/null 2>&1; then SHA=(shasum -a 256)
else echo "blocked:movers-equivalence:no-sha256-tool"; exit 1; fi

fail=0
_ok()  { echo "ok: $1"; }
_bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A throwaway repo that exercises every branch the loop has: a plain file, a
# file in a subdir, a SYMLINK, an ignored file, a top-level plan/issues/*.md
# (skipped), a nested plan/issues/*/*.md (NOT skipped), and a plan/index.d
# fragment (skipped). The plan/* cases are here because a clean checkout once
# reported 40+ phantom adds when they were missed, and the hermetic fixtures
# could not see it -- their throwaway repos had no plan/ tree.
REPO="$TMP/repo"
mkdir -p "$REPO/sub" "$REPO/plan/issues/nested" "$REPO/plan/index.d" "$REPO/ign"
(
  cd "$REPO" || exit 9
  git init -q .
  printf 'ign/\n' > .gitignore
  printf 'alpha\n'            > a.txt
  printf 'beta\n'             > sub/b.txt
  printf 'gamma\n'            > ign/ignored.txt
  printf 'top\n'              > plan/issues/top-level.md
  printf 'nested\n'           > plan/issues/nested/deep.md
  printf 'frag\n'             > plan/index.d/20260920t000000z-x.yaml
  ln -s a.txt link-to-a 2>/dev/null || printf 'nolink\n' > link-to-a
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
)

# --- the OLD implementation, transcribed -------------------------------------
_old_now() {
  local REPO_ROOT="$1" _p
  while IFS= read -r -d '' _p; do
    case "$_p" in
      plan/index.d/*.yaml|plan/loop_status.d/*.md|plan/mo-full-attestations.d/*.md) continue ;;
      plan/issues/*.md) case "${_p#plan/issues/}" in */*) : ;; *) continue ;; esac ;;
    esac
    if [[ -L "$REPO_ROOT/$_p" ]]; then
      printf '%s\t%s\n' "$(readlink "$REPO_ROOT/$_p" | "${SHA[@]}" | cut -d' ' -f1)" "$_p"
    elif [[ -f "$REPO_ROOT/$_p" ]]; then
      printf '%s\t%s\n' "$("${SHA[@]}" < "$REPO_ROOT/$_p" | cut -d' ' -f1)" "$_p"
    fi
  done < <(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard 2>/dev/null | LC_ALL=C sort -z)
}

# --- the NEW implementation, transcribed from the patched gate-stamp.sh -------
_new_now() {
  local REPO_ROOT="$1" _p _lp d="$TMP/new.$$"
  mkdir -p "$d"; : > "$d/links.z"; : > "$d/regular.z"
  while IFS= read -r -d '' _p; do
    case "$_p" in
      plan/index.d/*.yaml|plan/loop_status.d/*.md|plan/mo-full-attestations.d/*.md) continue ;;
      plan/issues/*.md) case "${_p#plan/issues/}" in */*) : ;; *) continue ;; esac ;;
    esac
    if [[ -L "$REPO_ROOT/$_p" ]]; then
      printf '%s\0' "$_p" >> "$d/links.z"
    elif [[ -f "$REPO_ROOT/$_p" ]]; then
      printf '%s\0' "$_p" >> "$d/regular.z"
    fi
  done < <(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard 2>/dev/null | LC_ALL=C sort -z)
  ( cd "$REPO_ROOT" && LC_ALL=C xargs -0 -r "${SHA[@]}" < "$d/regular.z" 2>/dev/null ) \
      | LC_ALL=C sed 's/^\([0-9a-fA-F][0-9a-fA-F]*\) [ *]/\1\t/'
  while IFS= read -r -d '' _lp; do
    printf '%s\t%s\n' "$(readlink "$REPO_ROOT/$_lp" | "${SHA[@]}" | cut -d' ' -f1)" "$_lp"
  done < "$d/links.z"
}

_old_now "$REPO" | LC_ALL=C sort > "$TMP/old.txt"
_new_now "$REPO" | LC_ALL=C sort > "$TMP/new.txt"

# ARM 1 -- BYTE-IDENTICAL. The whole point.
if cmp -s "$TMP/old.txt" "$TMP/new.txt"; then
  _ok "old and new movers digests are byte-identical ($(wc -l < "$TMP/old.txt" | tr -d ' ') paths)"
else
  _bad "old and new movers digests DIFFER:"
  diff "$TMP/old.txt" "$TMP/new.txt" | head -10
fi

# ARM 2 -- THE OUTPUT IS NOT VACUOUSLY EMPTY. Two empty files are identical.
if [ -s "$TMP/old.txt" ]; then
  _ok "the comparison is non-vacuous (the old form produced output)"
else
  _bad "the old form produced NO output -- arm 1 compared two empty files and proved nothing"
fi

# ARM 3 -- THE SYMLINK IS HASHED BY LINK TEXT, not by the target's content.
# If the batched form ever swept links into the file batch this goes red: the
# digest would become sha256("alpha\n") instead of sha256("a.txt\n").
if [ -L "$REPO/link-to-a" ]; then
  want="$(printf 'a.txt\n' | "${SHA[@]}" | cut -d' ' -f1)"
  got="$(awk -F'\t' '$2 == "link-to-a" {print $1}' "$TMP/new.txt")"
  if [ "$got" = "$want" ]; then
    _ok "the symlink is hashed by its LINK TEXT"
  else
    _bad "the symlink digest is wrong (got '$got', want '$want') -- links must not join the file batch"
  fi
else
  echo "skip: symlink arm -- this filesystem did not create a symlink"
fi

# ARM 4 -- THE plan/* FILTERS SURVIVE. A skipped path appearing here is the
# 40-phantom-adds defect returning.
for skipped in "plan/index.d/20260920t000000z-x.yaml" "plan/issues/top-level.md" "ign/ignored.txt"; do
  if awk -F'\t' -v p="$skipped" '$2 == p {found=1} END {exit !found}' "$TMP/new.txt"; then
    _bad "a path that must be skipped was digested: $skipped"
  else
    _ok "skipped as required: $skipped"
  fi
done
# ...and the NESTED plan/issues path must NOT be skipped.
if awk -F'\t' '$2 == "plan/issues/nested/deep.md" {found=1} END {exit !found}' "$TMP/new.txt"; then
  _ok "a NESTED plan/issues path is digested (only top-level ones are skipped)"
else
  _bad "the nested plan/issues path was skipped; the filter is too broad"
fi

[ "$fail" -eq 0 ] && echo "ok:gate-stamp-movers-batching-is-equivalent:all" || echo "FAIL:gate-stamp-movers-batching-is-equivalent"
exit "$fail"
