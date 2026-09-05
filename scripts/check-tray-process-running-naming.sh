#!/usr/bin/env bash
# check-tray-process-running-naming.sh — the --diagnose field that observes a
# PROCESS must not be named for a VM. (980-ja2m)
#
# WHAT THIS GUARDS. `vm_owner_live` was documented as "a live tray process owns
# the VM". The probe is a singleton-lock try_acquire: it establishes that a tray
# PROCESS is running and nothing more. A wedged tray holding no VM at all takes
# the lock exactly as a healthy one does, so the field could not separate them
# in either direction — and the name asserted the separation the probe cannot
# make. Renamed to `tray_process_running` for the fact it establishes.
#
# WHY THE NEEDLES ARE CONCATENATED. The doc comments in diagnose.rs
# DELIBERATELY name the old identifiers, as history — "renamed from
# `vm_owner_live`" is the sentence a future reader needs. A guard scanning for
# the bare substring would trip on the very documentation that explains it, and
# on this file. So it scans DECLARATIONS, and assembles the needles at runtime
# so this script's own text is not a match for itself. (Trap named by
# macneo-macos 2026-09-04; same technique as vz.rs's minimal-PATH scan.)
#
# THE REQUIRE ARM IS NOT OPTIONAL. Two forbid-arms alone pass on a file with the
# field DELETED, which is not the fixed state — it is a different defect. So the
# new declaration must be present.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:tray-process-naming:[0-9]+ checked|violation:tray-process-naming:[0-9]+)$
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TARGET="crates/tillandsias-macos-tray/src/diagnose.rs"

# Assembled, never written whole — see the header.
_old_field="vm_""owner_live"
_old_fn="live_""tray_owns_vm"
forbid_field="pub ${_old_field}:"
forbid_fn="fn ${_old_fn}"
require_field="pub tray_process_running: bool,"

violations=0
detail=""

if [ ! -f "$TARGET" ]; then
    echo "violation:tray-process-naming:1"
    echo "  $TARGET is missing — the guard cannot run, and a check that cannot run must not report ok (980-ja2m)" >&2
    exit 1
fi

if grep -Fq "$forbid_field" "$TARGET"; then
    violations=$((violations + 1))
    detail="${detail}  ${TARGET}: declares '${forbid_field}' — the field observes a PROCESS, not a VM owner (980-ja2m)"$'\n'
fi

if grep -Fq "$forbid_fn" "$TARGET"; then
    violations=$((violations + 1))
    detail="${detail}  ${TARGET}: declares '${forbid_fn}' — the probe establishes that a tray process is running, not that it owns a VM (980-ja2m)"$'\n'
fi

if ! grep -Fq "$require_field" "$TARGET"; then
    violations=$((violations + 1))
    detail="${detail}  ${TARGET}: does not declare '${require_field}' — deleting the field is not the fixed state (980-ja2m)"$'\n'
fi

if [ "$violations" -gt 0 ]; then
    echo "violation:tray-process-naming:${violations}"
    printf '%s' "$detail" >&2
    exit 1
fi

echo "ok:tray-process-naming:3 checked"
