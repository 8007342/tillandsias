## 1. Nix Packages

- [x] 1.1 Add fish, zsh to `flake.nix` forge-image contents
- [x] 1.2 Add mc, vim, nano to `flake.nix` forge-image contents
- [x] 1.3 Add eza, bat, fd, fzf, zoxide, htop, tree to `flake.nix` forge-image contents

## 2. Shell Configurations

- [x] 2.1 Create `images/default/shell/bashrc` — colored prompt, aliases (ll, la, ..), eza/bat integration, zoxide init, PATH setup
- [x] 2.2 Create `images/default/shell/config.fish` — PATH setup, aliases, zoxide init
- [x] 2.3 Create `images/default/shell/zshrc` — prompt with path, autocompletion, history, aliases, zoxide init

## 3. Image Integration

- [x] 3.1 In `flake.nix`, add shell config files to the image (copy to `/etc/skel/`)
- [x] 3.2 In `entrypoint.sh`, deploy shell configs from `/etc/skel/` to home directory if not present
- [x] 3.3 Rebuild image: `./scripts/build-image.sh forge --force`
- [x] 3.4 Test: enter bash mode, verify tools are available and configs loaded
