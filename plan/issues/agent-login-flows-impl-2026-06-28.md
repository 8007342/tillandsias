# Agent Login Flows Implementation

## Objective
Implement `--claude-login`, `--codex-login`, and `--antigravity-login` CLI subcommands using a generalized `run_provider_login(ProviderId)` logic mirroring the existing `run_github_login` flow. Store the captured tokens in Vault under a unified OAuth device-code schema.

## Execution Summary
- Added `ProviderId` and `AuthModel` enums in `crates/tillandsias-headless/src/main.rs`.
- Extracted and replaced `run_github_login` with a parameterized `run_provider_login(config: &ProviderLoginConfig, debug: bool)`.
- Defined `ProviderLoginConfig` which specifies the exact container image, the `token_script`, and the Vault schema path per provider.
- Created `get_generic_login_token_script` to dynamically generate a secure, interactive bash script that prompts the user for a token (hiding characters) and writes it into Vault via `vault-cli.sh`.
- Bound `--claude-login`, `--codex-login`, and `--antigravity-login` CLI arguments to the new flow.
- Re-routed GitHub authentication through the new system while preserving its original token fetching/verifying specifics via conditional logic in `run_provider_login`.
- Reconciled headless unit tests (`github_login_prompts_after_infrastructure_preflight`, `idiomatic_podman_launch_paths_do_not_bypass_shared_layer`) to assert cleanly on the new abstraction.

## Next Steps
- Verify integration between the proxy header injection and these securely-stored Vault tokens during active forge sessions.
