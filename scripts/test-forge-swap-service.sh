#!/usr/bin/env bash
# test-forge-swap-service.sh — the non-root arms of 1376-8zdz's closure, and
# of 1448-kmyn's (arms 8-12: the binary's own --swap on|off|status).
# @trace order:1376-8zdz, order:1448-kmyn
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
# cksum, not sha256sum: macOS has no sha256sum, and an empty snapshot on both
# sides would compare EQUAL — a vacuous pass. The premise asserts it listed the
# six installed files before any comparison means anything.
snap() { (cd "$P" && find . -type f -exec cksum {} + | sort); }
snap1="$(snap)"
out2="$(bash scripts/install-forge-swap-service.sh --prefix "$P" --user tester)"
snap2="$(snap)"
if [ "$(printf '%s\n' "$snap1" | grep -c .)" != 6 ]; then
    bad "premise: the install snapshot does not list the 6 installed files ($(printf '%s\n' "$snap1" | grep -c .))"
elif [ "$out1" = "$out2" ] && [ "$snap1" = "$snap2" ]; then
    ok "a second install is byte-identical with the same verdict"
else bad "install is not idempotent"; fi
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
    case "$o" in refused:instance:*) prefix_ok=1 ;; *) prefix_ok=0 ;; esac
    if [ "$rc" = 2 ] && [ "$prefix_ok" = 1 ] && [ ! -e "$W/swapdir" ]; then
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

# ── 8-12: the binary's own `--swap` (order 1448-kmyn) ─────────────────────
# The binary embeds scripts/forge-swap/* and must install exactly what the
# script installs. Resolved through the shared probe (721-nyev), never a
# hardcoded target/ path; TILLANDSIAS_BIN overrides. Never run live here: on a
# host with pkexec a live `--swap on` would prompt the operator.
if [ -n "${TILLANDSIAS_BIN:-}" ]; then
    BIN="$TILLANDSIAS_BIN"
else
    if [ -r scripts/plan-binary-probe.sh ]; then . scripts/plan-binary-probe.sh; else resolve_target_binary() { return 1; }; fi
    BIN="$(resolve_target_binary tillandsias debug "$PWD" 2>/dev/null)"
    [ -n "$BIN" ] || BIN="$PWD/target/debug/tillandsias"
fi
# `--swap` is LINUX-ONLY by design (swap_cmd.rs is #[cfg(target_os = "linux")];
# macOS and Windows print what governs swap there). And on Windows
# target/debug/tillandsias.exe is the TRAY, not tillandsias-headless, so the
# arms resolved the wrong program and failed "Unsupported option: --swap"
# (yolanda, 2026-09-28, 1462-trch). Name the skip rather than resolve harder:
# there is no --swap to test on those platforms. On Linux a binary without
# --swap stays a FAIL — the gate builds it fresh, so that is a regression.
_os="$(uname -s 2>/dev/null || echo unknown)"
if [ "$_os" != Linux ]; then
    skp "swap-is-linux-only: --swap arms not run on $_os"
elif [ ! -x "$BIN" ]; then
    skp "no tillandsias binary at $BIN: the --swap arms did not run (./build.sh builds it)"
else
    # The binary's VERDICTS are on stdout; its host warnings are on stderr. In a
    # forge it warns on every call that /run/user/1000 cannot be set to 0700,
    # which a `2>&1` capture folded into the verdict and 5 arms failed on it
    # (macuahuitl-forge, 2026-09-28). Read stdout only, keep stderr for the
    # failure message, and give the binary a runtime dir the test owns.
    mkdir -p -m 700 "$W/xdg"
    swapbin() { XDG_RUNTIME_DIR="$W/xdg" "$BIN" "$@" 2>>"$W/swap-stderr.log"; }
    B="$W/bin-root"; S="$W/script-root"
    bash scripts/install-forge-swap-service.sh --prefix "$S" --user tester >/dev/null
    o8="$(swapbin --swap on --prefix "$B" --user tester)"; r8=$?
    # The units name the helper by its absolute path, which is inside each
    # scratch root: normalise the root before comparing, and compare modes too.
    tree() { (cd "$1" && find . -type f | sort | while read -r f; do
        printf '%s %s %s\n' "$f" "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" \
            "$(sed "s|$1|<ROOT>|g" "$f" | cksum)"; done); }
    tb="$(tree "$B")"; ts="$(tree "$S")"
    if [ "$r8" != 0 ] || [ "$o8" != "ok:swap-on:prefix=$B:user=tester:helper=$B/usr/local/libexec/tillandsias-swap" ]; then
        bad "8 --swap on: rc=$r8 out=[$o8] (a binary without the verb is the pre-fix state)"
    elif [ "$(printf '%s\n' "$tb" | grep -c .)" != 6 ]; then
        bad "8 premise: --swap on did not write 6 files ($(printf '%s\n' "$tb" | grep -c .))"
    elif [ "$tb" = "$ts" ]; then
        ok "8 --swap on writes byte-identical files, with identical modes, to the installer's"
    else bad "8 the embedded assets differ from scripts/forge-swap/: $(diff <(echo "$ts") <(echo "$tb") | head -3)"; fi

    o9="$(swapbin --swap on --prefix "$B" --user tester)"; t9="$(tree "$B")"
    case "$o9" in ok:swap-on:*) v9=1 ;; *) v9=0 ;; esac
    [ "$v9" = 1 ] && [ "$o9" = "$o8" ] && [ "$t9" = "$tb" ] && ok "9 a second --swap on changes nothing" || bad "9 second on: out=[$o9]"

    st_on="$(swapbin --swap status --prefix "$B")"
    mkdir -p "$B/var/swap"; : > "$B/var/swap/tillandsias-launch-1"; : > "$B/var/swap/forge-live.swap"
    o10="$(swapbin --swap off --prefix "$B")"; r10=$?
    left=""
    for p in usr/local/libexec/tillandsias-swap etc/systemd/system/tillandsias-swap@.service \
             etc/systemd/system/tillandsias-swap-gc.service etc/systemd/system/tillandsias-swap-gc.timer \
             etc/polkit-1/rules.d/50-tillandsias-swap.rules etc/tillandsias/swap.conf; do
        [ -e "$B/$p" ] && left="$left $p"
    done
    if [ "$r10" = 0 ] && [ "$o10" = "ok:swap-off:prefix=$B:removed=6:swapfiles=1" ] && [ -z "$left" ] \
       && [ ! -e "$B/var/swap/tillandsias-launch-1" ] && [ -e "$B/var/swap/forge-live.swap" ]; then
        ok "10 --swap off removes every installed path and the per-launch swapfile, and keeps a file it did not create"
    else bad "10 off: rc=$r10 out=[$o10] left=[$left]"; fi

    # 11: the removal is COMPLETE (the list --uninstall reuses, 1437-evzi):
    # after on + off, the only file left in the root is the one we planted.
    rest="$(cd "$B" && find . -type f | sort)"
    st_off="$(swapbin --swap status --prefix "$B")"
    if [ "$rest" = "./var/swap/forge-live.swap" ] && [ "$st_on" = "ok:swap-status:installed=yes:active=0" ] \
       && [ "$st_off" = "ok:swap-status:installed=no:active=0" ]; then
        ok "11 the removal list covers every file --swap on installs (status yes -> no)"
    else bad "11 left after off: [$rest] status on=[$st_on] off=[$st_off]"; fi

    # 12: NEGATIVE CONTROL — off on a root with nothing installed exits 0 and
    # removes nothing else.
    N="$W/empty-root"; mkdir -p "$N/etc/polkit-1/rules.d" "$N/var/swap"
    echo keep > "$N/etc/polkit-1/rules.d/10-other.rules"; echo keep > "$N/var/swap/other.swap"
    o12="$(swapbin --swap off --prefix "$N")"; r12=$?
    if [ "$r12" = 0 ] && [ "$o12" = "ok:swap-off:prefix=$N:removed=0:swapfiles=0" ] \
       && [ -f "$N/etc/polkit-1/rules.d/10-other.rules" ] && [ -f "$N/var/swap/other.swap" ]; then
        ok "12 negative control: off with nothing installed exits 0 and removes nothing"
    else bad "12 off on empty root: rc=$r12 out=[$o12]"; fi
fi

total=$((pass + fail))
if [ "$fail" = 0 ]; then echo "ok:forge-swap-service:$pass arms (skipped=$skip)"; exit 0; fi
echo "FAIL:forge-swap-service:$pass/$total (skipped=$skip)"; exit 1
