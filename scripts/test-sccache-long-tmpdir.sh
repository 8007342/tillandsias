#!/usr/bin/env bash
# @trace order:1804-sccl
# Land run 184 (#590): "sccache: encountered fatal error" on cargo's rustc probe.
# Cause: sccache's server-start socket lives under $TMPDIR; a long TMPDIR (the
# door's pf-guard dir under an agent TMPDIR) overflows SUN_LEN when no server runs.
# ARM 1 (control)  bare sccache, long TMPDIR, dead server: FAILS (reproduces defect)
# ARM 2            scripts/sccache-wrapper.sh, same conditions: rustc -vV succeeds
# ARM 3            sccache that always fails (rc 254): wrapper falls back, rc 0
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$(command -v sccache 2>/dev/null || true)"
[ -n "$SC" ] || { echo "skip:sccache-long-tmpdir:no-sccache"; exit 0; }
W="$(mktemp -d /tmp/sclt.XXXXXX)"; trap 'rm -rf "$W"' EXIT
LONG="$W/$(printf 'd%.0s' $(seq 1 100))"; mkdir -p "$LONG"
export SCCACHE_DIR="$W/cache" SCCACHE_SERVER_PORT=$((20000 + RANDOM % 20000))
trap '"$SC" --stop-server >/dev/null 2>&1; rm -rf "$W"' EXIT
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }
"$SC" --stop-server >/dev/null 2>&1
if TMPDIR="$LONG" "$SC" rustc -vV >/dev/null 2>&1; then bad "arm1 bare sccache did not fail under a long TMPDIR (fixture proves nothing)"; else ok "arm1 defect reproduces: bare sccache fails with a long TMPDIR and no server"; fi
"$SC" --stop-server >/dev/null 2>&1
o2="$(TMPDIR="$LONG" TILLANDSIAS_SCCACHE_BIN="$SC" "$ROOT/scripts/sccache-wrapper.sh" rustc -vV 2>/dev/null)"
if grep -q '^rustc ' <<<"$o2"; then ok "arm2 wrapper survives a long TMPDIR with a dead server"; else bad "arm2 wrapper failed under a long TMPDIR"; fi
printf '#!/bin/sh\nexit 254\n' > "$W/badsc"; chmod +x "$W/badsc"
o3="$(TILLANDSIAS_SCCACHE_BIN="$W/badsc" "$ROOT/scripts/sccache-wrapper.sh" rustc -vV 2>/dev/null)"
if grep -q '^rustc ' <<<"$o3"; then ok "arm3 broken sccache falls back to the bare compiler"; else bad "arm3 broken sccache redded the build"; fi
exit $fail
