# @trace spec:tillandsias-vault, order:2063-nfag
# Provider-scoped session policy mounted only into a running copilot forge.
# Read restores the copilot sign-in state (an opaque archive of COPILOT_HOME's
# credential files) into tmpfs; create/update persist a rotation. No other lane
# holds this policy, so no other lane can read the copilot token.
path "secret/data/copilot/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/copilot/oauth" {
  capabilities = ["read"]
}
