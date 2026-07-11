# litmus-stdlib Authoring Guide

`scripts/litmus-stdlib.sh` provides portable building-block functions for
litmus `command:` fields. Use them to avoid the recurring class of
cross-host breakage caused by hand-derived backslash-escape arithmetic in
GNU-vs-BSD `grep -E`, bash-3.2-vs-4+ builtins, and YAML double-quote
escaping layers.

## Available Functions

| Function | Purpose |
|---|---|
| `mf_literal FILE PATTERN` | Exit 0 if PATTERN found in FILE (literal match) |
| `mf_literal_count FILE PATTERN` | Print count of lines containing PATTERN |
| `mf_regex FILE PATTERN` | Exit 0 if PATTERN found (extended regex, portable) |
| `mf_regex_count FILE PATTERN` | Print count of lines matching PATTERN |
| `mf_absent FILE PATTERN` | Exit 0 if PATTERN NOT found |
| `mf_threshold FILE PATTERN MIN` | Exit 0 if count >= MIN |
| `mf_threshold_std COUNT MIN` | Exit 0 if pre-computed COUNT >= MIN |
| `mf_file_exists FILE` | Exit 0 if FILE is a regular file |
| `mf_assert_count ACTUAL EXPECTED` | Exit 0 if ACTUAL == EXPECTED |

## When to Use

- **Always** for grep-based checks (literal or regex).
- **Always** for file existence checks.
- **Use raw `command:`** for bespoke `awk` one-liners, `sed` transformations,
  `find` operations, or `for` loops where the body uses `mf_*` functions.

## Basic Examples

**Literal existence check** (replaces `grep -qF`):
```yaml
command: "mf_literal Containerfile tillandsias-forge && echo ok || echo FAIL"
```

**Regex match with portable escaping** (replaces hand-escaped `grep -cE`):
```yaml
command: "count=$(mf_regex_count file.log '\"Foo|Bar\"\\|'); mf_threshold_std $count 2"
```

**Count + threshold** (replaces `grep -cF | awk`):
```yaml
command: "mf_threshold state.rs '@trace spec:app-lifecycle' 10 && echo ok || echo FAIL"
```

**Assert absence** (replaces `! grep -qF`):
```yaml
command: "mf_absent run-forge-standalone.sh ':latest' && echo 'ok: no :latest'"
```

**N-of-M files loop** (loop structure stays raw, grep call uses stdlib):
```yaml
command: "for s in opencode claude codex; do mf_literal Containerfile \"entrypoint-forge-$s.sh\" || exit 1; done && echo ok"
```

## Writing Patterns for `mf_regex` / `mf_regex_count`

Write standard POSIX ERE (Extended Regular Expression) syntax:

| Metachar | Meaning | Example |
|---|---|---|
| `|` | Alternation | `(Foo|Bar)` |
| `()` | Grouping | `(abc)+` |
| `[]` | Character class | `[0-9]` |
| `\` | Escape in ERE | `\.` for literal dot |

The stdlib handles GNU/BSD `grep -E` dialect differences internally.
You do NOT need `\|`, `\(`, `\[` workarounds.

## Testing

Before committing, run your new litmus on the host:

```bash
./scripts/run-litmus-test.sh your-litmus-name --phase pre-build --size instant
```

Also verify on a sibling host (or CI) to confirm portability.

## Adding a New Primitive

If a pattern appears 5+ times across the litmus corpus, add it to
`scripts/litmus-stdlib.sh`. Pattern:
1. Mine the actual usage (not speculative).
2. Add a function with `mf_` prefix.
3. Handle per-OS dialect branching inside the function.
4. Update this guide.
5. Update the drift-protection litmus count if needed.

## See Also

- `scripts/litmus-stdlib.sh` — source
- `openspec/litmus-tests/litmus-litmus-stdlib-portability-shape.yaml` — drift protection
