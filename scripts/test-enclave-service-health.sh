#!/usr/bin/env bash
# test-enclave-service-health.sh — hermetic fixture for
# scripts/check-enclave-service-health.sh (order 798-tk7b).
#
# No live podman, no containers, no network: every reading comes from a
# scripted `podman` on PATH. That matters for the one case the real host cannot
# produce on demand — a STOPPED container whose recorded healthcheck still says
# `healthy`, which is the state the packet was filed about and the state most
# likely to be quietly dropped by a future edit. Scenario 4 pins it and the
# mutation control proves scenario 4 can fail.
#
# The expected strings here are the CONVERGED grammar: yoga implemented the
# same packet the same night inside the product (format_enclave_service_line,
# crates/tillandsias-headless/src/main.rs) and its spellings are canonical —
# fail:enclave-service-dead / note:enclave-service-stopped / signal=SIGKILL,
# shared keys in its order, this script's extra facts appended.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-enclave-service-health.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/enclave-service-health-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()   { echo "ok: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }

# A scripted podman. PS_OUT is the `ps -a --format` body (name|state|exitcode|
# started|exited|restarts); HEALTH_<name> and LABEL_<name> feed inspect. PS_RC
# forces a failed reading.
make_podman() { # <dir>
    mkdir -p "$1"
    cat > "$1/podman" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    ps)
        [ "${PS_RC:-0}" -eq 0 ] || exit "${PS_RC}"
        printf '%s\n' "$PS_OUT"
        ;;
    inspect)
        # health|io.tillandsias.image.name — the single round trip the reporter
        # makes per down service.
        name="$2"
        key="$(printf '%s' "$name" | tr -c '[:alnum:]' '_')"
        eval "h=\"\${HEALTH_${key}:-}\"; l=\"\${LABEL_${key}:-}\""
        printf '%s|%s\n' "$h" "$l"
        ;;
    *) exit 1 ;;
esac
FAKE
    chmod +x "$1/podman"
}

BIN="$TMP/bin"
make_podman "$BIN"

# A PATH that carries the tools the guard itself needs. Stripping PATH to
# nothing tests the harness, not the code — that trap cost a sibling a fixture
# on 798-c4mq the same night.
REALPATH_DIRS="/usr/bin:/bin"
run() { PATH="$BIN:$REALPATH_DIRS" bash "$GUARD" "$@" 2>"$TMP/err"; }

now="$(date -u +%s)"

# A tools-only PATH for the no-podman scenario. It must carry what the guard
# uses (date, tr) and NOT podman — pointing at /usr/bin would find the real
# one, which is how this scenario first "passed" by reporting the live host.
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for t in date tr; do
    src="$(command -v "$t")" && ln -sf "$src" "$TOOLS/$t"
done

# ---------------------------------------------------------------- scenario 1
# No podman at all: a blocked reading, never a clean bill of health.
# Invoked through an ABSOLUTE bash: with PATH pointing only at $TOOLS, the
# shell itself is unresolvable and the run produces empty output that looks
# like a silent pass. Caught by this scenario returning '' on the first try.
[ -x "$TOOLS/date" ] || bad "harness: tools-only PATH is not set up as intended"
out="$(PATH="$TOOLS" "${BASH:-/bin/bash}" "$GUARD" 2>/dev/null)"
if [ "$out" = "blocked:enclave-service-health:no-podman" ]; then
    ok "no podman -> blocked:no-podman (not a healthy report)"
else
    bad "no podman: expected blocked:no-podman, got '$out'"
fi

# ---------------------------------------------------------------- scenario 2
# Everything up.
export PS_OUT="tillandsias-vault|running|0|${now}|0|0
tillandsias-proxy|running|0|${now}|0|0
tillandsias-router|running|0|${now}|0|0"
out="$(run)"; rc=$?
if [ "$out" = "ok:enclave-service-health:services=3:up=3:down=0:dead=0:absent=0" ] && [ "$rc" -eq 0 ]; then
    ok "all running -> ok, 3/3 up, rc=0"
else
    bad "all running: got '$out' rc=$rc"
fi

# ---------------------------------------------------------------- scenario 3
# One dead of SIGTERM two days ago. Signal is spelled as yoga spells it.
exited=$((now - 250492))
export PS_OUT="tillandsias-vault|running|0|${now}|0|0
tillandsias-nix|exited|143|$((now - 300000))|${exited}|0"
out="$(run)"; rc=$?
err="$(cat "$TMP/err")"
if [ "$out" = "degraded:enclave-service-health:services=2:up=1:down=1:dead=1:absent=0" ] && [ "$rc" -eq 0 ]; then
    case "$err" in
        *"fail:enclave-service-dead:service=tillandsias-nix:state=exited:rc=143:signal=SIGTERM:age=2d21h:restarts=0:health=none:origin=unlabelled:age_s=250492"*)
            ok "exited(143) -> dead, signal=SIGTERM, age=2d21h, restarts+origin+age_s; rc still 0 (report, not gate)" ;;
        *) bad "exited(143): detail line wrong: $err" ;;
    esac
else
    bad "exited(143): got '$out' rc=$rc"
fi

# --------------------------------------------------------------- scenario 3a
# A CLEAN STOP IS NOT A FAULT (yoga's distinction, adopted). Conflating an
# operator's `podman stop` with a crash makes the report noisy enough to
# ignore, which is how the original blind spot survived five hours of cycles.
export PS_OUT="tillandsias-proxy|exited|0|$((now - 800))|$((now - 700))|2"
out="$(run)"
err="$(cat "$TMP/err")"
if [ "$out" = "degraded:enclave-service-health:services=1:up=0:down=1:dead=0:absent=0" ]; then
    case "$err" in
        *"note:enclave-service-stopped:service=tillandsias-proxy:state=exited:rc=0:signal=none:age=11m:restarts=2"*)
            ok "clean stop (rc=0) -> note:...stopped, dead=0, restarts carried" ;;
        *) bad "clean stop: detail wrong: $err" ;;
    esac
else
    bad "clean stop: got '$out'"
fi

# --------------------------------------------------------------- scenario 3b
# origin distinguishes a product-built service from something merely wearing
# the name prefix. Both are REPORTED — the annotation must never become a
# filter, or a real service built outside the labelled path (tillandsias-nix-cache,
# live on macuahuitl 2026-08-18) disappears from the one place that lists it.
export PS_OUT="tillandsias-vault|exited|1|$((now - 500))|$((now - 400))|0
tillandsias-scratch|exited|1|$((now - 500))|$((now - 400))|0"
export LABEL_tillandsias_vault="vault"
out="$(run)"
err="$(cat "$TMP/err")"
lab=0; unlab=0
case "$err" in *"service=tillandsias-vault:"*":origin=product-vault"*) lab=1 ;; esac
case "$err" in *"service=tillandsias-scratch:"*":origin=unlabelled"*) unlab=1 ;; esac
if [ "$lab" -eq 1 ] && [ "$unlab" -eq 1 ] && [ "$out" = "degraded:enclave-service-health:services=2:up=0:down=2:dead=2:absent=0" ]; then
    ok "origin: labelled -> product-vault, unlabelled -> unlabelled, BOTH still reported"
else
    bad "origin: labelled=$lab unlabelled=$unlab out='$out'"
fi
unset LABEL_tillandsias_vault

# ---------------------------------------------------------------- scenario 4
# THE PACKET'S CASE. Stopped, SIGKILLed, and podman still says healthy.
export PS_OUT="tillandsias-vault|exited|137|$((now - 20000))|$((now - 18000))|0"
export HEALTH_tillandsias_vault="healthy"
out="$(run)"
err="$(cat "$TMP/err")"
stale_ok=0
case "$err" in *":signal=SIGKILL:"*":health=stale-healthy"*) stale_ok=1 ;; esac
note_ok=0
case "$err" in *"podman's stale record, not a reading"*) note_ok=1 ;; esac
if [ "$stale_ok" -eq 1 ] && [ "$note_ok" -eq 1 ] && [ "$out" = "degraded:enclave-service-health:services=1:up=0:down=1:dead=1:absent=0" ]; then
    ok "Exited(137) + recorded 'healthy' -> health=stale-healthy, signal=SIGKILL, explanatory NOTE"
else
    bad "stale-healthy: stale=$stale_ok note=$note_ok out='$out' err='$err'"
fi
unset HEALTH_tillandsias_vault

# ---------------------------------------------------------------- scenario 5
# A running container that is genuinely healthy must NOT be called stale --
# the cross-control without which scenario 4 would pass on a healthy stack.
export PS_OUT="tillandsias-proxy|running|0|${now}|0|0"
export HEALTH_tillandsias_proxy="healthy"
out="$(run)"
err="$(cat "$TMP/err")"
if [ "$out" = "ok:enclave-service-health:services=1:up=1:down=0:dead=0:absent=0" ] && [ -z "$err" ]; then
    ok "running + healthy -> ok, silent, NOT reported as stale-healthy"
else
    bad "running healthy: out='$out' err='$err'"
fi
unset HEALTH_tillandsias_proxy

# ---------------------------------------------------------------- scenario 6
# Declared-but-absent: enumeration cannot see it, a declaration can.
export PS_OUT="tillandsias-proxy|running|0|${now}|0|0"
out="$(run --expect tillandsias-git,tillandsias-proxy)"
err="$(cat "$TMP/err")"
if [ "$out" = "degraded:enclave-service-health:services=1:up=1:down=0:dead=0:absent=1" ]; then
    case "$err" in
        *"fail:enclave-service-absent:service=tillandsias-git:state=absent"*)
            ok "--expect names a missing service -> absent=1, service named" ;;
        *) bad "absent: detail wrong: $err" ;;
    esac
else
    bad "absent: got '$out'"
fi

# ---------------------------------------------------------------- scenario 7
# A foreign container in the same store is not an enclave service. Without the
# prefix test this reads down=1 on a perfectly healthy stack; `created` is the
# live shape on macuahuitl (`modest_proskuriakova`).
export PS_OUT="tillandsias-proxy|running|0|${now}|0|0
modest_proskuriakova|created|0|0|0|0"
out="$(run)"
if [ "$out" = "ok:enclave-service-health:services=1:up=1:down=0:dead=0:absent=0" ]; then
    ok "foreign container ignored -> services=1, no false alarm"
else
    bad "foreign container: got '$out'"
fi

# ---------------------------------------------------------------- scenario 8
# --strict is the opt-in gate, and only on a degraded reading.
export PS_OUT="tillandsias-nix|exited|139|$((now - 900))|$((now - 600))|0"
run --strict >/dev/null; rc_deg=$?
export PS_OUT="tillandsias-proxy|running|0|${now}|0|0"
run --strict >/dev/null; rc_ok=$?
if [ "$rc_deg" -eq 1 ] && [ "$rc_ok" -eq 0 ]; then
    ok "--strict: degraded -> rc=1, ok -> rc=0"
else
    bad "--strict: degraded rc=$rc_deg (want 1), ok rc=$rc_ok (want 0)"
fi

# ---------------------------------------------------------------- scenario 9
# A FAILED reading must not be reported as a healthy one. This is the whole
# family the packet belongs to: silence read as good news.
export PS_OUT=""
export PS_RC=125
out="$(run)"; rc=$?
err="$(cat "$TMP/err")"
if [ "$out" = "blocked:enclave-service-health:unreadable" ] && [ "$rc" -eq 0 ]; then
    case "$err" in
        *"NOT a report of a healthy stack"*) ok "podman ps rc=125 -> blocked:unreadable, says so explicitly" ;;
        *) bad "unreadable: missing the explicit disclaimer: $err" ;;
    esac
else
    bad "unreadable: got '$out' rc=$rc"
fi
unset PS_RC

# --------------------------------------------------------------- mutation
# Delete the stale-healthy branch (delete, not comment out: a commented line
# still contains its own text, which is how a mutation control was defeated
# earlier in this fleet's history). Scenario 4 MUST go red.
MUT="$TMP/mutant.sh"
sed '/health="stale-healthy"/d' "$GUARD" > "$MUT"
chmod +x "$MUT"
if cmp -s "$GUARD" "$MUT"; then
    bad "mutation: the branch was not removed — control is vacuous"
else
    export PS_OUT="tillandsias-vault|exited|137|$((now - 20000))|$((now - 18000))|0"
    export HEALTH_tillandsias_vault="healthy"
    mut_err="$(PATH="$BIN:$REALPATH_DIRS" bash "$MUT" 2>&1 >/dev/null)"
    # Assert the POSITIVE fact — the mutant's detail line passes podman's word
    # through as `:health=healthy`. An absence test on "health=stale-healthy"
    # reports a working mutant, because that phrase also appears in the guard's
    # own explanatory NOTE, which the mutant still prints. Same self-reference
    # shape as 797-8dzt, found here by this control failing when it had to pass.
    case "$mut_err" in
        *":health=healthy"*) ok "mutation: without the branch the corpse reports podman's 'healthy' verbatim — scenario 4 is falsifiable" ;;
        *) bad "mutation: mutant did not pass 'healthy' through — control proves nothing: $mut_err" ;;
    esac
    unset HEALTH_tillandsias_vault
fi

echo "---"
echo "enclave-service-health: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok: all enclave-service-health scenarios passed"
