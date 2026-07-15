#!/usr/bin/env bash
# @trace spec:default-image
set -uo pipefail

if [ "${TILLANDSIAS_HOST_KIND:-}" != "forge" ]; then
    echo "skip:not-forge-host"
    exit 0
fi

if [ -n "${FORGE_SERVICE_HEALTH_CHECK_DIR:-}" ]; then
    services_cmd=("$FORGE_SERVICE_HEALTH_CHECK_DIR/services")
    vault_cmd=("$FORGE_SERVICE_HEALTH_CHECK_DIR/vault")
    outbound_cmd=("$FORGE_SERVICE_HEALTH_CHECK_DIR/outbound")
else
    services_cmd=(tillandsias-services --json)
    vault_cmd=(vault-cli health)
    outbound_cmd=(curl -fsS --max-time 10 https://api.github.com/rate_limit)
fi

if ! services_json="$(timeout 10 "${services_cmd[@]}")"; then
    echo "failed:enclave-services"
    exit 1
fi
if ! jq -e '
    ([.services[] | select(.name == "proxy" and .status == "up")] | length) == 1
    and ([.services[] | select(.name == "git-service" and .status == "up")] | length) == 1
    and ([.services[] | select(.name == "inference" and .status == "up")] | length) == 1
' >/dev/null <<<"$services_json"; then
    echo "failed:enclave-services"
    exit 1
fi
if ! timeout 10 "${vault_cmd[@]}" >/dev/null; then
    echo "failed:vault-health"
    exit 1
fi
if ! timeout 15 "${outbound_cmd[@]}" >/dev/null; then
    echo "failed:outbound-https"
    exit 1
fi

echo "ok:forge-services"
