#!/usr/bin/env bash
# ORDER 1138-bb5r. A tool that is PRESENT and cannot RUN must not be handed back
# as available.
#
# resolve_tool used to accept anything `command -v` could see. That is a claim
# about the PATH, not about the binary. MEASURED on lenovinha while reproducing
# 1137-dzzu: with a stub `rg` on PATH exiting non-zero,
# scripts/check-cheatsheet-refs.sh ran a broken rg for every scan, matched
# nothing, recorded no broken reference, and exited 0 — announcing that every
# cheatsheet reference resolves, having examined none.
#
# WHY THIS MATTERED MORE THAN THE BUG IT WAS FOUND UNDER. 1137-dzzu was a FALSE
# REFUSAL: loud, it blocked a land, somebody read the log. This is a FALSE PASS.
# And the defect sits in the shared resolver, deliberately the one definition of
# dispatch, so every guard that resolves a tool through it inherits the same
# silence.
#
# NOT HYPOTHETICAL ON THIS FLEET: a brew shim whose on-demand install fails
# under attestation verification is exactly a present-but-unusable binary, and
# 965-sxec already measured that shape for ruby on a forge — on PATH, exit 127
# when run. That packet fixed one caller. This pins the resolver.
#
# REGIME. Every arm EXECUTES resolve_tool against a PATH built in a temporary
# directory. Nothing is read from the resolver source, and nothing depends on
# which tools this particular host happens to have: the usable and unusable
# tools are both fabricated here under names no real host carries. Arm 4 is
# skipped rather than faked when no toolbox is reachable, and says so. No arm
# asserts any absolute moment.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

. "$ROOT/scripts/lib/tool-dispatch.sh" || {
    echo "FAIL could not source scripts/lib/tool-dispatch.sh"
    echo "tool-dispatch-rejects-unusable-host-tool: 0 passed, 1 failed"
    exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/unusable-host-tool.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/bin"

# A USABLE tool: answers --version 0, like every real one we dispatch.
cat > "$work/bin/tilde-probe-usable" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { echo "tilde-probe-usable 1.0"; exit 0; }
echo "ran"; exit 0
STUB

# An UNUSABLE tool: on PATH, non-zero however it is invoked. This is the shim
# shape — installed, resolvable, and dead — not a missing file.
cat > "$work/bin/tilde-probe-broken" <<'STUB'
#!/bin/sh
echo "tilde-probe-broken: not installed (1138-bb5r fixture)" >&2
exit 127
STUB
chmod +x "$work/bin/tilde-probe-usable" "$work/bin/tilde-probe-broken"

# ── ARM 1 — THE CONTROL. A usable host tool is still resolved, unchanged. If
#           the probe were too strict everything would fall through to the
#           toolbox and the whole host arm would quietly stop being used.
got="$(PATH="$work/bin:$PATH" resolve_tool tilde-probe-usable 2>/dev/null || printf '')"
if [ "$got" = "tilde-probe-usable" ]; then
    ok "a usable host tool is still resolved to its bare name"
else
    bad "a usable host tool resolved to '$got' — the probe is rejecting working tools"
fi

# ── ARM 2 — THE DEFECT. Present, unusable, must not come back as available.
got="$(PATH="$work/bin:$PATH" resolve_tool tilde-probe-broken 2>/dev/null || printf '')"
if [ "$got" = "tilde-probe-broken" ]; then
    bad "a present-but-unusable host tool was handed back — callers will run it and fail quietly, which is the 1138-bb5r defect"
elif [ -z "$got" ]; then
    ok "a present-but-unusable host tool is NOT returned — presence is no longer mistaken for availability"
else
    ok "a present-but-unusable host tool fell through to the toolbox ('$got') rather than being returned"
fi

# ── ARM 3 — THE RETURN CODE, not just the string. Callers branch on it
#           (`resolve_tool rg || printf ''`), so a function that printed nothing
#           and still returned 0 would satisfy arm 2 and break every caller.
if PATH="$work/bin:$PATH" resolve_tool tilde-probe-broken >/dev/null 2>&1; then
    # Only legitimate if a toolbox genuinely supplied it, which it cannot for a
    # name invented in this fixture.
    bad "resolve_tool returned success for an unusable tool no toolbox can supply"
else
    ok "resolve_tool returns non-zero for an unusable tool, so the caller's fallback arm runs"
fi

# ── ARM 4 — THE CONSEQUENCE AT THE CALL SITE, which is where the defect was
#           actually observed. With rg present-but-broken, check-cheatsheet-refs
#           must reach its could-not-run exit 2 instead of passing over nothing.
#
#           SKIPPED, LOUDLY, where a toolbox can supply a real rg: there the
#           correct answer is that the toolbox arm rescues the run, and asserting
#           exit 2 would pin the wrong behaviour.
cat > "$work/bin/rg" <<'STUB'
#!/bin/sh
echo "rg: not installed (1138-bb5r fixture)" >&2
exit 127
STUB
chmod +x "$work/bin/rg"

if command -v toolbox >/dev/null 2>&1 \
   && toolbox run --container tillandsias-builder rg --version >/dev/null 2>&1; then
    ok "SKIPPED arm 4: this host has a real rg in the toolbox, so the fallback correctly rescues the run"
else
    PATH="$work/bin:/usr/bin:/bin" bash scripts/check-cheatsheet-refs.sh >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "a broken host rg reaches the could-not-run exit 2 instead of passing over zero references"
    elif [ "$rc" -eq 0 ]; then
        bad "a broken host rg still yields exit 0 — the checker is passing having examined nothing, which is the whole packet"
    else
        bad "a broken host rg yields exit $rc, expected 2 (could-not-run)"
    fi
fi

echo "tool-dispatch-rejects-unusable-host-tool: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
