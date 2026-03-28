# Tasks: fix-entrypoint-agent-launch

- [x] Read entrypoint.sh fully and identify all opencode references
- [x] Move OC_BIN definition inside install_opencode() / opencode branch
- [x] Fix doubled opencode/opencode path in tar extraction and binary reference
- [x] Make case statement handle claude and opencode explicitly
- [x] Verify shell configs (bashrc, zshrc, config.fish) don't have stale opencode PATH entries
- [x] Run cargo test --workspace to confirm no regressions
- [x] Mark tasks complete
