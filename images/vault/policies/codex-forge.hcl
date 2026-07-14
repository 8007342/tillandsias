# @trace spec:tillandsias-vault
# Provider-scoped session policy mounted only into a running Codex forge.
# Read restores startup state; create/update persist provider rotation.
path "secret/data/codex/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/codex/oauth" {
  capabilities = ["read"]
}
