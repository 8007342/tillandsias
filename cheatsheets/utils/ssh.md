# ssh

@trace spec:agent-cheatsheets

**Version baseline**: OpenSSH 9.x (Fedora 43 `openssh-clients`).
**Use when**: ssh to other machines from the forge (rare — forge typically credential-free; usually no host keys).

## Provenance

- OpenSSH ssh(1) man page (OpenBSD, canonical upstream): <https://man.openbsd.org/ssh> — complete option reference
- OpenSSH project manual index: <https://www.openssh.com/manual.html> — links to all OpenSSH man pages
- **Last updated:** 2026-04-25

Verified against OpenBSD ssh(1) man page: `-J` ProxyJump (confirmed); `-A` agent forwarding (confirmed); `-L` local port forwarding (confirmed); `-N` no remote command (confirmed); `-D` SOCKS proxy — both SOCKS4 and SOCKS5 (confirmed); `-tt` forces TTY allocation (confirmed). Ed25519 recommendation sourced from ssh-keygen(1) and OpenSSH release notes.

## Quick reference

| Op | Command | Notes |
|----|---------|-------|
| Connect | `ssh user@host` / `ssh -p 2222 user@host` | Default port 22 |
| Identity | `ssh -i ~/.ssh/id_ed25519 user@host` | Override default key |
| Local fwd | `ssh -L 8080:localhost:80 user@host` | Bind local 8080 → host:80 |
| Remote fwd | `ssh -R 9000:localhost:3000 user@host` | Host's 9000 → local 3000 |
| Dynamic fwd | `ssh -D 1080 user@host` | SOCKS5 proxy on local 1080 |
| ProxyJump | `ssh -J bastion user@target` | Hop through bastion |
| Agent fwd | `ssh -A user@host` | Forwards local agent (DANGEROUS) |
| Run command | `ssh user@host "ls -la"` | Non-interactive exec |
| Verbose | `ssh -v` / `-vv` / `-vvv` | Debug auth/connection |
| No TTY | `ssh -T user@host` | Skip pseudo-terminal alloc |
| Force TTY | `ssh -tt user@host` | Allocate TTY in non-interactive |
| Option | `ssh -o StrictHostKeyChecking=no host` | Override config (use sparingly) |
| Keygen | `ssh-keygen -t ed25519 -C "label"` | ed25519 preferred over RSA |
| Add key | `ssh-add ~/.ssh/id_ed25519` | Requires running ssh-agent |
| Copy key | `ssh-copy-id user@host` | Append pubkey to authorized_keys |

## Common patterns

**ProxyJump through a bastion (preferred over `-W`):**
```bash
ssh -J jump.example.com user@internal.example.com
# or persistent in ~/.ssh/config:
#   Host internal
#     HostName internal.example.com
#     ProxyJump jump.example.com
```

**Local port forward (access remote service locally):**
```bash
ssh -N -L 5432:db.internal:5432 user@bastion
# -N: no remote command, pure tunnel. localhost:5432 now hits remote db
```

**Remote port forward (expose local service to remote host):**
```bash
ssh -N -R 8080:localhost:3000 user@public-host
# public-host:8080 now reaches your local :3000 (set GatewayPorts yes server-side)
```

**Agent forwarding (only with trusted hosts):**
```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh -A user@trusted-host          # forwarded agent usable on remote
# Prefer ProxyJump over -A whenever possible.
```

**~/.ssh/config Host blocks:**
```sshconfig
Host work-*
  User alice
  IdentityFile ~/.ssh/id_work
  IdentitiesOnly yes

Host work-db
  HostName db.internal.example.com
  ProxyJump bastion.example.com
  LocalForward 5432 localhost:5432
```

## Common pitfalls

- **No ssh-agent in the forge by default**: `ssh-add` fails with `Could not open a connection to your authentication agent`. Start one in-shell with `eval "$(ssh-agent -s)"` — but the forge has no keys to add anyway.
- **No host keys, StrictHostKeyChecking on**: a fresh forge has empty `~/.ssh/known_hosts`. First connection blocks on `yes/no` prompt; non-interactive scripts hang or fail. Pre-populate with `ssh-keyscan host >> ~/.ssh/known_hosts`, never disable strict checking globally.
- **`-A` agent forwarding is dangerous**: a compromised remote host can use your forwarded agent to reach anywhere your key has access. Use `ProxyJump`/`-J` instead — it never exposes the agent to intermediate hops.
- **Strict permissions on `~/.ssh`**: ssh refuses to use keys readable by group/other. Required: `~/.ssh` = `0700`, private keys = `0600`, `authorized_keys` = `0600`. Symptoms: `Permissions 0644 are too open` or silent fallback to password auth.
- **ControlMaster / ControlPath races**: multiplexing (`ControlMaster auto`, `ControlPath ~/.ssh/cm-%r@%h:%p`) speeds up reconnects but a stale socket from a killed master leaves new sessions hanging. Clear with `ssh -O exit user@host` or `rm ~/.ssh/cm-*`.
- **`IdentitiesOnly` not set**: ssh offers every key in the agent to the server. With many keys, the server hits `MaxAuthTries` and rejects you before reaching the right one. Set `IdentitiesOnly yes` per Host block.
- **TTY assumptions break scripts**: `ssh host "cmd | less"` fails because no TTY is allocated. Use `-tt` to force one, or rewrite the remote command to not need a terminal.

## Forge-specific

- The forge has no SSH keys by default. Push/pull to the project mirror is over `git://`, not ssh.
- No ssh-agent forwarding from host into forge — the host/forge boundary is a hard credential break (see Enclave Architecture in CLAUDE.md).
- ssh egress to github.com is blocked by the proxy allowlist anyway; even with a key, `git push git@github.com:...` would fail.

## See also

- `runtime/networking.md` — why no ssh to github from forge
- `utils/git.md` — git over the enclave mirror, not ssh
