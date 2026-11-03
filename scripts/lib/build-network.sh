#!/usr/bin/env bash
# 1955-chrn: the --network a `podman build` may carry for a given --isolation.
#
# 1955-hq7k added --network=private so RUN steps pick up the user's
# containers.conf pasta_options (dead-IPv6 hang, macuahuitl 2026-11-02). But
# podman refuses every network other than host under --isolation chroot:
#   Error: cannot set --network other than host with --isolation chroot
# and chroot is build-image.sh's default, so every image build failed.
# A chroot build already runs in the host's network namespace, so the hang
# the private network fixed cannot occur there: omit --network for chroot,
# keep private for oci/rootless.
#
# Usage: build_network_args <isolation>   -> prints zero or one argument
build_network_args() {
    case "${1:-}" in
        chroot) ;;
        *) printf '%s\n' "--network=private" ;;
    esac
}
