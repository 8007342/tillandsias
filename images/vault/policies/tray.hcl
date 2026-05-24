# @trace spec:tillandsias-vault
# Full CRUD on the secret tree; the tray manages secret rotation on the
# user's behalf (--github-login and future credential acquisition flows).
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
