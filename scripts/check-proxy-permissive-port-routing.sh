#!/usr/bin/env bash
# @trace spec:proxy-container
# @trace order:245
#
# ORDER 245 §5 P6. Keep images/proxy/squid.conf HONEST about whether anything
# actually uses the permissive port.
#
# THE DEFECT THIS EXISTS FOR, measured 2026-08-30. squid.conf described :3129
# flatly as "PERMISSIVE (image builds)", declared `http_port 3129 ssl-bump`,
# carried an `acl build_port localport 3129`, and entrypoint.sh announced
# `permissive: :3129` at startup — while the string `3129` appeared NOWHERE in
# crates/. No published port, no HTTP_PROXY value, no build argument. Image
# builds egressed directly through `--dns 8.8.8.8`. A reader asking "are image
# builds proxied?" found four pieces of configuration saying yes and a build
# path that said no.
#
# That is the same failure as a source citation pointing at unrelated code: it
# survives review precisely BECAUSE it reads as evidence. P6 has been open since
# 2026-07 asking for the port to be either wired or deleted; neither happened,
# and in the meantime the config started asserting the first.
#
# WHAT THIS CHECKS — the AGREEMENT, not the decision:
#   * if NO consumer references 3129, squid.conf must say so (the header must
#     carry NOT ROUTED), and
#   * if a consumer DOES reference 3129, that caveat must be gone.
# Either state is legal. Being in one and documenting the other is not. The
# operator's decision (wire it, or delete the port) is untouched by this guard —
# it only refuses the silent middle.
#
# Verdict grammar, one line on stdout:
#   ok:proxy-permissive-port:unrouted-and-documented     exit 0
#   ok:proxy-permissive-port:routed:<n> consumer(s)      exit 0
#   violation:proxy-permissive-port:<reason>             exit 1
#   blocked:<reason>                                     exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

CONF="${TILLANDSIAS_PROXY_CONF:-images/proxy/squid.conf}"
# Where a real consumer would live: the Rust that builds podman argv and env.
CONSUMER_ROOT="${TILLANDSIAS_PROXY_CONSUMER_ROOT:-crates}"

[ -r "$CONF" ] || { echo "blocked:proxy-conf-unreadable:$CONF"; exit 2; }
[ -d "$CONSUMER_ROOT" ] || { echo "blocked:consumer-root-missing:$CONSUMER_ROOT"; exit 2; }

# SCOPE, and a correction someone will otherwise "fix". This searches `crates/`
# only, and that is right even though `build.sh` contains `3129` in several
# places. Those are a DIFFERENT proxy: `_ensure_dev_proxy` runs
# `tillandsias-dev-proxy` from `docker.io/library/squid:6.1` and publishes
# `3129:3129` on the host for dev build tooling. The question this guard asks is
# whether anything routes to the TILLANDSIAS PROXY IMAGE's permissive port, so
# adding build.sh to the search would make it answer a different question and
# report the port as routed when it is not.

# A CONSUMER is Rust that names the port — a published port, a proxy URL, an
# argument. squid.conf declaring its own listener is not a consumer, which is
# the whole distinction the old comment collapsed.
consumers="$(grep -rlF -- '3129' --include='*.rs' "$CONSUMER_ROOT" 2>/dev/null | sort -u)"
n_consumers=$(printf '%s' "$consumers" | grep -c . || true)

# The caveat must be present as a phrase, not merely the word "3129" — the
# config mentions the port many times by construction.
if grep -qF -- 'NOT ROUTED' "$CONF"; then
    documented_unrouted=1
else
    documented_unrouted=0
fi

if [ "$n_consumers" -eq 0 ]; then
    if [ "$documented_unrouted" -eq 1 ]; then
        echo "ok:proxy-permissive-port:unrouted-and-documented"
        exit 0
    fi
    echo "  $CONF describes the permissive port without saying it is unrouted," >&2
    echo "  and no .rs under $CONSUMER_ROOT references 3129 — so nothing sends" >&2
    echo "  traffic to it. Say so in the header (the phrase NOT ROUTED), or wire" >&2
    echo "  a build path through it and delete the caveat. Order 245 P6." >&2
    echo "violation:proxy-permissive-port:undocumented-unrouted"
    exit 1
fi

if [ "$documented_unrouted" -eq 1 ]; then
    echo "  $CONF still says the permissive port is NOT ROUTED, but ${n_consumers}" >&2
    echo "  consumer(s) now reference 3129:" >&2
    printf '%s\n' "$consumers" | sed 's/^/    /' >&2
    echo "  P6 has been acted on — remove the NOT ROUTED caveat in the same" >&2
    echo "  commit that wired it, or the config understates what it does." >&2
    echo "violation:proxy-permissive-port:stale-unrouted-caveat"
    exit 1
fi

echo "ok:proxy-permissive-port:routed:${n_consumers} consumer(s)"
exit 0
