# @trace spec:tillandsias-vault
# Write-capable policy for the one-shot codex-login container.
# Created at --codex-login time; scoped AppRole token dropped after write.
path "secret/data/codex/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/codex/oauth" {
  capabilities = ["read"]
}
