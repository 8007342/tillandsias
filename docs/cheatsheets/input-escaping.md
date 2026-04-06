# Input Escaping & Command Injection Prevention

@trace spec:podman-orchestration

## The Problem

User inputs (git name, email, project names) are passed as:
1. Podman `-e NAME=VALUE` arguments (environment variables)
2. Shell variables inside entrypoint scripts
3. Git config values

Unescaped inputs can cause:
- **Command injection**: `My Name; rm -rf /` as a git author name
- **Argument injection**: `--my-rogue-param` as a project name
- **Shell expansion**: `$(whoami)` or backticks in values

## Best Practices

### Rust side (handlers.rs, launch.rs)

```rust
// GOOD: Rust's Command API handles quoting automatically
// Each arg is a separate string — no shell interpretation
cmd.arg("-e").arg(format!("GIT_AUTHOR_NAME={}", name));

// BAD: Building a shell command string
let cmd = format!("podman run -e GIT_AUTHOR_NAME={} ...", name); // INJECTION RISK
```

Rust's `std::process::Command` does NOT use a shell — each argument is
passed directly to the kernel via `execvp()`. Shell metacharacters
(`; | & $ \``) have no special meaning. This is safe by default.

**However**: the `-e NAME=VALUE` format means VALUE can contain `=` signs
(which is fine) but also newlines (which some tools misinterpret).

### Shell side (entrypoints)

```bash
# GOOD: Always double-quote variable expansions
git config user.name "${GIT_AUTHOR_NAME}"
cd "${TILLANDSIAS_PROJECT}"
echo "${HTTP_PROXY}"

# BAD: Unquoted variables — word splitting + glob expansion
git config user.name $GIT_AUTHOR_NAME   # breaks on spaces
cd $TILLANDSIAS_PROJECT                  # breaks on spaces, globs
```

### Validation rules

| Input | Regex | Max Length | Reject |
|-------|-------|-----------|--------|
| Git author name | `^[\\p{L}\\p{N} .'-]+$` | 128 chars | Control chars, semicolons, pipes, backticks |
| Git author email | `^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$` | 256 chars | Spaces, control chars |
| Project name | `^[a-zA-Z0-9._-]+$` | 64 chars | Spaces, slashes, control chars |
| Container name | `^[a-zA-Z0-9._-]+$` | 128 chars | Same as project |

### Where validation happens

1. **`gh-auth-login.sh`**: Validates name/email from `read -rp` before writing to gitconfig
2. **`launch.rs`**: Validates project name before constructing container name
3. **`handlers.rs`**: Validates user inputs before passing as env vars

## Checklist

- [ ] All `${VAR}` in shell scripts are double-quoted
- [ ] All user inputs are validated with regex before use
- [ ] No `eval`, backtick, or `$(...)` on user-controlled strings
- [ ] `std::process::Command` used (not shell strings) in Rust
- [ ] Git config values written via `git config` (not direct file append)
- [ ] Container names sanitized (alphanumeric + dash + dot only)
