# Linux data root contains a stray empty `.git` directory (2026-07-20)

- order: 456
- status: ready
- **Class**: exploration (creator unknown)
- **Severity**: P3 / low priority
- **Found**: Linux coordinator host, 2026-07-20
- **Owner host**: linux

## Symptom and concrete evidence

`~/.local/share/tillandsias/.git` exists on the Linux coordinator host as an
empty directory. It is not a repository:

```text
git -C ~/.local/share/tillandsias log
fatal: not a git repository (or any of the parent directories): .git
```

Some Git invocation, directory setup, or mount-point creation has therefore
targeted the Tillandsias data root instead of the intended repository path and
left debris behind.

## Leading hypothesis and how to confirm it

The creator is unknown. Search the codebase for code that joins the runtime
data root with `.git`, and trace every Git command and mount declaration whose
working directory or target can resolve to `~/.local/share/tillandsias`.
Instrument or reproduce fresh initialization to identify which path creates
the directory before removing the symptom.

## Blast radius

An empty `.git` directory in a parent of runtime paths can interfere with Git
repository discovery for processes running beneath the data root. It also
masks a more important path-selection bug: something that intended to create
or use a repository elsewhere targeted the data root, and silently cleaning
the debris without finding that creator would allow the bug to recur.

## Smallest correct fix and exit criteria

Identify and correct the creator so no operation targets the data root as a Git
directory. Add `--init` or doctor cleanup for an existing empty stray `.git`
directory, without deleting a non-empty or valid repository, and make
doctor/status report the condition when found.

Closure is verifiable when a fresh runtime bring-up leaves no `.git` entry in
the Tillandsias data root, while a fixture-created stray empty `.git` directory
is flagged by doctor/status and safely removed by the documented cleanup path.
