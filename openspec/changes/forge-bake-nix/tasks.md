# Tasks: forge-bake-nix

## 1. Containerfile Nix Installation (Wave 1)

- [x] 1.1 Add nix installation to Containerfile (curl installer, single-user mode)
- [x] 1.2 Create /etc/nix/nix.conf with experimental-features = nix-command flakes
- [x] 1.3 Install direnv to Containerfile
- [x] 1.4 Install nix-direnv to Containerfile
- [x] 1.5 Verify /nix/store mount point exists (dependency on forge-cache-architecture)
- [x] 1.6 Add direnv hooks to bashrc
- [x] 1.7 Add direnv hooks to zshrc

## 2. Shell Configuration and Entrypoint (Wave 1)

- [x] 2.1 Add direnv hooks to config.fish
- [x] 2.2 Set NIX_CONFIG and NIX_PATH env vars in entrypoint or Containerfile
- [x] 2.3 Update TILLANDSIAS_CAPABILITIES to include nix

## 3. Testing and Verification (Wave 1)

- [ ] 3.1 Test: podman run forge nix --version
- [ ] 3.2 Test: podman run forge nix flake --help
- [ ] 3.3 Test: direnv hook verification in bash/zsh/fish

## 4. Documentation and Methodology (Wave 2+)

- [ ] 4.1 Add "Nix-First for New Projects" section to project CLAUDE.md
- [ ] 4.2 Add "Nix-First for New Projects" section to workspace CLAUDE.md
- [ ] 4.3 Update forge-opencode-onboarding with nix-first.md instruction

## 5. Archive and Sync (After Implementation)

- [ ] 5.1 Run /opsx:verify to confirm implementation matches specs
- [ ] 5.2 Run /opsx:archive to archive change and sync delta specs to main
- [ ] 5.3 Bump version: ./scripts/bump-version.sh --bump-changes
