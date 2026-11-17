# @trace spec:tillandsias-vault, order:2063-nfag
# Write-capable policy for the one-shot copilot-login container
# (`tillandsias --copilot-login`, the operator's device-code sign-in).
# Created at --copilot-login time; scoped AppRole token dropped after write.
path "secret/data/copilot/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/copilot/oauth" {
  capabilities = ["read"]
}
