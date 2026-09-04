#!/usr/bin/env bash
# ORDER 965-sxec. A gate that cannot RUN a check must never assert what the
# check would have FOUND.
#
# Measured on lenovinha-tillandsias-forge 2026-09-02: the forge image ships no
# ruby by design, scripts/archive-plan-packets.sh exited 127, and build.sh's
# `-ne 0` branch printed "the plan archiver would CHANGE THE READY SET, orphan
# events, or leave archived rows unanswerable" — a substantive claim about the
# ledger, on the strength of a command that never executed. The agent it blocked
# then went looking for ledger damage that did not exist. 923-ws3r had already
# built the could-not-run channel; 127 simply never reached it.
#
# THIS FIXTURE PINS THE VERDICT TEXT, not the exit code alone, because the exit
# code was never the defect — build.sh failed either way. What was wrong was
# WHAT IT SAID, and a test that only checked the code would have stayed green
# through the whole incident.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()   { echo "ok   $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL $*"; fail=$((fail + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/archiver-verdict.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

# THE FORGE'S CONDITION, REPRODUCED RATHER THAN DESCRIBED: a `ruby` that is
# ON PATH and cannot execute. That is precisely what a forge has — a brew shim
# whose on-demand install fails by design under attestation verification — and
# it is why the probe in the script runs the interpreter instead of testing for
# the binary. A fixture that emptied PATH would exercise a different bug and,
# on an MSYS host, would also break the shell it needs to run the script with.
#
# `toolbox` is shadowed the same way so `_ruby`'s fallback arm cannot resolve
# either; on a host that has no toolbox this changes nothing, and on one that
# does it stops the fixture depending on which host it runs on.
mkdir -p "$work/bin"
for c in ruby toolbox; do
    printf '#!/bin/sh
echo "%s: not installed (965-sxec fixture)" >&2
exit 127
' "$c" > "$work/bin/$c"
    chmod +x "$work/bin/$c"
done

out="$(PATH="$work/bin:$PATH" bash scripts/archive-plan-packets.sh --check 2>&1)"
rc=$?

# ARM 1 — the exit code reaches the could-not-run channel instead of a bare 127.
if [ "$rc" -eq 3 ]; then
    ok "no usable ruby -> exit 3 (could-not-run), not a bare 127"
else
    bad "no usable ruby -> exit $rc, expected 3 (this is what build.sh routes on)"
fi

# ARM 2 — the machine-readable token build.sh's narrow forge skip keys on. Only
# THIS cause is skip-eligible; a stale plan binary also exits 3 and must not be.
if printf '%s' "$out" | grep -q 'could-not-run:no-usable-ruby'; then
    ok "the skip-eligible cause is tokenised"
else
    bad "no could-not-run:no-usable-ruby token — build.sh cannot tell this exit 3 from the others"
fi

# ARM 3 — THE ONE THAT MATTERS. The output must not assert anything about the
# ready set, because nothing measured it.
if printf '%s' "$out" | grep -qi 'CHANGE THE READY SET'; then
    bad "the output claims the ready set changed on a run that never executed the check"
else
    ok "no substantive ready-set claim on a check that could not run"
fi

# ARM 4 — build.sh's own branch text. A grep on the source rather than a full
# gate run: the routing is a two-line decision and running ./build.sh --check
# here would cost ten minutes to re-test one `if`.
if grep -q 'could-not-run:no-usable-ruby' build.sh \
   && grep -q 'TILLANDSIAS_HOST_KIND:-}" = "forge"' build.sh; then
    ok "build.sh skips only in a forge and only on the tokenised cause"
else
    bad "build.sh no longer keys the skip on both the forge and the token — it may now skip a stale-binary exit 3"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: archiver could-not-run verdict ${pass}/${pass} (965-sxec)"
    exit 0
fi
echo "FAIL: archiver could-not-run verdict ${pass} passed, ${fail} failed (965-sxec)"
exit 1
