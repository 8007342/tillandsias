# @trace spec:tillandsias-vault
# Write-capable policy for the one-shot claude-login container.
# Created at --claude-login time; scoped AppRole token dropped after write.
path "secret/data/claude/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/claude/oauth" {
  capabilities = ["read"]
}
