#!/usr/bin/env bash
# @trace order:823-u5zf
#
# Fixture: the wt-reparse deletion scan must red on a LIVE symbol and stay green
# on a comment that merely names it.
#
# WHY BOTH DIRECTIONS ARE REQUIRED. 823-u5zf's closure asks for "a source scan
# finds no argv_survives_wt_reparse". A plain grep satisfies the words and
# cannot satisfy the intent, in both directions at once:
#
#   FALSE POSITIVE — the tree today is CORRECT (the predicates are deleted) and
#   a grep reports three hits, all comments recording the deletion. The packet
#   never closes, and the tempting repair is to delete the explanation.
#
#   FALSE NEGATIVE — if a fix "passed" by deleting those comments, the grep
#   would then be satisfied by a tree with no explanation, and a later
#   re-introduction inside a doc comment would read the same as one in code.
#
# Arm 2 is the one with teeth. Arm 1 alone is satisfied by a scan that always
# says ok, which is exactly the failure mode this repo hit when a litmus step
# matched a deleted test's doc comment and went green over an absence
# (1055-6yp8).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNDER_TEST="$ROOT/scripts/check-wt-reparse-workarounds-deleted.sh"
[ -f "$UNDER_TEST" ] || { echo "SKIP: scan not present" >&2; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

_verdict() { # dir -> ok|violation|other
    local out
    out="$(cd "$ROOT" && bash "$UNDER_TEST" "$1" 2>/dev/null)"
    case "$out" in
        ok:wt-reparse-workarounds-deleted:*) echo ok ;;
        violation:wt-reparse-workaround-live:*) echo violation ;;
        *) echo "other:$out" ;;
    esac
}

echo "== 823-u5zf: the deletion scan classifies by position, not by presence"

# ---- ARM 1: comments naming the deleted predicates are NOT occurrences ------
mkdir -p "$WORK/comments/src"
cat > "$WORK/comments/src/lib.rs" <<'RS'
// The argv_survives_wt_reparse guard (order 795-zshi) is deleted: every lane
// now emits a verbatim argv, so it always returned true.
/// Historical note: wt_safe_title used to sanitise the tab title.
pub fn spawn() {}
RS
_result "arm1-comment-only-tree-is-clean" "ok" "$(_verdict "$WORK/comments")"

# ---- ARM 2: NEGATIVE CONTROL — a live symbol must red ----------------------
# This is the arm that stops a scan which always says ok from passing as a fix.
mkdir -p "$WORK/live/src"
cat > "$WORK/live/src/lib.rs" <<'RS'
// A comment mentioning argv_survives_wt_reparse must not be what trips this.
fn argv_survives_wt_reparse(argv: &[String]) -> bool {
    argv.iter().all(|a| !a.is_empty())
}
RS
_result "arm2-live-definition-reds" "violation" "$(_verdict "$WORK/live")"

# A CALL is as live as a definition — the predicate being back in the decision
# path is the defect, wherever it is defined.
mkdir -p "$WORK/call/src"
cat > "$WORK/call/src/lib.rs" <<'RS'
pub fn spawn(argv: &[String]) {
    if argv_survives_wt_reparse(argv) { wt(); } else { conhost(); }
}
RS
_result "arm2-live-call-reds" "violation" "$(_verdict "$WORK/call")"

# The second symbol must be guarded too, or half the closure is unpinned.
mkdir -p "$WORK/title/src"
cat > "$WORK/title/src/lib.rs" <<'RS'
fn wt_safe_title(t: &str) -> String { t.to_string() }
RS
_result "arm2-second-symbol-reds" "violation" "$(_verdict "$WORK/title")"

# ---- ARM 3: a trailing comment on a live line must not hide it -------------
# `code(); // argv_survives_wt_reparse` is a comment; the reverse is not.
mkdir -p "$WORK/trailing/src"
cat > "$WORK/trailing/src/lib.rs" <<'RS'
pub fn spawn(argv: &[String]) {
    let ok = argv_survives_wt_reparse(argv); // legacy guard, see 795-zshi
    let _ = ok;
}
RS
_result "arm3-code-with-a-trailing-comment-still-reds" "violation" "$(_verdict "$WORK/trailing")"

# ---- ARM 4: the real workspace is clean ------------------------------------
_result "arm4-workspace-is-clean" "ok" "$(_verdict "crates")"

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:wt-reparse-scan:$fail arm(s) failed"
    exit 1
fi
echo "ok:wt-reparse-scan:$pass arm(s)"
