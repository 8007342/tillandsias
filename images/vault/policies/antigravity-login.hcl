# @trace spec:tillandsias-vault
# Write-capable policy for the one-shot antigravity-login container.
# Created at --antigravity-login time; scoped AppRole token dropped after write.
path "secret/data/antigravity/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/antigravity/oauth" {
  capabilities = ["read"]
}
