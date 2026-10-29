#!/bin/sh
# @trace spec:git-mirror-service, order:1910-nb6m
# seed-mirror <bare-mirror-dir>
#
# Seed an empty mirror's exported heads and tags from origin. The configured
# default refspec only populates refs/remotes/origin/* (safe reconciliation),
# which would leave a fresh mirror with no cloneable heads/tags, so this
# one-time seed writes local heads and tags directly; later reconcile fetches
# use the safe tracking refspec.
#
# 1910-nb6m: a TRANSPORT failure is retried with backoff. Measured on macOS
# 2026-10-28: on a cold enclave squid's first DNS lookups hung ~30 s and came
# back 503, squid then answered github.com with an instant 503 from its
# negative cache, and the single seed attempt landed on it. The next attempt
# was the reconciler, 120 s later, after the forge had given up. An AUTH
# refusal is not retried: retrying cannot fix a missing credential.
#
# SEED_RETRY_DELAYS: seconds to wait before each retry ("" = one attempt).
# The default spans squid's 60 s negative_dns_ttl.
#
# Exit 0 when seeded. Otherwise exit 1 with the retry history and the last
# fetch output on stdout; the entrypoint classifies it (auth vs transport) and
# prints the launcher's seed-failure marker.

mirror="$1"
if [ -z "$mirror" ] || [ ! -d "$mirror" ]; then
    echo "seed-mirror: usage: seed-mirror <bare-mirror-dir>" >&2
    exit 2
fi

delays="${SEED_RETRY_DELAYS-2 4 8 16 30 30}"
attempt=1
while :; do
    if out="$(git -C "$mirror" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1)"; then
        [ "$attempt" -gt 1 ] && echo "seed-mirror: seeded on attempt $attempt"
        exit 0
    fi
    case "$out" in
        *"could not read Username"*|*"terminal prompts disabled"*|*"Authentication failed"*|*"Invalid username or password"*|*"error: 401"*|*"error: 403"*)
            echo "$out"
            exit 1
            ;;
    esac
    # shellcheck disable=SC2086 # word-splitting the delay list is the point
    set -- $delays
    if [ "$#" -eq 0 ]; then
        echo "seed-mirror: attempt $attempt failed, no retries left"
        echo "$out"
        exit 1
    fi
    echo "seed-mirror: attempt $attempt failed, retrying in ${1}s"
    sleep "$1"
    shift
    delays="$*"
    attempt=$((attempt + 1))
done
