#!/usr/bin/env bash
# @trace order:1843-dex5
#
# test-builder-toolbox-exists.sh — _toolbox_exists in with-tillandsias-builder.sh
# must not answer "absent" for a container that exists just because
# `toolbox list` failed this once. A false "absent" sends the caller into
# `toolbox create`, which dies "container tillandsias-builder already exists"
# (land queue, macuahuitl 2026-10-23: #612 evicted with the builder up 43 h).
#
# The function is extracted from the script (it execs on load, so it cannot be
# sourced whole) and run against stub toolbox/podman on PATH.
# ARM 1  toolbox list FAILS, podman says it exists   -> exists.  PRE-FIX: absent.
# ARM 2  toolbox list FAILS, podman says it does not -> absent (negative control).
# ARM 3  podman unavailable, toolbox lists it         -> exists (fallback kept).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts/with-tillandsias-builder.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/test-builder-toolbox-exists.XXXXXX")"; trap 'rm -rf "$W"' EXIT
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }

fn="$(sed -n '/^_toolbox_exists() {/,/^}/p' "$S")"
[ -n "$fn" ] || { echo "FAIL: _toolbox_exists not found in $S"; exit 1; }
printf '%s\n' "$fn" > "$W/fn.sh"

mk() { # mk <dir> <toolbox-mode:fail|list> <podman-mode:yes|no|absent>
    mkdir -p "$1"
    case "$2" in
        fail) printf '#!/bin/sh\nexit 1\n' > "$1/toolbox" ;;
        list) printf '#!/bin/sh\nprintf "CONTAINER ID  CONTAINER NAME  CREATED  STATUS  IMAGE\\nefe9  tillandsias-builder  5d  running  fedora\\n"\n' > "$1/toolbox" ;;
    esac
    case "$3" in
        yes) printf '#!/bin/sh\nexit 0\n' > "$1/podman" ;;
        no)  printf '#!/bin/sh\nexit 1\n' > "$1/podman" ;;
    esac
    chmod +x "$1"/*
    for t in awk grep sh; do ln -sf "$(command -v "$t")" "$1/$t"; done
}
probe() { # probe <dir> -> exists|absent
    PATH="$1" TOOLBOX_NAME=tillandsias-builder "$(command -v bash)" -c ". '$W/fn.sh'; _toolbox_exists && echo exists || echo absent"
}

mk "$W/a1" fail yes;   r="$(probe "$W/a1")"; [ "$r" = exists ] && ok "arm1 failed toolbox list does not hide an existing container" || bad "arm1 got $r"
mk "$W/a2" fail no;    r="$(probe "$W/a2")"; [ "$r" = absent ] && ok "arm2 absent container still reads absent" || bad "arm2 got $r"
mk "$W/a3" list absent; r="$(probe "$W/a3")"; [ "$r" = exists ] && ok "arm3 toolbox list fallback still finds it" || bad "arm3 got $r"
exit $fail
