#!/usr/bin/env bash
# freshness: added 2026-08-29 linux-yoga (order 923-rmtw)
# @trace order:923-rmtw, order:801-kqme, spec:proxy-container
#
# enclave-proxy.sh — THE shell-side copy of the enclave proxy env, and the only
# one. Source it; do not execute it.
#
#     . "$(dirname "$0")/lib/enclave-proxy.sh"
#     ... --env "no_proxy=$ENCLAVE_NO_PROXY" ...
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
#
# The canonical list is ENCLAVE_NO_PROXY_BASE in
# crates/tillandsias-headless/src/main.rs, and Rust callers all read it through
# enclave_no_proxy(). Shell callers could not, so they each pasted a copy — and
# a pasted constant is a constant that stops tracking its source.
#
# MEASURED 2026-08-29, after 923-rmtw removed the containers.conf block: TWO
# shell copies were still frozen at their pre-801-kqme values, eleven days after
# the constant changed:
#
#   scripts/run-forge-project.sh:149
#       localhost,127.0.0.1,proxy,git-service,inference
#   scripts/orchestrate-enclave.sh:63
#       localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service,10.0.42.0/24
#
# Both name `git-service`, which the Rust list dropped, and neither names
# `nix-cache`, which it gained (801-kqme). A container launched by either script
# therefore sends https://nix-cache:5000 through squid and gets
# `Recv failure: Connection reset by peer` — the same 883-ncrs symptom the
# containers.conf block produced, from a different source. Fixing the deployed
# file and leaving these would have retired one instance of the class and kept
# two.
#
# ── WHY A LIB AND NOT A CALL INTO THE BINARY ────────────────────────────────
#
# Reading the value from `tillandsias` at run time would be a truer single
# source, and it is the wrong trade here: these scripts run in places where the
# binary is not necessarily built (orchestrate-enclave.sh brings the enclave up;
# run-forge-project.sh runs against a mounted checkout), so a binary dependency
# converts a stale list into a hard failure. One shell definition plus a GATE
# that fails when it diverges from the Rust constant gets the same protection
# without the runtime coupling — scripts/test-enclave-proxy-lib.sh is that gate,
# and it parses main.rs rather than restating the value, so the next change to
# ENCLAVE_NO_PROXY_BASE breaks the build instead of stranding the fleet.
#
# THE SUBNET IS APPENDED, exactly as enclave_no_proxy() does it. A CIDR entry
# does NOT cover a hostname — curl matches no_proxy against the name as written,
# not against the address it resolves to — which is precisely why `nix-cache`
# must be named even though the subnet is listed.

# Keep in step with ENCLAVE_NO_PROXY_BASE (main.rs) — the gate enforces it.
ENCLAVE_NO_PROXY_BASE="localhost,127.0.0.1,0.0.0.0,::1,vault,tillandsias-vault,inference,proxy,nix-cache"
# Mirrors DEFAULT_ENCLAVE_SUBNET and its TILLANDSIAS_ENCLAVE_SUBNET override.
ENCLAVE_SUBNET_DEFAULT="10.0.42.0/24"
ENCLAVE_NO_PROXY="${ENCLAVE_NO_PROXY_BASE},${TILLANDSIAS_ENCLAVE_SUBNET:-$ENCLAVE_SUBNET_DEFAULT}"
ENCLAVE_PROXY_URL="http://proxy:3128"

# The six --env flags, in the order proxy_env_args() emits them. Callers that
# build a podman argv can splice this array instead of writing the flags out.
ENCLAVE_PROXY_ENV_ARGS=(
    --env "http_proxy=$ENCLAVE_PROXY_URL"
    --env "https_proxy=$ENCLAVE_PROXY_URL"
    --env "HTTP_PROXY=$ENCLAVE_PROXY_URL"
    --env "HTTPS_PROXY=$ENCLAVE_PROXY_URL"
    --env "no_proxy=$ENCLAVE_NO_PROXY"
    --env "NO_PROXY=$ENCLAVE_NO_PROXY"
)
