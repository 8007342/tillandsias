# @trace spec:tillandsias-vault
# Vault server config for the Tillandsias enclave POC.
#
# Phase 3 constraints:
#   - file storage backend (single-node POC, no Raft).
#   - 0.0.0.0:8200 listener with TLS disabled — ONLY safe because the
#     container has no --publish flag and the enclave network ACL keeps
#     traffic intra-enclave. NEVER expose to the host.
#   - disable_mlock = true because rootless podman cannot mlock.
#   - audit device wired to /vault/audit/audit.json for the
#     observability convergence stream.

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

api_addr     = "http://vault:8200"
cluster_addr = "http://vault:8201"

ui            = false
disable_mlock = true
log_level     = "info"
