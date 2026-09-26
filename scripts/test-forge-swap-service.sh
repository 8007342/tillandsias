#!/usr/bin/env bash
# test-forge-swap-service.sh — the non-root arms of 1376-8zdz's closure.
# @trace order:1376-8zdz
#
# PRE-FIX RESULT: FAILS — none of the units, the helper, the polkit rule or
# this test existed, and `swapon --show` listed only zram0.
#
# Arms (the live arm — a forge launch lists /var/swap/tillandsias-<id> at pri
# 10, stop removes it, kill -9 of the tray removes it within 3 min — needs the
# operator's one-time sudo install and is recorded on the row, not here):
#   1 install into a scratch prefix; 2 a second install is byte-identical;
#   3 systemd-analyze verify accepts the installed units;
#   4 the helper refuses "../x", "a b" and a 65-char id with refused:instance,
#     and creates nothing; 5 the polkit rule, evaluated by node over fixture
#   (action, subject) pairs; 6 gc stops exactly the instances whose lease is
#   not held; 7 the §9.6 size policy.
# Each needed tool is checked first; a missing one is a NAMED skip, never a pass.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
W="$(mktemp -d "${TMPDIR:-/tmp}/forge-swap-test.XXXXXX")"
holder=""
trap '[ -n "$holder" ] && kill "$holder" 2>/dev/null; rm -rf "$W"' EXIT
pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }
skp()  { skip=$((skip + 1)); echo "skip $1"; }

P="$W/root"; H="$P/usr/local/libexec/tillandsias-swap"

# ── 1, 2: install, then idempotence ───────────────────────────────────────
out1="$(bash scripts/install-forge-swap-service.sh --prefix "$P" --user tester)"
if [ "$out1" = "ok:install-swap:prefix=$P:user=tester:helper=$H" ] && [ -x "$H" ] \
   && [ -f "$P/etc/systemd/system/tillandsias-swap@.service" ] \
   && [ -f "$P/etc/polkit-1/rules.d/50-tillandsias-swap.rules" ] \
   && ! grep -q '@HELPER@\|@INSTALL_USER@' "$P/etc/systemd/system/"* "$P/etc/polkit-1/rules.d/"*; then
    ok "install writes every file, placeholders substituted"
else bad "install: $out1"; fi
snap1="$(cd "$P" && find . -type f -exec sha256sum {} + | sort)"
out2="$(bash scripts/install-forge-swap-service.sh --prefix "$P" --user tester)"
snap2="$(cd "$P" && find . -type f -exec sha256sum {} + | sort)"
[ "$out1" = "$out2" ] && [ "$snap1" = "$snap2" ] && ok "a second install is byte-identical with the same verdict" \
    || bad "install is not idempotent"
out_bad="$(bash scripts/install-forge-swap-service.sh --prefix "$P" --user 'x; rm -rf /')"
case "$out_bad" in refused:install-swap:user:*) ok "a hostile --user is refused" ;; *) bad "hostile user accepted: $out_bad" ;; esac

# ── 3: systemd-analyze verify ─────────────────────────────────────────────
if command -v systemd-analyze >/dev/null 2>&1; then
    U="$P/etc/systemd/system"
    cp "$U/tillandsias-swap@.service" "$W/tillandsias-swap@abc-123.service"
    if systemd-analyze verify "$W/tillandsias-swap@abc-123.service" "$U/tillandsias-swap-gc.service" "$U/tillandsias-swap-gc.timer" >"$W/verify.log" 2>&1; then
        ok "systemd-analyze verify accepts the template instance, gc service and timer"
    else bad "systemd-analyze verify: $(head -3 "$W/verify.log")"; fi
else skp "systemd-analyze absent (not a systemd host): units unverified here"; fi

# ── 4: instance refusals, and nothing created ─────────────────────────────
long="$(printf 'a%.0s' $(seq 1 65))"
for id in "../x" "a b" "$long" ""; do
    o="$(TILLANDSIAS_SWAP_CONF=/dev/null SWAP_DIR="$W/swapdir" "$H" start "$id")"; rc=$?
    if [ "$rc" = 2 ] && [ "${o%%:*}" = refused ] && printf '%s' "$o" | grep -q '^refused:instance:' && [ ! -e "$W/swapdir" ]; then
        ok "start refuses instance '${id:0:12}' with refused:instance and creates nothing"
    else bad "instance '${id:0:12}': rc=$rc out=$o"; fi
done
o="$(TILLANDSIAS_SWAP_CONF=/dev/null "$H" stop "../x")"; rc=$?
[ "$rc" = 2 ] && ok "stop refuses a traversal id" || bad "stop ../x: rc=$rc $o"

# ── 5: the polkit rule under node ─────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
    cat > "$W/polkit.js" <<'JS'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const R = { YES: "yes", NO: "no", NOT_HANDLED: "not_handled" };
let rule = null;
const polkit = { Result: R, addRule: (f) => { rule = f; } };
new Function("polkit", src)(polkit);
const act = (id, unit, verb) => ({ id, lookup: (k) => ({ unit, verb })[k] });
const sub = (user, groups) => ({ user, isInGroup: (g) => groups.includes(g) });
const M = "org.freedesktop.systemd1.manage-units";
const cases = [
  ["group member starts a matching instance", act(M, "tillandsias-swap@abc-123.service", "start"), sub("alice", ["tillandsias"]), "yes"],
  ["group member stops a matching instance", act(M, "tillandsias-swap@abc-123.service", "stop"), sub("alice", ["tillandsias"]), "yes"],
  ["installing user (no group) starts", act(M, "tillandsias-swap@abc-123.service", "start"), sub("tester", []), "yes"],
  ["restart is not granted", act(M, "tillandsias-swap@abc-123.service", "restart"), sub("alice", ["tillandsias"]), "not_handled"],
  ["another user outside the group", act(M, "tillandsias-swap@x.service", "start"), sub("mallory", ["wheel"]), "not_handled"],
  ["any other unit", act(M, "sshd.service", "stop"), sub("alice", ["tillandsias"]), "not_handled"],
  ["a traversal-shaped instance", act(M, "tillandsias-swap@../x.service", "start"), sub("alice", ["tillandsias"]), "not_handled"],
  ["a 65-char instance", act(M, "tillandsias-swap@" + "a".repeat(65) + ".service", "start"), sub("alice", ["tillandsias"]), "not_handled"],
  ["another action", act("org.freedesktop.login1.reboot", "tillandsias-swap@abc.service", "start"), sub("alice", ["tillandsias"]), "not_handled"],
];
let bad = 0;
for (const [name, a, s, want] of cases) {
  const got = rule(a, s);
  console.log((got === want ? "ok   " : "FAIL ") + "polkit: " + name + " -> " + got);
  if (got !== want) bad++;
}
process.exit(bad ? 1 : 0);
JS
    while read -r line; do case "$line" in ok*) ok "${line#ok   }" ;; FAIL*) bad "${line#FAIL }" ;; esac; done \
        < <(node "$W/polkit.js" "$P/etc/polkit-1/rules.d/50-tillandsias-swap.rules" 2>&1)
else skp "node absent: the polkit rule was not evaluated here (the gate's toolbox has node)"; fi

# ── 6: gc stops exactly the instances whose lease is not held ─────────────
if command -v flock >/dev/null 2>&1; then
    mkdir -p "$W/run/1000/tillandsias"
    cat > "$W/systemctl" <<EOF
#!/bin/sh
if [ "\$1" = list-units ]; then
  printf '%s\n' "tillandsias-swap@held-1.service loaded active exited x" \
                "tillandsias-swap@free-2.service loaded active exited x" \
                "tillandsias-swap@gone-3.service loaded active exited x"
  exit 0
fi
echo "\$*" >> "$W/systemctl.log"
EOF
    chmod +x "$W/systemctl"
    : > "$W/run/1000/tillandsias/swap-held-1.lease"; : > "$W/run/1000/tillandsias/swap-free-2.lease"
    # premise: hold one lease from a live process, exactly as the tray does
    flock "$W/run/1000/tillandsias/swap-held-1.lease" sleep 60 & holder=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$W/run/1000/tillandsias/swap-held-1.lease" true 2>/dev/null || break; sleep 0.2; done
    if flock -n "$W/run/1000/tillandsias/swap-held-1.lease" true 2>/dev/null; then
        bad "premise: the held lease is not held, so the gc arm would mean nothing"
    else
        o="$(TILLANDSIAS_SWAP_CONF=/dev/null TILLANDSIAS_SWAP_SYSTEMCTL="$W/systemctl" TILLANDSIAS_SWAP_LEASE_GLOB="$W/run/*/tillandsias" "$H" gc)"
        stopped="$(sort "$W/systemctl.log" 2>/dev/null | paste -sd, -)"
        if [ "$stopped" = "stop tillandsias-swap@free-2.service,stop tillandsias-swap@gone-3.service" ] && [ "$o" = "ok:swap-gc:stopped=2" ]; then
            ok "gc stops the unheld and the lease-less instance, keeps the held one"
        else bad "gc: out=$o stopped=[$stopped]"; fi
    fi
else skp "flock absent: gc unverified here"; fi

# ── 7: size policy (§9.6) ─────────────────────────────────────────────────
for pair in 250:24 210:24 150:16 105:16 60:8 30:8 28:8 27:refused 5:refused; do
    free="${pair%%:*}"; want="${pair#*:}"
    got="$(TILLANDSIAS_SWAP_CONF=/dev/null "$H" size-for-free-gb "$free" 2>/dev/null)" || got=refused
    [ "$got" = "$want" ] && ok "size: free ${free} GB -> $want" || bad "size: free ${free} GB -> $got, want $want"
done

total=$((pass + fail))
if [ "$fail" = 0 ]; then echo "ok:forge-swap-service:$pass arms (skipped=$skip)"; exit 0; fi
echo "FAIL:forge-swap-service:$pass/$total (skipped=$skip)"; exit 1
