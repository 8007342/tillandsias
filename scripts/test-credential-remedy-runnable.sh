#!/usr/bin/env bash
# @trace order:1052-548e
#
# Fixture: the credential guard's PRINTED remedy must actually run, and must
# never put the token in its output.
#
# IT RUNS THE PRINTED TEXT, NOT A COPY OF IT. The command under test comes from
# `check-credential-channel.sh print-remedy` and is executed verbatim. That is
# the whole point of the packet's third criterion: the broken line shipped with
# the words "measured 18s on esmeraldinha after a 10-minute hang" attached to
# it, so whatever was measured, it was not the text an operator was shown. A
# fixture that hand-copies the command can drift from the guard the same way
# that measurement did.
#
# WHAT WAS BROKEN, measured by esmeraldinha 2026-09-05T03:00Z after a full day
# credential-blocked. The remedy's first line was:
#
#   gh auth token | git credential-store --file ... store
#
# `git credential-store ... store` reads a credential DESCRIPTION on stdin
# (protocol=, host=, username=, password=, blank line), not a bare token. It
# answered `fatal: unable to read credential`, left the store at 0 bytes, and
# the guard's next verdict was unchanged — indistinguishable, to the operator,
# from the refresh itself having failed.
#
# AND IT PRINTED THE SECRET: git's rejection path echoes the line it rejected,
# and the rejected line is the token. That is arm 2 below, and it is why this
# was filed p1 on the disclosure alone.
#
# NO REAL CREDENTIAL IS INVOLVED. `gh` is stubbed to a sentinel string and the
# store is a temp file; the fixture never reads the host's real token, and the
# only token bytes it ever handles are its own fake.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

command -v git >/dev/null 2>&1 || { echo "SKIP: no git(1) to exercise credential-store" >&2; exit 0; }

FAKE_TOKEN="ghp_FIXTURE0000NOTAREALTOKEN0000000000"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
_result() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 — expected $2, got $3" >&2
    fi
}

# A stub gh on PATH: `gh auth token` yields the sentinel, `gh api user --jq
# .login` yields an account name. Nothing reaches the network and the host's
# real credential is never read.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "auth token") echo "ghp_FIXTURE0000NOTAREALTOKEN0000000000" ;;
  "api user --jq .login") echo "fixture-account" ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# A real repo, so `git rev-parse --git-dir` in the remedy resolves.
git init -q "$WORK/repo" 2>/dev/null || { echo "SKIP: git init failed" >&2; exit 0; }

_run_remedy() { # command-text -> writes captured output to $WORK/out, echoes rc
    local text="$1" rc=0
    ( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" bash -c "$text" ) \
        > "$WORK/out" 2>&1 || rc=$?
    echo "$rc"
}

# ── 1. THE PRINTED REMEDY RUNS AND SEEDS THE STORE ──────────────────────────
remedy="$(scripts/check-credential-channel.sh print-remedy)"
[ -n "$remedy" ] || { echo "FAIL: the guard printed no remedy" >&2; exit 1; }

rc="$(_run_remedy "$remedy")"
_result "the printed remedy succeeds" 0 "$rc"

store="$WORK/repo/.git/.gh-credentials"
if [ -s "$store" ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: the remedy left the store empty — this is the 0-byte shape esmeraldinha measured" >&2
fi

# The store SHOULD hold the token; that is its job. The output must not.
if grep -q "$FAKE_TOKEN" "$store" 2>/dev/null; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: the store does not contain the credential it was asked to seed" >&2
fi

# ── 2. THE TOKEN APPEARS NOWHERE IN THE OUTPUT ──────────────────────────────
# The criterion that makes this p1. Checked against the CAPTURED output of the
# real run above, not against the command text.
if grep -q "$FAKE_TOKEN" "$WORK/out" 2>/dev/null; then
    fail=$((fail + 1))
    echo "FAIL: the remedy printed the token — this is the disclosure (1052-548e)" >&2
    sed "s/$FAKE_TOKEN/<TOKEN REDACTED BY FIXTURE>/g" "$WORK/out" >&2
else
    pass=$((pass + 1))
fi

# The printed TEXT must not embed a token either: it must defer to $(gh auth
# token) so the remedy stays safe to paste into a bug report.
case "$remedy" in
    *'$(gh auth token)'*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); echo "FAIL: the remedy must defer to \$(gh auth token), not embed a value" >&2 ;;
esac

# ── 3. NEGATIVE CONTROL: THE OLD LINE STILL FAILS THE WAY IT WAS REPORTED ───
# Without this the two arms above could pass because the check is broken open.
# This runs the exact form that shipped and asserts BOTH failure modes, so the
# fixture is known to be able to see the defect it exists to catch.
rm -f "$store"
old_line='gh auth token | git credential-store --file "$(git rev-parse --git-dir)/.gh-credentials" store'
old_rc="$(_run_remedy "$old_line")"

if [ "$old_rc" -ne 0 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: negative control — the bare-token form was expected to fail, got rc=0" >&2
fi

if grep -q "$FAKE_TOKEN" "$WORK/out" 2>/dev/null; then
    pass=$((pass + 1))   # confirms the fixture CAN see a disclosure
else
    fail=$((fail + 1))
    echo "FAIL: negative control — the bare-token form was expected to ECHO the token; if git stopped doing that, arm 2 above is no longer proof of anything" >&2
fi

echo "credential-remedy fixture: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
