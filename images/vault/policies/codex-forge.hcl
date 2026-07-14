# @trace spec:tillandsias-vault
# Read-only policy mounted only into a running Codex forge session.
path "secret/data/codex/oauth" {
  capabilities = ["read"]
}
path "secret/metadata/codex/oauth" {
  capabilities = ["read"]
}
