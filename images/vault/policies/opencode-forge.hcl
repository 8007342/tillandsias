# @trace spec:tillandsias-vault, spec:default-image
# OpenCode preserves the existing Gemini credential source but receives it as
# an in-memory OPENCODE_AUTH_CONTENT document. The forge may read this one key,
# but cannot create, rotate, enumerate, or read any sibling secret.
path "secret/data/gemini/api-key" {
  capabilities = ["read"]
}
