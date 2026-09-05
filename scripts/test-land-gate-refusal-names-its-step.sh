#!/usr/bin/env bash
# @trace order:1033-iycs
#
# Pin: when the land tool's gate refuses, the refusal must name the failing step
# and the log that holds the gate's output.
#
# WHAT IT USED TO SAY, verbatim and in full, when macbookair hit it landing
# 997-e4v2 on osx-next:
#
#   land: attempt 1/4 — fetch + integrate onto origin/osx-next
#   land: attempt 1 — unpushed set has 2 merge commit(s); MERGING
#   land: attempt 1 — gate (./build.sh --check)
#   refused:land:gate-failed — run ./build.sh --check to see why
#
# No step, no reason, no log. And the remedy it printed does not work: the
# standalone re-run on the same commit graph, no edits between, returned
# GATE_EXIT=0 and the retry landed clean — because it is a DIFFERENT invocation
# against a tree the land's own integrate step may have moved. The one instance
# became irreproducible by construction, and whether the gate is
# non-deterministic could not even be asked.
#
# THE FILE ALREADY KNEW. Its header records that an earlier version discarded
# `git push`'s output and reported LANDED for a refused push. That lesson was
# applied to the push call and not to the gate call two lines above it, which is
# why this fixture pins the property rather than the sentence.
#
# The gate here is a STUB. Running a real gate would take minutes and would not
# fail on demand, and synthesising a real gate failure is not the same evidence
# as one — the packet's third criterion asks for a REAL refusal on some host and
# this fixture deliberately does not pretend to supply it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAND="$ROOT/scripts/land-on-platform-branch.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/land-gate-refusal.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
# The script derives the repo root from its OWN location (scripts/..), so it has
# to sit at scripts/ in the scratch repo. Copying it to the repo root made it
# resolve one directory too high and it reported "not a git repository" — a
# fixture failing on its own layout rather than on the behaviour under test.
mkdir -p scripts
cp "$LAND" scripts/land-on-platform-branch.sh
chmod +x scripts/land-on-platform-branch.sh
printf 'base\n' > README.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

# A stub gate that fails on a NAMED step, in build.sh's own verdict shape.
cat > build.sh <<'STUB'
#!/usr/bin/env bash
echo "[build] Checking the thing that works..."
echo "[build] Checking scripts/check-invented-guard.sh (order 9999-test)..."
echo "violation:invented-guard-tripped:1"
echo "[build] a script tripped the invented guard — see the verdict line above"
exit 1
STUB
chmod +x build.sh
printf 'work\n' > work.txt
G add -A >/dev/null; G commit -q -m "work to land"

out="$(bash scripts/land-on-platform-branch.sh linux-next 1 2>&1)"; rc=$?

# ── 1. It still refuses, with the same verdict token ───────────────────────
[ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q '^refused:land:gate-failed' \
    && ok "a failing gate still refuses with refused:land:gate-failed" \
    || bad "the refusal token or exit code changed (rc=$rc)"

# ── 2. IT NAMES A LOG, and the log exists and holds the gate's output ──────
_log="$(printf '%s\n' "$out" | sed -n 's/.*its output is at \(.*\)$/\1/p' | head -1)"
if [ -n "$_log" ] && [ -s "$_log" ]; then
    ok "the refusal names a log path that exists and is non-empty"
else
    bad "no usable log path in the refusal: ${_log:-<none>}"
fi
if [ -n "$_log" ] && grep -q 'violation:invented-guard-tripped' "$_log" 2>/dev/null; then
    ok "the log holds the gate's actual output"
else
    bad "the named log does not contain what the gate printed"
fi

# ── 3. IT NAMES THE FAILING STEP, which is the part a reader needs ─────────
# The FIRST failing line, not the last: build.sh prints its verdict after the
# failure, so a tail would show the summary and not the cause.
if printf '%s' "$out" | grep -q 'first failing line:.*violation:invented-guard-tripped'; then
    ok "the refusal quotes the first failing line, not the trailing summary"
else
    bad "the refusal does not quote the failing step: $(printf '%s' "$out" | grep -m1 'first failing')"
fi

# ── 4. It warns AGAINST the old remedy ────────────────────────────────────
# "run ./build.sh --check to see why" is what made the one real instance
# irreproducible; the tool must not send the next reader down it.
printf '%s' "$out" | grep -q 'Do NOT re-run' \
    && ok "the refusal warns that a standalone re-run is a different invocation" \
    || bad "the refusal still points at a re-run as the diagnosis path"

# ── 4b. A MARKER INSIDE AN `ok` ROW IS NOT THE CAUSE ──────────────────────
# Found by the FIRST REAL REFUSAL this fix caught, minutes after it landed: the
# gate is full of fixtures whose EXPECTED output quotes `refused:` or
# `violation:`, and an unanchored match named
# `ok   no evidence at all -> refused:no-evidence:...` — a PASSING arm — as the
# failing step. A diagnostic that names the wrong cause is worse than the four
# words it replaced, because this one looks like an answer.
cat > build.sh <<'STUB'
#!/usr/bin/env bash
echo "ok   no evidence at all                -> refused:no-evidence:v0.4:missing=linux (0 mutations)"
echo "ok:   a passing arm that quotes violation: in its own text"
echo "FAIL: the arm that actually failed"
echo "[build] the real verdict banner"
exit 1
STUB
chmod +x build.sh
G add -A >/dev/null; G commit -q -m "a gate whose passing arms quote the markers"
out3="$(bash scripts/land-on-platform-branch.sh linux-next 1 2>&1)"
if printf '%s' "$out3" | grep -q 'first failing line: FAIL: the arm that actually failed'; then
    ok "a marker inside an ok row is skipped; the real FAIL line is named"
else
    bad "the diagnostic named a passing arm: $(printf '%s' "$out3" | grep -m1 'first failing')"
fi

# ── 5. NEGATIVE CONTROL: a PASSING gate says none of this ─────────────────
# Without this, arms 1-4 are satisfied by a tool that refuses unconditionally.
cat > build.sh <<'STUB'
#!/usr/bin/env bash
echo "[build] everything is fine"
exit 0
STUB
chmod +x build.sh
G add -A >/dev/null; G commit -q -m "make the gate pass"
out2="$(bash scripts/land-on-platform-branch.sh linux-next 1 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ] && ! printf '%s' "$out2" | grep -q 'refused:land:gate-failed'; then
    ok "CONTROL: a passing gate lands without a refusal"
else
    bad "CONTROL: a passing gate did not land (rc=$rc2)"
    printf '%s\n' "$out2" | tail -4 | sed 's/^/      /' >&2
fi
# And it must not leave a scary log line on the happy path.
printf '%s' "$out2" | grep -q 'first failing line' \
    && bad "a passing gate printed a failing-line note" \
    || ok "CONTROL: a passing gate names no failing line"

echo "land-gate-refusal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
