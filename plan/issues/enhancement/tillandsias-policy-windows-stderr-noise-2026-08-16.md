# tillandsias-policy emits `-z...The system cannot find the file specified.` noise on windows

- date: 2026-08-16
- host: windows (Yolanda, Git Bash / MSYS, native PE binary)
- class: enhancement
- discovered_by: windows meta-orchestration cycle 4 while landing 770-ifeg
  (first run of `regenerate-cheatsheet-index --check` through the freshly
  resolved `target/debug/tillandsias-policy.exe`)

## Observation

Running `scripts/regenerate-cheatsheet-index.sh --check` on the windows host
prints repeated lines of the shape:

```
-zThe system cannot find the file specified.
```

interleaved with the real output. The check itself works (it correctly
detected the stale `transport-overhead.md` INDEX entry and the subsequent
regeneration produced a correct one-line diff), so this is noise, not a wrong
verdict — but the noise looks like an error, and error-shaped noise trains
readers to ignore red text (the 672-4nts lesson).

The `-z` prefix suggests the binary shells out to a subprocess with a `-z`
style argument (git plumbing is the likely suspect: `git log -z`/`diff -z`
date lookups for `last_verified` stamps) and the subprocess launch fails on
windows (`os error 2` text), each failure printing one line.

Until now this code path never ran on windows: the naive
`target/debug/tillandsias-policy` existence check exec'd the stale Linux ELF
and died with Exec format error before reaching any of this (~30s lost, the
770-ifeg problem statement). Run-don't-stat resolution made the windows lane
reachable, which surfaced this.

## Smallest next action

Reproduce with `RUST_LOG`/strace-equivalent on windows, find the subprocess
call in `crates/tillandsias-policy` (grep for `-z` argument construction),
and either make the call windows-correct or degrade it silently with the
value it was fetching reported as absent.
