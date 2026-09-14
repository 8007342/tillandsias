#!/usr/bin/env bash
# @trace order:1165-g6wx, spec:ci-release
#
# Fixture for probe-silverblue-update-skew.sh.
#
# REGIME: hermetic and offline. Every arm feeds the probe stub text through
# --status-from / --check-from / --journal-from, so it runs no rpm-ostree, opens
# no network, reads no journal, and asserts nothing about this host.
#
# WHY STUBS ARE THE ONLY HONEST CONSTRUCTION HERE: the condition is TRANSIENT BY
# DEFINITION — it clears the moment the updates repo publishes
# kernel-devel-matched for the base's kernel. No host can be relied on to be in
# it, and the host that WAS in it (lenovinha) is the one that cannot run this.
# A fixture that waited for a real skew would assert nothing on almost every
# run, which is the shape this fleet keeps paying for.
#
# The stub journal text is lenovinha's, read-only, 2026-09-13. No absolute
# moment is encoded in an assertion (1130-i6xj): the date appears only inside
# quoted evidence, never as something an arm compares against.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/probe-silverblue-update-skew.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok:   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ── stub inputs ─────────────────────────────────────────────────────────────
cat > "$W/status-akmods" <<'EOS'
State: idle
Deployments:
● fedora:fedora/44/x86_64/silverblue
                  Version: 44.20260912.0 (2026-09-12T00:32:41Z)
          LayeredPackages: akmod-nvidia akmods xorg-x11-drv-nvidia
EOS
cat > "$W/status-rocm" <<'EOS'
State: idle
Deployments:
● fedora:fedora/44/x86_64/silverblue
                  Version: 44.20260913.0 (2026-09-13T00:50:48Z)
          LayeredPackages: google-chrome-stable rocm
EOS
cat > "$W/check-offered" <<'EOS'
AvailableUpdate:
        Version: 44.20260913.0 (2026-09-13T00:50:48Z)
         Commit: 7fb21146b65c08b3dd69699e450358548507084fde652c4adb3f7cb32576aefc
           Diff: 44 upgraded
EOS
printf 'No updates available.\n' > "$W/check-none"
# lenovinha's depsolve failure, quoted
cat > "$W/journal-depsolve" <<'EOS'
rpm-ostree[900]: Txn Upgrade on /org/projectatomic/rpmostree1/fedora_silverblue failed: Could not depsolve transaction; 4 problems detected
rpm-ostree[900]:  Problem 1: package akmod-nvidia-3:580.95.05-1.fc44.x86_64 requires akmods, but none of the providers can be installed
rpm-ostree[900]:   - package akmods-0.6.2-14.fc44.noarch requires (kernel-devel-matched if kernel-core), but none of the providers can be installed
EOS
printf 'rpm-ostree[900]: In idle state; will auto-exit in 64 seconds\n' > "$W/journal-quiet"

run() { bash "$PROBE" "$@" 2>&1; }

# 1. THE DEFECT: akmods layered, update offered, depsolve failure in the journal
out="$(run --status-from "$W/status-akmods" --check-from "$W/check-offered" --journal-from "$W/journal-depsolve")"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'skew:akmods-kernel-devel-matched:'; then
    ok "the three conditions together report skew, with the offered version named"
else bad "the skew case gave rc=$rc: $out"; fi

# 2. NEGATIVE CONTROL A — no akmods layered. yoga's real shape, and the scope
#    test that proved the cause was akmods rather than GPU drivers generally.
out="$(run --status-from "$W/status-rocm" --check-from "$W/check-offered" --journal-from "$W/journal-depsolve")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ok:no-skew:no-akmods-layered'; then
    ok "no akmods layered reports no-skew even with a depsolve failure in the journal"
else bad "the no-akmods case gave rc=$rc: $out"; fi

# 3. NEGATIVE CONTROL B — akmods layered but nothing offered to depsolve against.
out="$(run --status-from "$W/status-akmods" --check-from "$W/check-none" --journal-from "$W/journal-depsolve")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ok:no-skew:no-update-offered'; then
    ok "no update offered reports no-skew"
else bad "the no-update case gave rc=$rc: $out"; fi

# 4. NEGATIVE CONTROL C, and the one that stops this reporting skew for every
#    akmods host forever: layered AND offered, but the journal shows no
#    depsolve failure. "An update is pending" is not "this host cannot apply it".
out="$(run --status-from "$W/status-akmods" --check-from "$W/check-offered" --journal-from "$W/journal-quiet")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'no-depsolve-failure'; then
    ok "a quiet journal reports no-skew — pending is not the same as blocked"
else bad "the quiet-journal case gave rc=$rc: $out"; fi

# 5. AN UNREADABLE INPUT IS could-not-run, NEVER no-skew (965-sxec). The probe
#    feeds a cycle preamble; a silent "ok" from a question that could not be
#    asked is the failure this fleet has paid for repeatedly.
out="$(run --status-from "$W/status-akmods" --check-from "$W/check-offered" --journal-from "$W/nonexistent")"; rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'could-not-run'; then
    ok "an unreadable journal is could-not-run, not a clean verdict"
else bad "the unreadable-journal case gave rc=$rc: $out"; fi

# 6. THE CONSTRAINT THE PACKET CARES ABOUT MOST: the probe must contain no
#    rpm-ostree invocation that can mutate a deployment. Checked as SOURCE text
#    rather than by running anything, because the only safe way to test "it
#    never mutates" is to prove the call cannot be written.
_bad="$(grep -nE 'rpm-ostree[[:space:]]+(upgrade([[:space:]]+--check)?@|deploy|rebase|pin|cleanup|install|uninstall|override|apply-live)' "$PROBE" \
        | grep -vE 'upgrade[[:space:]]+--check' | grep -vE '^\s*[0-9]+:#' || true)"
if [ -z "$_bad" ]; then
    ok "the probe contains no deployment-mutating rpm-ostree call"
else
    bad "the probe can mutate a deployment: $_bad"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: silverblue-update-skew-probe $pass/$total (1165-g6wx)"; exit 0; fi
echo "FAIL: silverblue-update-skew-probe $pass/$total (1165-g6wx)"; exit 1
