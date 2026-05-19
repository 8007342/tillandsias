#!/usr/bin/env bash
set -euo pipefail
exec cargo test -p tillandsias-podman --test podman_integration -- --ignored
