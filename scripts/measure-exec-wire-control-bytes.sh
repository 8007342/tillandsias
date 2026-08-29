#!/usr/bin/env bash
# measure-exec-wire-control-bytes.sh — does exec-wire stdin survive intact?
#
# @trace order:926-bin4
#
# Sends `AB<byte>CD` over a real exec-wire session for each canonical-mode
# special and compares md5 host-side against guest-side. Reproduces the
# evidence on 926-bin4 and is the before/after harness for any fix.
#
# THE LAST ROW IS A NEGATIVE CONTROL and is the reason to trust the rest: 0x41
# is a plain 'A' that no line discipline touches. If it ever reports CORRUPTED,
# this harness is broken and every other row is measuring the harness rather
# than the wire — fix that before reading anything else.
#
# macOS only (drives tillandsias-tray --exec-guest); one VM boot per byte.
set -uo pipefail
TRAY="${TILLANDSIAS_TRAY:-dist/Tillandsias.app/Contents/MacOS/tillandsias-tray}"
if [ ! -x "$TRAY" ]; then
    echo "unavailable:no-tray-binary:$TRAY (build with scripts/build-macos-tray.sh)" >&2
    exit 2
fi
fail=0
printf 'byte  name         sent recv host_md5 guest_md5 rc   verdict\n'
probe() {
    hexb="$1"; name="$2"; expect="${3:-intact}"
    hostmd5=$(printf "AB\\x${hexb}CD" | md5sum | cut -c1-8)
    sent=$(printf "AB\\x${hexb}CD" | wc -c | tr -d ' ')
    out=$(printf "AB\\x${hexb}CD" | timeout 120 "$TRAY" --exec-guest \
        'cat > /tmp/cb; printf "R=%s:%s\n" "$(wc -c < /tmp/cb | tr -d " ")" "$(md5sum < /tmp/cb | cut -c1-8)"' 2>&1)
    rc=$?
    r=$(printf '%s\n' "$out" | grep -oE 'R=[0-9]+:[0-9a-f]{8}' | tail -1)
    recv=${r#R=}; recv=${recv%%:*}; gmd5=${r##*:}
    if [ -z "$r" ]; then
        verdict="NO-RESULT(rc=$rc)"
    elif [ "$gmd5" = "$hostmd5" ]; then
        verdict="INTACT"
    else
        verdict="CORRUPTED"
    fi
    printf '0x%s  %-11s  %-4s %-4s %-8s %-9s %-4s %s\n' \
        "$hexb" "$name" "$sent" "${recv:-?}" "$hostmd5" "${gmd5:-?}" "$rc" "$verdict"
    if [ "$expect" = intact ] && [ "$verdict" != INTACT ]; then fail=1; fi
}
probe 03 VINTR        broken
probe 04 VEOF         broken
probe 08 VERASE-BS    intact
probe 11 VSTART       broken
probe 13 VSTOP        broken
probe 15 VKILL        broken
probe 1a VSUSP        broken
probe 7f VERASE-DEL   broken
probe 41 plain-A      intact
if [ "$fail" != 0 ]; then
    echo "refused:negative-control-or-known-good-byte-was-corrupted — the harness \
or the wire changed shape; do not read the other rows as evidence" >&2
    exit 1
fi
echo "ok:exec-wire-control-bytes:measured"
