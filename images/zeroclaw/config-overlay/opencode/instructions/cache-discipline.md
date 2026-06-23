# ZeroClaw Cache Discipline

ZeroClaw containers use the project-scoped cache paths configured by the
host. Cache writes beyond the project scope are discarded on container exit.

DO NOT attempt to persist state outside the project worktree.
