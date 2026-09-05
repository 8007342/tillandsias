#!/usr/bin/env bash
# @trace spec:windows-native-tray
#
# Order 620-duta: make the "zero dependencies ephemeral portable tool" promise
# FALSIFIABLE for the Windows tray by reading the built binary's actual PE
# import table and refusing any DLL Windows does not ship in-box.
#
# This is not theoretical. Rust's MSVC targets link the C runtime dynamically
# by default, which put `vcruntime140.dll` — a Visual C++ Redistributable
# component, not an OS component — in the tray's imports. A clean Windows
# machine without the redist would have failed to start the binary, while every
# developer machine (which has it) reported success. Static CRT removed it; this
# check is what keeps it removed.
#
# Emits exactly one line matching the falsifiable grammar:
#   ^(ok:import-surface-os-only|non-os:[a-z0-9.,_+-]+|skip:(no-tray-binary|no-import-reader))$
# Exit 0 on ok and on either skip; 1 on a non-OS import.
#
# The two skips are deliberate and are NOT failures: this runs in a corpus that
# also executes on Linux and macOS hosts, where there is no tray binary to read,
# and refusing there would make the check a platform gate instead of a contract
# check.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# DLLs shipped with Windows 10+ in-box. Anything outside this set is a runtime
# dependency the user would have to install, which is exactly what the portable
# promise forbids.
#
# `api-ms-win-*` are the API-set stubs, including the UCRT
# (`api-ms-win-crt-*`), which IS an OS component since Windows 10 — unlike
# `vcruntime140.dll`, which is not. Keeping that distinction is the whole point
# of the list; collapsing it would let the redist dependency back in.
is_os_shipped() {
    case "$1" in
        api-ms-win-*) return 0 ;;
        advapi32.dll|bcrypt.dll|bcryptprimitives.dll|combase.dll|comctl32.dll) return 0 ;;
        crypt32.dll|dbghelp.dll|dnsapi.dll|gdi32.dll|iphlpapi.dll|kernel32.dll) return 0 ;;
        ncrypt.dll|netapi32.dll|ntdll.dll|ole32.dll|oleaut32.dll|powrprof.dll) return 0 ;;
        psapi.dll|secur32.dll|shell32.dll|shlwapi.dll|user32.dll|userenv.dll) return 0 ;;
        version.dll|winmm.dll|ws2_32.dll|wtsapi32.dll) return 0 ;;
        *) return 1 ;;
    esac
}

# Test seam: a newline- or space-separated DLL list stands in for objdump, so
# BOTH directions of this check are exercisable without building a binary that
# deliberately depends on a redist.
if [[ -n "${TILLANDSIAS_IMPORT_FIXTURE:-}" ]]; then
    imports="$(printf '%s\n' $TILLANDSIAS_IMPORT_FIXTURE | tr '[:upper:]' '[:lower:]' | sort -u)"
else
    # 1043-kvvn: the cargo bin target is tillandsias-windows-tray; the shipped
    # artifact is still tillandsias-tray.exe, so an INSTALLED path passed via
    # TILLANDSIAS_TRAY_EXE keeps its name and only the dev-build default moves.
    tray_exe="${TILLANDSIAS_TRAY_EXE:-$ROOT/target/release/tillandsias-windows-tray.exe}"
    if [[ ! -f "$tray_exe" ]]; then
        echo "skip:no-tray-binary"
        exit 0
    fi
    reader=""
    for candidate in objdump llvm-objdump; do
        command -v "$candidate" >/dev/null 2>&1 && { reader="$candidate"; break; }
    done
    if [[ -z "$reader" ]]; then
        echo "skip:no-import-reader"
        exit 0
    fi
    imports="$("$reader" -p "$tray_exe" 2>/dev/null \
        | grep -iE '^[[:space:]]*DLL Name:' \
        | awk '{print tolower($3)}' | sort -u)"
    if [[ -z "$imports" ]]; then
        # A PE with no readable import table is not a pass. Treat an empty read
        # as an unusable reader rather than silently reporting a clean surface.
        echo "skip:no-import-reader"
        exit 0
    fi
fi

offenders=""
while IFS= read -r dll; do
    [[ -n "$dll" ]] || continue
    if ! is_os_shipped "$dll"; then
        offenders="${offenders:+$offenders,}$dll"
    fi
done <<< "$imports"

if [[ -n "$offenders" ]]; then
    echo "non-os:$offenders"
    exit 1
fi
echo "ok:import-surface-os-only"
exit 0
