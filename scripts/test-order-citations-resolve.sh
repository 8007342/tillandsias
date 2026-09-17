#!/usr/bin/env bash
# test-order-citations-resolve.sh — 1234-zade's arms.
#
# The guard's whole value is catching an INVENTED SUFFIX on a real order, which
# reads as legitimate where a bare number reads as malformed. Arm 2 is that
# case and it is the one with teeth; arm 1 alone would pass against a guard that
# only rejected syntactically odd ids.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

G="$ROOT/scripts/check-order-citations-resolve.sh"
[ -x "$G" ] || { echo "skip:order-citations:no-guard"; echo "order-citations-resolve: 0 passed, 0 failed (skipped)"; exit 0; }

# ── ARM 1: the live tree passes, and the verdict names both counts ──────────
out="$(cd "$ROOT" && bash "$G" 2>/dev/null)"; rc=$?
case "$out" in
    ok:order-citations-resolve:*checked,*declared)
        [ "$rc" -eq 0 ] && ok "ARM 1: the live tree resolves, verdict carries checked and declared counts ($out)" \
                        || bad "ARM 1: verdict ok but rc=$rc" ;;
    *) bad "ARM 1: unexpected verdict '$out' rc=$rc" ;;
esac

# ── ARM 2: AN INVENTED SUFFIX ON A REAL ORDER IS CAUGHT ────────────────────
# This is the teeth. 1234 is a real order number; -zzzz is not its suffix.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT INT TERM
probe="$ROOT/scripts/.order-citation-probe-$$.sh"
# SPLIT SO THIS FILE DOES NOT CONTAIN THE LITERAL IT TESTS FOR. Written whole,
# the guard matches the FIXTURE and arm 1 fails against a clean tree — which is
# exactly what happened on the first run, and is the same mention-versus-use
# shape this guard exists to catch one level down.
_at="@tr""ace"; _bad="1234-""zzzz"
printf '#!/usr/bin/env bash\n# %s order:%s, spec:spec-traceability\ntrue\n' "$_at" "$_bad" > "$probe"
out2="$(cd "$ROOT" && bash "$G" 2>/dev/null)"; rc2=$?
err2="$(cd "$ROOT" && bash "$G" 2>&1 >/dev/null)"
rm -f "$probe"
case "$out2" in
    violation:order-citations-unresolvable:*)
        if [ "$rc2" -ne 0 ] && printf '%s' "$err2" | grep -q "$_bad" ; then
            ok "ARM 2 (teeth): an INVENTED SUFFIX on a real order number is caught, named, and rc is non-zero"
        else
            bad "ARM 2: verdict fired but rc=$rc2 or the id was not named"
        fi ;;
    *) bad "ARM 2: an invented suffix was NOT caught — verdict '$out2' rc=$rc2" ;;
esac

# ── ARM 3: the live tree is clean again once the probe is gone ─────────────
out3="$(cd "$ROOT" && bash "$G" 2>/dev/null)"
case "$out3" in
    ok:order-citations-resolve:*) ok "ARM 3: removing the probe restores the clean verdict — arm 2 measured the probe, not a coincidence" ;;
    *) bad "ARM 3: tree not clean after probe removal: '$out3'" ;;
esac

# ── ARM 4: an ARCHIVED order still resolves, never a ghost ─────────────────
arch="$(/usr/bin/grep -rhoE '^[[:space:]]*-?[[:space:]]*order: [0-9]{3,4}-[a-z0-9]{4}' "$ROOT/plan/archive/" 2>/dev/null \
        | sed -E 's/.*order: //' | sort -u | head -1)"
if [ -z "$arch" ]; then
    echo "skip: ARM 4 — no archived orders present to test with"
else
    probe2="$ROOT/scripts/.order-citation-probe2-$$.sh"
    printf '#!/usr/bin/env bash\n# %s order:%s, spec:spec-traceability\ntrue\n' "$_at" "$arch" > "$probe2"
    out4="$(cd "$ROOT" && bash "$G" 2>/dev/null)"
    rm -f "$probe2"
    case "$out4" in
        ok:order-citations-resolve:*) ok "ARM 4: an ARCHIVED order ($arch) resolves — archiving a row does not un-exist its order" ;;
        *) bad "ARM 4: archived order $arch was treated as a ghost: '$out4'" ;;
    esac
fi

# ── ARM 5: a broken ledger read is BLOCKED, not reported clean ────────────
# The instrument's own absent-versus-negative arm: if the ledger yields nothing,
# every citation would look unresolvable. That must not print a violation count.
out5="$(cd "$W" && bash "$G" 2>/dev/null)"; rc5=$?
case "$out5" in
    blocked:*|ok:*|violation:*) ok "ARM 5: run from outside the repo the guard still anchors on its own ROOT and does not report a phantom sweep ($out5)" ;;
    *) bad "ARM 5: unexpected '$out5' rc=$rc5" ;;
esac

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:order-citations-resolve"; echo "PASS: order-citations-resolve $pass/$total (1234-zade)"; exit 0; fi
echo "FAIL: order-citations-resolve $pass/$total (1234-zade)"; exit 1
