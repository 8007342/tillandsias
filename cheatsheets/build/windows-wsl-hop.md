---
tags: [windows, wsl, msys2, git-bash, shell-expansion, stdin, cross-platform]
languages: [bash]
since: 2026-09-28
last_verified: 2026-09-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://www.msys2.org/docs/filesystem-paths/
  - https://www.msys2.org/wiki/Porting/
authority: medium
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
---
# Windows → WSL hop: sending shell to a guest without losing it

@trace spec:cheatsheet-tooling, order:1215-8jui, order:1155-jurn

**Version baseline**: Windows 11, WSL 2.7.x, Git Bash (MSYS2 runtime) calling `wsl.exe`
**Use when**: you run shell in a WSL guest (`tillandsias`, `tillandsias-build`) from Git Bash or PowerShell and a value comes back empty, zero, or wrong.

The upstream docs above cover `wsl.exe`'s flags and MSYS2's argument
conversion. Everything below the symptom table is **derived** from
measurements on the Tillandsias Windows hosts (yolanda, esmeraldinha,
2026-09-15..27); the plan rows named inline carry the evidence.

## Find it by symptom

| You saw | It is | Fix |
|---|---|---|
| `${#VAR}` reads `0`, a file "is empty", a count is `0` | `$` expansions in the `wsl.exe` ARGUMENT STRING are mangled in transit | Pipe the script on stdin (recipe below) |
| Variables set in a heredoc written inside `bash -c '...'` arrive blank | same | same |
| `echo $?` after a failing command prints `0`; `rc=$?` leaves `rc` empty | `?` mangled in the argument string (1155-jurn) | `$?` inside a script piped on stdin, or `scripts/lib-wsl-exec.sh` |
| A loop prints `: ` / `:` instead of names | same `$` mangling | stdin |
| A fragment of your text RAN as a command (a pattern word like `shutdown` executed) | the quoting of the argument string broke across the hop and a `\|` split it into pipeline stages | stdin; never pass a pattern containing `\|` in the argument string |
| `/mnt/c/...`: No such file or directory | `/mnt/c` is not mounted in the `tillandsias` runtime distro (it IS in `tillandsias-build`) | stdin, which needs no shared path |
| An absolute Windows path arrives as `/Device/Null`, or `C:/...` is treated as relative | MSYS path conversion on arguments to a native `.exe` | `MSYS_NO_PATHCONV=1`, or pass argv as JSON (`tillandsias-plan run --argv-json -`) |

## The recipe: pipe the script on stdin

```bash
cat <<'EOS' | MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias -u root -- bash -s
TOK="$(cat /run/some/token)"
echo "token_len=${#TOK}"
for b in git gh; do printf '%s: %s\n' "$b" "$(command -v "$b" || echo ABSENT)"; done
false; echo "rc=$?"
EOS
```

- `<<'EOS'` (quoted delimiter) keeps the LOCAL shell from expanding anything;
  the text reaches the guest byte for byte on stdin.
- `bash -s` reads the script from stdin, so nothing but `bash -s` is in the
  argument string, and there is nothing for the transport to rewrite.
- `MSYS_NO_PATHCONV=1` stops Git Bash rewriting the arguments that remain.

## Quoting does not help, and why

The corruption happens in transit, BEFORE any shell sees the text: Git Bash
(MSYS) converts the arguments it passes to a native program, and `wsl.exe`
re-joins them into a command line for the guest. Single quotes, double quotes
and backslash escapes are all part of the text being rewritten, so no quoting
arrangement survives reliably, and `MSYS_NO_PATHCONV=1` alone does NOT fix the
`$` case (measured, 1155-jurn). Moving the script OFF the argument string is
the only fix that removes the thing being mangled.

A read-only query is not exempt. On 2026-09-27 a journal query passed in the
argument string lost its quoting, and the word `shutdown` inside a grep
pattern executed as root in the guest, scheduling a poweroff. A mangled
argument is not only a wrong answer: any fragment that happens to be a real
command runs.

## Exit status across the hop

`$?` evaluated INSIDE the guest (in a script on stdin, or a sourced file) is
correct; only a `$?` written in the argument string is zeroed.
`scripts/lib-wsl-exec.sh` (1155-jurn) is the positive control: it sends a
known failing command through the hop and refuses to trust a measurement when
the known answer does not come back.

## Why not base64

Encoding the script as base64 in the argument string also avoids the mangling,
but `methodology.yaml` → `runtime_language_policy.base64_script_injection_ban`
forbids embedding scripts in base64 literals unconditionally (it was used to
smuggle a banned language past policy). The stdin recipe needs no encoding at
all, so there is no reason to reach for base64 and the ban needs no exception.

## Common pitfalls

- Testing the recipe with a script that contains no `$`: it will "work" either
  way. Include `${#VAR}` and `$?` in the first probe.
- A capped `| head` inside the guest is a page, not an enumeration: count
  before concluding something is absent.
- `wslpath` is mangled by the same conversion when called from Git Bash; do
  path translation inside the guest script instead.
