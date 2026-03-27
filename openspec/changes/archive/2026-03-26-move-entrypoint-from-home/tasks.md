## 1. Move Entrypoint in flake.nix

- [x] 1.1 Create `/usr/local/bin/` directory in `fakeRootCommands` and copy entrypoint there
- [x] 1.2 Update `chmod +x` to target the new path
- [x] 1.3 Update container `Entrypoint` config to `/usr/local/bin/tillandsias-entrypoint.sh`

## 2. Verification

- [x] 2.1 Confirm no other references to `/home/forge/entrypoint.sh` remain in the codebase
- [ ] 2.2 Rebuild forge image and verify entrypoint runs correctly
- [ ] 2.3 Verify `ls ~` inside a running forge container shows no `entrypoint.sh`
