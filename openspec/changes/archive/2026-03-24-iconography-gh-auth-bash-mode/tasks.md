## 1. Attach Here Lifecycle Emoji

- [x] 1.1 In `menu.rs`, cross-reference scanned projects against running containers to determine emoji prefix (🌱 idle, 🌺 running)
- [x] 1.2 Prefix each "Attach Here" label with the appropriate emoji
- [x] 1.3 Verify menu rebuilds correctly when a container starts/stops (emoji transitions)

## 2. GitHub Auth Script

- [x] 2.1 Create `gh-auth-login.sh` with `--help` and `--status` flags
- [x] 2.2 Implement interactive `podman run -it --rm` with forge image, mounting secrets dirs, prompting for git identity, running `gh auth login`
- [x] 2.3 Add forge image check — offer to build if missing
- [x] 2.4 Add re-auth prompt when credentials already exist
- [x] 2.5 Delete `images/default/skills/command/gh-auth-login.md`
- [x] 2.6 Update `handlers.rs` `handle_github_login()` to call `open_terminal("gh-auth-login.sh")` instead of inline script
- [x] 2.7 Install `gh-auth-login.sh` alongside the binary in `build.sh --install`
- [x] 2.8 Test: run `./gh-auth-login.sh` and complete the full auth flow

## 3. CLI --bash Mode

- [x] 3.1 Add `--bash` flag to `cli.rs` `CliMode::Attach`
- [x] 3.2 In `runner.rs`, add `--entrypoint /bin/bash` to podman command when `bash` flag is set
- [x] 3.3 Update `--help` output to include `--bash` description
- [x] 3.4 Test: `tillandsias ../lakanoa/ --bash` drops into a bash shell inside the container
