## ADDED Requirements

### Requirement: Ollama host env var in forge containers
All forge containers SHALL have `OLLAMA_HOST=http://inference:11434` set so that tools and agents can query local LLM models.

@trace spec:inference-container, spec:environment-runtime

#### Scenario: Forge has OLLAMA_HOST
- **WHEN** a forge container is launched
- **THEN** the environment SHALL include `OLLAMA_HOST=http://inference:11434`
