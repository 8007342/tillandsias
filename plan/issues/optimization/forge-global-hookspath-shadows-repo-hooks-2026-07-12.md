# Forge dev hosts set a global core.hooksPath that shadows per-repo hooks

- Date: 2026-07-12
- Class: optimization / test-authoring gotcha
- Found on: Forge, while writing scripts/test-git-mirror-ref-convergence.sh (order 301)

## Observation

The forge developer environment has a **global** `core.hooksPath`
(`/home/forge/.cache/tillandsias/git-hooks`). Git's `core.hooksPath`, when set
at global scope, overrides *every* repository's own `hooks/` directory — so a
bare repo's `hooks/post-receive` is silently never invoked on push. This cost
two debug iterations in the ref-convergence fixture: the installed
post-receive hook produced zero output and the relay never fired, with no error.

The mirror container itself has no such global override, so production is
unaffected; this is strictly a **fixture/test-authoring hazard** on forge hosts.

## Reduction

The fixture now defends against it explicitly:
`git -C "$mirror" config core.hooksPath "$mirror/hooks"` in `configure_mirror`,
neutralizing any inherited global value so the repo's own hook runs.

## Smallest Next Action (candidate, not yet promoted)

Any future test that installs and exercises a git hook on a forge host must
pin repo-local `core.hooksPath`. Options to make this loud rather than
per-author-remembered:

- A tiny shared helper (e.g. `scripts/lib-git-fixture.sh`) exposing
  `git_fixture_init_bare <dir>` that always sets repo-local hooksPath, reused by
  hook-exercising fixtures.
- Or a shape-litmus asserting hook fixtures set `core.hooksPath` locally.

Left as a research note; not promoted to a ready packet this cycle (forge
single-packet budget already spent on order 301).
