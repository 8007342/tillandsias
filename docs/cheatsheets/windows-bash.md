# Git Bash (MSYS2) on Windows

How Git Bash works on Windows, how it translates paths, and the pitfalls when calling `bash.exe` from a native Windows process like a Rust binary.

@trace spec:cross-platform, spec:embedded-scripts

## Architecture

Git for Windows ships a stripped-down [MSYS2](https://www.msys2.org/) environment. MSYS2 is a fork of Cygwin that provides a POSIX compatibility layer on top of Windows. It includes:

- A modified `msys-2.0.dll` runtime (Cygwin fork) that translates POSIX syscalls to Windows API calls.
- A set of GNU tools (`bash`, `coreutils`, `grep`, `sed`, etc.) compiled against that runtime.
- MinGW toolchains that produce native Windows binaries (no POSIX layer needed at runtime).

**Key distinction:** MSYS binaries (linked to `msys-2.0.dll`) run inside the POSIX emulation layer. MinGW/native binaries run directly on Windows. Path translation happens at the boundary between these two worlds.

### Git for Windows Layout

```
C:\Program Files\Git\
  bin\
    bash.exe          # Wrapper — sets up environment, calls usr\bin\bash.exe
    git.exe           # Wrapper
  usr\bin\
    bash.exe          # Actual MSYS2 bash (linked to msys-2.0.dll)
    env.exe           # MSYS2 env
    coreutils.exe     # ls, cat, etc.
  mingw64\bin\
    git.exe           # Native MinGW git (no POSIX layer)
  etc\
    profile            # Login profile sourced by bash -l
```

### `bin\bash.exe` vs `usr\bin\bash.exe`

| | `Git\bin\bash.exe` | `Git\usr\bin\bash.exe` |
|---|---|---|
| Type | Wrapper / launcher | Actual MSYS2 bash binary |
| Behavior | Sets `MSYSTEM`, adjusts `PATH`, then execs `usr\bin\bash.exe` | The real shell |
| PATH setup | Prepends `/mingw64/bin:/usr/bin` | Inherits whatever PATH it receives |
| Use from terminal emulators | Recommended (full environment) | Direct invocation, lighter weight |
| Use from `Command::new()` | Either works, but `bin\bash.exe` provides fuller env | May need manual PATH/MSYSTEM setup |

**Recommendation for Tillandsias:** Use `bin\bash.exe` (found via PATH as just `bash`) because it sets up the MinGW environment automatically.

## Path Translation

### How It Works

MSYS2 maintains a virtual filesystem rooted at the Git install directory:

| Virtual path | Resolves to |
|---|---|
| `/` | `C:\Program Files\Git\` (install root) |
| `/usr/bin/bash` | `C:\Program Files\Git\usr\bin\bash.exe` |
| `/c/Users/alice` | `C:\Users\alice` |
| `/d/Projects` | `D:\Projects` |
| `/tmp` | `C:\Users\alice\AppData\Local\Temp` (or `$TEMP`) |
| `/home/alice` | `C:\Users\alice` (configurable) |

Drive letters are mapped as `/<lowercase-letter>/`, so `C:\` becomes `/c/`, `D:\` becomes `/d/`, etc.

### When Translation Happens

**Automatic conversion occurs when an MSYS2 process calls a native Windows executable.** The MSYS2 runtime intercepts the argument list and converts anything that looks like a Unix path to a Windows path.

```bash
# Inside Git Bash: calling native python.exe
python /c/Users/alice/script.py
# MSYS2 runtime converts to: python C:/Users/alice/script.py
```

**Translation does NOT happen:**
- Between two MSYS2 processes (both understand the virtual FS).
- When a native Windows process passes arguments to `bash.exe`. The native caller sends raw Windows paths; bash receives them as-is.

### The Critical Pitfall for Tillandsias

When Rust calls `Command::new("bash").arg("C:/Users/.../script.sh")`:

1. Rust's `Command` is a native Windows process.
2. It passes `C:/Users/.../script.sh` as a literal string argument to `bash.exe`.
3. Bash receives `C:/Users/.../script.sh` and interprets it as a Unix path.
4. In bash's virtual filesystem, `C:` is not a valid directory prefix.
5. Bash looks for the file relative to the virtual root, fails, and reports **"No such file or directory"**.

**The fix:** Convert Windows paths to MSYS2 virtual paths before passing them to bash:

```
C:\Users\alice\Temp\script.sh  -->  /c/Users/alice/Temp/script.sh
C:/Users/alice/Temp/script.sh  -->  /c/Users/alice/Temp/script.sh
```

This is what `embedded::bash_path()` does in the Tillandsias codebase, but it only converts backslashes to forward slashes (`C:/...`), which is NOT sufficient. The path must also be converted from `C:/...` to `/c/...` format for bash to find the file.

### Path Conversion Rules Summary

| Scenario | Conversion? | Direction |
|---|---|---|
| MSYS2 process calls native `.exe` | Yes, automatic | Unix -> Windows |
| MSYS2 process calls MSYS2 process | No | Both use virtual FS |
| Native `.exe` calls `bash.exe` | No | Caller must convert manually |
| `bash -c "command"` from native | No | Paths in the string are literal |

## Environment Variables

### `MSYS_NO_PATHCONV`

Disables automatic POSIX-to-Windows path conversion for arguments when MSYS2 calls native executables.

```bash
# Without: /foo gets converted to C:\Program Files\Git\foo
echo /foo | native-tool.exe

# With: /foo is passed literally
MSYS_NO_PATHCONV=1 native-tool.exe /foo
```

**Gotcha:** The value does not matter. Setting `MSYS_NO_PATHCONV=0`, `MSYS_NO_PATHCONV=false`, or even `MSYS_NO_PATHCONV=` all disable conversion. Only whether the variable *exists* matters.

### `MSYS2_ARG_CONV_EXCL`

Fine-grained control over which arguments are excluded from conversion.

```bash
# Exclude all arguments
MSYS2_ARG_CONV_EXCL="*" native-tool.exe /foo /bar

# Exclude specific prefixes (semicolon-separated)
MSYS2_ARG_CONV_EXCL="--path=;/test" native-tool.exe --path=/usr/local /test/foo
```

### `MSYSTEM`

Controls which MSYS2 environment is active. Affects `PATH` ordering and which toolchain is preferred.

| Value | Environment | PATH prefix | C runtime |
|---|---|---|---|
| `MSYS` | Core POSIX layer | `/usr/bin` | Cygwin/MSYS |
| `MINGW64` | MinGW 64-bit | `/mingw64/bin:/usr/bin` | msvcrt |
| `UCRT64` | UCRT 64-bit | `/ucrt64/bin:/usr/bin` | ucrt (modern) |
| `CLANG64` | Clang 64-bit | `/clang64/bin:/usr/bin` | ucrt |

Git for Windows defaults to `MINGW64`. The `bin\bash.exe` wrapper sets this automatically.

## Shebang Handling

### How `#!/usr/bin/env bash` Works

On Linux, the kernel reads the shebang and launches the specified interpreter. On Windows, there is no kernel shebang support. Instead:

- **Inside Git Bash:** Bash itself parses the shebang when you run `./script.sh`. It finds `/usr/bin/env` in the MSYS2 virtual filesystem, which then finds `bash` in `PATH`.
- **From native Windows:** Windows cannot execute `.sh` files directly. You must explicitly invoke `bash script.sh`. The shebang is irrelevant because bash is already the interpreter.

### CRLF in Shebangs

If a script has Windows-style line endings (CRLF), the shebang becomes `#!/usr/bin/env bash\r`. Bash interprets the `\r` as part of the interpreter name and fails with:

```
/usr/bin/env: 'bash\r': No such file or directory
```

**Prevention in Tillandsias:** The `embedded::write_lf()` function strips `\r` from all embedded scripts before writing them to disk. The `.gitattributes` file should also enforce LF for `.sh` files:

```gitattributes
*.sh text eol=lf
```

## CRLF vs LF

| Scenario | Risk | Mitigation |
|---|---|---|
| `git clone` with `core.autocrlf=true` | Scripts get CRLF, break with `\r` errors | `.gitattributes: *.sh text eol=lf` |
| Script written by Windows editor | CRLF silently added | Configure editor for LF on `.sh` files |
| Script passed to Linux container | Container bash chokes on `\r` | `write_lf()` strips `\r` at extraction time |
| `git diff` shows no changes but script fails | Invisible `\r` at end of lines | `cat -A script.sh` to reveal `^M` characters |

### `core.autocrlf` Settings

| Value | On checkout | On commit |
|---|---|---|
| `true` | LF -> CRLF | CRLF -> LF |
| `input` | No change | CRLF -> LF |
| `false` | No change | No change |

**Recommended for Tillandsias:** `core.autocrlf=input` or use `.gitattributes` (which overrides `autocrlf` per-file).

## Calling Bash from Native Windows Apps (Rust)

### How `Command::new("bash")` Resolves

Rust's `std::process::Command` on Windows uses the Win32 `CreateProcessW` API, which searches:

1. The directory of the calling executable
2. The system directory (`C:\Windows\System32`)
3. The Windows directory (`C:\Windows`)
4. The `PATH` environment variable

If Git Bash is installed and `C:\Program Files\Git\bin` (or `cmd`) is in PATH, `bash` resolves to Git Bash. If WSL is installed, `C:\Windows\System32\bash.exe` may shadow Git Bash (WSL's legacy `bash.exe`).

**Gotcha with `.env()`:** There is a known Rust issue where `Command::new("bash")` may resolve differently depending on whether `.env()` is called. Without any `.env()` call, the system PATH is used directly. With `.env()`, the command inherits modified environment which can change PATH resolution. See [rust-lang/rust#122660](https://github.com/rust-lang/rust/issues/122660).

### Common Pitfalls

| Problem | Cause | Fix |
|---|---|---|
| "No such file or directory" | Windows path `C:/foo/script.sh` passed to bash | Convert to `/c/foo/script.sh` (MSYS2 virtual path) |
| Wrong bash found | WSL `bash.exe` in System32 shadows Git Bash | Use full path or ensure Git\bin is before System32 in PATH |
| Script fails silently | CRLF line endings | Use `write_lf()` or `.gitattributes` |
| Console window flashes | Subprocess creates visible console | Use `CREATE_NO_WINDOW` flag on Windows |
| `\` in paths interpreted as escape | Backslash is escape char in bash | Convert `\` to `/` before passing to bash |
| Environment not set up | Using `usr\bin\bash.exe` directly | Use `bin\bash.exe` or set MSYSTEM manually |

### Correct Pattern for Tillandsias

```rust
// Convert Windows path to MSYS2 virtual path for Git Bash
fn msys_path(path: &std::path::Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    // Convert "C:/..." to "/c/..."
    if s.len() >= 2 && s.as_bytes()[1] == b':' {
        let drive = s.as_bytes()[0].to_ascii_lowercase() as char;
        format!("/{drive}{}", &s[2..])
    } else {
        s
    }
}

// Usage:
let mut cmd = Command::new("bash");
cmd.arg(msys_path(&script_path));
#[cfg(windows)]
{
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
}
```

## Debugging Path Issues

```bash
# Inside Git Bash — check which bash is running
which bash           # /usr/bin/bash (MSYS2 virtual path)
echo "$MSYSTEM"      # MINGW64

# Check what a Windows path looks like inside bash
echo "Windows sees: $(cygpath -w /c/Users)"    # C:\Users
echo "Unix sees: $(cygpath -u 'C:\Users')"     # /c/Users

# Check for CRLF
file script.sh                 # "ASCII text, with CRLF line terminators"
cat -A script.sh | head -1     # #!/usr/bin/env bash^M  (^M = \r)

# Convert line endings
dos2unix script.sh             # or: sed -i 's/\r$//' script.sh

# Test if MSYS path conversion is active
echo "$MSYS_NO_PATHCONV"      # empty = conversion active
```

## Sources

- [MSYS2 Filesystem Paths](https://www.msys2.org/docs/filesystem-paths/) -- official path conversion documentation
- [MSYS2 Environments](https://www.msys2.org/docs/environments/) -- MSYSTEM and environment differences
- [Git Bash / MSYS2 Setup on Windows](https://www.pascallandau.com/blog/setting-up-git-bash-mingw-msys2-on-windows/) -- detailed architecture walkthrough
- [Docker and Git Bash path workaround](https://gist.github.com/borekb/cb1536a3685ca6fc0ad9a028e6a959e3) -- MSYS_NO_PATHCONV examples
- [bin\bash.exe vs usr\bin\bash.exe](https://superuser.com/questions/1819677/) -- wrapper vs actual binary
- [Rust Command on Windows](https://doc.rust-lang.org/std/process/struct.Command.html) -- PATH resolution behavior
- [Rust Command PATH issue #122660](https://github.com/rust-lang/rust/issues/122660) -- env variable side effects on PATH
- [CVE-2026-24739](https://symfony.com/blog/cve-2026-24739-incorrect-argument-escaping-under-msys2-git-bash-on-windows-can-lead-to-destructive-file-operations) -- MSYS2 argument escaping security issue
