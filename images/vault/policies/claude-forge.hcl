# @trace spec:tillandsias-vault
# Provider-scoped session policy mounted only into a running claude forge.
# Read restores startup state; create/update persist provider rotation.
path "secret/data/claude/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/claude/oauth" {
  capabilities = ["read"]
}
