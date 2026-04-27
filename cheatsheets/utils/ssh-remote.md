# SSH and rsync

@trace spec:agent-source-of-truth

**Version baseline**: OpenSSH 8.7, rsync 3.2.7 (Fedora 43)  
**Use when**: Connecting to remote systems, transferring files securely, or synchronizing directories

## Provenance

- https://man.openbsd.org/ssh — OpenSSH manual (canonical reference)
- https://linux.die.net/man/1/rsync — rsync manual
- **Last updated:** 2026-04-27

## Quick reference

| Task | SSH | rsync |
|------|-----|-------|
| Connect | `ssh user@host` | N/A |
| Custom port | `ssh -p 2222 user@host` | `rsync -e 'ssh -p 2222'` |
| Key auth | `ssh -i ~/.ssh/id_rsa user@host` | `rsync -e 'ssh -i ~/.ssh/id_rsa'` |
| Command exec | `ssh user@host 'ls'` | N/A |
| Port forward local | `ssh -L 8080:localhost:80 user@host` | N/A |
| Port forward remote | `ssh -R 8080:localhost:80 user@host` | N/A |
| Copy to remote | N/A | `rsync -a ./local/ user@host:/remote/` |
| Copy from remote | N/A | `rsync -a user@host:/remote/ ./local/` |
| Dry run | N/A | `rsync -n -a ./src user@host:/dst` |
| Exclude | N/A | `rsync -a --exclude='*.log' ./src user@host:/dst` |
| Delete on dest | N/A | `rsync -a --delete ./src user@host:/dst` |

## Common patterns

**SSH key-based setup:**
```bash
ssh-keygen -t ed25519 -C "user@host"
ssh-copy-id -i ~/.ssh/id_ed25519 user@host
ssh user@host  # Passwordless
```

**Synchronize entire project:**
```bash
rsync -a --exclude '.git' --exclude 'target' \
  ./ user@host:/home/user/project/
```

**SSH with verbose and X11:**
```bash
ssh -vv -X user@host
```

**Port forwarding to access remote service locally:**
```bash
ssh -L 5432:db.internal:5432 user@host
# Now `psql localhost:5432` connects to remote db.internal
```

**Batch file copy over SSH:**
```bash
scp -r ./src user@host:/dst/
scp user@host:/src/file ./
```

## Common pitfalls

- **Key permissions**: SSH silently rejects keys with wrong permissions. Always `chmod 600 ~/.ssh/id_*` and `chmod 700 ~/.ssh/`.
- **Host key verification**: First connection prompts. Use `-o StrictHostKeyChecking=accept-new` to auto-accept once.
- **rsync trailing slash**: `/src/` syncs contents; `/src` syncs the directory itself. Easy to lose a level.
- **Port forwarding loop**: `-L` and `-R` forward ports. Use `ssh -N` to keep connection open without executing commands.
- **rsync delete risk**: `--delete` removes files on destination not in source. Always dry-run: `rsync -n --delete ...`.
- **SSH timeout**: Long idle SSH connections drop. Use `ServerAliveInterval=60` in `~/.ssh/config`.
- **rsync through jump host**: `rsync -e 'ssh -J jump-user@jump-host'` to tunnel through intermediate server.

## See also

- `utils/git-workflows.md` — Git over SSH (uses SSH keys internally)
- `runtime/networking.md` — SSH in enclave context (git service SSH daemon)
