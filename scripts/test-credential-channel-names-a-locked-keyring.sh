#!/usr/bin/env bash
# @trace order:1189-2ra5, spec:meta-orchestration
#
# test-credential-channel-names-a-locked-keyring.sh — pin the discriminator
# between a keyring that is ABSENT and one that is merely LOCKED.
#
# WHY THIS MATTERS MORE THAN A VERDICT STRING. missing:no-credential-channel
# means "there is no credential here", and the obvious response to that is to
# make one: `gh auth login`. That is the one action 1025-a896 forbids, because a
# re-auth on one host evicts the operator's token on EVERY other host. So a
# locked keyring reported as missing turns one workstation's passphrase prompt
# into a fleet-wide outage.
#
# MEASURED on lenovinha 2026-09-14: the guard read ok:gh-keyring-push-verified
# at 18:52Z, a gated and integrated land was refused at the push at 19:37Z
# ("could not read Username for 'https://github.com'"), and the guard read
# missing:no-credential-channel at 19:47Z — while gnome-keyring-daemon was
# running, org.freedesktop.secrets was on the bus, ~/.config/gh/hosts.yml was
# intact since 2026-08-20, and the login collection read Locked=true.
#
# Hermetic: every arm drives a STUB busctl (and a stub gh) on PATH inside a
# scratch repo, so no arm consults this host's real keyring and the fixture's
# verdict is identical on a locked host, an unlocked host, and a host with no
# secret service at all.
#
# THE ARMS THAT MATTER ARE 2 AND 3, the negative controls. If arm 2 goes red the
# guard has started calling a genuinely credential-less host "locked", which
# sends the operator to unlock a keyring that does not exist. If arm 3 goes red
# the lock probe has begun firing on unlocked hosts, which would block every
# cycle in the fleet on a working credential.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

GUARD="$ROOT/scripts/check-credential-channel.sh"
[ -f "$GUARD" ] || { echo "skip:locked-keyring:$GUARD is absent"; exit 3; }

W="$(mktemp -d "${TMPDIR:-/tmp}/locked-keyring.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# A stub gh that has NO token: every earlier arm of the guard declines, so the
# run reaches the fall-through where the lock question is asked. That is the
# real-world shape — a locked keyring is exactly a gh that cannot answer.
mk_bin() { # mk_bin <dir> <busctl-behaviour>
    local bin="$1" mode="$2"
    mkdir -p "$bin"
    cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
# No token: `auth status` fails, like gh against a keyring it cannot open
# (bounded by the guard, so a real hang is not needed to reach the same arm).
exit 1
GH
    chmod +x "$bin/gh"
    case "$mode" in
        absent) ;;   # no busctl at all on PATH
        locked)
            cat > "$bin/busctl" <<'BC'
#!/usr/bin/env bash
case "$*" in
  *--user*list*) echo "org.freedesktop.secrets 1234 gnome-keyring-daemon"; exit 0 ;;
  *"/collection/login"*Locked*) echo "b true"; exit 0 ;;
  *Locked*) echo "b false"; exit 0 ;;
esac
exit 1
BC
            chmod +x "$bin/busctl" ;;
        unlocked)
            cat > "$bin/busctl" <<'BC'
#!/usr/bin/env bash
case "$*" in
  *--user*list*) echo "org.freedesktop.secrets 1234 gnome-keyring-daemon"; exit 0 ;;
  *Locked*) echo "b false"; exit 0 ;;
esac
exit 1
BC
            chmod +x "$bin/busctl" ;;
        noservice)
            # busctl EXISTS but no secret service answers — the macOS/forge and
            # headless-server shape. It must read as missing, never as locked.
            cat > "$bin/busctl" <<'BC'
#!/usr/bin/env bash
echo "Failed to get property: no such service" >&2
exit 1
BC
            chmod +x "$bin/busctl" ;;
    esac
}

scratch() {
    local d="$W/$1"
    mkdir -p "$d"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config core.hooksPath .git/hooks
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    printf '%s' "$d"
}

run_guard() { # run_guard <repo> <bin>; sets OUT and RC
    local repo="$1" bin="$2"
    OUT="$( cd "$repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_HOST_KIND \
            PATH="$bin:$PATH" bash "$GUARD" 2>"$repo/.stderr" )"
    RC=$?
    ERR="$(cat "$repo/.stderr" 2>/dev/null || true)"
}

echo "arm 1 — a PRESENT but unopenable secret service reads unknown:, NOT missing:"
mk_bin "$W/bin-locked" locked
D="$(scratch locked)"
run_guard "$D" "$W/bin-locked"
# 1265-8qr6 REMOVED THE Locked READ, so the old blocked:gh-keyring-locked is
# unreachable and asserting it would pin a probe that aborts its own subject.
# What 1189-2ra5 actually protects is the REMEDY, and that survives: a service
# on the bus means the channel EXISTS, so the verdict must not be missing:.
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '^unknown:secret-service-unprobed$'; then # sigpipe-ok: safe pipeline
    ok "unknown:secret-service-unprobed at rc=$RC — present, unopenable, not absent"
elif printf '%s' "$OUT" | grep -q '^missing:no-credential-channel$'; then # sigpipe-ok: safe pipeline
    bad "REGRESSION 1189-2ra5: a service ON THE BUS read as missing: — that verdict invites the fleet-evicting re-auth that 1025-a896 forbids"
else
    bad "expected unknown:secret-service-unprobed, got rc=$RC out='$OUT'"
fi

echo "arm 2 — NEGATIVE CONTROL: no secret service on the bus reads unretrievable, never locked"
#
# EXPECTATION CHANGED 2026-09-22 (1347-r9g8), DELIBERATELY, AND IT WANTS A
# SECOND OPINION -- flagged in the PR rather than slipped in, because changing a
# fixture to match behaviour is the move that hides regressions.
#
# This arm asserted `missing:no-credential-channel`. The repo asserted BOTH
# answers for this one bus state: test-check-credential-channel.sh arm 15 pins
# `blocked:credential-unretrievable-no-keyring-service` for "no secret-service
# on the bus", and this arm pinned `missing:`. The contradiction was invisible
# because this arm never reached the not-serving path: its stub exits 1, the
# state reader called EVERY failure `unknown`, and `unknown` bypassed the gate
# to land on the terminal `missing:`. It passed for the wrong reason.
#
# `missing:no-credential-channel` means "there is no credential here", and its
# remedy is `gh auth login` -- the re-auth 1025-a896 forbids because it evicts
# the fleet. A host whose bus carries no secret service has an UNREACHABLE
# store, not a proven-absent credential, and the honest remedy is the one
# arm 15's verdict already carries: run inside a session with a keyring, or
# inject GH_TOKEN. So the two fixtures are reconciled toward the SAFER verdict
# rather than toward the one that happened to be here.
#
# THIS ARM'S ORIGINAL INTENT IS PRESERVED IN FULL: its subject is that a missing
# service must never read as a LOCKED one, and `blocked:credential-
# unretrievable-no-keyring-service` makes no lock claim. That assertion is kept
# explicit below so the arm still fails if a lock claim reappears.
#
# arm 2b (no busctl AT ALL -- macOS, forge) still expects `missing:` and is
# untouched: a platform with no org.freedesktop.secrets by design was never
# going to answer, which is a different fact from a bus that answered "nothing
# here".
mk_bin "$W/bin-nosvc" noservice
D="$(scratch nosvc)"
run_guard "$D" "$W/bin-nosvc"
# HERE-STRINGS, NOT `printf | grep -q`. Refused by
# check-sigpipe-verdict-pipelines-added, and the hazard is real rather than
# stylistic: `grep -q` EXITS ON ITS FIRST MATCH, which SIGPIPEs the producer
# still writing into it, and under `pipefail` that 141 becomes the pipeline's
# status. The failure mode is the nastiest orientation possible — it fires only
# when the pattern MATCHES, so a verdict arm can report failure precisely when
# the thing it asserts is TRUE, and never when it is false.
#
# I wrote these by copying the shape from line 121 of this same file, which
# carries a `# sigpipe-ok` marker earning its exemption. Copying the code and
# not the justification is how a reviewed exception becomes an unreviewed
# default.
if grep -q '^blocked:credential-unretrievable-no-keyring-service$' <<<"$OUT"; then
    ok "blocked:credential-unretrievable-no-keyring-service — unreachable store, not a proven-absent credential"
elif grep -q '^missing:no-credential-channel$' <<<"$OUT"; then
    bad "no secret service read as missing: — that verdict's remedy is the fleet-evicting re-auth 1025-a896 forbids"
else
    bad "expected blocked:credential-unretrievable-no-keyring-service, got '$OUT'"
fi
# MATCH A LOCK CLAIM, NOT THE SUBSTRING "lock" -- which is inside "bLOCKed",
# the very verdict this arm now asserts is correct. The first version of this
# assertion used `grep -qi lock` and failed on its own expected output. Third
# instance of this exact mistake in one session (a marker prepended to a literal
# an assert searched for; a `grep -f` pattern matching its own watcher's command
# line), and the rule each time is the same: assert the SENTENCE that does the
# work, never a fragment that can appear inside an unrelated word.
if grep -qiE 'is locked|unlock' <<<"$ERR"; then
    bad "THE ARM'\''S ORIGINAL SUBJECT: a missing service claimed a LOCK"
else
    ok "makes no lock claim (this arm'\''s original subject, preserved)"
fi

echo "arm 2b — NEGATIVE CONTROL: no busctl at all (macOS, forge) still reads missing:"
# THIS ARM USED TO PREPEND ITS STUB DIR TO $PATH, which does not remove anything
# — the system busctl at /usr/bin stayed reachable, so the guard probed THIS
# host's real keyring. It passed for a year of minutes only because the keyring
# happened to be unlocked at the time; the moment this host's login collection
# re-locked, the arm reported "a host without busctl" while reading a host that
# has one. That is 1109-t8kw's class exactly: a fixture asserting a property of
# the environment it runs in. Build the PATH from nothing instead, the way arm 9
# does, so "absent" means absent.
_bin2b="$W/bin-nobusctl-real"
mkdir -p "$_bin2b"
for _t in bash sh git grep sed awk cat cut tr wc head tail date mktemp dirname \
          basename sort uniq stat env printf id hostname find xargs jq rm mkdir chmod expr timeout; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$_bin2b/$_t"
done
cat > "$_bin2b/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
chmod +x "$_bin2b/gh"
if PATH="$_bin2b" command -v busctl >/dev/null 2>&1; then
    bad "could not build a busctl-free PATH — this arm would assert about the wrong host"
else
    D="$(scratch nobusctl)"
    OUT2B="$( cd "$D" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_HOST_KIND \
              PATH="$_bin2b" bash "$GUARD" 2>/dev/null )"
    if grep -q '^missing:no-credential-channel$' <<<"$OUT2B"; then
        ok "missing:no-credential-channel with genuinely no busctl on PATH"
    else
        bad "a host without busctl must read missing:, got '$OUT2B'"
    fi
fi

echo "arm 3 — NEGATIVE CONTROL: an UNLOCKED collection does not trip the lock arm"
mk_bin "$W/bin-unlocked" unlocked
D="$(scratch unlocked)"
run_guard "$D" "$W/bin-unlocked"
# The lock probe is gone (1265-8qr6), so "does not trip the LOCK arm" now means
# the verdict must carry no lock claim at all. Service on the bus, gh unable to
# answer: that is unknown:, the same as arm 1 — this arm no longer discriminates
# locked from unlocked, because the guard cannot, and saying so is the honest
# form. What it still pins is that neither state is ever reported as a lock.
if printf '%s' "$OUT" | grep -qi 'locked'; then # sigpipe-ok: safe pipeline
    bad "an unlocked collection must not read as locked, got '$OUT'"
elif printf '%s' "$OUT" | grep -q '^unknown:secret-service-unprobed$'; then # sigpipe-ok: safe pipeline
    ok "unlocked + no token reads unknown:, with no lock claim"
else
    bad "expected unknown:secret-service-unprobed with no lock claim, got '$OUT'"
fi

echo "arm 4 — the remedy names UNLOCK and FORBIDS the re-auth (1025-a896)"
D="$(scratch remedy)"
run_guard "$D" "$W/bin-locked"
_r_unlock=0; _r_noauth=0; _r_order=0
grep -qi 'UNLOCK' <<<"$ERR" && _r_unlock=1
grep -qi "do not run 'gh auth login'" <<<"$ERR" && _r_noauth=1
grep -q '1025-a896' <<<"$ERR" && _r_order=1
if [ "$_r_unlock" -eq 1 ] && [ "$_r_noauth" -eq 1 ] && [ "$_r_order" -eq 1 ]; then
    ok "remedy says unlock, says not to re-auth, and cites 1025-a896"
else
    bad "remedy incomplete (unlock=$_r_unlock no-reauth=$_r_noauth order=$_r_order): $ERR"
fi

echo "arm 5 — TRIPWIRE (1265-8qr6): the Locked property read must NOT come back"
# This arm used to assert the busctl probe was BOUNDED through _ccc_timeout.
# The probe is now removed outright, so a bounded-probe assertion would demand
# the very call that aborts gnome-keyring-daemon 50.0 in its own GetProperty
# handler. The arm is inverted rather than deleted: order 988's concern was an
# unbounded probe, and absence satisfies it strictly. A reinstated read — by
# any spelling, on any namespace — fails here first.
if grep -qE 'get-property[^|]*Locked' "$GUARD"; then # sigpipe-ok: safe pipeline
    bad "a Locked property read is BACK in the guard — it aborts gnome-keyring-daemon 50.0 and D-Bus re-activates it LOCKED, manufacturing the state it reports (1265-8qr6)"
else
    ok "no Locked property read in the guard"
fi

echo "arm 6 — gh auth status is bounded too (it BLOCKS on a locked keyring)"
if grep -qE '_ccc_timeout [0-9]+ gh auth status' "$GUARD"; then
    ok "gh auth status runs under _ccc_timeout"
else
    bad "gh auth status is unbounded — against a locked keyring it blocks, hanging the guard itself"
fi

echo "arm 7 — a hanging probe cannot wedge the guard: the locked arm answers fast"
_t0=$(date +%s)
D="$(scratch timing)"
run_guard "$D" "$W/bin-locked"
_t1=$(date +%s)
if [ $((_t1 - _t0)) -le 60 ]; then
    ok "verdict in $((_t1 - _t0))s"
else
    bad "the locked arm took $((_t1 - _t0))s — a guard that hangs is the failure it reports"
fi

echo "arm 9 — REGRESSION (1193-yw6u): with NO timeout(1)/gtimeout(1), a healthy gh"
echo "        must not read as 'no credential channel'"
#
# THE BLIND SPOT THIS ARM CLOSES. 1189-2ra5 bounded `gh auth status` in
# _ccc_timeout, which on a host with no timeout(1) AND no gtimeout(1) returns 127
# WITHOUT RUNNING THE COMMAND (order 988's refusal to run a probe unbounded). The
# gh arm therefore went false on a healthy gh and the verdict fell through to
# missing:no-credential-channel — a channel that EXISTS, reported as absent,
# pointing the reader at the `gh auth login` that 1025-a896 forbids. Both macOS
# hosts lost the ability to land for a day.
#
# NO LINUX OR WINDOWS GATE COULD SEE IT: check-host-tools.sh's prover row for
# `timeout` is scoped platform: macos, so the only arm that exercised this state
# runs on the two hosts that were broken by it. This arm reproduces the state on
# ANY platform by curating PATH, so the next regression of this shape is caught
# by whoever writes it rather than by whoever it breaks.
_bin9="$W/bin-notimeout"
mkdir -p "$_bin9"
# Symlink the tools the guard needs, DELIBERATELY EXCLUDING timeout and gtimeout.
for _t in bash sh git grep sed awk cat cut tr wc head tail date mktemp dirname \
          basename sort uniq stat env printf id hostname find xargs jq rm mkdir chmod expr; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$_bin9/$_t"
done
# A gh that HAS a token: `auth status` green, exactly the healthy macOS host.
cat > "$_bin9/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$_bin9/gh"
if [ -x "$_bin9/bash" ] && ! PATH="$_bin9" command -v timeout >/dev/null 2>&1; then
    D9="$(scratch notimeout)"
    OUT9="$( cd "$D9" && env -u GH_TOKEN -u GITHUB_TOKEN -u TILLANDSIAS_HOST_KIND \
             PATH="$_bin9" bash "$GUARD" 2>/dev/null )"
    case "$OUT9" in
        missing:no-credential-channel)
            bad "a healthy gh with no timeout(1) reads as missing:no-credential-channel — 1193-yw6u is back, and every macOS host is blocked" ;;
        blocked:*|ok:*|unverified:*)
            ok "verdict is '$OUT9' — the absence of coreutils is not an answer about the credential" ;;
        *)
            bad "unexpected verdict with no timeout(1): '$OUT9'" ;;
    esac
else
    printf 'skip: could not build a timeout-free PATH on this host\n'
fi

echo
echo "locked-keyring discriminator: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:locked-keyring-discriminator:$fail"
    exit 1
fi
echo "ok:locked-keyring-discriminator:$pass"
exit 0
