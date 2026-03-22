## 1. Fix opencode.json config

- [x] 1.1 Remove `$schema`, `provider`, and `model` fields from `images/default/opencode.json`
- [x] 1.2 Keep only `tools` and `permissions` declarations in the config

## 2. Fix entrypoint.sh fallback behavior

- [x] 2.1 Update `images/default/entrypoint.sh` to attempt launching OpenCode and fall back to bash if it fails
- [x] 2.2 Add a diagnostic message to the welcome banner when falling back to bash
- [x] 2.3 Ensure `exec opencode` is called without arguments that reference broken config

## 3. Update spec

- [x] 3.1 Add graceful fallback requirement to `default-image` spec (scenario: OpenCode fails to start)
- [x] 3.2 Add config-only-tools-and-permissions scenario to `default-image` spec
