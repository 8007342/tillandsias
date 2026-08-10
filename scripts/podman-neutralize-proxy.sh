#!/usr/bin/env bash
# Neutralize the enclave-only proxy env for HOST-side podman operations.
# Order 653-zzkb. @trace spec:proxy-container
#
# `tillandsias --init` writes an enclave-only proxy into
# ~/.config/containers/containers.conf as a GLOBAL env list:
#
#     http_proxy=http://proxy:3128   https_proxy=http://proxy:3128   (+ upper)
#
# Podman injects those into every container it launches AND every image pull, on
# every network. `proxy` is a network alias that exists only inside the enclave
# pod network, so anywhere else it does not resolve and egress dies with
# `proxyconnect tcp: dial tcp: lookup proxy: no such host`.
#
# WHY THIS IS A SHARED SCRIPT AND NOT ANOTHER COPY OF THE LOOP.
# This is a recurring class — tillandsias-podman/src/client.rs:709 records it as
# "Proxy-exemption class (orders 116/118/119; 4th instance 2026-07-11)", each
# instance fixed at the site where it was found. The fifth instance landed inside
# the CONTROL ARM of a p0 security audit (606-9wqd): the proxy poisoned the test
# and the control identically, the control read as "this host has no container
# egress at all", and the reproduction was filed INCONCLUSIVE. It was
# reproducible the whole time. A per-site fix for a class that recurs at new
# sites is a convention, not a fix.
#
# USAGE — source it, do not execute it (it must mutate your environment):
#
#     source scripts/podman-neutralize-proxy.sh
#     podman run ...
#
# An operator who really set a proxy keeps it: only variables that are UNSET are
# given an empty value. An empty value overrides containers.conf `[engine] env`,
# which is the documented mechanism (with-tillandsias-builder.sh:78 has carried
# this loop by hand since order 116).

for _tillandsias_proxy_var in \
    http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
do
    if [[ -z "${!_tillandsias_proxy_var+x}" ]]; then
        export "$_tillandsias_proxy_var="
    fi
done
unset _tillandsias_proxy_var
