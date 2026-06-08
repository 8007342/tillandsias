# @trace spec:tillandsias-vault
# Vault server config for the Tillandsias enclave POC.
#
# Phase 3 constraints:
#   - file storage backend (single-node POC, no Raft).
#   - 0.0.0.0:8200 listener with a short-lived leaf certificate signed by
#     the enclave CA. The key and certificate arrive as Podman secrets.
#   - disable_mlock = true because rootless podman cannot mlock.
#   - audit device wired to /vault/audit/audit.json for the
#     observability convergence stream.

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/run/secrets/tillandsias-vault-tls-cert"
  tls_key_file    = "/run/secrets/tillandsias-vault-tls-key"
  tls_client_ca_file = "/run/secrets/tillandsias-vault-tls-ca"
}

api_addr     = "https://vault:8200"
cluster_addr = "https://vault:8201"

ui            = false
disable_mlock = true
log_level     = "info"
