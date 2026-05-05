## ADDED Requirements

### Requirement: Allowlist covers OpenCode's default egress footprint

The domain allowlist (`/etc/squid/allowlist.txt`, sourced from `images/proxy/allowlist.txt`) SHALL include every external domain that OpenCode Web reaches in its default configuration. At minimum the allowlist MUST contain `.models.dev` (OpenCode model registry), `.openrouter.ai` (OpenRouter aggregation gateway), and `.helicone.ai` (Helicone telemetry / gateway), in addition to the provider domains already listed (`.anthropic.com`, `.openai.com`, `.together.ai`, `.groq.com`, `.deepseek.com`, `.mistral.ai`, `.fireworks.ai`, `.cerebras.ai`, `.sambanova.ai`, `.huggingface.co`). New providers added to OpenCode MUST have their domains added to the allowlist in the same commit that introduces the provider.

#### Scenario: models.dev is allowed
- **WHEN** a forge container issues `CONNECT models.dev:443` via the proxy
- **THEN** Squid matches `.models.dev` in the allowlist
- **AND** responds with `TCP_TUNNEL/200` (not `TCP_DENIED`)

#### Scenario: OpenRouter is allowed
- **WHEN** a forge container issues `CONNECT openrouter.ai:443` or
  `CONNECT api.openrouter.ai:443`
- **THEN** Squid matches `.openrouter.ai` in the allowlist
- **AND** the CONNECT tunnel is established

### Requirement: Allowlist entries follow Squid 6.x single-entry rule

Every allowlist entry SHALL be listed exactly once and SHALL use the
leading-dot form (`.example.com`). Bare-domain duplicates of an already-listed
subdomain pattern are prohibited because Squid 6.x treats duplicate dstdomain
entries as a fatal startup error.

#### Scenario: Proxy starts with no duplicate dstdomain errors
- **WHEN** the proxy container boots
- **THEN** Squid parses `allowlist.txt` without emitting
  `FATAL: duplicate key "..."` for any entry
- **AND** the proxy listens on port 3128 ready to serve the enclave

#### Scenario: Adding a new provider appends one line
- **WHEN** an engineer adds a new provider to OpenCode's default config
- **THEN** they add one `.provider.example` line to `allowlist.txt`
- **AND** do NOT add a bare `provider.example` alongside
- **AND** the change is reviewed against the existing list to avoid subdomain
  duplicates of already-covered domains
