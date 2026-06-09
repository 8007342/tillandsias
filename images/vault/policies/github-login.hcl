# @trace spec:tillandsias-vault
# Write-capable policy for the one-shot github-login container.
# Created at --github-login time; scoped AppRole token dropped after write.
path "secret/data/github/token" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/github/token" {
  capabilities = ["read"]
}
