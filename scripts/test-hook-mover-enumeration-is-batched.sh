#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1307-kic6
#
# Pin 1307-kic6: the pre-push hook's "which paths moved since the stamp"
# enumeration must not spawn a shell PER FILE.
#
# PRE-FIX RESULT, measured 2026-09-20 over a 7073-file tree, same stamp, same
# mover list (141) on both platforms:
#   per-file `xargs -I{} sh -c`, yolanda (Windows 11, MSYS)  ~18 min
#       (7070 x ~155 ms per spawn; five bounds of 120-240 s all killed it)
#   per-file `xargs -I{} sh -c`, macuahuitl (Fedora 44)      3.9 s
#   batched form,                yolanda                     2.3 s
# So it cost Linux four seconds on EVERY push and Windows eighteen minutes.
# THIS FIXTURE IS NOT WINDOWS-ONLY for exactly that reason: the hook is shared
# by every host, and the defect was live on all of them.
#
# WHY THIS PINS THE SHAPE AND NOT A DURATION. A timing assertion on a shared
# hook would be flaky on the floor tier and meaningless on a fast one. What is
# invariant is the SHAPE: no `-I{}` per-file spawn in the enumeration, and the
# truncation happening after capture rather than inside a pipeline under
# pipefail. Both are read out of the file; the behavioural arm then proves the
# enumeration still answers correctly.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

HOOK="${TILLANDSIAS_HOOK_SRC:-scripts/hooks/pre-push-local-gate.sh}"
[ -f "$HOOK" ] || { echo "blocked:hook-mover-enumeration:no-hook:$HOOK"; exit 1; }

fail=0
_ok()   { echo "ok: $1"; }
_bad()  { echo "FAIL: $1"; fail=1; }

# Comments are stripped before every scan: this file's own header quotes the
# forbidden idiom, and so does the hook's explanatory comment. A scan that
# reads comments refuses the very tree that fixed the defect.
CODE="$(mktemp)"; trap 'rm -f "$CODE"' EXIT
sed 's|#.*||' "$HOOK" > "$CODE"

# ARM 1 -- THE DEFECT ITSELF. `-I{}` with a shell is the per-file spawn.
if grep -qE 'xargs[^|]*-I\{\}[^|]*sh -c' "$CODE"; then
    _bad "the enumeration still spawns a shell per file (xargs -I{} sh -c)"
else
    _ok "no per-file 'xargs -I{} sh -c' spawn in the hook"
fi

# ARM 2 -- THE REPLACEMENT IS PRESENT AND BATCHED. Without -I, xargs batches.
if grep -qE "xargs -0 -r sh -c 'find \"\\\$@\"" "$CODE"; then
    _ok "the enumeration batches paths into find as arguments"
else
    _bad "the batched 'xargs -0 -r sh -c find \"\$@\"' enumeration is absent"
fi

# ARM 3 -- THE SECOND HAZARD. A truncating consumer inside the enumeration
# pipeline inverts its status under this file's `set -uo pipefail`.
if grep -nE 'xargs.*\| *head ' "$CODE" >/dev/null 2>&1; then
    _bad "the enumeration still ends in a truncating 'head' inside the pipeline"
else
    _ok "no truncating consumer inside the enumeration pipeline"
fi
if grep -qE "awk 'NF && NR <= 12'" "$CODE"; then
    _ok "truncation happens after capture"
else
    _bad "the after-capture truncation is absent"
fi

# ARM 4 -- BEHAVIOURAL, and it runs everywhere. Build a throwaway git repo,
# plant a stamp, then a file NEWER than it and an IGNORED file newer than it,
# and run the hook's exact idiom against them.
#
# THE IGNORED FILE IS THE POINT: the stamp covers `ls-files --cached --others`,
# so an ignored file moving invalidates nothing and must NOT be named. A
# `find . -newer` form names it, which is why that form was rejected.
TMP="$(mktemp -d)"; trap 'rm -f "$CODE"; rm -rf "$TMP"' EXIT
(
  cd "$TMP" || exit 9
  git init -q . 2>/dev/null
  printf 'ignored/\n' > .gitignore
  mkdir -p ignored
  printf 'a\n' > tracked-old.txt
  git add -A 2>/dev/null; git -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  stamp=.stamp
  printf 's\n' > "$stamp"
  sleep 1
  printf 'b\n' > tracked-new.txt
  printf 'c\n' > untracked-new.txt
  printf 'd\n' > ignored/ignored-new.txt

  movers="$(
    git ls-files -z --cached --others --exclude-standard 2>/dev/null \
      | xargs -0 -r sh -c 'find "$@" -maxdepth 0 -newer "$0" -type f -print' "$stamp" 2>/dev/null
  )"
  printf '%s\n' "$movers" > movers.txt
)
MOV="$TMP/movers.txt"
if [ ! -f "$MOV" ]; then
    _bad "behavioural arm produced no output at all"
else
    case "$(cat "$MOV")" in
        *tracked-new.txt*) _ok "BEHAVIOURAL: a newer TRACKED file is named" ;;
        *) _bad "BEHAVIOURAL: the newer tracked file was not named: $(cat "$MOV")" ;;
    esac
    case "$(cat "$MOV")" in
        *untracked-new.txt*) _ok "BEHAVIOURAL: a newer UNTRACKED file is named" ;;
        *) _bad "BEHAVIOURAL: the newer untracked file was not named" ;;
    esac
    case "$(cat "$MOV")" in
        *ignored-new.txt*) _bad "BEHAVIOURAL: an IGNORED newer file was named; the stamp does not cover it" ;;
        *) _ok "BEHAVIOURAL: a newer IGNORED file is NOT named" ;;
    esac
    case "$(cat "$MOV")" in
        *tracked-old.txt*) _bad "BEHAVIOURAL: an OLDER file was named" ;;
        *) _ok "BEHAVIOURAL: an older file is not named" ;;
    esac
fi

[ "$fail" -eq 0 ] && echo "ok:hook-mover-enumeration-is-batched:all" || echo "FAIL:hook-mover-enumeration-is-batched"
exit "$fail"
