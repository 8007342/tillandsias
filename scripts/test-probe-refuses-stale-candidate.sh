#!/usr/bin/env bash
# @trace order:1172-dyvd, spec:accel-capability-probe
#
# Fixture for order 1172-dyvd: host-capability-probe.sh's resolver must REFUSE a
# candidate it cannot show is CURRENT, and must say which one and why.
#
# WHY THIS EXISTS. `resolve_probe` admitted any candidate whose
# `--inference-tier` exited 0. That proves a binary RUNS and says nothing about
# whether it knows the vocabulary the ledger is written in — and this script
# WRITES THE LEDGER. So a stale-but-runnable binary published a confident wrong
# capability row, silently, and the matrix routes on that row.
#
# MEASURED on yolanda 2026-09-13, both binaries present, same command:
#   ./target/release/tillandsias    PE32+, 2026-08-29, --inference-tier rc 0
#     -> accel_gpu=none accel_npu=none          (no accel_side key at all)
#   ./target/debug/tillandsias.exe  PE32+, 2026-09-13
#     -> accel_gpu=present-unusable AMD_Radeon_TM_860M_Graphics
#        accel_npu=present-unusable NPU_Compute_Accelerator_Device
# The stale one won — it is the extensionless candidate tried second — and the
# row it published says this host has no GPU and no NPU. It has both.
#
# POLARITY, which is why this row went first: a host with NO runnable binary
# exits 2 and misleads nobody (esmeraldinha, 1171-ccf2). A host with a STALE
# runnable one exited 0 and published. The loud failure was already safe; the
# silent one was not.
#
# REGIME: hermetic ONCE THE HOST'S OWN CANDIDATES ARE SHADOWED (see run_probe
# below; the first Linux run found the installed launcher on PATH answering
# for the refused fake). Every arm builds its own fake candidates in a scratch dir
# and drives the real resolver through TILLANDSIAS_HEADLESS_BIN. No cargo, no
# network, no repo binary, no host state, and nothing here encodes a wall-clock
# time — the fakes differ by what they PRINT, never by mtime, because the fix is
# deliberately a vocabulary probe and not a timestamp comparison.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$REPO_ROOT/scripts/host-capability-probe.sh"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/probe-stale-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A STALE candidate: runs, answers --inference-tier, and emits a pre-schema-3
# envelope with no accel_side key — exactly the Aug-29 binary's shape.
cat > "$TMP/stale" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --inference-tier) echo "cpu"; exit 0 ;;
  --capabilities)   echo "accel_class=cpu-only accel_gpu=none accel_npu=none accel_cpu_cores=16"; exit 0 ;;
esac
exit 0
EOF

# A CURRENT candidate: same, plus the discriminating key.
cat > "$TMP/current" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --inference-tier) echo "cpu"; exit 0 ;;
  --capabilities)
      echo "accel_class=cpu-only accel_gpu=none accel_npu=none accel_side=windows-host"
      exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/stale" "$TMP/current"

# ISOLATE THE RESOLVER FROM THE HOST (macuahuitl, 2026-09-13, first Linux run
# of this fixture). resolve_probe REFUSES a stale candidate and CONTINUES to
# the next one — ./target/release/tillandsias, then `tillandsias` on PATH — so
# on a host whose installed launcher is current, the stale arm read as
# admitted (rc=0) and the identical-age arm as "same verdict": the fixture was
# hermetic only on a host with no fallback candidate, which is the host that
# wrote it. The shadow `tillandsias` fails --inference-tier so the resolver
# skips it exactly as it skips an absent one, and running from $TMP takes the
# relative release path out of the list. PATH is prefixed, never replaced:
# a fixture whose scratch PATH came from bash and git had no dirname on a Mac.
mkdir -p "$TMP/shadow"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/shadow/tillandsias"
chmod +x "$TMP/shadow/tillandsias"
run_probe() {
    ( cd "$TMP" && PATH="$TMP/shadow:$PATH" TILLANDSIAS_HEADLESS_BIN="$1" bash "$PROBE" --fragment 2>&1 >/dev/null )
}

# ORDER 1171-ccf2. The install-dir arm needs the OPPOSITE of run_probe: no
# TILLANDSIAS_HEADLESS_BIN at all, because that override pre-empts every later
# candidate and would prove nothing about whether the install path is consulted.
# LOCALAPPDATA is fixture-supplied, which is also the regime guard under test --
# the candidate must appear when it is set and vanish when it is not.
run_probe_install_dir() {
    ( cd "$TMP" && PATH="$TMP/shadow:$PATH" LOCALAPPDATA="$1"         env -u TILLANDSIAS_HEADLESS_BIN bash "$PROBE" --fragment 2>&1 >/dev/null )
}

# ── 1. THE DEFECT: a stale candidate must NOT be admitted. ───────────────────
out="$(run_probe "$TMP/stale")"
rc=$?
if [ "$rc" -eq 2 ]; then
    ok "a stale candidate is refused (rc=2) rather than published"
else
    bad "a stale candidate produced rc=$rc — pre-fix this was 0 and the row was written"
fi
case "$out" in
    *refused:probe:stale-candidate:*stale*)
        ok "the refusal NAMES the candidate it refused" ;;
    *)
        bad "the refusal does not name the candidate: $out" ;;
esac
case "$out" in
    *accel_side*) ok "the refusal says WHICH contract the candidate predates" ;;
    *)            bad "the refusal does not name the missing key: $out" ;;
esac

# ── 2. THE POSITIVE CONTROL, and it is not optional. A guard that refuses
#       everything is not a fix; the pre-fix resolver admitted BOTH of these.
out2="$(run_probe "$TMP/current")"
rc2=$?
# ASSERT ON RESOLUTION, NOT ON THE WHOLE RUN. These fakes emit the envelope
# line and no capability DOCUMENT, so the probe legitimately fails later at
# "not a schema-2-or-later capability document" (rc=1). That is a different
# layer and a limitation of the fake, not of the fix. The property this row
# owns is whether the RESOLVER admitted the candidate, so the arm asserts
# rc != 2 (the resolver's own refusal code) and the absence of the stale line.
# Asserting rc=0 would have required building a full fake document and would
# have coupled this fixture to a schema it does not test.
if [ "$rc2" -ne 2 ]; then
    ok "a current candidate is still ADMITTED by the resolver (rc=$rc2, not the resolver's 2)"
else
    bad "a current candidate was refused by the resolver — the fix would block every host: $out2"
fi
case "$out2" in
    *refused:probe:stale-candidate:*)
        bad "a current candidate was reported as stale: $out2" ;;
    *)  ok "and is not reported as stale" ;;
esac

# ── 3. THE DISCRIMINATOR IS THE VOCABULARY, NOT THE FILESYSTEM. Both fakes are
#       created in the same second by the same script, so any mtime-based rule
#       would rank them identically. Arm 1 and arm 2 disagree, which is only
#       possible if the check reads what the candidate PRINTS.
if [ "$rc" -eq 2 ] && [ "$rc2" -ne 2 ]; then
    ok "two candidates of identical age get opposite RESOLVER verdicts — the check reads output, not mtime"
else
    bad "identical-age candidates got the same verdict; the discriminator is not the vocabulary"
fi

# ── 4. RUNNABILITY IS STILL REQUIRED, and separately refused. A candidate that
#       does not run at all must not be mistaken for a stale one — the two
#       states have different remedies (build one, versus rebuild yours).
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP/broken"
chmod +x "$TMP/broken"
out3="$(run_probe "$TMP/broken")"
case "$out3" in
    *refused:probe:stale-candidate:*broken*)
        bad "a NON-RUNNING candidate was reported as stale; it is absent, not out of date" ;;
    *)  ok "a non-running candidate is not misreported as stale" ;;
esac

# ── 5. ORDER 1171-ccf2: the resolver consults the WINDOWS INSTALL DIR.
#
# install-windows.ps1 extracts into $LOCALAPPDATA\Programs\Tillandsias, which is
# NOT on PATH — so before this order a Windows host with a tray installed had no
# candidate at all and host-capability-probe.sh exited 2 at the very locus whose
# expired-row verdict told it to publish. The installer is deliberately not made
# to edit the user's PATH; the resolver looks where the install puts things.
#
# REGIME for these arms: LOCALAPPDATA is fixture-supplied and the host's own
# value never reaches them, so they read the same on a Linux host (where the
# variable is normally unset) as on Windows.
inst="$TMP/fakelocal/Programs/Tillandsias"
mkdir -p "$inst"
cp "$TMP/current" "$inst/tillandsias.exe"

out5="$(run_probe_install_dir "$TMP/fakelocal")"
rc5=$?
if [ "$rc5" -ne 2 ]; then
    ok "a current binary in the install dir is CONSULTED (rc=$rc5, not the resolver's 2)"
else
    bad "the install dir was not consulted; a Windows install still has no candidate: $out5"
fi

# THE VOCABULARY PROBE STILL APPLIES THERE. Living in the install directory is
# not a currency claim: a stale installed tillandsias.exe must be refused BY
# NAME like any other candidate, or this order would re-open 1172-dyvd through
# a new door.
cp "$TMP/stale" "$inst/tillandsias.exe"
out6="$(run_probe_install_dir "$TMP/fakelocal")"
case "$out6" in
    *refused:probe:stale-candidate:*tillandsias.exe*)
        ok "a STALE binary in the install dir is refused by name, not admitted for its location" ;;
    *)
        bad "a stale installed binary was not refused by name: $out6" ;;
esac

# THE REGIME GUARD: with LOCALAPPDATA unset the candidate must not exist at all,
# so the in-guest Linux locus never consults a Windows path nor reports a
# Windows binary as its own.
cp "$TMP/current" "$inst/tillandsias.exe"
out7="$( cd "$TMP" && PATH="$TMP/shadow:$PATH"     env -u TILLANDSIAS_HEADLESS_BIN -u LOCALAPPDATA bash "$PROBE" --fragment 2>&1 >/dev/null )"
rc7=$?
if [ "$rc7" -eq 1 ] || [ "$rc7" -eq 2 ]; then
    ok "with LOCALAPPDATA unset the install candidate does not exist (rc=$rc7)"
else
    bad "an unset LOCALAPPDATA still reached a Windows install path (rc=$rc7): $out7"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:probe-stale-candidate-fixture:all"
    exit 0
fi
echo "fail:probe-stale-candidate-fixture"
exit 1
