# Research: Agent Login Flows (Claude, Codex, Antigravity)

## 1. Auth Model Decision
**Decision:** Operator sign-off confirmed that we will strictly use **OAuth (Device Code / Interactive Sessions)** for Claude, Codex, and Antigravity. API keys will not be used because they are considered too expensive compared to interactive session tokens.

## 2. Vault OAuth-Token Schema
Because we are using OAuth, we need a schema in Vault to store tokens and handle lifecycle events (like refresh).
The secrets will be stored under `secret/data/<provider>/oauth`.

**Schema structure (`AuthModel::OAuth`):**
```json
{
  "access_token": "string",
  "refresh_token": "string (optional)",
  "expires_at": "number (Unix timestamp)",
  "client_id": "string",
  "scope": "string (optional)"
}
```
*Note: Our vault schema uses `secret/data/...` for KV v2.*

## 3. Containerized Login Boundary & Egress Endpoints
Like `--github-login`, the login flows must run entirely within a container (e.g., `tillandsias-agent-login-*`). The host will NOT see the token directly; the container will interact with the Vault container to inject the final OAuth tokens.

**Required Egress Endpoints (via Squid Proxy):**
1. **Claude (Anthropic)**: 
   - `auth.anthropic.com:443` (for device authorization)
   - `api.anthropic.com:443` (for token exchange)
2. **Codex (OpenAI)**: 
   - `auth0.openai.com:443` (or their specific device code authorization URL)
   - `api.openai.com:443`
3. **Antigravity**: 
   - `auth.antigravity.dev:443` (placeholder for their identity provider)
   - `api.antigravity.dev:443`

*The squid proxy whitelist (`/etc/squid/squid.conf.template`) will need these endpoints added.*

## 4. Shared `run_provider_login` API Shape
We will abstract `run_github_login` into a generic `run_provider_login` function in `crates/tillandsias-headless/src/main.rs` (or a dedicated auth module).

**Rust API Sketch:**

```rust
pub enum ProviderId {
    GitHub,
    Claude,
    Codex,
    Antigravity,
}

impl ProviderId {
    pub fn vault_path(&self) -> &'static str {
        match self {
            ProviderId::GitHub => "github/token", // legacy format
            ProviderId::Claude => "claude/oauth",
            ProviderId::Codex => "codex/oauth",
            ProviderId::Antigravity => "antigravity/oauth",
        }
    }
}

pub enum AuthModel {
    /// E.g. raw personal access token
    Token, 
    /// OAuth Device Code flow
    OAuthDevice,
}

pub struct ProviderLoginConfig {
    pub provider: ProviderId,
    pub auth_model: AuthModel,
    /// Container image to use (e.g., "git" for GitHub, "curl" or custom for others)
    pub image: &'static str,
    /// The script to execute inside the container to perform the login
    pub script: &'static str,
}

pub fn run_provider_login(config: &ProviderLoginConfig, debug: bool) -> Result<(), String> {
    // 1. require_desktop_user_session
    // 2. start vault + proxy
    // 3. mint approle secret lease for the specific provider's vault_path
    // 4. podman run --rm -it ... [script]
    // 5. script orchestrates the OAuth device flow and uses `vault kv put` internally
}
```

This ensures a uniform login architecture where the host remains isolated from the credentials and only the orchestrated container has access to them during the login flow.
