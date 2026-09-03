#!/usr/bin/env bash
# @trace order:975-rsgm, spec:proxy-container
#
# check-enclave-ca-consistency.sh — is the enclave CA bundle present, and does
# the proxy's private key still match the certificate it will be served?
#
# THE FAILURE THIS NAMES, measured on yoga 2026-09-03 over five cycles in which
# cycle-preflight reported only `fail:enclave-service-start-failed:...:action=operator`:
#
#   1. /tmp is cleared, so /tmp/tillandsias-ca vanishes. The proxy binds
#      `/tmp/tillandsias-ca/intermediate.crt` and podman recorded that SOURCE at
#      creation, so `podman start` can never succeed again on its own:
#        crun: cannot stat `/tmp/tillandsias-ca/intermediate.crt`
#   2. The documented remedy — re-run the enclave orchestration — DOES
#      re-materialize the bundle, with a NEW keypair.
#   3. But the proxy does not read its key from that bind. Only the CERT is
#      bound; the KEY arrives as the podman secret `tillandsias-ca-key`, which
#      `ensure_proxy_ca_key_secret` refreshes with `--replace` ON THE LAUNCH
#      PATH ONLY. A proxy started any other way — `podman start`, which is what
#      the health check's own self-heal and its printed remedy both do — keeps
#      the OLD key.
#   4. So the proxy then starts and dies DIFFERENTLY:
#        WARNING: '/etc/squid/certs/intermediate.key' X509_check_private_key() failed
#        FATAL: No valid signing certificate configured for HTTP_port [::]:3128
#
# THE REMEDY CHANGES THE FAILURE'S SIGNATURE WITHOUT FIXING IT, and that is the
# expensive property. Before: a stat error naming a path, obviously
# environmental. After: a TLS keypair mismatch inside squid, which reads like a
# certificate bug in the proxy and points investigation at the wrong subsystem
# entirely. An operator who ran the documented remedy and then read the logs was
# further from the answer than before they started.
#
# So this reports the CONDITION rather than leaving the next reader to infer it
# from squid's last words.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:enclave-ca-consistent|absent:enclave-ca-bundle|desync:enclave-ca-key-secret|skip:[a-z0-9-]+)$
set -uo pipefail

CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"
SECRET="tillandsias-ca-key"

command -v podman >/dev/null 2>&1 || { echo "skip:no-podman"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "skip:no-openssl"; exit 0; }

# Nothing to be consistent WITH if the enclave was never provisioned here.
podman secret inspect "$SECRET" >/dev/null 2>&1 || { echo "skip:no-enclave-ca-secret"; exit 0; }

if [ ! -r "$CA_DIR/intermediate.crt" ]; then
    echo "absent:enclave-ca-bundle"
    {
        echo "  $CA_DIR/intermediate.crt is missing, and the proxy binds it by that"
        echo "  path — podman recorded the bind SOURCE at container creation, so"
        echo "  \`podman start tillandsias-proxy\` cannot succeed until it exists."
        echo "  /tmp is volatile by design: a reboot or a systemd-tmpfiles sweep"
        echo "  removes it, and that is not a fault of the proxy (975-rsgm)."
        echo "  REMEDY: re-run the enclave orchestration (\`tillandsias --init\`) —"
        echo "  and see the desync warning below, because regenerating the bundle"
        echo "  alone leaves the proxy's key secret stale."
    } >&2
    exit 1
fi

# The proxy is served the CERT from the bind and the KEY from the secret. If
# they were generated at different times they will not match, and squid dies
# with a message about certificates that names neither of them.
cert_mod="$(openssl x509 -noout -modulus -in "$CA_DIR/intermediate.crt" 2>/dev/null | openssl md5 2>/dev/null)"
secret_mod=""
if _tmp="$(mktemp)" && podman secret inspect --showsecret --format '{{.SecretData}}' "$SECRET" >"$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
    secret_mod="$(openssl rsa -noout -modulus -in "$_tmp" 2>/dev/null | openssl md5 2>/dev/null)"
fi
rm -f "${_tmp:-}" 2>/dev/null || true

# A podman build that cannot reveal secret data is a real limitation, not a
# desync — say so rather than reporting a mismatch we did not observe.
[ -n "$secret_mod" ] || { echo "skip:secret-data-unreadable"; exit 0; }
[ -n "$cert_mod" ] || { echo "skip:cert-unreadable"; exit 0; }

if [ "$cert_mod" != "$secret_mod" ]; then
    echo "desync:enclave-ca-key-secret"
    {
        echo "  The proxy's certificate and its private key do not match."
        echo "    cert   $CA_DIR/intermediate.crt (bind mount)"
        echo "    key    podman secret '$SECRET'"
        echo "  squid will start and then die with X509_check_private_key() failed"
        echo "  and 'No valid signing certificate configured' — a message that names"
        echo "  neither of the two files, which is why this reads as a proxy bug."
        echo "  CAUSE: the CA was regenerated without rotating the secret."
        echo "  ensure_proxy_ca_key_secret refreshes it with --replace on the LAUNCH"
        echo "  path only, so a proxy brought up with \`podman start\` — which the"
        echo "  health check's self-heal and its printed remedy both do — keeps the"
        echo "  old key (975-rsgm)."
        echo "  REMEDY: bring the proxy up through the orchestration rather than"
        echo "  \`podman start\`, so the secret is refreshed from the current bundle."
    } >&2
    exit 1
fi

echo "ok:enclave-ca-consistent"
