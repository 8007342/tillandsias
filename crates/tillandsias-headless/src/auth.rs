pub enum ProviderId {
    GitHub,
    Claude,
    Codex,
    Antigravity,
}

impl ProviderId {
    pub fn vault_path(&self) -> &'static str {
        match self {
            ProviderId::GitHub => "github/token",
            ProviderId::Claude => "claude/oauth",
            ProviderId::Codex => "codex/oauth",
            ProviderId::Antigravity => "antigravity/oauth",
        }
    }
    
    pub fn name(&self) -> &'static str {
        match self {
            ProviderId::GitHub => "GitHub",
            ProviderId::Claude => "Claude",
            ProviderId::Codex => "Codex",
            ProviderId::Antigravity => "Antigravity",
        }
    }
    
    pub fn id_str(&self) -> &'static str {
        match self {
            ProviderId::GitHub => "github",
            ProviderId::Claude => "claude",
            ProviderId::Codex => "codex",
            ProviderId::Antigravity => "antigravity",
        }
    }
}

pub enum AuthModel {
    Token,
    OAuthDevice,
}

pub struct ProviderLoginConfig {
    pub provider: ProviderId,
    pub auth_model: AuthModel,
    pub image: &'static str,
    pub script: String,
}
