## 1. flake.nix — Ensure home dir files are user-writable

- [ ] 1.1 After `chown -R 1000:1000 ./home/forge`, add `chmod -R u+rw ./home/forge`
- [ ] 1.2 After copying skel files, add `chmod -R a+r ./etc/skel` so shell configs are
        readable when deployed at runtime

## 2. entrypoint.sh — Set umask

- [ ] 2.1 Add `umask 0022` immediately after `set -euo pipefail` (line 2 of the script)
        so all spawned processes (OpenCode, npm, openspec, bash) inherit a permissive umask

## 3. Shell configs — Set umask

- [ ] 3.1 Add `umask 0022` to `images/default/shell/bashrc` (interactive bash sessions)
- [ ] 3.2 Add `umask 0022` to `images/default/shell/zshrc` (interactive zsh sessions)
- [ ] 3.3 Add `umask 022` to `images/default/shell/config.fish` (fish sessions — fish syntax)

## 4. Verification

- [ ] 4.1 `./build.sh --check` passes (cargo check)
- [ ] 4.2 `./scripts/build-image.sh forge --force` succeeds (image rebuild with fixes)
- [ ] 4.3 Launch a container, run `touch test-file && ls -la test-file` — permissions
        should be `-rw-r--r--` (0644), not `-r--r--r--` (0444)
- [ ] 4.4 Create a file via npm/openspec inside the container, verify it is writable
        from the host without `chmod`
