#!/usr/bin/env bash
# ORDER 900-z3kv. The probe that lets a Linux e2e demonstrate which state it ran
# in must never turn "I could not ask" into "the room was clean".
#
# THE DEFECT BEING SERVED: a Linux clean room reuses a months-old Shamir share
# because `podman system reset --force` does not reach the host keychain, while
# the runbook asserted the reset re-initializes Vault. A test that RAN and
# reported a property it was not measuring. The probe's whole job is to stop a
# report from being silent about which state produced it — so the probe's own
# failure modes matter more than its happy path.
#
# REGIME. Every arm EXECUTES the probe. The host-dependent arms are the ones
# that cannot be faked (this host's real keychain state), and they are reported
# as observations rather than asserted in a direction; the arms that PIN
# BEHAVIOUR run against a stubbed PATH so they hold on any host, cold or warm.
# No arm materialises a secret and no arm asserts an absolute moment.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

PROBE="scripts/probe-credential-cold-state.sh"
[ -x "$PROBE" ] || { bad "$PROBE is missing or not executable"; echo "credential-cold-state-probe: $pass passed, $fail failed"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/cred-cold-probe.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# ── 1. THE SECRET IS NEVER MATERIALISED. The load-bearing safety property:
#      `secret-tool search --all` prints the secret inline and put live tokens
#      into two transcripts on 2026-08-25. Metadata answers the question, so the
#      probe must not contain the call at all — asserted on the source, because
#      "it did not print a secret on THIS host today" is not the claim.
if grep -vE '^[[:space:]]*#' "$PROBE" | grep -qE 'secret-tool[[:space:]]+search'; then
    bad "the probe calls secret-tool search — that prints the secret inline; metadata answers this question completely"
else
    ok "the probe never calls secret-tool search (metadata only)"
fi

# ── 2. COULD-NOT-RUN IS NOT COLD. With no busctl on PATH the question cannot be
#      asked, and reporting that as a clean room is the exact substitution this
#      order exists to stop. PATH is narrowed rather than a stub planted: a stub
#      that exits non-zero is still a busctl on PATH, and `command -v` would find
#      it — the same distinction that made an earlier reproduction wrong.
# A MINIMAL PATH BUILT BY SYMLINK, not a narrowed one. Narrowing to
# /usr/bin:/bin does not exclude busctl on a host that keeps it there — this arm
# SKIPPED on its author's own machine for exactly that reason, and a safety arm
# that skips where it matters is not a safety arm. Symlinking only the tools the
# probe needs makes the absence real on any host.
mkdir -p "$W/bin"
for _t in bash sed awk grep date cut tr head printf sort; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$W/bin/$_t" 2>/dev/null
done
if PATH="$W/bin" command -v busctl >/dev/null 2>&1; then
    bad "arm 2 could not construct a busctl-free PATH, so the could-not-run path is untested"
else
    out="$(PATH="$W/bin" bash "$PROBE" 2>&1)"; rc=$?
    case "$out" in
        *could-not-run*) ok "no busctl -> could-not-run, and it says so" ;;
        *cold*)          bad "no busctl reported COLD — an unaskable question became a clean-room verdict" ;;
        *)               bad "no busctl produced an unclassified verdict: $out" ;;
    esac
    case "$out" in
        *"NOT a cold verdict"*) ok "the could-not-run line states outright that it is not cold" ;;
        *) bad "the could-not-run line does not disclaim coldness; a reader skimming for 'cold' could mistake it" ;;
    esac
    [ "$rc" -eq 2 ] \
        && ok "could-not-run exits 2, distinct from both cold and warm (0)" \
        || bad "could-not-run exited $rc, expected 2 — a caller cannot branch on it"
fi

# ── 3. THE VERDICT IS DETERMINISTIC. Measured during development: the first cut
#      used `busctl --user list | grep -q ...`, and two consecutive runs on this
#      host disagreed — warm, then could-not-run. `grep -q` exits on the first
#      match and SIGPIPEs busctl, so the status depended on which side won
#      (792-ksr8). A verdict decided by a signal is exactly what this probe must
#      never emit, and a spurious could-not-run is the honest-looking half.
_verdicts="$(for _ in 1 2 3 4 5; do bash "$PROBE" 2>&1 | sed -E 's/^(credential-state:[a-z-]+).*/\1/'; done | sort -u)"
_n="$(printf '%s\n' "$_verdicts" | grep -c .)"
if [ "${_n:-0}" -eq 1 ]; then
    ok "five consecutive runs agree ($_verdicts) — no pipeline race in the verdict"
else
    bad "consecutive runs disagreed, so the verdict is decided by a race: $(printf '%s' "$_verdicts" | tr '\n' ' ')"
fi

# ── 4. BOTH OUTPUT FORMATS ANSWER, and answer the SAME WAY. The md form is what
#      gets pasted into a findings file; a format that disagreed with the line
#      form would put a different claim in the record than the one the operator
#      saw.
line_v="$(bash "$PROBE" 2>&1 | sed -E 's/^credential-state:([a-z-]+).*/\1/')"
md_out="$(bash "$PROBE" --format=md 2>&1)"
case "$line_v" in
    cold)  md_expect='credential-cold' ;;
    warm)  md_expect='credential-warm' ;;
    *)     md_expect='' ;;
esac
if [ -z "$md_expect" ]; then
    ok "SKIPPED arm 4: the line verdict is '$line_v' (could-not-run); the md form has no counterpart to compare"
elif printf '%s' "$md_out" | grep -q "$md_expect"; then
    ok "the md form reports the same verdict as the line form ($md_expect)"
else
    bad "the md form disagrees with the line form ($line_v): the findings file would record a different claim than the operator saw"
fi

# ── 5. THE ATTRIBUTE SCHEMA IS PINNED TO ITS SOURCE. The probe searches on the
#      keyring crate's `service`/`username` attributes, which vault_bootstrap.rs
#      supplies as Entry::new(KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1). An
#      earlier cut searched the wrong attribute and returned zero items on a host
#      that HOLDS the share — a false credential-cold, the very verdict this
#      order is about, produced inside its own instrument. A wrong query and an
#      absent secret look identical from outside, so the coupling is asserted.
_svc="$(grep -h 'const KEYCHAIN_SERVICE' crates/tillandsias-headless/src/vault_bootstrap.rs 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' | head -1)"
_att="$(grep -h 'const VAULT_SHAMIR_SHARE_V1' crates/tillandsias-headless/src/vault_bootstrap.rs 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' | head -1)"
if [ -z "$_svc" ] || [ -z "$_att" ]; then
    bad "could not read KEYCHAIN_SERVICE / VAULT_SHAMIR_SHARE_V1 from vault_bootstrap.rs — the probe's schema can no longer be checked against its source"
else
    if grep -q "KEYCHAIN_SERVICE=\"$_svc\"" "$PROBE" && grep -q "SHARE_ATTR=\"$_att\"" "$PROBE"; then
        ok "the probe's search attributes match vault_bootstrap.rs ($_svc / $_att)"
    else
        bad "the probe's search attributes have drifted from vault_bootstrap.rs ($_svc / $_att) — it would report cold on a host that holds the share"
    fi
fi

echo "credential-cold-state-probe: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
