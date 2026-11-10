---
tags: [forge-tooling, tooling-language, lua, rust, go, python-multiprocessing, memory]
languages: [lua, rust, go, python]
since: 2026-11-09
last_verified: 2026-11-09
sources:
  - https://www.lua.org/manual/5.4/
  - https://doc.rust-lang.org/cargo/
  - https://go.dev/doc/
  - https://docs.python.org/3/library/multiprocessing.html
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
---
# Tooling language in a forge: Lua > Rust > Go

@trace spec:default-image, order:2067-faum

**Version baseline**: the forge image's Fedora packages (`lua` 5.4 with `lfs` and `lpeg`, `rust`/`cargo`, `golang`, from `images/default/Containerfile.base`)  
**Use when**: choosing the language for a script, helper or tool you write inside a forge

## Provenance

- Lua 5.4 Reference Manual: <https://www.lua.org/manual/5.4/>. The standard library is small and the interpreter is a single process.
- The Cargo Book: <https://doc.rust-lang.org/cargo/>. `cargo` builds and runs Rust tools.
- Go documentation: <https://go.dev/doc/>. `go run` and `go build`; goroutines are multiplexed onto threads in one process.
- Python `multiprocessing`: <https://docs.python.org/3/library/multiprocessing.html>. The `spawn` and `forkserver` start methods launch a fresh Python interpreter process for each worker.
- **Derived (project rule, not upstream):** the order itself is an operator ruling of 2026-11-09 (order 2067-faum). It is recorded here and in `images/default/config-overlay/mcp/forge-agent-guidance.md`.
- **Last updated:** 2026-11-09

## The rule

1. **Lua** for scripts, glue, text edits and small checks (`lua`, `lua-edit`, `lua-conflict`).
2. **Rust** when it needs speed, types or concurrency (`cargo`, `rustc`).
3. **Go** when a Go library or tool fits better (`go`).
4. **Python only when a library forces it.** Python, Perl and the other languages stay installed, so existing projects keep working.

All of `lua`, `cargo`, `rustc` and `go` are always on the forge PATH. The forge image build refuses to finish without them, and `scripts/lua/check-forge-languages.lua` (litmus `forge-languages`) pins that.

## Why

A forge runs every process inside one fixed memory budget. A pool of Python `multiprocessing` workers with the `spawn` or `forkserver` start method puts a separate interpreter in each worker. On 2026-11-09 one forge stalled on exactly this kind of memory thrash. Lua stays small, and Rust and Go get parallelism from threads in a single process.
