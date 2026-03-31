# OpenCode Installation

## Official Installer

- `curl -fsSL https://opencode.ai/install | bash` — handles install AND update
- Idempotent: exits early if same version already installed
- Default install location: `$HOME/.opencode/bin/opencode`
- Custom dir: `OPENCODE_INSTALL_DIR=/path curl -fsSL https://opencode.ai/install | bash`
- Specific version: `VERSION=0.2.5 curl -fsSL https://opencode.ai/install | bash`

## Alternative Install Methods

- Homebrew: `brew install opencode` or `brew install anomalyco/tap/opencode`
- npm: `npm i -g opencode-ai@latest`
- Nix: `nix run nixpkgs#opencode`

## Platform Support

- linux-x64, linux-arm64
- darwin-x64 (Intel), darwin-arm64 (Apple Silicon)
- Handles musl/Alpine, Rosetta, AVX2 baselines

## Container Integration (Tillandsias)

- Installed to `$CACHE/opencode/` via `OPENCODE_INSTALL_DIR` env var
- Binary persists in cache mount across container restarts
- Update throttled daily via stamp file (`needs_update_check`)
- Entrypoint: `entrypoint-forge-opencode.sh`

## Config

- `opencode.json` in project root or `~/.config/opencode/`
- `opencode --version` to check installed version

## Known Pitfalls

- Manual tar extraction is fragile — archive structure changes between releases
- Always use the official installer, not direct GitHub release downloads
- The installer modifies shell config (.bashrc/.zshrc) to add PATH — in containers, set PATH explicitly instead
