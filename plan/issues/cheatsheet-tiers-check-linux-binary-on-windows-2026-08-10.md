# check-cheatsheet-tiers.sh execs a Linux-format tillandsias-policy on Windows hosts (672-4nts)

- Date: 2026-08-10
- Class: `enhancement/` — noisy non-blocking ERROR on every Windows gate run
- Host: windows "Yolanda"

## Symptom

Every `./build.sh --check` on the Windows host prints:

```
⚠ cheatsheet-tiers: validation ERRORs (non-blocking):
  .../scripts/check-cheatsheet-tiers.sh: line 69:
  .../target/debug/tillandsias-policy: cannot execute binary file: Exec format error
```

## Cause

The check resolves `target/debug/tillandsias-policy` from the **in-tree**
target directory. On Windows, builds run inside the `tillandsias-build` WSL2
distro with a distro-native `CARGO_TARGET_DIR` (with-wsl2-builder.sh), so the
in-tree `target/` only holds STALE Linux ELF artifacts from before that
redirect — and the outer Git-Bash gate phases (which run host-side) try to
exec an ELF binary on Windows. It fails as designed (non-blocking), but the
check silently provides zero coverage on Windows AND prints an ERROR banner
that trains agents to ignore red text — both bad.

Same class as the freshness rule: a probe that can never succeed on a host
should say `skip:<reason>`, not error.

## Suggested resolution

In `check-cheatsheet-tiers.sh` (and any sibling that execs a target/ binary
from host-side gate phases):

1. Before exec, verify the binary is runnable on this host (`"$BIN" --version
   >/dev/null 2>&1`); on failure emit exactly one advisory line
   `skip:policy-binary-not-host-executable` instead of the raw bash exec error.
2. Optionally, on Windows, route the check through the WSL2 builder
   (`scripts/with-wsl2-builder.sh <check>`) so it regains real coverage
   rather than skipping — decide by cost; the skip alone removes the noise.

## Verifiable closure

A Windows `./build.sh --check` run prints either a real cheatsheet-tiers
verdict or a single `skip:` line; the string "Exec format error" no longer
appears in gate output.
