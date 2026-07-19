# Forge-base image: missing CLI utilities (cmp, diff, file, patch)

- date: 2026-07-18
- filed_by: linux-forge-opencode-20260718T0509Z (meta-orchestration)
- host: forge
- order: 412
- status: ready

## What happened

On a clean host with fresh tokens, the meta-orchestration boundary guard
verify failed with:

```
scripts/meta-orchestration-worktree-guard.sh: line 88: cmp: command not found
error: worktree differs from startup boundary
```

This is a FALSE verdict — the worktree was clean. The guard hard-depends on
`cmp` (from diffutils) which is absent from the forge-base image. The same
gap blocks agents from using `diff`, `patch`, `file`, and other fundamental
CLI tools.

## Missing packages

From the Fedora 44 repos (already available, just not installed):

| Package | Provides | Why needed |
|---------|----------|------------|
| diffutils | cmp, diff, sdiff | Boundary guard, ad-hoc comparison |
| patch | patch | Applying diffs |
| file | file | File type detection (build.sh --check) |
| binutils | xxd, strings (already present) | Hex debugging |
| gettext | envsubst | Template variable substitution |
| diffstat | diffstat | Diff summary formatting |

## Existing related work

- order 240 (forge-build-check-tooling-gap): completed for build.sh path,
  but the missing packages were never added to the image recipe
- plan/issues/forge-build-check-tooling-gap-2026-07-08.md: addendums
  2026-07-15, 2026-07-16, 2026-07-18 all document the same gap
- Guard-side fallback (same_file() helper) is an alternative reduction but
  does not solve the agent-facing gap (diff/patch/file still missing)

## Smallest next action

Add `diffutils patch file gettext diffstat` to the `microdnf install` line
in `images/default/Containerfile.base`. These are tiny Fedora packages with
zero image-size concerns. Pin with a litmus or the existing
litmus:forge-lsp-availability-shape extended to check PATH availability.
