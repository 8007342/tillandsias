# @trace spec:tillandsias-vault
# Provider-scoped session policy mounted only into a running antigravity forge.
# Read restores startup state; create/update persist provider rotation.
path "secret/data/antigravity/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/antigravity/oauth" {
  capabilities = ["read"]
}
