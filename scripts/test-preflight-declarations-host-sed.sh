#!/usr/bin/env bash
# @trace order:1545-qdb5
#
# The door reads a guard's own header for three declarations: `# preflight:
# gate-only — <reason>` (1496-w25b), `gate-only-decider` (1518-8p5k) and
# `serial` (1499-m9fj). It reads them with sed, and sed is the HOST's. On
# darwin, BSD sed rejected the `1,40{...p}` group (it wants `;}`), printed
# nothing on stdout, and so every Mac preflight read NO declaration: serial
# guards ran concurrently and gate-only ones were run, with no refusal anywhere.
# Linux's GNU sed accepted the same text, so no Linux gate could see it.
#
# This fixture does not grep build.sh for `;}`. A grep for the spelling would
# pass on any text that happens to contain it. It lifts the door's OWN
# _pf_predecide out of build.sh, plants one guard per declaration in a scratch
# root, and asks the function what it decides under whatever sed this host has.
# Pre-fix on darwin every arm but the negative control is red.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

fn="$(awk '/^_pf_predecide\(\) \{/,/^\}/' build.sh)"
if [ -z "$fn" ]; then
    echo "FAIL: _pf_predecide() not found in build.sh — the door's parser moved; re-point this fixture"
    exit 1
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pf-decl-sed.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/scripts/hooks"
plant() {  # $1 = path under scratch, $2 = header line (may be empty)
    { echo '#!/usr/bin/env bash'; [ -n "$2" ] && echo "$2"; echo 'echo ok'; } > "$SCRATCH/$1"
}
plant scripts/test-zz-go.sh      '# preflight: gate-only — drives the litmus runner end to end'
plant scripts/check-zz-god.sh    '# preflight: gate-only-decider — live synthesis costs seconds per case'
plant scripts/test-zz-serial.sh  '# preflight: serial — writes target/release/tillandsias-plan'
plant scripts/test-zz-none.sh    ''

# Run the door's own function, in a subshell, against the scratch root. The
# preconditions table is stubbed empty so only the header declarations decide.
# sed's stderr is captured: a host sed that rejects the program says so there.
decide() {  # $1 = path; prints "<rc>|<stdout>", sed complaints go to $SCRATCH/err
    local out rc
    out="$( SCRIPT_DIR="$SCRATCH"
            _preflight_preconditions() { :; }
            eval "$fn"
            _pf_predecide "$1" "${1##*/}" 2>>"$SCRATCH/err" )"
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

r="$(decide scripts/test-zz-go.sh)"
if [ "${r%%|*}" = 10 ] && [ "${r#*|}" = "skip:preflight:test-zz-go.sh:gate-only — drives the litmus runner end to end" ]; then
    ok "gate-only is read with its reason (declared skip, rc 10)"
else
    bad "gate-only was not read: got rc/out '$r', want 10 and the named skip"
fi

r="$(decide scripts/check-zz-god.sh)"
if [ "${r%%|*}" = 10 ] && [ "${r#*|}" = "skip:preflight:check-zz-god.sh:gate-only — live synthesis costs seconds per case" ]; then
    ok "gate-only-decider is read with its reason (declared skip, rc 10)"
else
    bad "gate-only-decider was not read: got rc/out '$r', want 10 and the named skip"
fi

r="$(decide scripts/test-zz-serial.sh)"
if [ "${r%%|*}" = 12 ]; then
    ok "serial is read with its reason (run alone, rc 12)"
else
    bad "serial was not read: got rc/out '$r', want rc 12"
fi

# NEGATIVE CONTROL: without a declaration the door runs the guard (rc 0). If this
# arm went red, the harness rather than the parser would be what is broken.
r="$(decide scripts/test-zz-none.sh)"
if [ "$r" = "0|" ]; then
    ok "NEGATIVE CONTROL: an undeclared guard is run (rc 0, nothing printed)"
else
    bad "an undeclared guard was not run plainly: got '$r'"
fi

if [ -s "$SCRATCH/err" ]; then
    bad "the host sed complained while the door read headers: $(head -n 1 "$SCRATCH/err")"
else
    ok "the host sed accepted every program the door reads headers with"
fi

echo "preflight-declarations-host-sed: $pass passed, $fail failed ($(sed --version >/dev/null 2>&1 && echo gnu-sed || echo bsd-sed))"
[ "$fail" -eq 0 ] && echo "ok:preflight-declarations-host-sed:$pass"
[ "$fail" -eq 0 ]
