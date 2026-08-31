# @trace spec:tillandsias-vault
# Provider-scoped session policy mounted only into a running claude forge.
# Read restores startup state; create/update persist provider rotation.
path "secret/data/claude/oauth" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/claude/oauth" {
  capabilities = ["read"]
}

# Operator's one-time interactive approvals (trust/bypass/onboarding) — the
# same restore/harvest rail as the OAuth document (2026-08-31 directive:
# approve once on first launch, vault carries it thereafter).
path "secret/data/claude/approvals" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/claude/approvals" {
  capabilities = ["read"]
}
