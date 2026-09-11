#!/usr/bin/env bash
# @trace order:147
#
# The tray's status refreshes must be SINGLE-SHOT over a PERSISTENT client:
# one connection reused, one request, one reply. No reconnect per tick, no
# retry loop, no sleep.
#
# WHY A GUARD AND NOT THE INSPECTION THAT ALREADY HAPPENED. Order 147's criteria
# 1 and 2 were confirmed on 2026-08-16 by reading the source and citing lines —
# "LIVE_CLIENT is a static OnceLock reused on the fast path
# (notify_icon.rs:135,1272-1293); refresh_vm_status (:1886) and
# refresh_github_login (:2116) are single-shot". Every one of those line numbers
# is now wrong: the symbols sit at :134, :1475, :2211 and :2389 at this tree.
# The FACTS still hold, and I re-checked them rather than assuming — but the
# citation rotted in three weeks and nothing would have said so. That is
# 881-29me's rule arriving from the other direction: cite what survives, and
# where the thing you are citing is a property rather than a line, pin the
# property.
#
# THE PROPERTY IS WHAT THE AUDIT IS ABOUT. 147 exists because the wire showed
# degraded/recovered oscillation, and a tray that reconnects on every poll tick
# manufactures exactly that signal. A reconnect-per-tick regression here would
# look like a transport fault and send the next reader to the transport.
#
# WINDOWS-ONLY SOURCES, INSPECTED TEXTUALLY, and that limit is stated rather
# than hidden: this crate does not compile on Linux or macOS, so no host that
# is not Windows can prove these properties by running them. Textual inspection
# is the honest available technique here, which is the same argument
# check-windows-only-sources-verified.sh already makes for this crate. A Windows
# host running the tray is still the stronger evidence and this does not replace
# it.
#
# Grammar (one line on stdout):
#   ok:tray-refresh-no-polling:<n> checked
#   violation:tray-refresh-polling:<n>
#   blocked:tray-refresh-no-polling:<reason>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

SRC="${1:-crates/tillandsias-windows-tray/src/notify_icon.rs}"
[ -r "$SRC" ] || { echo "blocked:tray-refresh-no-polling:unreadable:$SRC"; exit 2; }

violations=0
checked=0

_fn_body() { # $1=signature-fragment -> the function body, brace-depth scoped
    awk -v sig="$1" '
        index($0, sig) { inside = 1 }
        inside {
            print
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
            depth += n - m
            if (started && depth <= 0) exit
            if (n > 0) started = 1
        }
    ' "$SRC"
}

# ── 1. The client is PERSISTENT ────────────────────────────────────────────
checked=$((checked + 1))
# The identifier BOUNDARY, not a prefix: `^static LIVE_CLIENT` also matches
# `static LIVE_CLIENT_RENAMED`, so the guard's own fixture caught it accepting
# a source where the static had been renamed away. A prefix is not a name.
if ! grep -qE '^static LIVE_CLIENT[[:space:]]*:' "$SRC"; then
    echo "  the live client is no longer a static: a per-call client reconnects on every refresh," >&2
    echo "  which is the reconnect-per-tick shape order 147 audits (it looks like a transport fault)." >&2
    violations=$((violations + 1))
fi

# ── 2. The fast path REUSES it, FOLLOWED THROUGH THE ACCESSOR ──────────────
#
# The first draft of this arm asserted that live_client_request contains the
# token "LIVE_CLIENT", and it FAILED against code that is correct: the fast path
# reaches the static through the live_client_mutex() accessor and never spells
# the name. I had pinned a SPELLING and called it a property — the same defect
# this file exists to prevent, in the file that prevents it. So follow the
# chain: the request path uses the accessor, and the accessor is backed by the
# static. Either link breaking is a real regression; neither link is a name.
checked=$((checked + 1))
_lcr="$(_fn_body 'async fn live_client_request' | sed 's://.*::')"
case "$_lcr" in
    *'live_client_mutex()'*|*LIVE_CLIENT*) ;;
    *)
    echo "  live_client_request no longer reaches the persistent client (neither" >&2
    echo "  live_client_mutex() nor LIVE_CLIENT appears in its body): the fast path" >&2
    echo "  is building a connection per call." >&2
    violations=$((violations + 1))
    ;;
esac

checked=$((checked + 1))
_acc="$(_fn_body 'fn live_client_mutex' | sed 's://.*::')"
if [ -z "$_acc" ]; then
    echo "  live_client_mutex() is gone; the accessor arm above cannot mean anything." >&2
    violations=$((violations + 1))
else
    case "$_acc" in
        *LIVE_CLIENT*) ;;
        *)
            echo "  live_client_mutex() no longer returns the LIVE_CLIENT static — the accessor" >&2
            echo "  is there but it is not backed by a persistent client." >&2
            violations=$((violations + 1))
            ;;
    esac
fi

# ── 3. The refreshes are SINGLE-SHOT ───────────────────────────────────────
# No sleep, no loop, no while. Comments are stripped first: what the code DOES,
# not what it mentions (the 901-jtvi occurrences-not-callers shape).
for fn in 'async fn refresh_vm_status' 'async fn refresh_github_login'; do
    checked=$((checked + 1))
    body="$(_fn_body "$fn" | sed 's://.*::')"
    if [ -z "$body" ]; then
        echo "  $fn not found in $SRC — the guard cannot see the function it pins." >&2
        violations=$((violations + 1))
        continue
    fi
    offending="$(printf '%s\n' "$body" | grep -nE '(\bloop\b|\bwhile\b|sleep\()' | head -3)"
    if [ -n "$offending" ]; then
        echo "  $fn contains a loop or a sleep; it must be single-shot (order 147):" >&2
        printf '%s\n' "$offending" | sed 's/^/    /' >&2
        violations=$((violations + 1))
    fi
done

if [ "$violations" -gt 0 ]; then
    echo "violation:tray-refresh-polling:$violations"
    exit 1
fi
echo "ok:tray-refresh-no-polling:$checked checked"
