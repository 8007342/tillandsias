#!/usr/bin/env bash
# @trace order:859-b2zc, spec:accel-capability-probe
#
# Fixture for order 859-b2zc: check-capability-row.sh must resolve a host
# WITHOUT a `hostname` binary, and must refuse to publish an EPHEMERAL identity.
#
# WHY THIS EXISTS. check-capability-row.sh resolved the host with
# `hostname -s || hostname`. No Fedora image this project runs ships that
# binary — both WSL distros on the Windows hosts and localhost/tillandsias-forge,
# the last verified directly under podman on 2026-08-23 — so the check answered
# `unavailable:host-unresolvable` in exactly the environments the 850-bif2 gate
# exists to prompt. The forge has therefore never been asked to publish a
# capability row, and the matrix read that as inattention.
#
# The chain was already correct in scripts/agent-identity.sh (order 743-mgf3,
# whose comment says "some environments ship no `hostname`"). Four other scripts
# had privately re-implemented the weaker version. This fixture pins the
# behaviour so the fallbacks cannot be dropped a third time.
#
# HOW `hostname` IS MADE ABSENT, stated plainly because the simulation is not
# literal: PATH is prefixed with a temp bin holding a `hostname` STUB that
# exits non-zero and prints nothing. Every call site invokes it as
# `hostname -s 2>/dev/null || ...`, to which a missing binary and a failing one
# are indistinguishable — and a stub is portable, where genuinely emptying PATH
# would strip the coreutils the script needs. The distinction this fixture
# cares about is "did the chain fall through to uname -n / /etc/hostname", and
# the stub exercises exactly that.
#
# HERMETIC: stub plan binary and stub hostname under mktemp; identity forced
# through the documented env seams (TILLANDSIAS_WORKSTATION, HOSTNAME,
# TILLANDSIAS_ETC_HOSTNAME, TILLANDSIAS_HOST_KIND,
# TILLANDSIAS_FORGE_CONTEXT). Never writes to the repo —
# in particular it never creates a .forge-startup-context.md marker, which
# would dirty the worktree and trip the meta-orchestration boundary guard.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/check-capability-row.sh"

pass=0; fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/capability-row-check.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

mkdir -p "$TMPD/bin"

# `hostname` is present on PATH but always fails — see the header.
cat > "$TMPD/bin/hostname" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMPD/bin/hostname"

# The matrix the stub plan binary serves. A real row line is tab-separated;
# the SUT greps `^host:<name><TAB>`, so the tab is load-bearing.
printf 'capability-matrix: 1 row(s)\nhost:knownbox\tlocus:bare-metal\tkind:linux\n' > "$TMPD/matrix.txt"

cat > "$TMPD/bin/stub-plan" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    capabilities)      printf 'compact\ncapability-matrix\n'; exit 0 ;;
    capability-matrix) cat "$TMPD/matrix.txt"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMPD/bin/stub-plan"

# Run the SUT with a controlled environment. Every case gets the failing
# `hostname` first on PATH and the stub plan binary; the rest is per-case.
run_sut() { #  run_sut <env assignments...>  -> prints "<verdict>|<exit>"
    local out rc
    # The outer process may itself be a forge. Each case declares its own
    # simulated locus; inherited forge/workstation markers would otherwise
    # divert the ordinary-host cases into the forge refusal branch before the
    # identity fallback under test is reached.
    out="$(env -u TILLANDSIAS_HOST_KIND -u TILLANDSIAS_WORKSTATION "$@" \
        PATH="$TMPD/bin:$PATH" \
        TILLANDSIAS_PLAN_BIN="$TMPD/bin/stub-plan" \
        TILLANDSIAS_FORGE_CONTEXT="$TMPD/no-forge-context" \
        bash "$SUT" 2>/dev/null)"
    rc=$?
    printf '%s|%s' "$out" "$rc"
}

echo "capability-row-check: 859-b2zc"

# 1-2. The regression itself: no usable `hostname`, identity in $HOSTNAME.
#      Before the fix both of these were unavailable:host-unresolvable|2.
ck "no hostname binary, HOSTNAME known -> ok" \
   "ok:capability-row-reported:knownbox|0" \
   "$(run_sut HOSTNAME=knownbox)"

ck "no hostname binary, HOSTNAME unknown -> due (not unavailable)" \
   "due:no-capability-row:otherbox|1" \
   "$(run_sut HOSTNAME=otherbox)"

# 3. Fallback one step further: HOSTNAME empty, /etc/hostname readable.
printf 'knownbox\n' > "$TMPD/etc-hostname"
ck "HOSTNAME empty -> falls through to /etc/hostname" \
   "ok:capability-row-reported:knownbox|0" \
   "$(run_sut HOSTNAME= TILLANDSIAS_ETC_HOSTNAME="$TMPD/etc-hostname")"

# 4. The matrix fold key is lowercase; Windows hosts report `Esmeraldinha`.
#    A verdict that skipped the lowercase would miss its own row.
ck "uppercase node name is lowercased" \
   "ok:capability-row-reported:knownbox|0" \
   "$(run_sut HOSTNAME=KnownBox)"

# 5. Domain-stripped: a FQDN must not become a different host.
ck "FQDN is domain-stripped" \
   "ok:capability-row-reported:knownbox|0" \
   "$(run_sut HOSTNAME=knownbox.ayahuitlcalpan.com)"

# 6. Launch-provided identity wins over the node name.
ck "TILLANDSIAS_WORKSTATION overrides HOSTNAME" \
   "ok:capability-row-reported:knownbox|0" \
   "$(run_sut TILLANDSIAS_WORKSTATION=knownbox HOSTNAME=otherbox)"

# 7-8. The half that is NOT just a widened chain. A forge has no stable node
#      name (no --hostname at launch, no exported workstation), so repairing
#      the chain alone would have it publish a row per container. It must
#      decline instead — and must still work when a stable name IS provided.
ck "forge without a stable identity refuses to publish" \
   "unavailable:forge-identity-ephemeral|2" \
   "$(run_sut TILLANDSIAS_HOST_KIND=forge HOSTNAME=d872da8c03df)"

ck "forge WITH TILLANDSIAS_WORKSTATION resolves normally" \
   "ok:capability-row-reported:knownbox|0" \
   "$(run_sut TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_WORKSTATION=knownbox HOSTNAME=d872da8c03df)"

# 9. An unreadable instrument is reported, never guessed around. Composed the
#    same way run_sut does — capturing stdout in $(...) first, so the verdict's
#    trailing newline is stripped before the exit code is appended.
_out="$(env -u TILLANDSIAS_HOST_KIND -u TILLANDSIAS_WORKSTATION \
        PATH="$TMPD/bin:$PATH" TILLANDSIAS_PLAN_BIN="$TMPD/bin/does-not-exist" \
        TILLANDSIAS_FORGE_CONTEXT="$TMPD/no-forge-context" \
        HOSTNAME=knownbox bash "$SUT" 2>/dev/null)"
_rc=$?
ck "no runnable plan binary is reported" \
   "unavailable:no-runnable-plan-binary|2" \
   "$_out|$_rc"

printf 'capability-row-check: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "ok:capability-row-check:$pass"
    exit 0
fi
echo "fail:capability-row-check:$fail"
exit 1
