# go test

@trace spec:agent-cheatsheets

**Version baseline**: Go 1.23+ test runner (Fedora 43 `golang` package).
**Use when**: testing Go — unit tests, subtests, benchmarks, fuzz, race detection, coverage.

## Provenance

- Go `testing` package documentation (pkg.go.dev): <https://pkg.go.dev/testing> — `t.Helper()`, `t.Cleanup()`, `t.Run()`, `t.Parallel()`, `b.N`, `b.ResetTimer()`, `f.Fuzz()` all documented
- Go `go test` command reference: <https://pkg.go.dev/cmd/go#hdr-Test_packages> — `-count`, `-race`, `-bench`, `-cover`, `-fuzz`, `-timeout` flags
- **Last updated:** 2026-04-25

Verified against pkg.go.dev: `t.Helper()` marks caller location for failures (confirmed); `t.Cleanup()` runs LIFO after test (confirmed); `t.Run()` creates subtests (confirmed); `t.Parallel()` signals parallel execution (confirmed). `go test ./...` recursive pattern, `-count=1` defeating cache, `-race` race detector all documented in the `cmd/go` reference.

## Quick reference

| Command / Pattern | Effect |
|---|---|
| `go test ./...` | Run every test in the module (passing tests are cached) |
| `go test -count=1 ./...` | Force re-run, defeating the test cache |
| `go test -run '^TestFoo$' ./pkg` | Run a single test by regex (anchor with `^…$` to avoid prefix matches) |
| `go test -run 'TestFoo/sub_one' ./pkg` | Run one subtest of a `t.Run` table |
| `go test -v ./...` | Verbose: print every test name + `t.Log` output (also for passes) |
| `go test -race ./...` | Enable the race detector (≈10× slower, ≈5× more memory) |
| `go test -timeout=30s ./...` | Per-package timeout (default 10m); panics with stack on hit |
| `go test -bench=. ./...` | Run benchmarks matching regex `.` (tests skipped unless `-run` set) |
| `go test -bench=. -benchmem -benchtime=2s` | Include alloc stats; run each bench for ≥2s instead of ≥1s |
| `go test -cover ./...` | Print line coverage % per package |
| `go test -coverprofile=c.out ./...` | Write profile; render with `go tool cover -html=c.out` |
| `go test -covermode=atomic ./...` | Required when combining `-cover` with `-race` |
| `go test -fuzz=FuzzFoo -fuzztime=30s ./pkg` | Run a fuzz target for 30 s (Go 1.18+, one target at a time) |
| `t.Run("name", func(t *T) {…})` | Define a subtest (table-driven testing primitive) |
| `t.Helper()` | Mark fn as helper so failures point to the caller |
| `t.Cleanup(func(){…})` | Register teardown; runs LIFO after the test (and parent subtests) |
| `t.Parallel()` | Mark test parallel; first call must precede any assertion |

## Common patterns

### Pattern 1 — Table-driven test with `t.Run` subtests
```go
func TestAdd(t *testing.T) {
    cases := []struct{ name string; a, b, want int }{
        {"zero", 0, 0, 0},
        {"pos",  2, 3, 5},
        {"neg", -1, 1, 0},
    }
    for _, tc := range cases {
        tc := tc // capture; required pre-Go 1.22
        t.Run(tc.name, func(t *testing.T) {
            t.Parallel()
            if got := Add(tc.a, tc.b); got != tc.want {
                t.Errorf("Add(%d,%d) = %d; want %d", tc.a, tc.b, got, tc.want)
            }
        })
    }
}
```
Subtest names show up as `TestAdd/zero` in `-v` output and `-run` filters. Go 1.22+ scopes loop vars per iteration, so `tc := tc` is no longer required there.

### Pattern 2 — Shared helper with `t.Helper()`
```go
func assertJSON(t *testing.T, got, want string) {
    t.Helper()
    if got != want {
        t.Errorf("json mismatch:\n got: %s\nwant: %s", got, want)
    }
}
```
Without `t.Helper()`, failures point inside the helper. With it, the report points to the caller — the line that actually matters.

### Pattern 3 — Benchmark with `b.N` + `b.ResetTimer`
```go
func BenchmarkParse(b *testing.B) {
    data := loadFixture(b) // expensive setup
    b.ResetTimer()         // exclude setup from timing
    b.ReportAllocs()
    for i := 0; i < b.N; i++ {
        if _, err := Parse(data); err != nil {
            b.Fatal(err)
        }
    }
}
```
The runner adapts `b.N` until each benchmark runs ≥`-benchtime` (default 1s). Reset the timer after setup, and use `b.Fatal` not `b.Error` to stop the loop on errors.

### Pattern 4 — Fuzz test (Go 1.18+)
```go
func FuzzReverse(f *testing.F) {
    f.Add("hello")            // seed corpus
    f.Add("")
    f.Fuzz(func(t *testing.T, s string) {
        got := Reverse(Reverse(s))
        if got != s {
            t.Errorf("Reverse(Reverse(%q)) = %q", s, got)
        }
    })
}
```
Run with `go test -fuzz=FuzzReverse -fuzztime=30s`. Failing inputs are saved under `testdata/fuzz/FuzzReverse/<hash>` and replayed on every subsequent `go test` run.

### Pattern 5 — `TestMain` for package-wide setup/teardown
```go
func TestMain(m *testing.M) {
    db, err := startTestDB()
    if err != nil { log.Fatal(err) }
    code := m.Run()
    db.Stop()
    os.Exit(code)
}
```
Exactly one `TestMain` per package. Always call `m.Run()` and propagate its exit code — otherwise no test in the package executes. Avoid `defer` here: `os.Exit` skips deferred funcs.

## Common pitfalls

- **Filename must end `_test.go`, not `test.go`** — `foo_test.go` is recognised; `footest.go` is compiled into the regular package and `*testing.T` references won't link. The `testing` import is only available in files with the `_test.go` suffix.
- **`package foo` vs `package foo_test`** — same-package tests (`package foo`) see unexported symbols; external tests (`package foo_test` in the same dir) only see the public API. External tests catch accidental import cycles and force you to dogfood the public surface — pick deliberately.
- **`t.Parallel()` ordering matters** — it must be the first call in the test (before any assertion or subtest setup). Calling it later silently does nothing. In a `t.Run` table, putting `t.Parallel()` inside the inner func runs subtests in parallel; putting it in the outer test parallels the parent against its siblings.
- **`-run` is a regex, not a glob** — `go test -run TestFoo.bar` matches `TestFoo*bar*` because `.` is "any char". Anchor with `^…$` and escape literal dots: `-run '^TestFoo\.bar$'`. Subtest paths use `/` as separator: `-run '^TestFoo$/^sub one$'`.
- **`t.Cleanup` runs LIFO and panics propagate** — cleanups added later run first. A panic in one cleanup still runs the rest, but is reported as a test failure. Don't rely on cleanup order for correctness when failures are possible — make each cleanup independent.
- **Forgetting `t.Helper()` in assertion helpers** — failure messages point inside the helper, hiding which call site failed. Add `t.Helper()` to the first line of every shared assertion func; it's cheap and the alternative is grepping through dozens of identical-looking error lines.
- **Test cache hides flakes** — `go test` caches passing results keyed by source + env vars. A test that touches the network/clock and "passes" once won't re-run on the next `go test`. Use `-count=1` in CI and during debugging; never commit a `t.Skip` to "fix" a flake before understanding it.
- **`-race` requires CGO** — the race detector is implemented in C; with `CGO_ENABLED=0` (common for static builds), `go test -race` silently does nothing useful. Set `CGO_ENABLED=1` for the race-test pass even if production builds are CGO-free.
- **Benchmarks measure too little by default** — at `-benchtime=1s` a fast op runs millions of iterations but noise dominates. Use `-benchtime=5s -count=10` and compare with `benchstat` (from `golang.org/x/perf/cmd/benchstat`) to get meaningful deltas.
- **Fuzz corpus lives under `testdata/fuzz/`** — that directory must be committed for failing inputs to replay across machines/CI. Adding it to `.gitignore` (because it looks generated) silently disables regression coverage for fuzz finds.

## Forge-specific

- The race detector and fuzzer both work in the forge — no special flags needed.
- Test binaries land in `$TMPDIR` (ephemeral) and are removed automatically; nothing to clean up between sessions.
- `go test` uses the standard `HTTPS_PROXY`/`GOPROXY` chain for any deps it needs to fetch — same allowlist as `go build`.

## See also

- `build/go.md` — module setup, `go build`, `go install`, GOPROXY behaviour
- `languages/bash.md` — invoking `go test` from CI / pre-commit scripts
- `runtime/networking.md` — proxy + allowlist for fetching test deps
