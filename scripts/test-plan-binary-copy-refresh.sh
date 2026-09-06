#!/usr/bin/env bash
# @trace order:1060-wxdh
#
# Pin: a plan binary that does not RUN must never be installed over a canonical
# copy.
#
# HOW THIS WAS FOUND: BY CAUSING IT, on this host, 2026-09-05. Proving that the
# 1058-fenk locus-skew detector names a skew meant running
# `TILLANDSIAS_PLAN_BIN=<stub exiting 127> cycle-preflight`. The detector
# worked; preflight's expert-refresh then installed the stub over
# ~/.local/bin/tillandsias-plan and the next `next-order` answered
# `/lib64/libm.so.6: version GLIBC_2.44 not found`. Restored by hand.
#
# WHY THIS PINS THE FUNCTION AND NOT A PREFLIGHT RUN. The obvious fixture —
# run cycle-preflight with HOME redirected and assert the canonical copy is
# byte-identical — was WRITTEN AND DISCARDED, because redirecting HOME also
# redirects the podman store, so with-tillandsias-builder.sh provisioned an
# ENTIRE SECOND builder toolbox inside the scratch dir: an image pull, a running
# container, and root-owned overlay mounts that `rm -rf` could not remove and
# that had to be torn down by hand with `podman --root <scratch> rm -f`. A gate
# fixture that pulls an image and leaks a container is not a gate fixture. So
# the decision was factored into refresh_plan_binary_copy in
# scripts/plan-binary-probe.sh, where it can be exercised in milliseconds with
# no HOME redirect, no containers, and no network.
#
# The behavioural claim is unchanged: cycle-preflight now performs the refresh
# ONLY through that function, which arm 5 pins.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/plan-copy-refresh.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"

# A "runnable" binary for this test is anything answering `capabilities` 0 —
# the same evidence the probe itself uses.
cat > "$W/good" <<'GOOD'
#!/usr/bin/env bash
[ "${1:-}" = "capabilities" ] && { echo fixture-capability; exit 0; }
exit 0
GOOD
cat > "$W/stub" <<'STUB'
#!/usr/bin/env bash
echo "$0: /lib64/libm.so.6: version \`GLIBC_2.44' not found" >&2
exit 127
STUB
chmod +x "$W/good" "$W/stub"

_dest="$W/canonical"

# ── 1. THE INCIDENT: an unrunnable source must not overwrite ────────────────
install -m0755 "$W/good" "$_dest"
_before="$(sha256sum "$_dest" | cut -d' ' -f1)"
_verdict="$(refresh_plan_binary_copy "$W/stub" "$_dest")"
_after="$(sha256sum "$_dest" | cut -d' ' -f1)"
if [ "$_before" = "$_after" ]; then
    ok "an unrunnable source leaves the canonical copy byte-identical"
else
    bad "the canonical copy was REPLACED by a binary that does not run — this is the incident"
fi
[ "$_verdict" = "refresh-refused-not-runnable" ] \
    && ok "and it says so: $_verdict" \
    || bad "the refusal is not named (got '$_verdict') — silence is what made this cost a diagnosis"

# ── 2. CONTROL: a runnable source still refreshes a STALE copy ──────────────
# Without this, "never install anything" passes every arm above while silently
# ending the refresh the step exists to perform (criterion 2).
printf 'stale\n' > "$_dest"; chmod 0755 "$_dest"
_verdict="$(refresh_plan_binary_copy "$W/good" "$_dest")"
if [ "$_verdict" = "refreshed" ] && cmp -s "$W/good" "$_dest"; then
    ok "CONTROL: a runnable source still refreshes a stale canonical copy"
else
    bad "CONTROL: the refresh no longer happens for a healthy binary (got '$_verdict')"
fi

# ── 3. An identical copy is reported current and not rewritten ─────────────
_verdict="$(refresh_plan_binary_copy "$W/good" "$_dest")"
[ "$_verdict" = "current" ] && ok "an identical copy reports current" \
    || bad "an unchanged copy reported '$_verdict'"

# ── 4. An ABSENT destination is left absent ────────────────────────────────
# The step's own contract: it refreshes a path that already exists and never
# creates one, so a host that does not install the expert stays untouched.
rm -f "$_dest"
_verdict="$(refresh_plan_binary_copy "$W/good" "$_dest")"
if [ "$_verdict" = "absent" ] && [ ! -e "$_dest" ]; then
    ok "an absent canonical copy is not created"
else
    bad "an absent destination was written or misreported (got '$_verdict')"
fi

# ── 5. cycle-preflight performs the refresh ONLY through this function ─────
# The arms above pin the function; this pins that the caller still uses it.
# Without it the function could be correct and bypassed — which is how the
# original defect would come back with all of the above still green.
_pf="$(sed 's/#.*//' "$ROOT/scripts/cycle-preflight.sh")"
case "$_pf" in
    *refresh_plan_binary_copy*) ok "cycle-preflight refreshes through the guarded function" ;;
    *) bad "cycle-preflight no longer calls refresh_plan_binary_copy" ;;
esac
if printf '%s' "$_pf" | grep -qE 'install -m0755 .*expert_bin'; then
    bad "cycle-preflight installs over the expert copy directly, bypassing the runnability check"
else
    ok "cycle-preflight has no direct install over the expert copy"
fi

echo "plan-binary-copy-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
