#!/usr/bin/env bash
# @trace order:767-qrbv, spec:meta-orchestration
#
# Hermetic fixture for scripts/smoke-consecutive-lanes.sh. A stub lane launcher
# (per-lane rc and log content from a plan file) and a stub podman (container
# ids from a file the stub launcher can rewrite) drive every verdict:
#   1 both lanes green, stack kept          -> ok:…:stack=kept
#   2 lane 1 fails                          -> lane1-failed, lane 2 NOT launched
#   3 lane 2 fails                          -> lane2-failed
#   4 lane 2 exits 0 but its log carries the supervisor's crash verdict
#                                           -> lane2-harness-crashed (rc 0 is not health)
#   5 lane 2 replaces a stack container     -> stack-replaced
#   6 no shared stack container             -> no-stack
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/smoke-consecutive-lanes.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/consecutive-lanes.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

mkdir -p "$W/bin" "$W/root/scripts"
cp "$SUBJECT" "$W/root/scripts/"
cat > "$W/bin/podman" <<'SH'
#!/usr/bin/env bash
cat "$STUB_DIR/containers"
SH
cat > "$W/launcher.sh" <<'SH'
#!/usr/bin/env bash
# lane n = 1 + lines in $STUB_DIR/launched; plan line n: "<rc> <log-text> [newid]"
echo x >> "$STUB_DIR/launched"
n="$(wc -l < "$STUB_DIR/launched" | tr -d ' ')"
line="$(sed -n "${n}p" "$STUB_DIR/plan")"
rc="${line%% *}"; rest="${line#* }"
text="${rest%% *}"; newid="${rest#* }"; [ "$newid" = "$rest" ] && newid=""
printf '%s\n' "$text" > "$STUB_DIR/lane.log"
[ -n "$newid" ] && sed -i "s/^tillandsias-proxy=.*/tillandsias-proxy=$newid/" "$STUB_DIR/containers"
exit "$rc"
SH
chmod +x "$W/bin/podman" "$W/launcher.sh"

run() { # run <name> <containers-file-content> <plan...>
    local d="$W/c-$1"; shift
    mkdir -p "$d"
    printf '%s' "$1" > "$d/containers"; shift
    printf '%s\n' "$@" > "$d/plan"; : > "$d/launched"
    local out
    out="$( cd "$W/root" && STUB_DIR="$d" PATH="$W/bin:$PATH" \
        TILLANDSIAS_CONSECUTIVE_LAUNCHER="$W/launcher.sh" \
        TILLANDSIAS_CONSECUTIVE_LANE_LOG="$d/lane.log" \
        bash scripts/smoke-consecutive-lanes.sh --gap 0 2>/dev/null )"
    RC=$?
    LAUNCHED="$(wc -l < "$d/launched" | tr -d ' ')"
    V="${out##*$'\n'}"
    # The exit status is the contract too: 0 on ok:, 1 on every fail:.
    case "$V" in
        ok:*) [ "$RC" -eq 0 ] || bad "$V exited $RC, not 0" ;;
        *) [ "$RC" -eq 1 ] || bad "$V exited $RC, not 1" ;;
    esac
}
# The podman stub prints whatever --format would; the subject asks for Names=ID.
STACK=$'tillandsias-proxy=aaa\ntillandsias-vault=bbb\ntillandsias-git-alpha=ccc\ntillandsias-alpha-forge=zzz\n'

run green "$STACK" "0 MO-SMOKE:PASS" "0 MO-SMOKE:PASS"
[ "$V" = "ok:consecutive-lanes:lane1=0:lane2=0:gap=0:stack=kept" ] && [ "$LAUNCHED" = 2 ] \
    && ok "1: two green lanes on the same stack -> $V" || bad "1: [$V] launched=$LAUNCHED"

run l1 "$STACK" "1 boom" "0 MO-SMOKE:PASS"
case "$V" in fail:consecutive-lanes:lane1-failed:lane1=1:lane2=not-run:*)
    [ "$LAUNCHED" = 1 ] && ok "2: lane 1 failure stops before lane 2 ($V)" || bad "2: lane 2 launched anyway ($LAUNCHED)" ;;
    *) bad "2: [$V]" ;; esac

run l2 "$STACK" "0 MO-SMOKE:PASS" "126 no-verdict"
case "$V" in fail:consecutive-lanes:lane2-failed:lane1=0:lane2=126:*) ok "3: $V" ;; *) bad "3: [$V]" ;; esac

run crash "$STACK" "0 MO-SMOKE:PASS" "0 fail:harness-crashed:harness=opencode:signal=11:rc=139"
case "$V" in fail:consecutive-lanes:lane2-harness-crashed:*) ok "4: a crash verdict under rc 0 is caught ($V)" ;; *) bad "4: [$V]" ;; esac

run replaced "$STACK" "0 MO-SMOKE:PASS" "0 MO-SMOKE:PASS NEWID"
# During lane 2 the stub gives tillandsias-proxy a NEW id; every other line stays.
case "$V" in fail:consecutive-lanes:stack-replaced:*)
    grep -qx 'tillandsias-proxy=NEWID' "$W/c-replaced/containers" && grep -qx 'tillandsias-vault=bbb' "$W/c-replaced/containers" \
        && ok "5: only the proxy's id changed, and it was caught ($V)" || bad "5: the premise (one id changed) did not hold" ;;
    *) bad "5: [$V]" ;; esac

run nostack $'ollama=111\ntillandsias-builder=222\n' "0 MO-SMOKE:PASS" "0 MO-SMOKE:PASS"
case "$V" in fail:consecutive-lanes:no-stack:*) [ "$LAUNCHED" = 1 ] && ok "6: $V" || bad "6: launched=$LAUNCHED" ;; *) bad "6: [$V]" ;; esac

echo "summary: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
echo "PASS: smoke-consecutive-lanes"
