## 1. Template + INDEX update

- [ ] 1.1 Update `cheatsheets/TEMPLATE.md` to include the mandatory `## Provenance` section with placeholders (URL examples + `**Last updated:** YYYY-MM-DD`).
- [ ] 1.2 Update `cheatsheets/INDEX.md` to mark every DRAFT cheatsheet with a `[DRAFT]` prefix on its line so the index is honest at a glance.

## 2. New foundational cheatsheets (with provenance from day one — exemplars)

- [ ] 2.1 Write `cheatsheets/runtime/cheatsheet-methodology.md` — meta-cheatsheet documenting the methodology itself. Cite this OpenSpec change ID + the project + workspace `CLAUDE.md` paths. Becomes the canonical reference for "how to write a cheatsheet" in this project.

## 3. Retrofit existing cheatsheets — agents (3 files, smallest batch first)

Retrofit agents SHALL use `WebFetch` against the cited URLs and confirm the content actually matches what's in the cheatsheet. If `WebFetch` is unavailable or the URL fails to resolve, the agent SHALL note the gap as a `RUNTIME_LIMITATIONS` report rather than fabricating provenance.

- [ ] 3.1 `cheatsheets/agents/openspec.md` — provenance: `github.com/Fission-AI/OpenSpec/` (canonical repo), `npmjs.com/package/@fission-ai/openspec`. Verify content.
- [ ] 3.2 `cheatsheets/agents/claude-code.md` — provenance: `docs.claude.com/en/docs/claude-code/` (Anthropic docs), `github.com/anthropics/claude-code` (canonical repo). Verify.
- [ ] 3.3 `cheatsheets/agents/opencode.md` — provenance: `opencode.ai` (canonical), `github.com/sst/opencode` (repo). Verify.

## 4. Retrofit runtime cheatsheets (3 files)

- [ ] 4.1 `cheatsheets/runtime/forge-container.md` — provenance: `docs.fedoraproject.org/en-US/fedora/latest/release-notes/`, `docs.podman.io/en/latest/markdown/podman-run.1.html`. Verify.
- [ ] 4.2 `cheatsheets/runtime/networking.md` — provenance: Squid docs (`wiki.squid-cache.org`), Caddy docs (`caddyserver.com/docs/`), git protocol (`git-scm.com/docs/git-protocol`). Verify.
- [ ] 4.3 `cheatsheets/runtime/runtime-limitations.md` — provenance: this OpenSpec change ID itself + project `CLAUDE.md`. Tillandsias-internal — no external authority needed; cite the spec.

## 5. Retrofit utilities (12 files — Wave A)

Each agent retrofits 1 cheatsheet. Spawn in parallel waves of 4 to cap concurrent token usage.

- [ ] 5.1 `cheatsheets/utils/git.md` — `git-scm.com/docs/`
- [ ] 5.2 `cheatsheets/utils/gh.md` — `cli.github.com/manual/`
- [ ] 5.3 `cheatsheets/utils/jq.md` — `jqlang.github.io/jq/manual/`
- [ ] 5.4 `cheatsheets/utils/yq.md` — `mikefarah.gitbook.io/yq/`
- [ ] 5.5 `cheatsheets/utils/curl.md` — `curl.se/docs/manpage.html`
- [ ] 5.6 `cheatsheets/utils/ripgrep.md` — `github.com/BurntSushi/ripgrep` (README + man page)
- [ ] 5.7 `cheatsheets/utils/fd.md` — `github.com/sharkdp/fd`
- [ ] 5.8 `cheatsheets/utils/fzf.md` — `github.com/junegunn/fzf` + `man fzf`
- [ ] 5.9 `cheatsheets/utils/ssh.md` — `man.openbsd.org/ssh`, `man.openbsd.org/ssh_config`
- [ ] 5.10 `cheatsheets/utils/rsync.md` — `download.samba.org/pub/rsync/rsync.1`
- [ ] 5.11 `cheatsheets/utils/tree.md` — `mama.indstate.edu/users/ice/tree/` (canonical)
- [ ] 5.12 `cheatsheets/utils/shellcheck-shfmt.md` — `github.com/koalaman/shellcheck/wiki/`, `github.com/mvdan/sh`

## 6. Retrofit languages (15 files)

- [ ] 6.1 `cheatsheets/languages/python.md` — `docs.python.org/3.13/`, PEP index
- [ ] 6.2 `cheatsheets/languages/rust.md` — `doc.rust-lang.org/book/`, `doc.rust-lang.org/std/`
- [ ] 6.3 `cheatsheets/languages/java.md` — `docs.oracle.com/en/java/javase/21/`
- [ ] 6.4 `cheatsheets/languages/typescript.md` — `typescriptlang.org/docs/`
- [ ] 6.5 `cheatsheets/languages/javascript.md` — `developer.mozilla.org/en-US/docs/Web/JavaScript`, ECMA-262 spec
- [ ] 6.6 `cheatsheets/languages/bash.md` — `gnu.org/software/bash/manual/`, POSIX shell at `pubs.opengroup.org`
- [ ] 6.7 `cheatsheets/languages/dart.md` — `dart.dev/language`, `dart.dev/null-safety`
- [ ] 6.8 `cheatsheets/languages/sql.md` — `postgresql.org/docs/`, `sqlite.org/lang.html`
- [ ] 6.9 `cheatsheets/languages/json.md` — RFC 8259 (`datatracker.ietf.org/doc/html/rfc8259`), JSON-Lines spec
- [ ] 6.10 `cheatsheets/languages/yaml.md` — `yaml.org/spec/1.2.2/`
- [ ] 6.11 `cheatsheets/languages/toml.md` — `toml.io/en/v1.0.0`
- [ ] 6.12 `cheatsheets/languages/xml.md` — W3C XML 1.0 spec, libxml2 docs
- [ ] 6.13 `cheatsheets/languages/html.md` — `html.spec.whatwg.org`, MDN HTML reference
- [ ] 6.14 `cheatsheets/languages/css.md` — W3C CSS modules + MDN CSS reference
- [ ] 6.15 `cheatsheets/languages/markdown.md` — `spec.commonmark.org`, GFM spec at `github.github.com/gfm/`

## 7. Retrofit build tools (15 files)

- [ ] 7.1 `cargo.md` — `doc.rust-lang.org/cargo/`
- [ ] 7.2 `npm.md` — `docs.npmjs.com/cli/`
- [ ] 7.3 `pnpm.md` — `pnpm.io/`
- [ ] 7.4 `yarn.md` — `yarnpkg.com/getting-started`, `classic.yarnpkg.com/en/docs/`
- [ ] 7.5 `pip.md` — `pip.pypa.io/en/stable/`
- [ ] 7.6 `pipx.md` — `pipx.pypa.io`
- [ ] 7.7 `uv.md` — `docs.astral.sh/uv/`
- [ ] 7.8 `poetry.md` — `python-poetry.org/docs/`
- [ ] 7.9 `maven.md` — `maven.apache.org/guides/`
- [ ] 7.10 `gradle.md` — `docs.gradle.org/current/userguide/`
- [ ] 7.11 `go.md` — `go.dev/doc/`, `pkg.go.dev/cmd/go`
- [ ] 7.12 `flutter.md` — `docs.flutter.dev`
- [ ] 7.13 `make.md` — `gnu.org/software/make/manual/`
- [ ] 7.14 `cmake.md` — `cmake.org/cmake/help/latest/`
- [ ] 7.15 `ninja.md` — `ninja-build.org/manual.html`

## 8. Retrofit web (6 files)

- [ ] 8.1 `protobuf.md` — `protobuf.dev/programming-guides/proto3/`
- [ ] 8.2 `grpc.md` — `grpc.io/docs/`
- [ ] 8.3 `openapi.md` — `spec.openapis.org/oas/v3.1.0`
- [ ] 8.4 `http.md` — RFC 9110 (HTTP semantics), RFC 9112 (HTTP/1.1), RFC 9113 (HTTP/2) at `datatracker.ietf.org`
- [ ] 8.5 `websocket.md` — RFC 6455 at `datatracker.ietf.org/doc/html/rfc6455`
- [ ] 8.6 `sse.md` — `html.spec.whatwg.org/multipage/server-sent-events.html`

## 9. Retrofit test (6 files)

- [ ] 9.1 `pytest.md` — `docs.pytest.org/en/stable/`
- [ ] 9.2 `junit.md` — `junit.org/junit5/docs/current/user-guide/`
- [ ] 9.3 `cargo-test.md` — `doc.rust-lang.org/cargo/commands/cargo-test.html`, `doc.rust-lang.org/book/ch11-00-testing.html`
- [ ] 9.4 `go-test.md` — `pkg.go.dev/testing`
- [ ] 9.5 `selenium.md` — `selenium.dev/documentation/`
- [ ] 9.6 `playwright.md` — `playwright.dev/docs/intro`

## 10. Wave plan summary

| Wave | Files | Strategy |
|---|---|---|
| Bootstrap | TEMPLATE + INDEX + cheatsheet-methodology.md | this change, manually |
| Foundation | runtime/* + agents/* (6 files) | Wave A — parallel agents with `WebFetch` |
| Wave B | utils/* (12 files) | parallel agents, batches of 4 |
| Wave C | languages/* (15 files) | parallel agents, batches of 5 |
| Wave D | build/* (15 files) | parallel agents, batches of 5 |
| Wave E | web/* + test/* (12 files) | parallel agents, batches of 4 |

Per-wave gate: build the forge image, smoke-test that the retrofitted cheatsheets render correctly inside `/opt/cheatsheets/`. Run `grep -lr 'DRAFT — provenance pending' cheatsheets/` after each wave to track outstanding work.

## 11. Tooling

- [ ] 11.1 Write `scripts/check-cheatsheet-staleness.sh` — script that walks `cheatsheets/`, reads each `**Last updated:** YYYY-MM-DD` line, flags any older than 90 days. Output is human-readable + machine-grep-able. Future enhancement: hit each cited URL with `curl -fsSI` to confirm reachability.
- [ ] 11.2 Add `scripts/check-cheatsheet-staleness.sh` to a project-defined cadence (e.g., a weekly script-runner or a CI-eligible workflow). NOT auto-triggered on commit per cloud-workflow conservation rules.

## 12. Trace + version

- [ ] 12.1 Each retrofit cheatsheet carries `@cheatsheet runtime/cheatsheet-methodology.md` if it cites the methodology itself.
- [ ] 12.2 No version bump now — happens at archive per CLAUDE.md.

## 13. Acceptance criteria

- [ ] 13.1 Every cheatsheet has either `## Provenance` populated OR the DRAFT banner. No silent gap.
- [ ] 13.2 `cheatsheets/INDEX.md` `[DRAFT]` markers stay synchronised with file state.
- [ ] 13.3 New specs after this change archives MUST cite at least one non-DRAFT cheatsheet under `## Sources of Truth` (warning if any cited cheatsheet is DRAFT).
- [ ] 13.4 At least 30 of the 60 existing cheatsheets retrofitted to non-DRAFT state before this change archives. The remaining 30 are tracked in a follow-up sweep change to keep this one tractable.
