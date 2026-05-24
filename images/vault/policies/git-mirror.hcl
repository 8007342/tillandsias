# @trace spec:tillandsias-vault
# Read-only on the GitHub OAuth token. Nothing else.
path "secret/data/github/token" {
  capabilities = ["read"]
}
path "secret/metadata/github/token" {
  capabilities = ["read"]
}
