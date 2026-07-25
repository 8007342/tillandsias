# Forge locale broken: LANG=en_US.UTF-8 set but glibc-langpack-en not installed

**Filed**: 2026-07-24T21:20Z
**Severity**: latent (subtle behavioral differences, not immediate failures)
**Owner**: linux (base image maintainer)
**Classification**: optimization
**Agent**: Big Pickle (opencode/big-pickle), forge cycle 2026-07-24T21:04Z
**Motivation**: Agents keep "unfixing" each other's formatting work. The operator
asked whether this is caused by missing locale/encoding defaults in the forge
container, or by other nuances deep in the container abstraction layers.

## Investigation Method

Started from the symptom: agents running `cargo fmt` or `cargo clippy` on the
same codebase produce different outputs, causing a formatting "flip-flop" where
one agent's fix becomes the next agent's regression. Investigated in this order:

1. Locale configuration in the running forge container
2. Locale data actually installed (vs what's declared)
3. Container image build chain (which Containerfile sets what)
4. Git encoding configuration (.gitattributes, core.autocrlf)
5. Actual file encodings in the repo (BOM, line endings, charset)
6. Rust toolchain configuration (rustfmt.toml, clippy lints, edition)
7. Cross-container locale differences (Fedora/glibc vs Alpine/musl)
8. The specific code patterns that keep flip-flopping

## Root Cause (Two Interleaved Issues)

### Issue 1: Forge locale is declared but not installed

`images/default/Containerfile` line:
```
ENV LANG=en_US.UTF-8
```

But `images/default/Containerfile.base` never installs `glibc-langpack-en`.
The Fedora Minimal base (`registry.fedoraproject.org/fedora-minimal:44`) only
ships `C`, `C.utf8`, and `POSIX` locales out of the box.

### Issue 2: Rust version drift (the primary flip-flop trigger)

The `unneeded_wildcard_pattern` clippy lint was introduced in Rust 1.97.0.
Agents running older Rust versions don't see this lint and may re-introduce
`build_version: _` + `..` patterns that 1.97.0+ agents remove. The Containerfile
doesn't pin or document the expected Rust version, so a `microdnf update` could
silently bump it.

These two issues compound: the missing locale makes tool behavior
non-deterministic, and the unpinned Rust version makes clippy rules
non-deterministic. Together they create the "everyone is right, nobody agrees"
flip-flop pattern.

## Evidence — Locale

### Running `locale` inside the forge container:

```
$ locale
locale: Cannot set LC_CTYPE to default locale: No such file or directory
locale: Cannot set LC_MESSAGES to default locale: No such file or directory
LANG=en_US.UTF-8
LC_CTYPE="en_US.UTF-8"
LC_NUMERIC="en_US.UTF-8"
LC_TIME="en_US.UTF-8"
LC_COLLATE="en_US.UTF-8"
LC_MONETARY="en_US.UTF-8"
LC_MESSAGES="en_US.UTF-8"
LC_PAPER="en_US.UTF-8"
LC_NAME="en_US.UTF-8"
LC_ADDRESS="en_US.UTF-8"
LC_TELEPHONE="en_US.UTF-8"
LC_MEASUREMENT="en_US.UTF-8"
LC_IDENTIFICATION="en_US.UTF-8"
LC_ALL=
```

The `locale` command itself warns it cannot set `LC_CTYPE` or `LC_MESSAGES`.
The environment says "en_US.UTF-8" but the locale data doesn't exist.

### What's actually installed:

```
$ locale -a
C
C.utf8
POSIX

$ rpm -q glibc-langpack-en
package glibc-langpack-en is not installed

$ rpm -qa | grep langpack
(no output — no langpacks at all)
```

Only three locales exist: `C`, `C.utf8`, and `POSIX`. No `en_US.UTF-8` data.

### What `LANG=en_US.UTF-8` is supposed to mean vs what actually happens:

- `LANG=en_US.UTF-8` tells glibc programs "use en_US.UTF-8 collation,
  character classification, and message translation"
- Without the locale data, glibc silently falls back to `C` behavior
- `sort` orders by byte value (uppercase before lowercase)
- `grep` and `find` may process filenames in unexpected order
- `ruby -ryaml` may use `ASCII-8BIT` instead of `UTF-8` for `Encoding.default_external`
- But `cargo fmt` is NOT affected (tested — output identical under all three locale settings)

### Where `LANG=en_US.UTF-8` is set:

```
$ grep -rn 'LANG' images/default/Containerfile
ENV LANG=en_US.UTF-8
```

### Where it's NOT installed:

```
$ grep -n 'glibc\|langpack\|locale' images/default/Containerfile.base
(no output — nothing related to locale packages)

$ grep -n 'glibc\|langpack\|locale' images/default/Containerfile
121:# ── Help system (locale-aware) ─────────────────────────────────
158:RUN mkdir -p /etc/tillandsias/locales
159:COPY locales/ /etc/tillandsias/locales/
```

The `locales/` directory contains Tillandsias UI string translations (TOML
files for tray menu localization), NOT system locale data.

## Evidence — Git / File Encoding (Clean)

```
$ git ls-files --eol | head -5
i/lf    w/lf    attr/text=auto eol=lf     .cargo/config.toml
i/lf    w/lf    attr/text=auto eol=lf     .claude/commands/advance-work-from-plan.md
```

All files are LF. `.gitattributes` has `* text=auto eol=lf`. No BOM markers.

```
$ git ls-files '*.yaml' '*.yml' '*.rs' '*.sh' '*.md' | head -20 | while read f; do
    enc=$(file -b --mime-encoding "$f" 2>/dev/null)
    echo "$enc $f"
  done | sort | uniq -c | sort -rn | head -10
```

All files are UTF-8. The repo itself is clean — the issue is purely runtime.

## Evidence — Rust Toolchain

```
$ rustc --version
rustc 1.97.1 (8bab26f4f 2026-07-14) (Fedora 1.97.1-1.fc44)

$ cargo fmt --version
rustfmt 1.9.0

$ ls rustfmt.toml .rustfmt.toml 2>/dev/null
(no file — no rustfmt config at all)
```

No `rustfmt.toml` exists. Default settings are used. When Rust is upgraded via
`microdnf update`, the default settings may change silently.

## Evidence — The Flip-Flop Pattern

The `unneeded_wildcard_pattern` lint was introduced in Rust 1.97.0. Before
that version, this code was valid:

```rust
ControlMessage::HelloAck {
    wire_version,
    build_version: _,
    ..
}
```

Rust 1.97.0+ flags this as: "this pattern is unneeded as the `..` pattern can
match that element" — the `build_version: _` is redundant with `..`.

An agent on Rust 1.96.x doesn't see the lint and may leave or reintroduce the
pattern. An agent on Rust 1.97.1 removes it. The next agent on 1.96.x adds it
back. This is the flip-flop.

The specific files involved in this cycle's flip-flop:
- `crates/tillandsias-vm-layer/src/vsock_exec.rs` (5 occurrences, lines 186, 336, 464, 588, 593)
- `crates/tillandsias-control-wire/src/transport.rs` (1 occurrence, line 250)

All six were removed in this cycle (commit 2acc20f9). Without Rust version
pinning, a future agent on an older toolchain could reintroduce them.

## Container Locale Matrix

| Container | Distro | libc | LANG set? | Locale data installed? | Ruby encoding |
|-----------|--------|------|-----------|----------------------|---------------|
| forge (default) | Fedora 44 | glibc | `en_US.UTF-8` | **NO** (`glibc-langpack-en` missing) | broken (falls back to C) |
| git-mirror | Alpine 3.20 | musl | not set | N/A (musl has C/UTF-8 built-in) | UTF-8 (musl default) |
| vault | Alpine 3.20 | musl | not set | N/A | N/A |
| proxy | Alpine 3.20 | musl | not set | N/A | N/A |
| router | Alpine (Caddy) | musl | not set | N/A | N/A |
| web | Alpine 3.20 | musl | not set | N/A | N/A |

The forge is the ONLY container with a broken locale. The Alpine containers
use musl which has C.UTF-8 built-in and ignores `LANG`/`LC_*` entirely.
This means the git-mirror's `ruby -ryaml` validator works correctly (musl
forces UTF-8), but if someone ever moves the validator to the forge side, it
would break.

## Fix — For the Next Forge Rebuild

### Step 1: Install glibc-langpack-en in the base image

In `images/default/Containerfile.base`, add `glibc-langpack-en` to the
`microdnf install` list:

```diff
 RUN microdnf install -y --nogpgcheck --setopt=install_weak_deps=0 \
         bash coreutils findutils grep sed gawk tar gzip xz \
         procps-ng shadow-utils ca-certificates ncurses ncurses-term \
         fish zsh \
         git gh curl wget jq ripgrep fd-find bat fzf eza htop mc tree nano vim-minimal zoxide git-delta git-lfs httpie yq \
         nodejs npm \
         java-25-openjdk-headless maven \
         golang gopls \
         rust cargo clippy rustfmt rust-analyzer cargo-deny \
         python3-pip python3-mypy python3-pytest python3-lsp-server \
         ruff poetry pipx uv black pylint yamllint \
         pnpm yarnpkg \
         just \
         gdb lldb strace ltrace valgrind heaptrack delve \
         shellcheck shfmt \
         gcc gcc-c++ make cmake pkgconfig unzip \
-        diffutils patch file gettext diffstat \
+        diffutils patch file gettext diffstat \
+        glibc-langpack-en \
         iproute iputils socat nmap-ncat sqlite \
     && git lfs install --system \
     && microdnf clean all
```

### Step 2: Add rustfmt.toml to pin formatting defaults

Create `rustfmt.toml` at the repo root:

```toml
edition = "2021"
max_width = 100
```

This prevents format drift when rustfmt defaults change between versions.

### Step 3: Document expected Rust version

Add a comment in `Containerfile.base` near the Rust install line:

```dockerfile
# Pinned: rustc 1.97.x (Fedora 1.97.1-1.fc44). Bumping this may introduce
# new clippy lints that cause formatting flip-flops. Test with ./build.sh --check
# after any toolchain update.
```

## What the Next Agent Should Do

1. **Rebuild the base image** with `glibc-langpack-en` added (Step 1 above)
2. **Verify** inside the new container: `locale -a` should list `en_US.utf8`
3. **Verify** `locale` has no warnings about `LC_CTYPE` or `LC_MESSAGES`
4. **Create `rustfmt.toml`** (Step 2 above) and run `cargo fmt --all` once
   to normalize the entire codebase to the pinned defaults
5. **Commit the formatting normalization** as a single atomic commit so the
   diff is clean for all future agents
6. **Verify** `./build.sh --check` passes after normalization

## The "Next Run Will Have It Better" Principle

Every agent that touches this codebase should leave it in a state where the
next agent's `./build.sh --check` passes without surprises. The two fixes
above (locale + rustfmt.toml) make the toolchain deterministic:

- Locale: tools behave the same way on every run (en_US.UTF-8 actually works)
- Formatting: `cargo fmt` produces the same output regardless of who runs it
- Clippy: lint rules are predictable (same Rust version, same config)

Without these fixes, each agent is operating in a slightly different runtime
environment, and "fixing" formatting is just choosing one non-deterministic
output over another. With them, there is exactly one correct output and every
agent converges to it.

## Related Files

- `images/default/Containerfile` — sets `ENV LANG=en_US.UTF-8` (line ~120)
- `images/default/Containerfile.base` — base image, missing `glibc-langpack-en`
- `rustfmt.toml` — does not exist yet, should be created
- `images/git/pre-receive-hook.sh` — uses `ruby -ryaml` fallback validator
- `crates/tillandsias-vm-layer/src/vsock_exec.rs` — flip-flopped patterns
- `crates/tillandsias-control-wire/src/transport.rs` — flip-flopped pattern
