<!-- @trace spec:secrets-management -->
# secrets-management Specification

## Status

obsolete (removed in v0.3 — see `tillandsias-vault` spec)

The OS-native-keyring-to-podman-secret path described below was the
pre-v0.3 credential model. The `--legacy-keyring-secrets` and `--without-vault`
flags were removed in v0.3. All credential handling is now Vault-native;
see `openspec/specs/tillandsias-vault/spec.md`. This spec is retained as a
historical reference only.

## Purpose

(This spec is obsolete. See `tillandsias-vault` for the current credential
architecture.)
