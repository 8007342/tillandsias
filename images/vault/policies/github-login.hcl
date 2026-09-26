# @trace spec:tillandsias-vault
# Write-capable policy for the one-shot github-login container.
# Created at --github-login time; scoped AppRole token dropped after write.
path "secret/data/github/token" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/github/token" {
  capabilities = ["read"]
}
# Order 1383-5hpk: the GitHub App REFRESH token lives on its own path so the
# git-mirror policy (secret/data/github/token only) can never read it. The
# login container WRITES it once and never reads it back: the host rotates it
# through the root token, not through this policy.
path "secret/data/github/refresh" {
  capabilities = ["create", "update"]
}
