#!/usr/bin/env bash
# @trace spec:vsock-transport
#
# test-macos-vsock-inference-closure.sh — order 830-xsk2, the row's closure.
#
# WHAT IT ASSERTS: a client container on the enclave network addresses
# `http://inference:11434` and receives a body composed by a process on the
# macOS HOST, with the PRODUCT launching the forwarder.
#
# NOT "the forwarder started". A relay that starts and answers nothing is
# indistinguishable, from inside the guest, from a service that is merely quiet
# — the silent-success shape this milestone exists to remove, and the exact way
# a sibling row's ARM 3 went vacuous. The assertion is the BODY.
#
# WHY THE GUEST HALF IS BOOT-TRIGGERED, and it is not a preference:
# Virtualization.framework delivers a guest-initiated vsock connect only while
# the host pumps CFRunLoop, so the tray must be running — and the tray OWNS the
# VM, so there is no second control-wire session to drive the guest from
# outside. Both doors are shut. A systemd oneshot enabled beforehand runs the
# guest half while the tray pumps, and reports through a share the tray does not
# own.
#
# THE SHARE IS home-src (~/src), NOT the model cache. Earlier probes on this row
# used the model cache and a dotfile there trips
# test-macos-model-share-writable.sh's empty-cache precondition — fine for a
# one-off, a defect in anything committed.
#
# SLOW BY NATURE, ~10 minutes: the product path is `--status-check`, which
# ensures eight images and creates a one-shot forge. DO NOT wire this into
# build.sh --check; it is a smoke-family fixture.
#
# GRAMMAR — one line, or two on a could-not-run (see below):
#   ^(ok:macos-vsock-inference-closure:[0-9]+|violation:macos-vsock-inference-closure:.*|unsupported:macos-vsock-inference-closure:.*|skip:macos-vsock-inference-closure:.*)$
#
# A COULD-NOT-RUN PRINTS TWO LINES: the `unsupported:` detail, then the `skip:`
# line the runner scores (1330-i4hu). Order is load-bearing.
set -uo pipefail

# A precondition this fixture cannot satisfy: say what was not tested, then end
# on the line the runner scores (1330-i4hu). scripts/run-litmus-test.sh
# step_terminal_verdict (:960) consults ONLY the last non-empty line and
# recognises only `skip:`/`advisory:`; with the detail line last the step falls
# through to check_signal and :992 returns FAILURE. Never used for a red.
cannot_run() {
    echo "unsupported:macos-vsock-inference-closure:$1"
    echo "skip:macos-vsock-inference-closure:$1"
    exit 0
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
say() { printf '  %s\n' "$1" >&2; }

[ "$(uname -s)" = "Darwin" ] || cannot_run "not-darwin"

TRAY="${TILLANDSIAS_TRAY_BIN:-$ROOT/dist/Tillandsias.app/Contents/MacOS/tillandsias-tray}"
# A bare target/release binary has no com.apple.security.virtualization
# entitlement and cannot start a VM at all, and it stages no guest (701-kgvk).
[ -x "$TRAY" ] || cannot_run "no-app-bundle-run-scripts/build-macos-tray.sh"

GUEST_ASSET="$(dirname "$TRAY")/../Resources/guest/tillandsias-headless-aarch64-unknown-linux-musl"
if [ -r "$GUEST_ASSET" ]; then
    # PROVE THE INSTRUMENT BEFORE TRUSTING ITS NEGATIVE. A guest binary that
    # predates the lane cannot pass this fixture, and `grep -ac` returning 0 for
    # the lane means nothing unless a string that MUST be present returns
    # non-zero. Measured once with `strings`, which is absent in the guest:
    # subject and control both read 0 and the reading was worthless.
    _ctl="$(grep -ac 'tillandsias-inference' "$GUEST_ASSET" 2>/dev/null || echo 0)"
    _lane="$(grep -ac 'tillandsias-vsock-forwarder' "$GUEST_ASSET" 2>/dev/null || echo 0)"
    if [ "$_ctl" -eq 0 ] 2>/dev/null; then
        cannot_run "cannot-inspect-guest-asset"
    fi
    if [ "$_lane" -eq 0 ] 2>/dev/null; then
        cannot_run "bundled-guest-predates-the-forwarder-lane"
    fi
fi

SRC_SHARE="${TILLANDSIAS_HOST_SRC_SHARE:-$HOME/src}"
[ -d "$SRC_SHARE" ] || cannot_run "no-home-src-share"

PORT_LIVE="${TILLANDSIAS_VSOCK_TEST_PORT:-42421}"
PORT_DEAD="${TILLANDSIAS_VSOCK_DEAD_PORT:-49997}"   # nothing binds this on the host
HOST_TCP="127.0.0.1:${TILLANDSIAS_VSOCK_TEST_TCP_PORT:-9999}"
RESULT="$SRC_SHARE/.vsock-closure-result.txt"          # host view
GUEST_RESULT="/home/forge/src/.vsock-closure-result.txt"  # guest view of the SAME file
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/vsock-closure.XXXXXX")" || {
    echo "violation:macos-vsock-inference-closure:cannot-mktemp"; exit 1; }

cleanup() {
    pkill -f "Tillandsias.app/Contents/MacOS/tillandsias-tray" 2>/dev/null
    sleep 5
    # 1253-gina: an ordinary stop of the tray orphans the VZ helper, which then
    # holds nvram and makes the NEXT start fail as "boot loader is invalid".
    pkill -f "com.apple.Virtualization.VirtualMachine" 2>/dev/null
    [ -n "${RESPONDER_PID:-}" ] && kill "$RESPONDER_PID" 2>/dev/null
    rm -f "$RESULT" "$SRC_SHARE"/.vsock-closure-sc-*.log
    rm -rf "$TMPD"
}
trap cleanup EXIT

# ---- the host-native service the guest must reach -------------------------
# THE RESPONDER IS perl, NOT THE OTHER OBVIOUS INTERPRETER: 1087-h2z9 bars that
# runtime anywhere in the harness and its scan matches the TOKEN, so even naming
# it in a comment refuses the file. perl carries no such rule, ships with macOS,
# and scripts/check-bash-dialect.sh and scripts/timing-log.sh already rely on it.
cat > "$TMPD/responder.pl" <<'PL'
use strict; use warnings; use IO::Socket::INET;
my $port = $ARGV[0];
my $body = '{"version": "host-native-closure-probe"}';
my $resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
         . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n" . $body;
my $srv = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port,
                                Proto => 'tcp', Listen => 16, ReuseAddr => 1)
    or die "bind $port: $!";
while (my $c = $srv->accept) { my $buf; $c->recv($buf, 8192); print $c $resp; close $c; }
PL

# ---- the guest half: BOTH arms in one boot, same clock, same images -------
cat > "$TMPD/oneshot.sh" <<ONESHOT
#!/usr/bin/env bash
set -u
OUT=$GUEST_RESULT
arm() { # arm <label> <cid:port|TRAY>
  install -d /run/tillandsias
  if [ "\$2" = "TRAY" ]; then
    # THE LIVE ARM TAKES ITS TARGET FROM THE TRAY, not from us (1309-rb3p).
    # Seeding the file here would mask the writer entirely: the closure would
    # pass whether or not the product could configure itself, which is the whole
    # thing this row added. We WAIT instead — the oneshot runs at boot and the
    # tray sends on its control-wire connect, so the guest is legitimately ahead.
    rm -f /run/tillandsias/vsock-forward
    waited=0
    while [ ! -s /run/tillandsias/vsock-forward ] && [ "\$waited" -lt 240 ]; do
      sleep 5; waited=\$((waited+5))
    done
    echo "\$1:target-from-tray-after-\${waited}s=[\$(cat /run/tillandsias/vsock-forward 2>/dev/null || echo MISSING)]"
  else
    # The MUTATION arm must pose a target the tray would never send, so it
    # writes one directly. That is the only place a seeded value belongs.
    printf '%s\n' "\$2" > /run/tillandsias/vsock-forward
  fi
  podman rm -f tillandsias-inference tillandsias-vsock-forwarder >/dev/null 2>&1
  LITMUS_PODMAN_MODE=1 timeout 900 tillandsias-headless --status-check >/home/forge/src/.vsock-closure-sc-\$1.log 2>&1
  local fwd; fwd="\$(podman inspect -f '{{.State.Status}}' tillandsias-vsock-forwarder 2>/dev/null || echo absent)"
  local inf; inf="\$(podman inspect -f '{{.State.Status}}' tillandsias-inference 2>/dev/null || echo absent)"
  local img; img="\$(podman images --format '{{.Repository}}:{{.Tag}}' | grep tillandsias-forge-base | grep -v latest | grep -v sha256 | head -1)"
  local body; body="\$(timeout 60 podman run --rm --network tillandsias-enclave --cap-drop=ALL \
      --security-opt=no-new-privileges --entrypoint curl "\$img" \
      -sS --max-time 20 http://inference:11434/api/version 2>/dev/null)"
  echo "\$1:forwarder=\$fwd inference=\$inf body=[\$body]"
}
{
  arm LIVE "TRAY"
  arm DEAD "2:$PORT_DEAD"
  echo "done"
} > "\$OUT" 2>&1
ONESHOT

cat > "$TMPD/install.sh" <<'INST'
set -u
install -D -m 0755 /tmp/closure-oneshot.sh /usr/local/lib/tillandsias/vsock-closure.sh
cat > /etc/systemd/system/tillandsias-vsock-closure.service <<'UNIT'
[Unit]
Description=830-xsk2 closure fixture (one-shot)
After=network-online.target podman.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/tillandsias/vsock-closure.sh
RemainAfterExit=yes
TimeoutStartSec=2400
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable tillandsias-vsock-closure.service >/dev/null 2>&1
INST

say "installing the guest oneshot (VM starts and stops once)…"
B1="$(base64 < "$TMPD/oneshot.sh" | tr -d '\n')"
B2="$(base64 < "$TMPD/install.sh" | tr -d '\n')"
# 795-imz3: capture the exit FIRST rather than `if ! <pipeline>`. The pipes here
# are inside the guest command STRING rather than a host pipeline, but the rule
# is about the shape a reader and a checker both see, and the capture idiom is
# correct either way.
"$TRAY" --exec-guest "echo $B1 | base64 -d > /tmp/closure-oneshot.sh; echo $B2 | base64 -d > /tmp/i.sh; bash /tmp/i.sh" </dev/null >"$TMPD/install.log" 2>&1
install_rc=$?
if [ "$install_rc" -ne 0 ]; then
    echo "violation:macos-vsock-inference-closure:cannot-install-guest-oneshot-rc-$install_rc"; exit 1
fi

rm -f "$RESULT"
perl "$TMPD/responder.pl" "${HOST_TCP##*:}" >/dev/null 2>&1 &
RESPONDER_PID=$!
sleep 2

say "starting the tray in continuous-runloop mode (this is what pumps CFRunLoop)…"
TILLANDSIAS_HOST_VSOCK_PORT="$PORT_LIVE" TILLANDSIAS_HOST_VSOCK_FORWARD_TO="$HOST_TCP" \
    "$TRAY" >"$TMPD/tray.log" 2>&1 &

deadline=$(( $(date +%s) + 1800 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q '^done$' "$RESULT" 2>/dev/null && break
    sleep 10
done

[ -s "$RESULT" ] || { echo "violation:macos-vsock-inference-closure:guest-produced-no-result"; exit 1; }
live="$(sed -n 's/^LIVE://p' "$RESULT")"
dead="$(sed -n 's/^DEAD://p' "$RESULT")"
say "LIVE: ${live:-<none>}"
say "DEAD: ${dead:-<none>}"

pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then say "ok   $1"; pass=$((pass+1)); else say "FAIL $1 (want '$2', got '$3')"; fail=$((fail+1)); fi; }

# ARM 0 — the PRODUCT configured the guest. Without this a green would not
# distinguish "the tray wrote the target" from "something else did".
case "$live" in
    *"target-from-tray-after-"*"=[2:"*) say "ok   the TRAY configured the guest over the control wire"; pass=$((pass+1)) ;;
    *"MISSING"*) say "FAIL the tray never wrote the target — the writer did not fire (1309-rb3p)"; fail=$((fail+1)) ;;
    *) say "FAIL no readable target line from the guest: ${live:-<none>}"; fail=$((fail+1)) ;;
esac

# ARM 1 — the closure itself.
case "$live" in
    *"host-native-closure-probe"*) say "ok   the client received a body composed on the HOST"; pass=$((pass+1)) ;;
    *) say "FAIL the client did not receive the host's body: ${live:-<none>}"; fail=$((fail+1)) ;;
esac
# The product must have taken the forwarder lane, exclusively.
case "$live" in
    *"forwarder=running"*) say "ok   the product launched the forwarder"; pass=$((pass+1)) ;;
    *) say "FAIL the forwarder is not running: ${live:-<none>}"; fail=$((fail+1)) ;;
esac
case "$live" in
    *"inference=absent"*) say "ok   the inference container is absent — the alias is not contested"; pass=$((pass+1)) ;;
    *) say "FAIL both containers claim the inference alias: ${live:-<none>}"; fail=$((fail+1)) ;;
esac

# ARM 2 — THE MUTATION. Same product path, same images, same clock; only the
# host port differs, and nothing is listening on it. If this still yields the
# host's body the fixture is measuring something other than the hop.
case "$dead" in
    *"host-native-closure-probe"*)
        say "FAIL MUTATION ARM PASSED: a dead host port still produced the host's body — this fixture does not discriminate"
        fail=$((fail+1)) ;;
    *"forwarder=running"*"body=[]"*)
        say "ok   mutation arm red as required: the SAME forwarder, pointed at a dead host port, yields no host body"
        pass=$((pass+1)) ;;
    *"forwarder=absent"*)
        # Not a pass. The lane never ran, so the empty body is explained by the
        # product path failing rather than by the port being dead, and the arm
        # discriminates nothing. See .vsock-closure-sc-DEAD.log on the share.
        say "FAIL mutation arm INCONCLUSIVE: the forwarder is absent, so 'no body' does not isolate the dead port — consult .vsock-closure-sc-DEAD.log"
        fail=$((fail+1)) ;;
    *)
        say "FAIL mutation arm did not produce a readable verdict: ${dead:-<none>}"
        fail=$((fail+1)) ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "violation:macos-vsock-inference-closure:$fail-arm(s)-failed"; exit 1
fi
echo "ok:macos-vsock-inference-closure:$pass"
