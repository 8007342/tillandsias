# Go (modules + build)

@trace spec:agent-cheatsheets

## Provenance

- Go Modules Reference (golang.org): <https://go.dev/ref/mod> — go mod init/tidy/download/why/vendor, go get, go install with @version, go.sum, GOPROXY, vendor/ behavior, replace directives, go.work (workspace mode)
  local: `cheatsheet-sources/go.dev/ref/mod`
- Go command documentation: <https://pkg.go.dev/cmd/go> — go build flags (-trimpath, -ldflags, -o), go test flags (-race, -count, -timeout), go vet, go fmt, CGO_ENABLED, build tags (//go:build)
- **Last updated:** 2026-04-25

**Version baseline**: Go 1.23+ (Fedora 43 `golang` package).
**Use when**: building / testing / running Go code in the forge.

## Quick reference

| Command | Effect |
|---|---|
| `go mod init <module-path>` | Create `go.mod` (module path is the import root, e.g. `github.com/user/repo`) |
| `go mod tidy` | Add missing + remove unused deps; rewrite `go.sum` |
| `go mod download` | Pre-populate the module cache (`$GOMODCACHE`) without building |
| `go mod why <pkg>` | Explain why a module is in the build graph |
| `go mod vendor` | Materialise deps into `./vendor/` for offline / reproducible builds |
| `go get <pkg>@<ver>` | Add / upgrade a dep at a specific version (`@latest`, `@v1.2.3`) |
| `go get -u ./...` | Upgrade all deps to latest minor/patch |
| `go build` | Compile current package; binary lands in cwd (named after dir) |
| `go build -o bin/foo ./cmd/foo` | Compile a specific subpackage to a chosen path |
| `go install ./cmd/foo` | Build + install to `$GOBIN` (default `~/go/bin`) |
| `go install <pkg>@<ver>` | Install a remote tool (e.g. `golang.org/x/tools/cmd/goimports@latest`) |
| `go run ./cmd/foo` | Build + run without producing a persistent binary |
| `go test ./...` | Run every test under the current module |
| `go test -race -v ./...` | Verbose run with the race detector enabled |
| `go vet ./...` | Static analysis (suspicious constructs); part of `go test` by default |
| `go fmt ./...` / `gofmt -w .` | Canonical formatter — non-negotiable in Go |
| `go work init ./a ./b` | Create a multi-module workspace (`go.work`) |

## Common patterns

### Pattern 1 — Bootstrap a module
```bash
mkdir my-tool && cd my-tool
go mod init github.com/me/my-tool
echo 'package main; import "fmt"; func main() { fmt.Println("hi") }' > main.go
go mod tidy
go run .
```
The module path becomes the import prefix for every package in the repo. Use a real (or future) URL — `go get` resolves it later.

### Pattern 2 — Install a remote CLI
```bash
go install golang.org/x/tools/cmd/goimports@latest
go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.61.0
```
`go install <pkg>@<ver>` is module-aware and works outside any module. The version selector (`@latest`, `@v1.2.3`) is **mandatory** — without it, you'd need to be inside the dep's module dir.

### Pattern 3 — Reproducible build of a subcommand
```bash
go build -trimpath -ldflags="-s -w -X main.version=$(cat VERSION)" \
  -o dist/myapp ./cmd/myapp
```
`-trimpath` strips workspace paths from the binary, `-s -w` drops debug + symbol tables, `-X` injects a string into a `var` at link time (classic version-stamping).

### Pattern 4 — Race-tested unit test loop
```bash
go test -race -count=1 -timeout=30s ./...
```
`-count=1` defeats the test-result cache (Go caches passing test runs by inputs). Use it whenever you need to actually re-execute, e.g. after touching env vars or external state.

### Pattern 5 — Local replace for cross-repo development
```go
// go.mod
module github.com/me/app

require github.com/me/lib v0.0.0

replace github.com/me/lib => ../lib
```
Lets you edit a sibling module without publishing a tag. Drop the `replace` line before tagging a release — published modules with `replace` directives are silently ignored by downstream consumers.

## Common pitfalls

- **GOPATH mode is gone** — Go 1.23 is modules-only by default (`GO111MODULE=on` is the default). Tutorials that say "put code under `$GOPATH/src/...`" are pre-2019 and will mislead you. Always start with `go mod init`.
- **`go install <pkg>` without `@version` fails** — outside a module dir, you must say `@latest` (or pin a tag). The error (`go install: version is required`) is surprisingly opaque if you've used older Go.
- **GOPROXY needs the forge's `HTTPS_PROXY`** — by default Go fetches modules from `proxy.golang.org`. The Go toolchain honours `HTTPS_PROXY`, but if you override `GOPROXY` to a custom mirror, that host must be on the enclave proxy allowlist or the fetch hangs until timeout.
- **`go.sum` mismatches block builds hard** — if `go.sum` has a hash for a version that doesn't match what the proxy serves, you get `checksum mismatch` and the build aborts. Resolve with `go mod tidy` (regenerates) or `go clean -modcache` + retry; never hand-edit `go.sum`.
- **`vendor/` and modules can disagree** — if `./vendor/` exists, `go build` uses it and ignores the module cache. After `go get` you must re-run `go mod vendor` or builds silently use the old vendored copy. Either commit to vendoring fully or delete `vendor/`.
- **`CGO_ENABLED=1` is the default** — Go links against glibc by default, producing a non-portable binary. For static, distroless-friendly binaries set `CGO_ENABLED=0` (and consider `-ldflags="-extldflags=-static"` if any dep insists on cgo).
- **Build tags are positional and picky** — the `//go:build linux` directive must appear before the `package` line, with a blank line after. The legacy `// +build` syntax still works but `gofmt` will add the modern form alongside it; never delete one without the other or constraints stop applying.
- **`go.work` overrides `go.mod` everywhere it reaches** — handy for multi-module dev, but a stray `go.work` in a parent dir silently rewrites your dep graph. CI should `GOWORK=off go build` (or set `GOFLAGS=-mod=mod`) to ensure published modules are used as-is.
- **`go test` caches results by source + env** — passing tests don't re-run on the next invocation. Add `-count=1` to force execution; it's the canonical "no, really, run it" flag (more idiomatic than `go clean -testcache`).
- **`go run` rebuilds every time** — there's no incremental cache for `go run`; for a tight inner loop, `go build -o /tmp/app && /tmp/app` is faster on large modules.

## Forge-specific

- `~/go` (which is both `GOPATH` and `GOMODCACHE`) is ephemeral. First build of new deps in a fresh forge re-downloads through the enclave proxy.
- `GOPROXY` honours `HTTPS_PROXY`, which the forge sets automatically. `proxy.golang.org` and `sum.golang.org` are on the proxy allowlist by default.
- `go install` writes to `~/go/bin/`, which is also ephemeral — installed CLIs vanish on container stop. For repeated use, either re-install per session or bake the tool into the forge image.

## See also

- `test/go-test.md` — `go test` flags, table-driven tests, benchmarks
- `runtime/forge-container.md` — why `~/go/` is ephemeral
- `runtime/networking.md` — proxy + allowlist details for module fetches
