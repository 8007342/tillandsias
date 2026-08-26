#!/usr/bin/env bash
# Fixture for order 799-tb7q — SHIPPED diagnostics degrade, they do not refuse.
#
# THE RULE, and it is narrower than "handle missing tools gracefully":
#
#   A diagnostic must always produce its DATA. Only the PRESENTATION may
#   degrade. And a missing parser must never be reported as a fault of the
#   thing under diagnosis.
#
# Both shipped diagnostics used to `exit 1` with "brew install jq". Two defects:
# they told an END USER to install a developer tool, and — the expensive one —
# exit 1's documented meaning was "could not locate or invoke tillandsias-tray,
# OR jq missing", so a healthy tray and an absent parser produced the same
# verdict. You run a diagnostic precisely when something is already wrong, which
# makes a misattributed verdict costlier here than anywhere else.
#
# NO SECOND JSON PARSER. The degrade path prints the RAW tray output rather than
# hand-rolling a jq-free parse. Two parsers that can disagree is a
# misattribution generator, and a diagnostic is the last place to put one.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/shipped-diag.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# A PATH THAT GENUINELY LACKS jq AND toolbox — and building it correctly is
# the fiddly part this packet's own notes already warned about.
#
# `PATH="$W/emptybin"` does NOT work: /usr/bin still carries jq, so
# the fixture silently tests the WITH-parser case while claiming to test the
# without. That is exactly what the first draft of this file did — it reported
# `PASS Version: 9` from a formatted run and only the exit-code arm caught it.
# A shadowing stub does not work either: `command -v` finds any EXECUTABLE
# regardless of exit status, and skips a non-executable one. So the only honest
# construction is a curated bin directory containing everything the script needs
# and nothing it must not find.
mkdir -p "$W/emptybin"
for _t in bash sh env printf echo grep sed awk cat cut tr head tail sort uniq           dirname basename mktemp rm mkdir test true false uname date wc; do
    _p="$(command -v "$_t" 2>/dev/null)" || continue
    ln -sf "$_p" "$W/emptybin/$_t" 2>/dev/null || true
done
# Prove the construction before relying on it — a fixture whose environment does
# not hold its own precondition cannot fail for the right reason.
if env -i PATH="$W/emptybin" sh -c 'command -v jq' >/dev/null 2>&1; then
    bad "PRECONDITION: jq is still reachable on the curated PATH — arms 1-2 would test nothing"
fi
if env -i PATH="$W/emptybin" sh -c 'command -v toolbox' >/dev/null 2>&1; then
    bad "PRECONDITION: toolbox is still reachable on the curated PATH"
fi
ok "curated PATH genuinely lacks jq and toolbox (precondition asserted, not assumed)"

# A fake tray that ANSWERS — the point is that the subject is healthy while the
# parser is absent, which is precisely the case the old exit 1 mis-reported.
cat >"$W/tray" <<'TRAYEOF'
#!/usr/bin/env bash
case " $* " in
  *" --diagnose "*|*" --diagnose"*)
    printf '%s\n' '{"version":"9.9.9","in_app":true,"image_root":"/tmp/x","checks":[]}'
    exit 0 ;;
esac
exit 0
TRAYEOF
chmod +x "$W/tray"

# ── 1. NO PARSER, HEALTHY SUBJECT: data still comes out, and exit != 1. ──────
out="$(cd "$W" && env -i HOME="$W" PATH="$W/emptybin" \
       TILLANDSIAS_TRAY_EXE="$W/tray" \
       bash "$ROOT/scripts/tray-diagnose.sh" 2>"$W/err")"; rc=$?
if printf '%s' "$out" | grep -q '"version":"9.9.9"'; then
    ok "no parser -> the tray's RAW answer still reaches stdout (data preserved)"
else
    bad "degrade path lost the data: out=$(printf '%s' "$out" | head -c 120)"
fi
[ "$rc" -ne 1 ] \
    && ok "exit is not 1 — a missing parser is not reported as a broken tray (rc=$rc)" \
    || bad "exit 1 on a HEALTHY tray with no parser — the original misattribution"
[ "$rc" -eq 3 ] && ok "exit 3 is the documented parser-absent code" \
    || bad "expected the documented exit 3, got $rc"

# ── 2. THE DIAGNOSIS SAYS WHOSE FAULT IT IS NOT. ────────────────────────────
grep -q 'NOT a tray' "$W/err" \
    && ok "stderr states outright that this is not a tray fault" \
    || bad "must say explicitly that the tray is not at fault"
grep -qi 'brew install jq' "$W/err" \
    && bad "still tells an end user to install a developer tool" \
    || ok "does not instruct an end user to install a developer tool"

# ── 3. NEGATIVE CONTROL: WITH a parser, nothing degrades. ───────────────────
# A degrade path that fires when it should not is as bad as one that never
# fires — it would train readers to ignore the notice.
if command -v jq >/dev/null 2>&1; then
    out2="$(cd "$W" && env HOME="$W" TILLANDSIAS_TRAY_EXE="$W/tray" \
            bash "$ROOT/scripts/tray-diagnose.sh" 2>"$W/err2")"; rc2=$?
    [ "$rc2" -ne 3 ] && ok "with jq present the parser-absent path does NOT fire (rc=$rc2)" \
        || bad "degraded despite jq being available"
    grep -q 'no JSON processor available' "$W/err2" \
        && bad "printed the parser-absent notice while a parser was present" \
        || ok "the notice is silent when a parser exists"
else
    ok "SKIP(no host jq): cannot run the with-parser control here"
fi

# ── 4. NO BARE `jq` SURVIVES in either shipped diagnostic. ─────────────────
# The guard against silent regression: a future edit that adds `| jq …` back
# reintroduces the hard failure on exactly the machines that ship.
for f in scripts/tray-diagnose.sh scripts/diagnose-macos-provision.sh; do
    if grep -nE '\| *jq |^\s*jq ' "$ROOT/$f" | grep -vE '^\s*[0-9]+:\s*#' | grep -q .; then
        bad "$f still calls jq bare — it will hard-fail where it ships"
    fi
done
ok "neither shipped diagnostic calls jq bare"

# ── 5. Both route through the documented host->toolbox dispatch. ────────────
for f in scripts/tray-diagnose.sh scripts/diagnose-macos-provision.sh; do
    grep -q 'toolbox run --container tillandsias-builder jq' "$ROOT/$f" \
        || bad "$f does not take the documented toolbox fallback"
done
ok "both take the documented host-preferred / toolbox-fallback dispatch"

# ── 6. They must stay bash 3.2 clean — these RUN ON macOS. ─────────────────
# A degrade path that only works on bash 4 degrades into a syntax error on the
# platform it was written for.
#
# DELEGATED TO THE REAL CHECKER rather than reimplemented. The first version of
# this arm inlined its own bash-4 regex, which made THIS file trip
# check-bash-dialect.sh — the checker cannot distinguish a bash-4 construct from
# a regex that searches for one. Assembling the pattern from pieces dodged half
# of it and still matched on `mapfile|readarray`.
#
# The deeper problem with the inline version was not the false positive: it was
# that a second copy of the rule can drift from the first, and then this arm
# would report "clean" against a definition the project no longer uses. There is
# one checker, it is wired into ./build.sh --check, and it already scans these
# two files. Ask it.
if [ -x "$ROOT/scripts/check-bash-dialect.sh" ]; then
    if bash "$ROOT/scripts/check-bash-dialect.sh" >/dev/null 2>&1; then
        ok "both remain bash 3.2 clean (per check-bash-dialect.sh, the one definition)"
    else
        bad "check-bash-dialect.sh refuses the tree — these two ship to macOS (bash 3.2)"
    fi
else
    bad "check-bash-dialect.sh is missing; the bash-3.2 property is unverified"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:shipped-diagnostic-tool-dispatch:all"
    exit 0
fi
echo "fail:shipped-diagnostic-tool-dispatch"
exit 1
