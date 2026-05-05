---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://www.gnu.org/software/make/manual/make.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# GNU make

@trace spec:agent-cheatsheets

## Provenance

- GNU Make manual (Edition 0.77, version 4.4.1, 2023-02-26): <https://www.gnu.org/software/make/manual/make.html> — .PHONY, -j parallel (§5.4), -n/make -B flags, automatic variables $@/$</$^/$* (§10.5.3), pattern rules (%), := vs = (§3.7), ?= +=, $(shell ...) (§8.14), include (§3.3)
- **Last updated:** 2026-04-25

**Version baseline**: GNU make 4.4 (Fedora 43).
**Use when**: orchestrating build/test/lint commands; ad hoc task runner; legacy C/C++ projects.

## Quick reference

| Syntax / Flag | Effect |
|---|---|
| `target: deps` <br> `<TAB>cmd` | Rule — build `target` from `deps` by running `cmd` (commands MUST start with a hard tab) |
| `make target` | Build a specific target (default: first non-`.`-prefixed rule in the file) |
| `make -j$(nproc)` | Parallel build using N jobs; respects dependency DAG |
| `make -C subdir target` | Recurse into `subdir` before building (preserves cwd outside) |
| `make -n target` | Dry run — print commands without executing |
| `make -B target` | Force rebuild even if mtimes look fresh |
| `make -f Makefile.alt` | Use a non-default makefile name |
| `$@` `$<` `$^` `$*` | Auto vars: target, first dep, all deps, stem (`%`) match |
| `%.o: %.c` | Pattern rule — build any `.o` from matching `.c` |
| `.PHONY: clean test` | Mark targets as not-files (always rebuild, no mtime check) |
| `VAR := value` | Simply-expanded (evaluated once at parse time) |
| `VAR = value` | Recursively-expanded (re-evaluated on every use — rare you want this) |
| `?=` `+=` | Set if unset / append |
| `$(shell cmd)` | Shell out at parse time (use sparingly — runs every invocation) |
| `include other.mk` | Inline another makefile; `-include` to ignore-if-missing |

## Common patterns

### Pattern 1 — Simple `.PHONY` task list

```make
.PHONY: build test lint clean
build:
	cargo build --workspace
test:
	cargo test --workspace
lint:
	cargo clippy --workspace -- -D warnings
clean:
	rm -rf target/
```

Make as a task runner — every target is `.PHONY` so mtime is ignored.

### Pattern 2 — Pattern rule for object files

```make
CFLAGS := -O2 -Wall
SRCS   := $(wildcard src/*.c)
OBJS   := $(SRCS:src/%.c=build/%.o)

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

build:
	mkdir -p $@
```

`$<` is the matched `.c`, `$@` is the `.o`. The `| build` is an order-only prerequisite (mtime ignored, just ensures the dir exists).

### Pattern 3 — Conditionals

```make
ifeq ($(shell uname),Darwin)
  TARGET := aarch64-apple-darwin
else
  TARGET := x86_64-unknown-linux-gnu
endif

ifneq ($(DEBUG),)
  CFLAGS += -g -O0
endif
```

Branch on env vars or shell output. `ifeq`/`ifneq`/`ifdef`/`ifndef` are evaluated at parse time.

### Pattern 4 — Split makefiles via `include`

```make
# Makefile
include build/common.mk
include build/$(PLATFORM).mk

all: $(TARGETS)
```

Keeps platform-specific rules out of the main file. Use `-include` instead for files that may not exist (e.g. auto-generated `.d` dep files from `gcc -MMD`).

### Pattern 5 — Multi-line recipes with `.ONESHELL`

```make
.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

deploy:
	cd dist
	for f in *.tar.gz; do
	  echo "uploading $$f"
	  curl -fsSL --upload-file "$$f" https://example.com/
	done
```

Without `.ONESHELL` each line runs in a separate shell (so `cd` doesn't persist, and loops need backslash continuation). With it, the whole recipe is one shell invocation.

## Common pitfalls

- **TABS, not spaces** — recipe lines MUST begin with a literal tab character. Spaces give the cryptic `*** missing separator. Stop.` error. Configure your editor to show tabs in `Makefile`s; many auto-format tools (Prettier, editorconfig) silently convert them and break the build.
- **`$$` vs `$`** — make consumes `$` for variable expansion. To pass a literal `$` to the shell (e.g. `$PATH`, `$$pid`, `${var}`) you must write `$$`. Forgetting this turns `$PATH` into make's empty `$P` followed by `ATH`.
- **`=` vs `:=`** — recursively-expanded (`=`) re-evaluates the right-hand side every time the variable is used. If RHS contains `$(shell ...)`, that subshell runs on every reference. Use `:=` (simply-expanded) by default; reach for `=` only when you genuinely want late binding.
- **Missing `.PHONY` for non-file targets** — if a file named `clean` ever appears in the directory, `make clean` becomes a no-op ("nothing to do for clean"). Always declare task-style targets in `.PHONY`.
- **`-j` without correct dependencies = race** — parallel make assumes the DAG is complete. Implicit ordering (rule A appears before rule B in the file) is NOT a dependency. Missing `target: dep` edges manifest as flaky builds that pass with `-j1` and fail with `-j8`.
- **Make tracks file mtimes, NOT command-line content** — changing `CFLAGS` does not invalidate object files. Use a stamp file or pass-through to `gcc -MMD` for accurate dep tracking; or just `make -B` after flag changes.
- **Implicit suffix rules surprise** — make ships with built-in rules (`.c.o`, `.l.c`, etc.). A stray `foo.c` next to your `foo` target may trigger an unwanted `cc -o foo foo.c`. Disable with `MAKEFLAGS += --no-builtin-rules` and `.SUFFIXES:` at the top of the file.
- **Recursive `$(MAKE) -C subdir` loses parallelism** — sub-makes do NOT share the `-j` job server unless you write `$(MAKE)` (with the variable, not literal `make`). Even then, recursive make hides the full DAG and prevents optimal scheduling. Prefer non-recursive make or switch to ninja for large trees.
- **`$(shell ...)` at parse time runs on EVERY invocation** — including `make -n`, `make clean`, tab-completion. A slow `$(shell git log ...)` makes the whole makefile feel laggy. Cache into a `:=` variable if it's expensive but only needed for some targets.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://www.gnu.org/software/make/manual/make.html`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.gnu.org/software/make/manual/make.html`
- **License:** see-license-allowlist
- **License URL:** https://www.gnu.org/software/make/manual/make.html

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.gnu.org/software/make/manual/make.html"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://www.gnu.org/software/make/manual/make.html" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/make.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/cmake.md`, `build/ninja.md` — modern alternatives for C/C++
- `languages/bash.md` — recipes are shell snippets
