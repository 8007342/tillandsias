# forge-environment-discoverability

## MODIFIED Requirements

### Requirement: local-experts agent is grounded-endpoint only
The `local-experts` OpenCode agent (dev `opencode.json` and the forge
overlay config) SHALL point at the grounded `expert-serve` loopback endpoint
(`tillandsias-experts` provider, baseURL `http://127.0.0.1:11436/v1`) and
SHALL NOT point at a raw model. Its prompt SHALL state the actual contract —
answers are cited envelopes verified against the published spec index, and
refusals are typed `unsupported:` completions — rather than an EXPERIMENTAL
/ ungrounded disclaimer.

#### Scenario: agent model routing
- **WHEN** an OpenCode session activates the `local-experts` agent
- **THEN** its requests go to `tillandsias-experts/<domain>` on the
  loopback grounded endpoint, where the model id selects the domain
  (all|spec|code|methodology|cheatsheet), never directly to `ollama/*`

#### Scenario: honest prompt
- **WHEN** the agent describes its own answers
- **THEN** it states that citations are verified and refusals are typed,
  and directs deterministic single-node questions to the forge-plan MCP
  tools — it no longer describes itself as ungrounded

#### Scenario: endpoint absent
- **WHEN** `expert-serve` is not running on the configured loopback port
- **THEN** the agent's requests fail fast at connect and the instruction
  files direct the agent to the forge-plan MCP experts — a dead endpoint
  never silently reroutes to a raw model

#### Scenario: forge lifecycle is fail-soft
- **WHEN** a forge launches from a checkout whose installed
  `tillandsias-plan` predates the `expert-serve` subcommand
- **THEN** the lifecycle block's capabilities probe skips the launch
  silently (logged to the lane log) and forge launch is never blocked
