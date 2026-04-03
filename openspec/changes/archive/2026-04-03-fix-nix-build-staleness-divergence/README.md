# fix-nix-build-staleness-divergence

Fix staleness check in build-image.sh to use git ls-files instead of find, preventing divergence between what the staleness check sees (working tree) and what Nix builds (git index). Prevents silent wrong-image builds when files are untracked.
