#!/usr/bin/env bash
# @trace order:1286-4437
#
# THE FLAG IS ACCEPTED AT RUNTIME, not merely mentioned in the source.
#
# WHY THIS FIXTURE EXISTS. v56.9.20.1 shipped with `--reset-state` parsed,
# dispatched, documented in usage AND in `--help`, and ABSENT from main.rs's
# `known_flags` allow-list — which exits 2 before either dispatch is reached.
# The published install.sh calls the flag, so every Linux curl-install of that
# release failed:
#
#   Running tillandsias --reset-state (resets local state, then reprovisions...)
#   [tillandsias] version: 56.9.20.1
#   Unsupported option: --reset-state
#   install_exit=2
#
# The litmus arm that was supposed to prove this contract asserted the flag
# "exists on the Linux surface" by COUNTING OCCURRENCES of `--reset-state` in
# main.rs and requiring >= 4. It counted 12 and passed, on a tree whose binary
# refused the flag. Mentions are not acceptance, and only running the thing can
# tell them apart.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

# Resolve through the shared probe (721-nyev), never a hardcoded target/ path.
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
BIN=""
if declare -f resolve_target_binary >/dev/null 2>&1; then
    BIN="$(resolve_target_binary tillandsias release "$ROOT" 2>/dev/null || true)"
    [ -n "$BIN" ] || BIN="$(resolve_target_binary tillandsias debug "$ROOT" 2>/dev/null || true)"
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "skip:reset-flags-accepted:no-runnable-tillandsias-binary — build it first; this arm must RUN the binary, and reading the source is what missed the defect"
    exit 0
fi

# ── ARM 1: the BEHAVIOURAL probe, and it uses --reset-guest DELIBERATELY ────
# `--reset-guest` under TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 REFUSES and returns
# (main.rs run_reset_guest: "guest reset refused: ..."), so the probe reaches the
# dispatch and destroys NOTHING.
#
# `--reset-state` under the same env is NOT safe to probe: its OK=0 path prints
# the shared skipped line and then calls run_init, which PROVISIONS THE ENCLAVE.
# A litmus step must not bring up a substrate to prove a flag parses, so this
# fixture proves acceptance on the flag whose refusal path is inert and proves
# the other one structurally, below. That asymmetry is measured, not assumed.
out="$(TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 "$BIN" --reset-guest 2>&1)"; rc=$?
case "$out" in
    *"Unsupported option"*) bad "the allow-list still rejects a reset flag at runtime (rc=$rc): ${out%%$'\n'*}" ;;
    *) ok "a reset flag gets PAST the allow-list and reaches its dispatch (rc=$rc)" ;;
esac
case "$out" in
    *"TILLANDSIAS_DESTRUCTIVE_RESET_OK=0"*) ok "the dispatch ran: it refused by naming the opt-out, destroying nothing" ;;
    *) bad "reached no recognisable dispatch; output was: ${out%%$'\n'*}" ;;
esac
[ "$rc" -ne 2 ] && ok "exit is not 2 (2 is the allow-list's own refusal code)" \
                || bad "exit 2 — indistinguishable from the allow-list refusal this fixture exists to catch"

# ── ARM 2: --reset-state is in the allow-list, asserted on the ARRAY ────────
# Not a count of mentions anywhere in the file: the defect was twelve mentions
# and no entry. This reads the array itself.
_arr="$(awk '/let known_flags = \[/,/\];/' crates/tillandsias-headless/src/main.rs)"
for f in --reset-state --reset-guest; do
    if printf '%s' "$_arr" | grep -q "\"$f\""; then
        ok "known_flags contains $f"
    else
        bad "known_flags does NOT contain $f — it will exit 2 however well the flag is documented"
    fi
done

# ── ARM 3: EVERY dispatched reset flag has an entry ─────────────────────────
# The anti-regression: a third reset flag added with a dispatch and no entry
# reds here rather than in a release.
_dispatched="$(grep -oE '^\s*let reset_[a-z]+ = user_args\.iter\(\)\.any\(\|a\| a == "(--reset-[a-z]+)"' \
    crates/tillandsias-headless/src/main.rs | grep -oE -- '--reset-[a-z]+' | sort -u)"
_missing=""
for f in $_dispatched; do
    printf '%s' "$_arr" | grep -q "\"$f\"" || _missing="$_missing $f"
done
if [ -z "$_missing" ]; then
    ok "every parsed --reset-* flag has an allow-list entry ($(printf '%s' "$_dispatched" | tr '\n' ' '))"
else
    bad "parsed but not allow-listed:$_missing"
fi

# ── ARM 4: NEGATIVE CONTROL — a genuinely unknown flag is still refused ─────
# Widening the allow-list must not stop it refusing anything.
out2="$(TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 "$BIN" --definitely-not-a-flag-1286 2>&1)"; rc2=$?
case "$out2" in
    *"Unsupported option"*) ok "NEGATIVE CONTROL: an unknown flag is still refused (rc=$rc2)" ;;
    *) bad "the allow-list no longer refuses an unknown flag — the guard was widened into nothing" ;;
esac

printf 'reset-flags-accepted %d/%d\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
echo "ok:reset-flags-accepted:$pass/$pass"
