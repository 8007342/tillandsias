## 1. New crate

- [ ] 1.1 `crates/tillandsias-cheatsheet-mcp/Cargo.toml` — new bin crate. Deps: `serde`, `serde_yaml`, `tokio` (for async stdio), `tracing`. Avoid heavy frameworks; the JSON-RPC layer is tiny enough to hand-roll.
- [ ] 1.2 `src/main.rs` — stdio JSON-RPC loop. Read line-delimited JSON from stdin, dispatch to handlers, write response to stdout.
- [ ] 1.3 `src/index.rs` — walk `cheatsheets/`, parse frontmatter via `serde_yaml`, build in-memory index. Re-index on SIGHUP for dev convenience.
- [ ] 1.4 `src/tools/search.rs`, `tools/get.rs`, `tools/related.rs`, `tools/list.rs`, `tools/stale_check.rs` — one file per tool.
- [ ] 1.5 Tests against fixture cheatsheets in `tests/fixtures/`.

## 2. Shell scripts

- [ ] 2.1 `scripts/regenerate-cheatsheet-index.sh` — bash, walks frontmatter via `awk`/`yq`, regenerates INDEX.md.
- [ ] 2.2 `scripts/check-cheatsheet-refs.sh` — bash + ripgrep. Fails non-zero on broken `@cheatsheet` / `## See also` paths.
- [ ] 2.3 `scripts/check-cheatsheet-provenance-reachability.sh` — bash + curl. Logs failures to a file, exits 0 (don't fail CI on transient URL outages).
- [ ] 2.4 `scripts/check-cheatsheet-staleness.sh` — bash + awk. Default informational; `--strict` flag for non-zero exit.

## 3. Pre-commit hook

- [ ] 3.1 Decide hook framework: bare `.git/hooks/pre-commit` shell script vs `lefthook` vs `pre-commit`. Recommend bare for simplicity.
- [ ] 3.2 Wire scripts/regenerate-cheatsheet-index.sh + scripts/check-cheatsheet-refs.sh as pre-commit. Provenance + staleness run separately on a slower cadence.

## 4. Forge image bake

- [ ] 4.1 `images/default/Containerfile` — copy `tillandsias-cheatsheet-mcp` binary into `/opt/agents/cheatsheet-mcp/bin/`. The host build script needs to build the binary first and stage it into the image build context (similar to how `cheatsheets/` is staged).
- [ ] 4.2 Update `images/default/opencode.json` (or wherever opencode config is baked) to register the MCP server.
- [ ] 4.3 Update `cheatsheets/agents/opencode.md` (DRAFT) to mention the MCP server is available — when retrofitted with provenance, this becomes the canonical reference.

## 5. Host setup

- [ ] 5.1 Document in this change's README how a host user adds the MCP server to `~/.claude/settings.json` for dogfooding. (Out of repo — manual user step.)
- [ ] 5.2 If the host tray exposes a control socket (Implementation D), wire the MCP binary there too.

## 6. Cheatsheet content

- [ ] 6.1 Update `cheatsheets/runtime/cheatsheet-architecture-v2.md` — replace the "MCP query interface (planned)" section with current behaviour.
- [ ] 6.2 Update `cheatsheets/runtime/cheatsheet-shortcomings.md` — strike items 1, 2, 3, 4, 5, 7, 9, 10. Item 6 remains; item 8 deferred.
- [ ] 6.3 Add `cheatsheets/agents/cheatsheet-mcp.md` (with provenance) covering the tool surface — for both forge agents AND host Claude.

## 7. Build + verify

- [ ] 7.1 `cargo build --release -p tillandsias-cheatsheet-mcp` — clean build, single-binary.
- [ ] 7.2 Smoke test: `echo '{"method":"cheatsheet.search","params":{"query":"rxjava"},"id":1}' | tillandsias-cheatsheet-mcp` — returns ranked results.
- [ ] 7.3 `cargo test --workspace` — green.
- [ ] 7.4 `scripts/build-image.sh forge --force` — confirm MCP binary baked into the new forge image.
- [ ] 7.5 Manual: launch tray, attach to a project, exec into the forge, run `which cheatsheet-mcp` AND `cheatsheet.search "rxjava"` via the opencode tool surface.
