# Step 16b: Git Identity Propagation

## Status

completed

## Objective

Close the gap where forge-launched Codex/OpenCode/OpenCode Web sessions could
start without the GitHub Login git identity, causing `git commit` or push
workflows to fail with missing `user.name` / `user.email`.

## Evidence landed

- Direct Rust launch argv now reads the managed GitHub Login gitconfig and
  injects `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and
  `GIT_COMMITTER_EMAIL` when both name and email are present.
- Tray agent argv now exports `TILLANDSIAS_PROJECT=<project>` so entrypoints
  select the intended mounted project directory.
- Shared entrypoint helper `configure_git_identity` writes repo-local
  `user.name` and `user.email` after entering the project directory.
- OpenCode, OpenCode Web, Claude, Codex, and maintenance entrypoints all call
  the helper.
- Specs and cheatsheets now document the identity contract.

## Verification

```bash
cargo test -p tillandsias-headless --bin tillandsias -- --nocapture
bash -n images/default/lib-common.sh images/default/entrypoint-forge-opencode.sh images/default/entrypoint-forge-opencode-web.sh images/default/entrypoint-forge-claude.sh images/default/entrypoint-forge-codex.sh images/default/entrypoint-terminal.sh
bash scripts/validate-spec-cheatsheet-binding-fast.sh
scripts/check-cheatsheet-refs.sh
```

## Residual work

- Full push smoke still requires a live GitHub token and network path.
