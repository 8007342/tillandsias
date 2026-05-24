# @trace spec:tillandsias-vault
# Read-only on the CA cert used for the enclave proxy.
# Explicitly NO github or token access — forge containers must remain
# credential-free for everything beyond TLS trust.
path "secret/data/ca/proxy-cert" {
  capabilities = ["read"]
}
path "secret/metadata/ca/proxy-cert" {
  capabilities = ["read"]
}
