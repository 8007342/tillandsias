#!/usr/bin/env bash
# @trace order:998-qrwu, order:975-rsgm
#
# lib-ca-path.sh — export TILLANDSIAS_CA_DIR from the ONE declaration.
#
# Source this instead of writing `/tmp/tillandsias-ca`, or
# `${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}` — the second form looks
# single-sourced and is not: the default is a literal, and there were a dozen of
# them. 975-rsgm has to MOVE this directory, and every literal is a site that
# must move with it; a missed one points at a directory that is not there, on a
# recovery path that only runs when something is already wrong.
#
# The declaration is images/default/ca-path.txt, the same file
# tillandsias-core::ca_path reads with include_str!. One value, both runtimes.
#
# An explicit TILLANDSIAS_CA_DIR from the caller always wins and is never
# overridden — the same rule the endpoint derivation applies (967-xq5e).

_lcp_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_lcp_manifest="$_lcp_root/images/default/ca-path.txt"

if [ -z "${TILLANDSIAS_CA_DIR:-}" ]; then
    if [ -r "$_lcp_manifest" ]; then
        TILLANDSIAS_CA_DIR="$(
            grep -v '^[[:space:]]*#' "$_lcp_manifest" \
              | grep -v '^[[:space:]]*$' \
              | head -1 \
              | tr -d '[:space:]'
        )"
        export TILLANDSIAS_CA_DIR
    else
        # FAIL LOUD rather than falling back to a literal. A fallback here would
        # be the 39th copy, and it would be the one that runs exactly when the
        # manifest is missing — i.e. when something is already wrong.
        echo "blocked:ca-path:manifest-unreadable:$_lcp_manifest" >&2
        return 1 2>/dev/null || exit 1
    fi
fi
unset _lcp_root _lcp_manifest
